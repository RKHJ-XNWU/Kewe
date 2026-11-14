/* ============================================================
 * dsc-duplex.js —— 豆包端到端实时语音（Seeduplex）全双工通话前端
 * ------------------------------------------------------------
 * 链路：
 *   麦克风 → WebAudio 采集 → 降采样到 16k → 20ms 一帧 PCM16
 *        → base64 → WebSocket（本地服务代理）→ 火山引擎
 *   火山引擎 → response.output_audio.delta（PCM16 24k）
 *        → AudioBuffer 队列播放；同时把字幕推到通话面板
 *
 * 关键约束（来自官方文档）：
 *   · 输入采样率只支持 16000，输出只支持 24000
 *   · 每帧建议 20ms（16k / int16 → 640 字节）
 *   · 关麦后必须发 input_audio_mute.commit，否则服务端超时无响应
 *   · 打断用 response.cancel
 *   · model 固定 1.2.6.1（由后端补齐，前端不必传）
 *
 * 本文件不伪造任何成功：连不上、鉴权失败、服务端报错都会原样显示。
 * ============================================================ */
(function () {
    'use strict';

    var CFG_API = '/api/doubao/config';
    var WS_PATH = '/api/doubao/realtime';

    var IN_RATE = 16000;
    var OUT_RATE = 24000;
    var FRAME = 320;          // 16000 * 0.02 = 320 samples = 640 bytes
    var MAX_BUFFERED = 512 * 1024;

    var D = {
        ws: null,
        active: false,
        connecting: false,
        micOn: true,
        // ★ 音色渲染：默认播放豆包端到端回传的原生 PCM（豆包官方原生音色）。
        //   端到端模型直接生成带情绪语气的语音，不再走 Edge TTS 二次合成。
        //   只有显式把 edgeVoice 设成 true 才回到 Edge TTS 兜底。
        edgeVoice: false,
        // 本轮是否收到过豆包原生音频（output_audio.delta）。
        // 收到过就用豆包 vivi 音色；没收到则回落到 Edge TTS 兜底，避免 AI 全程哑巴。
        gotAudio: false,
        stream: null,
        ctx: null,
        src: null,
        proc: null,
        inRate: 48000,
        pend: [],
        playCtx: null,
        nextTime: 0,
        sources: [],
        lang: 'zh',
        voice: '',
        // 待朗读文本：一轮回复可能分多段返回，先攒起来，等 response.done
        // 一次性朗读，避免同一句话被读两遍。
        pendingSay: '',
        // 兜底朗读定时器：个别情况下服务端不发 response.done，
        // 只发 output_text.done。没有这个兜底，文本攒住了却永远不出声
        //（表现就是「通话一直不说话」）。攒到文本后 2.5 秒仍未收到
        // response.done，就自己读一次。
        sayTimer: null,
        // 上一条已显示的气泡文本：服务端偶尔把同一句发两遍，界面上也要去重
        lastBubbleText: '',
        // ★ 打断修复：追踪当前/已作废的 response_id，用于丢弃打断后旧 response
        //   迟到的音频/文字残留（否则旧音频会在打断后继续响、旧文字被读出来）。
        activeRid: null,
        staleRid: null,
        instructions: '',
        sending: 0,
        reopened: 0,
        // 通话记录：一次通话 = 一次保存（纯文本），通话结束写入 kewe/data/voice/
        history: [],
        callSeq: 0,
        // 用户语音转文字的流式累计（delta 逐字下发，completed 不带文本字段）
        userTranscript: '',
        // 打断后需要丢弃的回声窗口帧数：AI 说话时的回声若继续上行，
        // 会被服务端 VAD 误判为「还在说话」，导致打断后识别不到用户语音。
        // 打断后丢弃约 200ms（10 帧 × 20ms）采集，让回声消散再恢复上行。
        skipFrames: 0
    };

    function $(id) { return document.getElementById(id); }

    function T(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    function toast(msg, type) {
        try {
            if (typeof window.dscToast === 'function') { window.dscToast(msg, type); return; }
        } catch (e) {}
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DUPLEX]', msg); return; }
        var t = el('div', 'dsc-toast ' + (type || ''), msg);
        wrap.appendChild(t);
        setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 4000);
    }

    function uiStatus(text, cls) {
        var n = $('dscDbCallStatus');
        if (n) n.textContent = text;
        var orb = $('dscDbCallOrb');
        if (orb) orb.className = 'dsc-db-call-orb' + (cls ? ' ' + cls : '');
    }

    function uiBubble(kind, text) {
        // 不画气泡框：改成纯文本字幕行（用户明确要求禁止气泡框）
        var log = $('dscDbCallLog');
        if (log) {
            var b = el('div', 'dsc-call-line ' + kind, text);
            log.appendChild(b);
            log.scrollTop = log.scrollHeight;
        }
        // 记录到通话历史（纯文本），通话结束时由上层保存到 kewe/data/voice/*.sts
        if (text && kind !== 'sys') {
            D.callSeq++;
            D.history.push({
                role: (kind === 'user') ? 'user' : 'ai',
                text: String(text),
                seq: D.callSeq,
                at: Date.now()
            });
        }
    }

    function newId() {
        return 'ev_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    }

    // ------------------------------------------------------------
    // 编解码
    // ------------------------------------------------------------
    function b64FromBytes(bytes) {
        var bin = '';
        for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin);
    }

    function bytesFromB64(b64) {
        var bin = atob(b64);
        var out = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    /// 线性插值降采样
    function downsample(buf, inRate, outRate) {
        if (outRate >= inRate) return buf;
        var ratio = inRate / outRate;
        var outLen = Math.round(buf.length / ratio);
        var out = new Float32Array(outLen);
        for (var i = 0; i < outLen; i++) {
            var pos = i * ratio;
            var i0 = Math.floor(pos);
            var i1 = Math.min(i0 + 1, buf.length - 1);
            var f = pos - i0;
            out[i] = buf[i0] * (1 - f) + buf[i1] * f;
        }
        return out;
    }

    // ------------------------------------------------------------
    // 发送
    // ------------------------------------------------------------
    function send(obj) {
        if (!D.ws || D.ws.readyState !== 1) return false;
        try {
            D.ws.send(JSON.stringify(obj));
            return true;
        } catch (e) {
            return false;
        }
    }

    function sendPcm(f32) {
        if (!D.ws || D.ws.readyState !== 1) return;
        // 上行拥塞时丢弃本帧，避免内存堆积导致越来越延迟
        if (D.ws.bufferedAmount > MAX_BUFFERED) return;
        var i16 = new Int16Array(f32.length);
        for (var i = 0; i < f32.length; i++) {
            var v = Math.max(-1, Math.min(1, f32[i]));
            i16[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
        }
        var bytes = new Uint8Array(i16.buffer);
        D.sending++;
        send({
            type: 'input_audio_buffer.append',
            event_id: newId(),
            audio: b64FromBytes(bytes)
        });
    }

    // ------------------------------------------------------------
    // 采集
    // ------------------------------------------------------------
    function onAudioProcess(ev) {
        if (!D.active || !D.micOn) return;
        // 打断后的回声窗口：丢弃指定帧数，避免 AI 回声被服务端误判
        if (D.skipFrames > 0) { D.skipFrames--; return; }
        var input = ev.inputBuffer.getChannelData(0);
        var f32 = downsample(input, D.inRate, IN_RATE);
        for (var i = 0; i < f32.length; i++) D.pend.push(f32[i]);
        while (D.pend.length >= FRAME) {
            var chunk = D.pend.slice(0, FRAME);
            D.pend = D.pend.slice(FRAME);
            sendPcm(chunk);
        }
    }

    // ------------------------------------------------------------
    // 播放
    // ------------------------------------------------------------
    function playPcm(b64) {
        var ctx = D.playCtx;
        if (!ctx) return;
        var u8 = bytesFromB64(b64);
        if (u8.length < 2) return;
        var n = u8.length >> 1;
        var buf = ctx.createBuffer(1, n, OUT_RATE);
        var ch = buf.getChannelData(0);
        for (var i = 0; i < n; i++) {
            var v = (u8[2 * i] | (u8[2 * i + 1] << 8));
            if (v >= 0x8000) v -= 0x10000;
            ch[i] = v / 32768;
        }
        var src = ctx.createBufferSource();
        src.buffer = buf;
        src.connect(ctx.destination);
        var t = Math.max(ctx.currentTime + 0.03, D.nextTime || 0);
        try { src.start(t); } catch (e) { return; }
        D.nextTime = t + buf.duration;
        D.sources.push(src);
        src.onended = function () {
            var k = D.sources.indexOf(src);
            if (k >= 0) D.sources.splice(k, 1);
        };
    }

    function stopPlayback() {
        for (var i = 0; i < D.sources.length; i++) {
            try { D.sources[i].stop(); } catch (e) {}
        }
        D.sources = [];
        D.nextTime = 0;
    }

    // ------------------------------------------------------------
    // 朗读调度
    // ------------------------------------------------------------
    /// 把攒好的文本交给上层朗读，并清空队列（保证同一句只读一次）
    function sayNow() {
        if (D.sayTimer) { clearTimeout(D.sayTimer); D.sayTimer = null; }
        var sayText = String(D.pendingSay || '').trim();
        D.pendingSay = '';
        // 有原生音频就用豆包 vivi 音色（已由 playPcm 播放），这里只做兜底：
        // 只有「整轮都没收到任何音频」时才把文本交给上层用 Edge TTS 朗读，
        // 避免豆包音色与 Edge 音色叠加读两遍。
        if (sayText && !D.gotAudio && window.dscDuplex &&
            typeof window.dscDuplex.onText === 'function') {
            try { window.dscDuplex.onText(sayText); } catch (e) {}
        }
        D.gotAudio = false;
    }

    /// 延时兜底：2.5 秒内没等到 response.done，就自己读一次
    function saySoon() {
        if (D.sayTimer) clearTimeout(D.sayTimer);
        D.sayTimer = setTimeout(function () {
            D.sayTimer = null;
            // 兜底：个别情况下服务端只发 output_text.done 不发 response.done / 音频，
            // 攒到文本 3.5 秒仍未收到音频就自己读一次（Edge TTS），绝不装高冷。
            if (D.pendingSay && !D.gotAudio) sayNow();
        }, 3500);
    }

    // ------------------------------------------------------------
    // 下行事件
    // ------------------------------------------------------------
    function _staleEvent(m) {
        var rid = m && (m.response_id || m.id || '');
        return !!(rid && D.staleRid && rid === D.staleRid);
    }

    function onMessage(ev) {
        var m;
        try { m = JSON.parse(ev.data); } catch (e) { return; }
        var t = m.type || '';

        if (t === 'session.created') {
            uiStatus(T('接続済み（全双工）'), 'listening');
            return;
        }
        if (t === 'session.closed') {
            uiStatus(T('セッション終了'), '');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.started') {
            D.userTranscript = '';
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.delta') {
            var dt = m.delta || m.text || '';
            if (dt) {
                D.userTranscript += dt;
                uiStatus(T('聞き取り中…') + ' ' + dt, 'listening');
            }
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.completed') {
            // 官方协议：completed 事件不带文本字段，文本来自 delta 的流式累计
            var ut = m.transcript || m.text || D.userTranscript || '';
            D.userTranscript = '';
            if (ut) uiBubble('user', ut);
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.failed') {
            uiBubble('sys', T('音声認識に失敗しました'));
            return;
        }
        if (t === 'response.output_text.delta') {
            if (_staleEvent(m)) return;   // 旧 response 残留文字，丢弃
            var dl = m.delta || '';
            if (dl) {
                if (!D.curText) D.curText = '';
                D.curText += dl;
                uiStatus(T('応答中…'), 'thinking');
            }
            return;
        }
        if (t === 'response.output_text.done') {
            if (_staleEvent(m)) { D.curText = ''; return; }   // 旧 response 残留，丢弃
            var tx = m.text || D.curText || '';
            D.curText = '';
            if (tx) {
                // 同一句重复到达时不再重复画气泡
                if (tx !== D.lastBubbleText) {
                    uiBubble('ai', tx);
                    D.lastBubbleText = tx;
                }
                // ★ 这里只把文字攒进待朗读队列，不立刻回调朗读。
                //   原先在本事件里直接朗读，一轮回复若分多段返回，
                //   就会被读两遍（用户反馈的「一句话说两次」）。
                //   现在统一等 response.done 再读一次，干净利落。
                // 拼装待朗读文本，三种情况分别处理，确保同一句不会读两遍：
                //   1) 还没有内容          → 直接作为第一段
                //   2) 新文本包含已有内容  → 用新文本替换（服务端重复发整句）
                //   3) 已有内容不含新片段  → 追加（正常的后续分段）
                var prevSay = D.pendingSay;
                if (!prevSay) {
                    D.pendingSay = tx;
                } else if (tx.indexOf(prevSay) === 0) {
                    D.pendingSay = tx;
                } else if (prevSay.indexOf(tx) < 0) {
                    D.pendingSay = prevSay + tx;
                }
                saySoon();
            }
            return;
        }
        if (t === 'response.output_audio.started') {
            var rid0 = m && (m.response_id || m.id || '');
            if (rid0) {
                // 新一轮音频开始：清除作废标记，记录当前 response
                D.staleRid = null;
                D.activeRid = rid0;
            }
            uiStatus(T('読み上げ中…'), 'speaking');
            return;
        }
        if (t === 'response.output_audio.delta') {
            if (_staleEvent(m)) return;   // 旧 response 的残留音频，丢弃不播
            var rid2 = m && (m.response_id || m.id || '');
            if (rid2 && !D.activeRid) { D.activeRid = rid2; D.staleRid = null; }
            // 播放豆包端到端回传的原生 PCM（含情绪、语气，官方原生 vivi 音色）
            // 官方协议：输出音频 Base64 在 delta 字段下行（上行才用 audio 字段）。
            // 这里兼容 delta / audio 两种字段名，避免因字段名不匹配导致 AI 全程不出声。
            var audioB64 = m.delta || m.audio || '';
            if (audioB64) { D.gotAudio = true; playPcm(audioB64); }
            return;
        }
        if (t === 'response.output_audio.done') {
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'response.done') {
            if (_staleEvent(m)) return;   // 旧 response 的 done，丢弃
            uiStatus(T('聞き取り中…'), 'listening');
            D.staleRid = null;
            D.activeRid = null;
            // 一轮回复彻底结束，把攒好的整段文本交出去朗读（只读一次）。
            sayNow();
            return;
        }
        if (t === 'response.canceled') {
            // 打断请求的确认（ack）
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'response.function_call_arguments.done') {
            uiBubble('sys', T('モデルがツール呼び出しを要求しました（未実装のため実行しません）'));
            return;
        }
        if (t === 'error') {
            var msg = m.message || (m.error && (m.error.message || m.error)) || T('不明なエラー');
            var code = m.code || '';
            if (code === 'upstream_connect_failed') {
                uiBubble('sys', T('接続に失敗しました：{0}', msg));
                uiStatus(T('接続失敗'), '');
            } else {
                uiBubble('sys', T('豆包エラー：{0}', msg));
            }
            return;
        }
    }

    // ------------------------------------------------------------
    // 启动 / 停止
    // ------------------------------------------------------------
    async function start() {
        if (D.active) return;
        if (D.connecting) return;
        D.connecting = true;
        D.curText = '';
        D.history = [];
        D.callSeq = 0;
        D.userTranscript = '';
        uiStatus(T('接続しています…'), 'thinking');

        try {
            var cfg = await fetch(CFG_API, { cache: 'no-store' }).then(function (r) { return r.json(); });
            // Seeduplex 认的是豆包语音控制台的 Key（或旧版 AppId+Token），
            // 方舟的 Key 通常会 401，因此这里不能只看 hasKey。
            var hasVoiceKey = !!(cfg && (cfg.hasDuplexKey || cfg.hasS2s));
            if (!cfg || !hasVoiceKey) {
                uiBubble('sys', T('⚠️ 音声サービス用の Key が未設定です（設定で豆包音声 API Key を入力してください）'));
                uiStatus(T('未設定'), '');
                D.connecting = false;
                return;
            }
            D.lang = cfg.duplexLang || 'zh';
            // ★ 修复音色切换失效：startCall() 已通过 setVoice() 把用户所选音色写入 D.voice，
            //   这里绝不能再用配置值覆盖它，否则切换音色永远回到默认 vivi。
            //   仅当用户从未选过音色（D.voice 为空）时才回落到配置默认值。
            if (!D.voice) if (!D.voice) D.voice = cfg.duplexVoice || '';
            D.instructions = cfg.duplexInstructions || '';
        } catch (e) {
            uiBubble('sys', T('設定の読み込みに失敗しました：{0}', e.message || e));
            D.connecting = false;
            return;
        }

        // ---- 音频采集 ----
        try {
            D.stream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: true,
                    noiseSuppression: true,
                    autoGainControl: true,
                    channelCount: 1
                }
            });
        } catch (e) {
            uiBubble('sys', T('マイクを使用できません：{0}', e.message || e));
            uiStatus(T('マイク使用不可'), '');
            D.connecting = false;
            return;
        }

        try {
            var AC = window.AudioContext || window.webkitAudioContext;
            D.ctx = new AC();
            D.inRate = D.ctx.sampleRate || 48000;
            D.src = D.ctx.createMediaStreamSource(D.stream);
            D.proc = D.ctx.createScriptProcessor(2048, 1, 1);
            D.proc.onaudioprocess = onAudioProcess;
            D.src.connect(D.proc);
            D.proc.connect(D.ctx.destination);
            D.playCtx = new AC();
            D.nextTime = 0;
            D.sources = [];
            // 确保两个 AudioContext 都处于 running 状态，否则 playPcm 静默无声（AI 不说话）
            if (D.ctx && D.ctx.state === 'suspended' && D.ctx.resume) { try { D.ctx.resume(); } catch (e) {} }
            if (D.playCtx && D.playCtx.state === 'suspended' && D.playCtx.resume) { try { D.playCtx.resume(); } catch (e) {} }
        } catch (e) {
            uiBubble('sys', T('音声処理の初期化に失敗しました：{0}', e.message || e));
            cleanup();
            D.connecting = false;
            return;
        }

        // ---- WebSocket ----
        var proto = (location.protocol === 'https:') ? 'wss:' : 'ws:';
        var q = [];
        if (D.lang) q.push('lang=' + encodeURIComponent(D.lang));
        if (D.voice) q.push('voice=' + encodeURIComponent(D.voice));
        if (D.instructions) q.push('instructions=' + encodeURIComponent(D.instructions));
        // Edge 接管音色：告诉后端不要指定豆包音色（账号无该音色权限时会直接被拒）
        if (D.edgeVoice) q.push('edge=1');
        var url = proto + '//' + location.host + WS_PATH + (q.length ? ('?' + q.join('&')) : '');

        var ws;
        try {
            ws = new WebSocket(url);
        } catch (e) {
            uiBubble('sys', T('WebSocket を作成できません：{0}', e.message || e));
            cleanup();
            D.connecting = false;
            return;
        }
        D.ws = ws;
        ws.binaryType = 'arraybuffer';

        ws.onopen = function () {
            D.active = true;
            D.connecting = false;
            uiStatus(T('接続済み（全双工）'), 'listening');
            uiBubble('sys', T('全双工通話を開始しました。話しかけてください。'));

            // 必ず session.create を送る（model / 采样率 / 音色はバックエンドが補完）
            send({
                type: 'session.create',
                session: {
                    model: '1.2.6.1',
                    audio: {
                        input: { format: { type: 'pcm', rate: IN_RATE } },
                        output: {
                            format: { type: 'pcm_s16le', rate: OUT_RATE },
                            // Edge 接管音色时不再指定豆包音色（账号没有该音色权限，
                            // 带上去反而会让 session.create 被拒），留空由服务端给默认值。
                            voice: (D.edgeVoice ? undefined : (D.voice || 'zh_female_vv_uranus_bigtts'))
                        }
                    },
                    instructions: D.instructions || undefined
                }
            });
        };

        ws.onmessage = onMessage;

        ws.onerror = function () {
            uiBubble('sys', T('接続でエラーが発生しました（Key やネットワークを確認してください）'));
            uiStatus(T('接続エラー'), '');
        };

        ws.onclose = function (ev) {
            var wasActive = D.active;
            D.active = false;
            D.connecting = false;
            D.ws = null;
            if (wasActive) {
                uiStatus(T('通話を終了しました'), '');
                if (ev && ev.code && ev.code !== 1000) {
                    uiBubble('sys', T('接続が切断されました（code={0}）', ev.code));
                }
            }
        };
    }

    function cleanup() {
        try { if (D.proc) { D.proc.onaudioprocess = null; D.proc.disconnect(); } } catch (e) {}
        D.proc = null;
        try { if (D.src) D.src.disconnect(); } catch (e) {}
        D.src = null;
        try { if (D.ctx && D.ctx.close) D.ctx.close(); } catch (e) {}
        D.ctx = null;
        try { if (D.playCtx && D.playCtx.close) D.playCtx.close(); } catch (e) {}
        D.playCtx = null;
        try { if (D.stream) D.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        D.stream = null;
        D.pend = [];
        stopPlayback();
    }

    function stop() {
        D.pendingSay = '';
        D.gotAudio = false;   // 断开连接：丢弃未朗读的旧句子
        if (D.sayTimer) { clearTimeout(D.sayTimer); D.sayTimer = null; }
        if (D.ws) {
            try { send({ type: 'session.close' }); } catch (e) {}
            try { D.ws.close(1000, 'client close'); } catch (e) {}
        }
        D.ws = null;
        D.active = false;
        D.connecting = false;
        cleanup();
        uiStatus(T('待機中'), '');
    }

    function setMic(on) {
        D.micOn = !!on;
        // 文档要求：关麦后必须显式发送静音事件，否则服务端会超时
        send({ type: on ? 'input_audio_unmute.commit' : 'input_audio_mute.commit', event_id: newId() });
        try {
            if (D.stream) D.stream.getAudioTracks().forEach(function (t) { t.enabled = D.micOn; });
        } catch (e) {}
        uiStatus(D.micOn ? T('聞き取り中…') : T('ミュート中'), D.micOn ? 'listening' : '');
        return D.micOn;
    }

    function cancel() {
        D.pendingSay = '';
        D.gotAudio = false;   // 打断：未朗读的旧句子一并作废
        if (D.sayTimer) { clearTimeout(D.sayTimer); D.sayTimer = null; }
        // ★ 把当前 response 标记为作废，打断后迟到的旧音频/旧文字一律丢弃
        if (D.activeRid) D.staleRid = D.activeRid;
        D.activeRid = null;
        stopPlayback();
        // ★ 清空本地采集残留：AI 说话时的回声残留在 pend 里，打断后继续上行
        //   会让服务端 VAD 误判为「还在说话」，表现就是打断后识别不到文字。
        D.pend = [];
        D.userTranscript = '';
        // ★ 打断后丢弃约 200ms（10 帧）采集，让 AI 回声消散后再恢复上行。
        //   否则打断瞬间扬声器里的 AI 声音会经麦克风回灌，服务端 VAD 误判。
        D.skipFrames = 10;
        // ★ 打断只发 response.cancel（官方 §2.2.12：取消进行中的响应，便于下一次识别）。
        //   input_audio_buffer.clear 在 Seeduplex 协议里根本不存在，
        //   发出去会被服务端 45000000「unknown event name」打回，这就是打断报错的根因。
        send({ type: 'response.cancel', event_id: newId() });
        // ★ 打断后无条件恢复麦克风（不管之前是否静音），并显式发送取消静音事件，
        //   让服务端 VAD 回到聆听态，能立即收到新一轮语音。
        D.micOn = true;
        send({ type: 'input_audio_unmute.commit', event_id: newId() });
        try {
            if (D.stream) D.stream.getAudioTracks().forEach(function (t) { t.enabled = true; });
        } catch (e) {}
        uiStatus(T('聞き取り中…'), 'listening');
    }

    // ★ 切换官方音色：通话建立前设置 D.voice；通话中则发送 session.update 即时生效
    function setVoice(v) {
        var vid = String(v || '').trim();
        if (!vid) return;
        D.voice = vid;
        if (D.ws && D.ws.readyState === 1) {
            send({ type: 'session.update', session: { voice: vid }, event_id: newId() });
        }
    }

    function sendText(text) {
        var v = String(text || '').trim();
        if (!v) return false;
        stopPlayback();
        // ★ 文本输入的正确事件是 conversation.item.create（role=user + input_text），
        //   模型收到这条 user 消息后会「理解并自动回复」。
        //   之前的 speech_text_buffer.commit 官方定义是「打招呼 / 直接 TTS 朗读」，
        //   所以会出现「你发的文字被原样读出来」而不是被理解回复。
        send({
            type: 'conversation.item.create',
            event_id: newId(),
            items: [{
                type: 'message',
                role: 'user',
                content: [{ type: 'input_text', text: v }]
            }]
        });
        uiBubble('user', v);
        return true;
    }

    window.dscDuplex = {
        // 由 dsc-doubao.js 覆盖：整句确定后回调，用于 Edge TTS 流式朗读
        onText: null,
        start: start,
        stop: stop,
        cancel: cancel,
        setMic: setMic,
        sendText: sendText,
        setVoice: setVoice,
        getHistory: function () { return D.history; },
        setVoice: function (v) { D.voice = String(v == null ? '' : v).trim(); },
        isActive: function () { return !!D.active; },
        isConnecting: function () { return !!D.connecting; }
    };

    // ============================================================
    // RTC AI 音视频互动（StartVoiceChat / StopVoiceChat）
    // ------------------------------------------------------------
    // 本模块只做「服务端任务编排」：把 Seeduplex 端到端模型挂到 RTC 房间。
    // 浏览器侧要真正收发音视频，必须用火山引擎官方 RTC Web SDK 加入同一房间，
    // 该 SDK 未随本项目分发——所以这里绝不会假装「已经能通话」。
    // 鉴权用 AccessKey/SecretKey 在 Dart 侧做 V4 签名，前端永远拿不到密钥。
    // ============================================================
    var R = {
        taskId: '',
        roomId: '',
        appId: '',
        busy: false,
        onLog: null,
        onStatus: null
    };

    function rlog(msg, kind) {
        // 回调签名是 addBubble(kind, text)，这里必须按 (kind, text) 传，
        // 否则消息与类名会互换（气泡里只剩 'sys'）。
        if (typeof R.onLog === 'function') {
            try { R.onLog(kind || 'sys', msg); } catch (e) {}
        }
    }

    function rstatus(text, cls) {
        if (typeof R.onStatus === 'function') {
            try { R.onStatus(text, cls || ''); } catch (e) {}
        }
    }

    function bind(logFn, statusFn) {
        R.onLog = (typeof logFn === 'function') ? logFn : null;
        R.onStatus = (typeof statusFn === 'function') ? statusFn : null;
    }

    async function probe() {
        try {
            var r = await fetch('/api/doubao/realtime/status', { cache: 'no-store' });
            var d = await r.json();
            return d || {};
        } catch (e) {
            return { ok: false, error: (e && e.message) || String(e) };
        }
    }

    async function startRtc(opts) {
        opts = opts || {};
        if (R.busy) return { ok: false, error: 'busy' };
        R.busy = true;
        rstatus(T('RTC タスクを起動しています…'), 'thinking');
        var body = {
            roomId: String(opts.roomId || '').trim(),
            userId: String(opts.userId || 'dsc_user').trim(),
            botUserId: String(opts.botUserId || 'dsc_bot').trim(),
            mixedMode: !!opts.mixedMode,
            lang: String(opts.lang || 'zh'),
            voice: String(opts.voice || '').trim(),
            instructions: String(opts.instructions || '').trim(),
            taskId: String(opts.taskId || '').trim(),
            llmModel: String(opts.llmModel || '').trim()
        };
        try {
            var r = await fetch('/api/doubao/rtc/start', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            var d = null;
            try { d = await r.json(); } catch (e2) { d = null; }
            if (d && d.success) {
                R.taskId = d.taskId || body.taskId || '';
                R.roomId = body.roomId;
                R.appId = d.appId || '';
                rlog(T('✅ RTC タスクを起動しました（TaskId: {0}）', R.taskId), 'ai');
                if (d.requestId) rlog('RequestId: ' + d.requestId, 'sys');
                rstatus(T('RTC 起動済み'), 'listening');
                return { ok: true, taskId: R.taskId, requestId: d.requestId || '' };
            }
            var em = (d && (d.error || d.message)) || T('不明なエラー');
            rlog(T('❌ RTC 起動失敗：{0}', T(String(em))), 'sys');
            rstatus(T('RTC 起動失敗'), '');
            return { ok: false, error: em, raw: d };
        } catch (e) {
            var m2 = (e && e.message) || String(e);
            rlog(T('❌ RTC 起動失敗：{0}', m2), 'sys');
            rstatus(T('RTC 起動失敗'), '');
            return { ok: false, error: m2 };
        } finally {
            R.busy = false;
        }
    }

    async function stopRtc() {
        var taskId = R.taskId;
        if (!taskId) {
            rlog(T('停止する RTC タスクがありません'), 'sys');
            rstatus(T('RTC タスクは起動していません'), '');
            return { ok: false, error: 'no task' };
        }
        try {
            var r = await fetch('/api/doubao/rtc/stop', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ taskId: taskId, roomId: R.roomId })
            });
            var d = null;
            try { d = await r.json(); } catch (e2) { d = null; }
            if (d && d.success) {
                rlog(T('✅ RTC タスクを停止しました'), 'ai');
                rstatus(T('待機中'), '');
                R.taskId = '';
                return { ok: true };
            }
            var em = (d && (d.error || d.message)) || T('不明なエラー');
            rlog(T('❌ RTC 停止失敗：{0}', T(String(em))), 'sys');
            return { ok: false, error: em };
        } catch (e) {
            var m3 = (e && e.message) || String(e);
            rlog(T('❌ RTC 停止失敗：{0}', m3), 'sys');
            return { ok: false, error: m3 };
        }
    }

    window.dscRtc = {
        bind: bind,
        probe: probe,
        start: startRtc,
        stop: stopRtc,
        taskId: function () { return R.taskId; },
        isBusy: function () { return !!R.busy; }
    };
})();
