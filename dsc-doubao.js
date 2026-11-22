/* ============================================================
 * dsc-doubao.js —— 豆包（火山方舟）前端
 *   1) 「⋯」メニューに 4 つの機能を追加
 *      豆包で画像生成 / 豆包で動画生成 / 豆包ポッドキャスト / 豆包音声通話
 *   2) 設定ダイアログに豆包専用カード（API Key・モデル・音色・自動ルーティング）
 *   3) 生成物はすべて ds_files/blob に保存され、そのまま再生・DL できる
 *   4) 失敗は必ずそのまま表示する（成功の捏造はしない）
 *
 * バックエンド: /api/doubao/*
 *   config / models / image / video / video/status / video/tasks /
 *   tts / podcast / asr / voice/turn / chat / analyze-audio
 * ============================================================ */
(function () {
    'use strict';

    // ============================================================
    // ★★★ 中转站（st 维度）前端全局停用（隐私整改）★★★
    //   与后端 relay.dart 的 RELAY_DISABLED 对应。恒为 true，不提供
    //   任何重新开启入口。DeepSeek(ds)/豆包(db) 两维度不受影响。
    // ============================================================
    window.DSC_RELAY_DISABLED = true;
    window.DSC_RELAY_DISABLED_MSG =
        '中转站（st 维度）API 已停止服务：因该渠道存在泄露用户聊天隐私的风险，' +
        '现已从前端到后端全面停用，无法再调用任何中转站模型。' +
        'DeepSeek 与豆包维度可正常使用。';

    // 统一弹窗报错：优先用自定义模态框，退化到 alert，再退化到 toast。
    // 保证用户一点击任何 st 入口都会被明确告知“已停用”。
    window.dscRelayBlockedAlert = function () {
        try {
            var existing = document.getElementById('dscRelayBlockedModal');
            if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
            var ov = document.createElement('div');
            ov.id = 'dscRelayBlockedModal';
            ov.className = 'dsc-modal-overlay open';
            ov.style.zIndex = '100090';
            ov.innerHTML =
                '<div class="dsc-modal" style="max-width:420px;">' +
                '<div class="dsc-modal-title">⛔ 该渠道已停用</div>' +
                '<div style="line-height:1.7;padding:6px 4px 14px;">' +
                window.DSC_RELAY_DISABLED_MSG +
                '</div>' +
                '<div class="dsc-modal-footer">' +
                '<button type="button" class="dsc-btn primary" id="dscRelayBlockedOk">我知道了</button>' +
                '</div></div>';
            document.body.appendChild(ov);
            var close = function () { if (ov.parentNode) ov.parentNode.removeChild(ov); };
            ov.addEventListener('click', function (e) { if (e.target === ov) close(); });
            var ok = ov.querySelector('#dscRelayBlockedOk');
            if (ok) ok.addEventListener('click', close);
            try { if (window.vibrate) window.vibrate(30); } catch (e) {}
            return;
        } catch (e) {}
        try { alert(window.DSC_RELAY_DISABLED_MSG); return; } catch (e2) {}
        try { toast(window.DSC_RELAY_DISABLED_MSG, 'error'); } catch (e3) {}
    };

    // 判定一个模型是否属于被停用的中转站目录（预置 + 自定义）。
    window.dscIsBlockedRelayModel = function (model) {
        try {
            if (window.__dscIsRelayModel && window.__dscIsRelayModel(model)) return true;
        } catch (e) {}
        return false;
    };

    var API = '/api/doubao';
    var S = {
        cfg: null,
        catalog: [],
        styles: [],
        imgBusy: false,
        vidBusy: false,
        podBusy: false,
        ttsBusy: false,
        pollTimer: null,
        call: null,
        asrBusy: false,
        editBusy: false
    };

    // 豆包联网内容插件信源（仅 douyin 由 UI 控制，其余保留后端值）
    var DB_WEB_SOURCES = [];

    // ------------------------------------------------------------
    // 抖音百科搜索「总开关」（输入框下方工具栏的豆包按钮）
    //   总闸关闭时，设置里的「抖音百科を情報源にする」开关一律无效：
    //   后端 dbWikiEffectiveSources() 直接返回空列表，抖音百科彻底失效。
    //   这就是「总闸拔了，空调打不开」的串联逻辑。
    // ------------------------------------------------------------
    var WIKI_KEY = 'dsc_douyin_wiki_total';

    function isWikiOn() {
        try { return localStorage.getItem(WIKI_KEY) === '1'; } catch (e) { return false; }
    }

    // 豆包（包子）形象：不依赖 emoji 字体，任何设备都必然渲染
    var WIKI_ICON_SVG =
        '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">' +
        '<path d="M12 3.1c1.06 0 1.94.62 2.44 1.5.63-.3 1.33-.2 1.82.29.5.5.57 1.2.3 1.82.72.5 1.14 1.36 1.14 2.26 0 3.66-2.56 6.2-5.7 6.2S6.3 12.63 6.3 8.97c0-.9.42-1.76 1.14-2.26a1.63 1.63 0 0 1 .3-1.82c.49-.49 1.19-.59 1.82-.29.5-.88 1.38-1.5 2.44-1.5Z" fill="currentColor"/>' +
        '<path d="M8.5 8.1c.62-1.1 1.9-1.75 3.5-1.75s2.88.65 3.5 1.75" stroke="#ffffff" stroke-width="1.2" stroke-linecap="round" fill="none" opacity=".7"/>' +
        '<circle cx="9.95" cy="10.1" r=".92" fill="#ffffff"/>' +
        '<circle cx="14.05" cy="10.1" r=".92" fill="#ffffff"/>' +
        '<path d="M10.2 12.6c.45.55 1.05.85 1.8.85s1.35-.3 1.8-.85" stroke="#ffffff" stroke-width="1.05" stroke-linecap="round" fill="none" opacity=".85"/>' +
        '</svg>';

    function syncWikiBtnUI() {
        var b = $('dscDbWikiBtn');
        if (!b) return;
        var on = isWikiOn();
        // 仅豆包模式显示（DeepSeek 通道没有联网内容插件）
        b.style.display = isDbMode() ? '' : 'none';
        if (on) b.classList.add('active'); else b.classList.remove('active');
        b.title = on ? T('抖音百科：オン（クリックでオフ）') : T('抖音百科：オフ（クリックでオン）');
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
    }

    // 设置里的信源开关跟随总闸：总闸关闭时灰化并强制取消勾选
    function syncWikiSwitchUI() {
        var row = $('dscDbWikiRow');
        var box = $('dscDbWikiDouyin');
        if (!row || !box) return;
        var on = isWikiOn();
        if (on) row.classList.remove('dsc-toggle-locked');
        else row.classList.add('dsc-toggle-locked');
        if (!on) box.checked = false;
        box.setAttribute('aria-disabled', on ? 'false' : 'true');
    }

    // 只提交关键字段，其余设置由后端沿用旧值。
    // 先取最新配置再写回，避免「其它信源（toutiao / moji 等）被空列表覆盖」。
    function persistWikiState() {
        var ready = S.cfg ? Promise.resolve(S.cfg) : loadConfig(true);
        return ready.then(function (cfg) {
            var base = (cfg && Array.isArray(cfg.webSources)) ? cfg.webSources : (DB_WEB_SOURCES || []);
            var ws = base.filter(function (x) { return x !== 'douyin'; });
            if (isWikiOn()) ws.push('douyin');
            return api('/config', {
                method: 'POST',
                body: { wikiEnabled: isWikiOn(), webSources: ws }
            });
        }).then(function (d) {
            S.cfg = d;
            DB_WEB_SOURCES = Array.isArray(d.webSources) ? d.webSources.slice() : [];
        });
    }

    function setWikiTotal(on, silent) {
        var want = !!on;
        if (want && !isDbMode()) {
            toast(T('抖音百科は豆包モードでのみ利用可能です'), 'error');
            return false;
        }
        try { localStorage.setItem(WIKI_KEY, want ? '1' : '0'); } catch (e) {}
        var box = $('dscDbWikiDouyin');
        if (box) box.checked = want;   // 开总闸即勾上信源；关总闸即强制取消
        syncWikiBtnUI();
        syncWikiSwitchUI();
        if (want) {
            // 抖音百科与工具模式互斥：开启瞬间自动关闭工具模式
            if (typeof window.dscSetToolMode === 'function') window.dscSetToolMode(false);
            var tb = $('dscToolModeBtn');
            if (tb) tb.classList.remove('active');
        }
        persistWikiState().catch(function (e) {
            console.log('[DB] wiki state save failed:', e && e.message);
        });
        if (!silent) {
            toast(want ? T('抖音百科をオンにしました') : T('抖音百科をオフにしました'), want ? 'success' : 'info');
            // オンにした瞬間、ツールが呼び出されないことを追加で警告
            if (want) {
                setTimeout(function () {
                    toast(T('抖音百科が開いているため、ツールは呼び出されません'), 'info');
                }, 450);
            }
        }
        return true;
    }

    function injectWikiBtn() {
        var panel = $('dscToolsExtra');
        if (!panel) return;
        if (!$('dscDbWikiBtn')) {
            var b = el('button', 'dsc-switch-btn dsc-db-wiki-btn');
            b.id = 'dscDbWikiBtn';
            b.type = 'button';
            var ic = el('span', 'ic');
            ic.innerHTML = WIKI_ICON_SVG;
            b.appendChild(ic);
            // 去抖：WebView 里注入式点击偶尔会派发两次 click，
            // 不去抖就会出现「开了又立刻关」的假象。
            var lastWikiTap = 0;
            b.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                var now = Date.now();
                if (now - lastWikiTap < 350) return;
                lastWikiTap = now;
                setWikiTotal(!isWikiOn());
            });
            /* 与专属工具按钮同源修复：末尾 appendChild 会被挤出横向滚动区，
               改插到首位，保证手机窄屏首屏可见。 */
            panel.insertBefore(b, panel.firstChild);
        }
        syncWikiBtnUI();
    }

    // 供 deepseek-chat.js 判断：豆包模式 + 总闸开启 = 工具模式必须让路
    window.dscWikiTotalOn = function () { return isWikiOn(); };
    window.dscWikiEffectiveOn = function () { return isDbMode() && isWikiOn(); };

    var RATIOS = ['16:9', '3:4', '4:3', '19:6', '21:9', '1:1', '9:16'];
    var IMG_STYLES_JA = ['アニメ', '二次元', '日本アニメ風', 'ピクセル', 'シネマティック', '特撮風', '中国アニメ風', '田園風'];

    function $(id) { return document.getElementById(id); }

    function T(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    function lang() {
        try { return (window.I18N && window.I18N.getLang()) || 'ja'; } catch (e) { return 'ja'; }
    }

    // ------------------------------------------------------------
    // 音色解析：豆包音色 ID / 任意输入 → 合法的 Edge Neural 音色名
    //   后端 /tts 直接把 voice 交给 Edge 合成（不做任何映射），
    //   播客则走 edgeVoiceFor()（仅按 male / 非 male 二分）。
    //   两条链路都只有在收到「xx-XX-XxxxNeural」这种合法 Neural 名时，
    //   才会真正按用户选择发音；否则统一落回同一个默认音色，
    //   表现就是「填什么值听起来都一样」。
    // ------------------------------------------------------------
    // 豆包端到端实时语音多语种官方音色（S2S 全双工 / O2.0，支持 30+ 语种自动识别）
    //   jupiter = S2S-O 旧版（中文为主）；uranus = 2.0 库（多语种）。
    var DUPLEX_VOICES = [
        { value: 'zh_female_vv_uranus_bigtts', label: 'Vivi 2.0（中/日/インドネシア/メキシコ + 30+ 言語）' },
        { value: 'zh_female_xiaohe_uranus_bigtts', label: '小何 2.0（中国語 + 30+ 言語）' },
        { value: 'zh_male_m191_uranus_bigtts', label: '云舟 2.0（中国語 + 30+ 言語）' },
        { value: 'zh_male_taocheng_uranus_bigtts', label: '小天 2.0（中国語 + 30+ 言語）' }
    ];

    // 豆包播客专用音色（中文双人对话，saturn 版本）
//   播客是中文双人对谈，不支持 30+ 语种；30+ 语种是语音通话（Seeduplex）的能力。
//   每项是一对发音人：女 + 男（官方播客模型仅支持 2 位发音人）。
var PODCAST_VOICE_PAIRS = [
    { value: 'mizai_dayi', label: '咪仔 + 大衣先生（既定）',
      speakers: ['zh_female_mizaitongxue_v2_saturn_bigtts', 'zh_male_dayixiansheng_v2_saturn_bigtts'] },
    { value: 'liufei_xiaolei', label: '刘飞 + 潇磊',
      speakers: ['zh_male_liufei_v2_saturn_bigtts', 'zh_male_xiaolei_v2_saturn_bigtts'] }
];

var EDGE_VOICE_POOL = {
        zh: ['zh-CN-XiaoxiaoNeural', 'zh-CN-XiaoyiNeural', 'zh-CN-YunjianNeural',
             'zh-CN-YunxiNeural', 'zh-CN-YunyangNeural', 'zh-CN-YunxiaNeural'],
        ja: ['ja-JP-NanamiNeural', 'ja-JP-KeitaNeural'],
        en: ['en-US-AriaNeural', 'en-US-GuyNeural', 'en-US-JennyNeural'],
        fr: ['fr-FR-DeniseNeural', 'fr-FR-HenriNeural'],
        ru: ['ru-RU-SvetlanaNeural', 'ru-RU-DmitryNeural'],
        ko: ['ko-KR-SunHiNeural', 'ko-KR-InJoonNeural']
    };

    // 已收录的豆包音色 → 各自对应的 Edge 音色（互不相同）
    var DB_TO_EDGE = {
        'zh_female_xiaohe_uranus_bigtts': 'zh-CN-XiaoxiaoNeural',
        'zh_female_shuangkuaisisi_moon_bigtts': 'zh-CN-XiaoxiaoNeural',
        'zh_female_wanwanxiaohe_moon_bigtts': 'zh-CN-XiaoxiaoNeural',
        'zh_female_gaolengyujie_moon_bigtts': 'zh-CN-XiaoyiNeural',
        'zh_female_qingxinnvsheng_mars_bigtts': 'zh-CN-XiaoxiaoNeural',
        'zh_female_mizai_conversation_wvae_bigtts': 'zh-CN-XiaoyiNeural',
        'zh_male_qingshuangnanda_mars_bigtts': 'zh-CN-YunxiNeural',
        'zh_male_yangguangqingnian_moon_bigtts': 'zh-CN-YunjianNeural',
        'zh_male_ahu_conversation_wvae_bigtts': 'zh-CN-YunyangNeural',
        'zh_male_shaonianzixin_moon_bigtts': 'zh-CN-YunxiaNeural',
        'zh_male_zhubajie_conversation_wvae_bigtts': 'zh-CN-YunjianNeural'
    };

    function voiceHash(str) {
        var h = 5381;
        for (var i = 0; i < str.length; i++) h = ((h * 33) ^ str.charCodeAt(i)) >>> 0;
        return h;
    }

    function dscEdgeVoiceOf(raw, lg) {
        var v = String(raw == null ? '' : raw).trim();
        if (!v) return '';
        // 已经是合法 Neural 名：原样使用（后端 isNeuralVoice 会直接采纳）
        if (/^[a-z]{2}-[A-Z]{2}-\w+Neural$/.test(v)) return v;
        if (DB_TO_EDGE[v]) return DB_TO_EDGE[v];
        var l = String(lg || 'zh').toLowerCase().slice(0, 2);
        var pool = EDGE_VOICE_POOL[l] || EDGE_VOICE_POOL.zh;
        // 未收录的自定义值：按字符串散列稳定分配，
        // 保证「填不同的值」→「不同的音色」，而不是永远同一个声音。
        return pool[voiceHash(v) % pool.length];
    }

    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DB]', msg); return; }
        var t = el('div', 'dsc-toast ' + (type || ''), msg);
        wrap.appendChild(t);
        setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 3600);
    }

    function setStatus(node, msg, kind) {
        if (!node) return;
        node.textContent = msg || '';
        node.className = 'dsc-db-status' + (kind ? ' ' + kind : '');
    }

    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    async function api(path, opts) {
        var o = opts || {};
        var res = await fetch(API + path, {
            method: o.method || 'GET',
            headers: o.body ? Object.assign({ 'Content-Type': 'application/json' }, o.headers || {}) : (o.headers || {}),
            body: o.body ? JSON.stringify(o.body) : undefined,
            cache: 'no-store'
        });
        var data = {};
        try { data = await res.json(); } catch (e) { data = {}; }
        if (!res.ok) {
            throw new Error((data && (data.error || data.message)) || ('HTTP ' + res.status));
        }
        return data;
    }

    function fileUrl(file) {
        if (!file) return '';
        return '/api/ds-files/download?id=' + encodeURIComponent(file.id);
    }

    function downloadUrl(file) {
        return fileUrl(file) + '&download=1';
    }

    function openExternal(url) {
        try { window.open(url, '_blank'); } catch (e) { location.href = url; }
    }

    function refreshFiles() {
        try { if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles(); } catch (e) {}
    }

    // ------------------------------------------------------------
    // 設定 / モデル
    // ------------------------------------------------------------
    function modelsByCat(cat) {
        return (S.catalog || []).filter(function (m) { return !cat || m.category === cat; });
    }

    // 模型能力标签：模型名保持语言无关（拉丁字母/数字），
    // 能力说明由后端 audioInput / videoInput 布尔字段驱动并走字典本地化，
    // 这样新增模型不会再出现「日语残留」或半日半中混排。
    function capSuffix(m) {
        if (!m) return '';
        var a = !!m.audioInput;
        var v = !!m.videoInput;
        var txt = '';
        if (a && v) txt = T('（音声理解・動画理解）');
        else if (v) txt = T('（動画理解）');
        else if (a) txt = T('（音声理解）');
        if (!txt) return '';
        // 中日文用全角括号，前面不再补空格；其他语言补一个空格更易读
        var lg = lang();
        return (lg === 'zh' || lg === 'ja') ? txt : ' ' + txt;
    }

    function fillSelect(sel, items, selected) {
        if (!sel) return;
        sel.innerHTML = '';
        items.forEach(function (m) {
            var o = document.createElement('option');
            o.value = m.value;
            o.textContent = T(m.label) + capSuffix(m) + ' · ' + m.value;
            if (selected && selected === m.value) o.selected = true;
            sel.appendChild(o);
        });
        if (selected) {
            var has = items.some(function (m) { return m.value === selected; });
            if (!has) {
                var o2 = document.createElement('option');
                o2.value = selected;
                o2.textContent = selected;
                sel.appendChild(o2);
                sel.value = selected;
            }
        }
    }

    async function loadConfig(force) {
        if (S.cfg && !force) return S.cfg;
        var d = await api('/config');
        S.cfg = d;
        S.catalog = (d.catalog && d.catalog.models) || [];
        S.styles = (d.catalog && d.catalog.styles) || IMG_STYLES_JA;
        return d;
    }

    // 通常チャットのモデル選択は DeepSeek 専用（豆包モデルはここに出さない）。
    // 旧版が注入した豆包モデル群が残っていれば必ず撤去する。
    var DB_CHAT_VALUES = [
        'doubao-seed-2-0-mini-260428', 'doubao-seed-evolving-latest-version',
        'doubao-seed-2-1-pro-260628', 'doubao-seed-2-1-turbo-260628',
        'doubao-seed-2-0-lite-260428', 'glm-5-2-260617'
    ];

    function isDbModelValue(v) {
        v = String(v || '').trim();
        if (!v) return false;
        if (DB_CHAT_VALUES.indexOf(v) >= 0) return true;
        if (S.catalog && S.catalog.some(function (m) { return m.value === v && m.category === 'chat'; })) return true;
        if (S.cfg && (S.cfg.customModels || []).indexOf(v) >= 0) return true;
        return /^(doubao-seed|doubao-1|doubao-pro|doubao-lite|glm-)/.test(v);
    }

    function purgeLegacyChatModels() {
        var sel = $('dscModelSelect');
        if (!sel) return;
        var g = $('dscDbModelGroup');
        if (g && g.parentNode) g.parentNode.removeChild(g);
        // 旧版が動的に追加した豆包モデルの option も 1 件ずつ撤去する
        for (var i = sel.options.length - 1; i >= 0; i--) {
            var v = sel.options[i].value;
            if (!isDbModelValue(v)) continue;
            var wasSelected = (sel.value === v);
            sel.remove(i);
            if (wasSelected) sel.value = 'deepseek-flash';
        }
        // 旧版で豆包モデルが選ばれたまま残っている場合は DeepSeek 既定値へ戻す
        if (isDbModelValue(sel.value)) {
            sel.value = 'deepseek-flash';
            try { localStorage.setItem('dsc_currentModel', 'deepseek-flash'); } catch (e) {}
        }
    }

    // ------------------------------------------------------------
    // 「⋯」メニューへのボタン追加
    // ------------------------------------------------------------
    // メニュー項目は「日本語キー＋実行関数」で保持し、言語切替時はラベルだけ貼り替える。
    // 再読込なしで言語を変えても、以前の言語の文言が残らないようにするため。
    var MENU_ITEMS = [
        { id: 'dscDbTtsBtn', ic: '🔊', label: T('豆包で音声生成'), tip: T('豆包音声生成'), open: function () { openTtsModal(); } },
        { id: 'dscDbAudioGenBtn', ic: '🎬', label: T('豆包オーディオ生成'), tip: T('豆包オーディオ生成'), open: function () { openAudioGenModal(); } },
        { id: 'dscDbImageBtn', ic: '🎨', label: T('豆包で画像生成'), tip: T('豆包画像生成'), open: function () { openImageModal(); } },
        { id: 'dscDbVideoBtn', ic: '🎬', label: T('豆包で動画生成'), tip: T('豆包動画生成'), open: function () { openVideoModal(); } },
        { id: 'dscDbPodcastBtn', ic: '🎧', label: T('豆包ポッドキャスト'), tip: T('豆包ポッドキャスト'), open: function () { openPodcastModal(); } },
        { id: 'dscDbCallBtn', ic: '📞', label: T('豆包音声通話'), tip: T('豆包音声通話'), open: function () { openCallModal(); } },
        { id: 'dscDbAsrBtn', ic: '🎤', label: T('録音ファイルを豆包で認識'), tip: T('豆包録音ファイル認識'), open: function () { openAsrModal(); } },
        { id: 'dscDbTranslateBtn', ic: '🌐', label: T('豆包機械翻訳'), tip: T('豆包機械翻訳'), open: function () { openTranslateModal(); } },
        // 术语表隐藏
        { id: 'dscDbEditBtn', ic: '🖌️', label: T('豆包画像編集'), tip: T('豆包画像編集'), open: function () { openEditModal(); } }
    ];

    function applyMenuLabels() {
        MENU_ITEMS.forEach(function (it) {
            var b = $(it.id);
            if (!b) return;
            b.title = T(it.tip);
            var tx = b.querySelector('.tx');
            if (tx) tx.textContent = T(it.label);
        });
    }

    function injectMenu() {
        var menu = $('dscMoreMenu');
        if (!menu) return;
        var first = menu.firstChild;
        // 既存ボタンは飛ばし、欠けている項目だけを個別に補う
        // （旧版が 1 度でも描画したページでも、新規項目が必ず出るようにする）
        MENU_ITEMS.forEach(function (it) {
            if ($(it.id)) return;
            var b = el('button', 'dsc-more-item');
            b.id = it.id;
            b.title = T(it.tip);
            b.appendChild(el('span', 'ic', it.ic));
            b.appendChild(el('span', 'tx', T(it.label)));
            b.addEventListener('click', function () { closeMoreMenu(); it.open(); });
            menu.insertBefore(b, first);
        });
        applyMenuLabels();
    }

    function closeMoreMenu() {
        var m = $('dscMoreMenu');
        var b = $('dscMoreBtn');
        if (m) m.classList.remove('open');
        if (b) b.classList.remove('more-active');
    }

    // ------------------------------------------------------------
    // モーダル基盤
    // ------------------------------------------------------------
    function buildModal(id, icon, title, sub) {
        var ov = el('div', 'dsc-db-overlay');
        ov.id = id;
        ov.setAttribute('data-lang', lang());   // 言語切替後の作り直し判定に使う
        var md = el('div', 'dsc-db-modal');
        var head = el('div', 'dsc-db-modal-head');
        head.appendChild(el('div', 'dsc-db-modal-ic', icon));
        head.appendChild(el('div', 'dsc-db-modal-title', T(title)));
        var close = el('button', 'dsc-db-close', '×');
        close.type = 'button';
        close.title = T('閉じる');
        head.appendChild(close);
        md.appendChild(head);
        if (sub) md.appendChild(el('div', 'dsc-db-modal-sub', T(sub)));
        ov.appendChild(md);
        document.body.appendChild(ov);
        close.addEventListener('click', function () { closeModal(id); });
        ov.addEventListener('click', function (e) { if (e.target === ov) closeModal(id); });
        return md;
    }

    // 言語切替後に開き直したとき、以前の言語で組んだ DOM が残っていれば作り直す。
    // busy が true の間（生成・通話中）は状態を壊さないため何もしない。
    function ensureModal(id, builder, busy) {
        var old = $(id);
        if (old && old.getAttribute('data-lang') === lang()) return;
        if (old) {
            if (busy) return;
            if (old.parentNode) old.parentNode.removeChild(old);
        }
        builder();
        var made = $(id);
        if (made) made.setAttribute('data-lang', lang());
    }

    function openModal(id) {
        var ov = $(id);
        if (!ov) return;
        ov.classList.add('open');
    }

    function closeModal(id) {
        var ov = $(id);
        if (ov) ov.classList.remove('open');
        if (id === 'dscDbCallOverlay') stopCall();
        if (id === 'dscDbVideoOverlay' && S.pollTimer) {
            clearTimeout(S.pollTimer);
            S.pollTimer = null;
        }
    }

    function field(labelText, inputEl, hint) {
        var f = el('div', 'dsc-db-field');
        if (labelText) {
            var lb = document.createElement('label');
            lb.textContent = T(labelText);
            f.appendChild(lb);
        }
        if (inputEl) f.appendChild(inputEl);
        if (hint) f.appendChild(el('div', 'dsc-db-hint', T(hint)));
        return f;
    }

    function input(id, type, placeholder, value) {
        var i = document.createElement('input');
        i.id = id;
        i.type = type || 'text';
        i.placeholder = placeholder ? T(placeholder) : '';
        i.value = value === undefined || value === null ? '' : value;
        i.autocomplete = 'off';
        return i;
    }

    function textarea(id, placeholder, value) {
        var t = document.createElement('textarea');
        t.id = id;
        t.placeholder = placeholder ? T(placeholder) : '';
        t.value = value || '';
        return t;
    }

    function select(id, options, selected) {
        var s = document.createElement('select');
        s.id = id;
        options.forEach(function (o) {
            var op = document.createElement('option');
            if (typeof o === 'string') { op.value = o; op.textContent = o; }
            else { op.value = o.value; op.textContent = T(o.label) + capSuffix(o); }
            if (selected && selected === op.value) op.selected = true;
            s.appendChild(op);
        });
        return s;
    }

    function switchRow(id, title, desc, checked) {
        var row = el('label', 'dsc-toggle-row');
        var tx = el('div', 'dsc-toggle-tx');
        tx.appendChild(el('div', 'dsc-toggle-title', T(title)));
        if (desc) tx.appendChild(el('div', 'dsc-toggle-desc', T(desc)));
        row.appendChild(tx);
        var sw = el('span', 'dsc-switch');
        var box = document.createElement('input');
        box.type = 'checkbox';
        box.id = id;
        box.checked = !!checked;
        sw.appendChild(box);
        sw.appendChild(el('span', 'dsc-switch-track'));
        row.appendChild(sw);
        return row;
    }

    // ------------------------------------------------------------
    // 設定カード（DeepSeek 設定ダイアログ内）
    // ------------------------------------------------------------
    function buildSettingsCard() {
        var host = document.querySelector('#dscSettingsOverlay .dsc-modal');
        if (!host) return;
        var exist = $('dscDbCard');
        if (exist) {
            // 自癒：過去に modal 直下へ挿入されたカードをスクロール領域へ戻す
            var body0 = host.querySelector('.dsc-settings-body');
            if (body0 && exist.parentNode !== body0) body0.appendChild(exist);
            return;
        }
        var body = host.querySelector('.dsc-settings-body') || host;
        var footer = host.querySelector('.dsc-modal-footer');

        var card = el('div', 'dsc-db-card');
        card.id = 'dscDbCard';

        var head = el('div', 'dsc-db-head');
        head.appendChild(el('div', 'dsc-settings-sec-title', T('豆包（火山方舟）設定')));
        head.appendChild(el('span', 'dsc-db-badge', 'Doubao'));
        card.appendChild(head);
        card.appendChild(el('div', 'dsc-db-sub',
            T('豆包の API Key は DeepSeek の Key とは別に保存します。現状は平文保存です（.sts）。')));

        var keyInput = input('dscDbApiKey', 'password', 'ARK API Key を入力');
        card.appendChild(field('豆包 API Key', keyInput, '保存済みの場合、空欄なら変更しません'));
        var agkInput = input('dscDbAudioGenKey', 'password', 'OpenSpeech API Key を入力');
        card.appendChild(field('豆包オーディオ生成キー（OpenSpeech）', agkInput, 'Seed-Audioの音声生成専用、ARKキーとは別に設定します'));
        card.appendChild(field('ベース URL', input('dscDbBaseUrl', 'text', DB_BASE_PH(), ''), '確定された：https://ark.cn-beijing.volces.com/api/v3'));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('対話モデル', select('dscDbChatModel', modelsByCat('chat'))));
        card.appendChild(el('div', 'dsc-db-sub',
            T('音声理解に対応：doubao-seed-2-0-mini / doubao-seed-2-0-lite。動画理解に対応：上記 2 モデルに加え doubao-seed-2-1-turbo / doubao-seed-2-1-pro / doubao-seed-evolving。2.1 系は動画理解のみで音声理解には非対応です。')));
        grid.appendChild(field('画像モデル', select('dscDbImageModel', modelsByCat('image'))));
        grid.appendChild(field('動画モデル', select('dscDbVideoModel', modelsByCat('video'))));
        grid.appendChild(field('音声合成モデル', select('dscDbTtsModel', modelsByCat('tts'))));
        grid.appendChild(field('ポッドキャストモデル', select('dscDbPodcastModel', modelsByCat('podcast'))));
        grid.appendChild(field('音声認識モデル', select('dscDbAsrModel', modelsByCat('asr'))));
        grid.appendChild(field('翻訳モデル（テキスト入力）', input('dscDbTranslateModel', 'text', 'Doubao-Seed-Translation')));
        grid.appendChild(field('リアルタイム音声モデル', select('dscDbRealtimeModel', modelsByCat('realtime'))));
        grid.appendChild(field('TTS リソース ID（任意）', input('dscDbTtsRes', 'text', '例：seed-tts-2.0', '')));
        card.appendChild(grid);

        var grid2 = el('div', 'dsc-db-grid');
        grid2.appendChild(field('音色 A（話者 1）', input('dscDbVoiceA', 'text', 'zh_female_xiaohe_uranus_bigtts', '')));
        grid2.appendChild(field('音色 B（話者 2）', input('dscDbVoiceB', 'text', 'zh_male_qingshuangnanda_mars_bigtts', '')));
        card.appendChild(grid2);

        // ---- 端到端实时语音（Seeduplex）----
        card.appendChild(el('div', 'dsc-settings-sec-title', T('エンドツーエンドリアルタイム音声（Seeduplex）')));
        card.appendChild(el('div', 'dsc-db-sub',
            T('全双工のリアルタイム通話。ブラウザは独自ヘッダーを付けられないため、ローカルサービスが X-Api-Key を付けて wss へプロキシします。')));
        var grid3 = el('div', 'dsc-db-grid');
        grid3.appendChild(field('全双工の音色（任意）',
            input('dscDbDuplexVoice', 'text', '空欄なら Vivi 2.0（zh_female_vv_uranus_bigtts）', '')));
        grid3.appendChild(field('全双工の言語',
            select('dscDbDuplexLang', [
                { value: 'zh', label: '中文' }, { value: 'ja', label: '日本語' },
                { value: 'en', label: 'English' }, { value: 'ko', label: '한국어' },
                { value: 'ru', label: 'Русский' }, { value: 'fr', label: 'Français' }
            ])));
        card.appendChild(grid3);
        card.appendChild(field('全双工の人設プロンプト（任意）',
            input('dscDbDuplexInstr', 'text', '空欄なら既定の短文プロンプト', '')));
        card.appendChild(switchRow('dscDbDuplexMusic', '歌唱能力（ネイティブ）',
            '打开后模型可随口唱歌（enable_music，端到端语音模型内置能力，不额外计费）', false));
        card.appendChild(switchRow('dscDbDuplexWeb', '内蔵ウェブ検索',
            '打开后语音通话具备联网搜索能力（enable_volc_websearch，需在火山控制台开通融合信息搜索）', false));
        card.appendChild(field('ウェブ検索 API Key（融合情報検索）',
            input('dscDbDuplexWebKey', 'password', '变更时才需填写，留空保持不变'),
            '开启内蔵ウェブ検索后需配置融合信息搜索 API Key（volc_websearch_api_key）'));
        card.appendChild(field('出力語速',
            input('dscDbDuplexRate', 'number', '语速 -50~100，0 为默认', '0'),
            '控制豆包语音播报语速（session.audio.output.speed，-50~100，数值越大越快）'));
        card.appendChild(field('豆包音声 API Key（Seeduplex 用）',
            input('dscDbDuplexKey', 'password', '変更しない場合は空欄'),
            '方舟の API Key では 401 になります。豆包音声コンソールの API Key を入力してください。'));

        // ---- RTC AI 音视频互动 ----
        card.appendChild(el('div', 'dsc-settings-sec-title', T('RTC AI 音声・映像インタラクション')));
        card.appendChild(el('div', 'dsc-db-sub',
            T('RTC 側はサーバー API（StartVoiceChat）でタスクを作成します。ブラウザで実際に音声・映像を送受信するには、公式 RTC Web SDK の導入が別途必要です。')));
        var grid4 = el('div', 'dsc-db-grid');
        grid4.appendChild(field('RTC AppId', input('dscDbRtcAppId', 'text', 'RTC アプリの AppId', '')));
        grid4.appendChild(field('RoomId', input('dscDbRtcRoomId', 'text', '既定のルーム ID', '')));
        card.appendChild(grid4);
        var grid5 = el('div', 'dsc-db-grid');
        grid5.appendChild(field('AccessKey', input('dscDbRtcAk', 'password', '変更しない場合は空欄')));
        grid5.appendChild(field('SecretKey', input('dscDbRtcSk', 'password', '変更しない場合は空欄')));
        card.appendChild(grid5);
        var grid6 = el('div', 'dsc-db-grid');
        grid6.appendChild(field('S2S AppId', input('dscDbS2sAppId', 'text', 'エンドツーエンド音声サービスの AppId', '')));
        grid6.appendChild(field('S2S Token', input('dscDbS2sToken', 'password', '変更しない場合は空欄')));
        card.appendChild(grid6);

        card.appendChild(switchRow('dscDbFastMode', '高速モード（深い思考をオフ）',
            '豆包の言語モデルで深い思考を無効化し、最初の一文字が届くまでの待ち時間を大幅に短縮します（実測 16.8 秒 → 0.9 秒）', true));
        var wikiRow = switchRow('dscDbWikiDouyin', '抖音百科を情報源にする（豆包モード限定）',
            '火山方舟の「ウェブ連携プラグイン」を使い、検索結果に抖音百科（douyin）を追加します。豆包モードのときだけ有効で、DeepSeek チャンネルには一切影響しません', false);
        wikiRow.id = 'dscDbWikiRow';
        card.appendChild(wikiRow);
        // 总闸未开时，这个信源开关点不开 —— 只会提示去开总闸
        wikiRow.addEventListener('click', function (e) {
            if (isWikiOn()) return;
            e.preventDefault();
            e.stopPropagation();
            var box = $('dscDbWikiDouyin');
            if (box) box.checked = false;
            toast(T('抖音百科のマスタースイッチを先にオンにしてください'), 'error');
        }, true);
        card.appendChild(switchRow('dscDbAutoRoute', '録音ファイルを豆包へ自動ルーティング',
            '豆包以外のモデルを選んでいても、録音を送ると豆包で認識・分析します', true));
        card.appendChild(switchRow('dscDbWatermark', '生成物に透かしを入れる',
            '画像・動画の「AI 生成」透かし（既定はオフ）', false));

        var row = el('div', 'dsc-db-row');
        var save = el('button', 'dsc-db-btn primary', T('豆包設定を保存'));
        save.type = 'button';
        save.id = 'dscDbSaveCfg';
        var clear = el('button', 'dsc-db-btn danger', T('Key を消去'));
        clear.type = 'button';
        clear.id = 'dscDbClearKey';
        row.appendChild(save);
        row.appendChild(clear);
        card.appendChild(row);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbCfgStatus';
        card.appendChild(st);

        card.appendChild(el('div', 'dsc-settings-sec-title', T('豆包モデル一覧（17 種）')));
        var list = el('div', 'dsc-db-models');
        list.id = 'dscDbModelList';
        card.appendChild(list);

        var addRow = el('div', 'dsc-db-row');
        addRow.style.marginTop = '8px';
        var addInput = input('dscDbCustomModel', 'text', 'カスタムモデル値（例：doubao-seed-2-2-pro）');
        var addBtn = el('button', 'dsc-db-btn', T('追加'));
        addBtn.type = 'button';
        addBtn.id = 'dscDbAddModel';
        addRow.appendChild(addInput);
        addRow.appendChild(addBtn);
        card.appendChild(addRow);

        // 重要：豆包カードは必ずスクロール領域（.dsc-settings-body）の末尾へ入れる。
        // modal 直下（footer の直前）へ挿入すると flex レイアウトで本文領域が潰れ、
        // DeepSeek の接続情報（API Key 入力欄）が見えなくなる。
        if (body && body !== host) {
            body.appendChild(card);
        } else if (footer && footer.parentNode === host) {
            host.insertBefore(card, footer);
        } else {
            host.appendChild(card);
        }

        save.addEventListener('click', saveCfg);
        clear.addEventListener('click', clearKey);
        addBtn.addEventListener('click', addCustomModel);
    }

    function DB_BASE_PH() { return 'https://ark.cn-beijing.volces.com/api/v3'; }

    function renderModelList() {
        var list = $('dscDbModelList');
        if (!list) return;
        list.innerHTML = '';
        (S.catalog || []).forEach(function (m) {
            var r = el('div', 'dsc-db-model-row');
            r.appendChild(el('span', 'dsc-db-model-name', T(m.label)));
            r.appendChild(el('span', 'dsc-db-model-val', m.value));
            list.appendChild(r);
        });
    }

    function fillCfgForm() {
        var c = S.cfg;
        if (!c) return;
        // モデル選択はカタログ到着後に populate する（空の select を残さない）
        var catMap = {
            dscDbChatModel: ['chat', 'chatModel'],
            dscDbImageModel: ['image', 'imageModel'],
            dscDbVideoModel: ['video', 'videoModel'],
            dscDbTtsModel: ['tts', 'ttsModel'],
            dscDbPodcastModel: ['podcast', 'podcastModel'],
            dscDbAsrModel: ['asr', 'asrModel'],
            dscDbRealtimeModel: ['realtime', 'realtimeModel']
        };
        Object.keys(catMap).forEach(function (id) {
            var sel = $(id);
            if (!sel) return;
            var cat = catMap[id][0];
            var key = catMap[id][1];
            var items = modelsByCat(cat);
            if (items.length === 0) return;
            fillSelect(sel, items, c[key]);
        });
        var map = {
            dscDbBaseUrl: c.baseUrl,
            dscDbChatModel: c.chatModel,
            dscDbImageModel: c.imageModel,
            dscDbVideoModel: c.videoModel,
            dscDbTtsModel: c.ttsModel,
            dscDbPodcastModel: c.podcastModel,
            dscDbAsrModel: c.asrModel,
            dscDbTranslateModel: c.translateModel,
            dscDbRealtimeModel: c.realtimeModel,
            dscDbTtsRes: c.ttsResourceId,
            dscDbVoiceA: c.voice,
            dscDbVoiceB: c.voiceB,
            dscDbDuplexVoice: c.duplexVoice,
            dscDbDuplexInstr: c.duplexInstructions,
            dscDbDuplexLang: (c.duplexLang || 'zh'),
            dscDbRtcAppId: c.rtcAppId,
            dscDbRtcRoomId: c.rtcRoomId,
            dscDbS2sAppId: c.s2sAppId
        };
        Object.keys(map).forEach(function (id) {
            var n = $(id);
            if (n) n.value = map[id] || '';
        });
        // 入力欄で上書きした豆包モデルがある場合、設定画面にもその値を出す
        //   （ここで保存すれば後端にも反映され、表示と実使用がずれない）
        (function () {
            var sel = $('dscDbChatModel');
            var ov = dbChatModelOverride();
            if (!sel || !ov) return;
            // ★【修复】以「实际生效的豆包模型」为准显示，即 override 优先。
            //   旧实现在后端已有 chatModel 时直接 return，结果聊天框下方快捷选择器
            //   切到 glm / 其它模型后，设置面板里的对话模型仍停在 doubao-seed-2-1-pro-260628，
            //   用户看到的就是「强制锁死 2.1-pro、根本切不动」。
            //   override 与后端值的一致性由 saveCfg() 保证：保存成功后会把 override
            //   同步成刚保存的模型，所以这里优先 override 不会把保存值顶掉。
            var found = false;
            for (var i = 0; i < sel.options.length; i++) {
                if (sel.options[i].value === ov) { found = true; break; }
            }
            if (!found) {
                var o = document.createElement('option');
                o.value = ov;
                o.textContent = ov;
                sel.appendChild(o);
            }
            sel.value = ov;
        })();
        var k = $('dscDbApiKey');
        if (k) {
            k.value = '';
            k.placeholder = c.hasKey ? T('保存済み（{0}）。空欄なら変更しません', c.maskedKey) : T('ARK API Key を入力');
        }
        var agk = $('dscDbAudioGenKey');
        if (agk) {
            agk.value = '';
            agk.placeholder = c.hasAudioGenKey ? T('保存済み（{0}）。空欄なら変更しません', c.maskedAudioGenKey) : T('音声生成 API Key を入力');
        var tk = $('dscDbTranslateApiKey');
        if (tk) { tk.value = ''; tk.placeholder = c.hasTranslateKey ? T('保存済み（{0}）。空欄なら変更しません', c.maskedTranslateKey) : T('翻訳専用 API Key を入力'); }
        }
        DB_WEB_SOURCES = Array.isArray(c.webSources) ? c.webSources.slice() : [];
        /* v6 修复：总闸只做「首次初始化」，不再被后端配置反复回写。
           旧实现每次加载配置 / 打开设置面板，都把服务端的 wikiEnabled 覆盖到本地：
           用户明明已经关掉百科，状态又被复活 → isWikiOn() 恒为 true →
           工具模式按钮进 locked 态、并被 600ms 的 sync 反复压回关闭，
           外部表现就是「工具模式点不动 / 一开就灭」。 */
        try {
            if (localStorage.getItem(WIKI_KEY) === null &&
                Object.prototype.hasOwnProperty.call(c, 'wikiEnabled')) {
                localStorage.setItem(WIKI_KEY, c.wikiEnabled ? '1' : '0');
            }
        } catch (e) {}
        var wd = $('dscDbWikiDouyin');
        if (wd) wd.checked = isWikiOn() && DB_WEB_SOURCES.indexOf('douyin') >= 0;
        syncWikiSwitchUI();
        syncWikiBtnUI();
        var fm = $('dscDbFastMode');
        if (fm) fm.checked = (c.fastMode !== false);
        var ar = $('dscDbAutoRoute');
        if (ar) ar.checked = !!c.autoRouteAudio;
        var wm = $('dscDbWatermark');
        if (wm) wm.checked = !!c.watermark;
        var dm = $('dscDbDuplexMusic');
        if (dm) dm.checked = !!c.duplexMusic;
        var dw = $('dscDbDuplexWeb');
        if (dw) dw.checked = !!c.duplexWebsearch;
        var dwk = $('dscDbDuplexWebKey');
        if (dwk) {
            dwk.value = '';
            dwk.placeholder = c.hasDuplexWebsearchKey
                ? T('保存済み。空欄なら変更しません')
                : T('融合信息搜索 API Key（开启内蔵ウェブ検索后需配置）');
        }
        var dr = $('dscDbDuplexRate');
        if (dr) dr.value = (c.duplexSpeechRate == null ? '0' : String(c.duplexSpeechRate));
        renderModelList();
        // ★ 修复「聊天框下方切换模型后，这里仍显示旧模型」的 bug：
        //   本行原先读的是后端配置里的 chatModel，而聊天框下方的快捷模型选择器
        //   （qmApply）出于安全只把选择写进 localStorage 覆盖值，不回写后端
        //   （避免后端「全量覆盖」把 API Key 清空）。因此切到 B 模型后，
        //   这里会一直停在 A。改为统一按「实际生效模型」dbChatModel() 渲染。
        refreshCfgStatus();
    }

    // 按「当前实际生效的对话模型」刷新豆包配置状态行
    //   ★ 修复：原先不论当前是豆包模式还是 DeepSeek 模式，一律显示豆包的 chatModel，
    //     于是在聊天框下方把模型切到 B 之后，这里仍停在旧的 A（例如
    //     deepseek-v4-1-flash-261017）。现按 isDbMode() 分别取豆包模型 / 当前
    //     DeepSeek 模型，与快捷按钮 qmSyncBtn() 使用同一来源，切哪个都同步。
    function refreshCfgStatus() {
        var st = $('dscDbCfgStatus');
        if (!st || !S.cfg) return;
        // 用下拉框切换模型（不经过快捷选择器）时也要同步状态行，只绑定一次。
        if (!refreshCfgStatus._bound) {
            refreshCfgStatus._bound = true;
            var sel = $('dscModelSelect');
            if (sel) {
                sel.addEventListener('change', function () {
                    setTimeout(function () {
                        try { refreshCfgStatus(); } catch (e) {}
                    }, 0);
                });
            }
            // ★ 设置面板里的「对话模型」下拉改动后，状态行必须立刻跟着变，
            //   不能等保存、也不能被 localStorage 里的旧 override 拉回去。
            var selCfgChat = $('dscDbChatModel');
            if (selCfgChat) {
                selCfgChat.addEventListener('change', function () {
                    try {
                        var nv = String(selCfgChat.value || '').trim();
                        if (nv) {
                            setDbChatModelOverride(nv);
                            // ★【修复】设置面板里只修改「豆包对话模型」这一配置项，绝不切换维度。
                            //   旧实现无条件 dscSetDimForModel('db', nv, false)：在 DeepSeek（ds）/
                            //   中转站（st）维度下打开设置、只是动一下这个下拉框，目标维度被写死成 'db'，
                            //   于是 crossDim = true → 播全套「穿越维度」全屏动画，并把用户拽进豆包维度。
                            //   现在：仅当用户本来就在豆包维度时才静默同步模型；其它维度只更新 override。
                            try {
                                var __curDimA = (window.dscDimOn ? window.dscDimOn() : 'ds');
                                if (__curDimA === 'db' && window.dscSetDimForModel) {
                                    window.dscSetDimForModel('db', nv, true);
                                }
                            } catch (eA) {}
                        }
                    } catch (e) {}
                    setTimeout(function () {
                        try { refreshCfgStatus(); } catch (e) {}
                    }, 0);
                });
            }
        }
        var hasKey = !!S.cfg.hasKey;
        // ★ 本行位于「豆包设置」面板内，必须与设置面板里的对话模型下拉框保持一致。
        //   旧实现按 isDbMode() 取 DeepSeek 侧当前模型（或 dbChatModel() 被 localStorage
        //   里的旧 override 压住），于是在设置里把模型改成 glm 等值并保存后，
        //   本行仍停在 doubao-seed-2-1-pro-260628 这类旧值。
        //   取值顺序：设置面板下拉当前值 → 后端已保存值 → 生效模型兜底。
        var selChatEl = $('dscDbChatModel');
        var selChatVal = (selChatEl && selChatEl.value) ? String(selChatEl.value).trim() : '';
        var savedChatVal = (S.cfg.chatModel == null ? '' : String(S.cfg.chatModel)).trim();
        var cur = selChatVal || savedChatVal || dbChatModel();
        setStatus(st, hasKey
            ? T('✅ 豆包 Key 設定済み · 対話モデル：{0}', cur)
            : T('⚠️ 豆包 Key 未設定'), hasKey ? 'ok' : 'err');
    }

    async function saveCfg() {
        var st = $('dscDbCfgStatus');
        var btn = $('dscDbSaveCfg');
        var body = {
            apiKey: ($('dscDbApiKey') || {}).value || '',
            audioGenApiKey: ($('dscDbAudioGenKey') || {}).value || '',
            baseUrl: ($('dscDbBaseUrl') || {}).value || '',
            chatModel: ($('dscDbChatModel') || {}).value || '',
            imageModel: ($('dscDbImageModel') || {}).value || '',
            videoModel: ($('dscDbVideoModel') || {}).value || '',
            ttsModel: ($('dscDbTtsModel') || {}).value || '',
            podcastModel: ($('dscDbPodcastModel') || {}).value || '',
            asrModel: ($('dscDbAsrModel') || {}).value || '',
            translateModel: ($('dscDbTranslateModel') || {}).value || '',
            realtimeModel: ($('dscDbRealtimeModel') || {}).value || '',
            ttsResourceId: ($('dscDbTtsRes') || {}).value || '',
            voice: ($('dscDbVoiceA') || {}).value || '',
            voiceB: ($('dscDbVoiceB') || {}).value || '',
            fastMode: !!(($('dscDbFastMode') || {}).checked),
            wikiEnabled: isWikiOn(),
            webSources: (function () {
                var ws = (DB_WEB_SOURCES || []).filter(function (x) { return x !== 'douyin'; });
                var d = $('dscDbWikiDouyin');
                // 串联：总闸未开时，信源开关勾着也不生效
                if (isWikiOn() && d && d.checked) ws.push('douyin');
                return ws;
            })(),
            autoRouteAudio: !!(($('dscDbAutoRoute') || {}).checked),
            watermark: !!(($('dscDbWatermark') || {}).checked),
            duplexVoice: ($('dscDbDuplexVoice') || {}).value || '',
            duplexInstructions: ($('dscDbDuplexInstr') || {}).value || '',
            duplexLang: ($('dscDbDuplexLang') || {}).value || 'zh',
            duplexMusic: !!(($('dscDbDuplexMusic') || {}).checked),
            duplexWebsearch: !!(($('dscDbDuplexWeb') || {}).checked),
            duplexSpeechRate: parseInt(($('dscDbDuplexRate') || {}).value || '0', 10) || 0,
            rtcAppId: ($('dscDbRtcAppId') || {}).value || '',
            rtcRoomId: ($('dscDbRtcRoomId') || {}).value || '',
            s2sAppId: ($('dscDbS2sAppId') || {}).value || ''
        };
        // センシティブ値は空欄なら送らない（既存の保存値を保持する）
        var dk = (($('dscDbDuplexKey') || {}).value || '').trim();
        if (dk) body.duplexApiKey = dk;
        var dwk = (($('dscDbDuplexWebKey') || {}).value || '').trim();
        if (dwk) body.duplexWebsearchApiKey = dwk;
        var rk = (($('dscDbRtcAk') || {}).value || '').trim();
        var rs = (($('dscDbRtcSk') || {}).value || '').trim();
        var st2 = (($('dscDbS2sToken') || {}).value || '').trim();
        if (rk) body.rtcAccessKey = rk;
        if (rs) body.rtcSecretKey = rs;
        if (st2) body.s2sToken = st2;
        if (btn) btn.disabled = true;
        setStatus(st, T('保存中…'), 'busy');
        try {
            var d = await api('/config', { method: 'POST', body: body });
            S.cfg = d;
            S.catalog = (d.catalog && d.catalog.models) || S.catalog;
            // ★ 关键修复：设置在里显式保存了对话模型后，必须让「实际生效模型」跟随保存值，
            //   并清掉聊天框快捷选择器留下的旧 override。否则 dbChatModel() 仍返回旧模型，
            //   且 fillCfgForm() 末尾的 override 分支会把下拉框改回旧值，
            //   造成「设置里改成 glm / 其他模型后，状态行和下拉仍是旧模型」。
            try { setDbChatModelOverride(String(body.chatModel || '').trim()); } catch (e) {}
            // ★【修复】保存豆包设置只落配置，绝不切换维度、绝不播全屏维度动画。
            //   旧实现无条件 dscSetDimForModel('db', __dbm, false)：目标维度被写死为 'db'，
            //   在 DeepSeek（ds）/ 中转站（st）维度下点「豆包設定を保存」时 crossDim = true，
            //   于是播放全套「穿越维度」全屏动画，并把用户强行拽进豆包维度。
            //   正确行为：已在豆包维度 → 静默同步模型（silent=true，不播 warp、不重载消息）；
            //   其它维度 → 仅保留 setDbChatModelOverride 写入的豆包模型，维度标志与消息流一概不动。
            try {
                var __dbm = String(body.chatModel || '').trim();
                if (__dbm) {
                    var __curDimB = (window.dscDimOn ? window.dscDimOn() : 'ds');
                    if (__curDimB === 'db' && window.dscSetDimForModel) {
                        window.dscSetDimForModel('db', __dbm, true);
                    }
                }
            } catch (e) {}
            fillCfgForm();
            purgeLegacyChatModels();
            syncDbModeUI();   // 対話モデルを変えたらボタンの title も即時追従
            toast(T('✅ 豆包設定を保存しました'), 'success');
        } catch (e) {
            setStatus(st, T('❌ 保存に失敗：{0}', e.message), 'err');
            toast(T('豆包設定の保存に失敗：{0}', e.message), 'error');
        } finally {
            if (btn) btn.disabled = false;
        }
    }

    async function clearKey() {
        if (!window.confirm(T('豆包 API Key を消去しますか？'))) return;
        var st = $('dscDbCfgStatus');
        try {
            var d = await api('/config', { method: 'POST', body: { clearKey: true } });
            S.cfg = d;
            fillCfgForm();
            setStatus(st, T('豆包 Key を消去しました'), 'err');
            toast(T('豆包 Key を消去しました'), 'info');
        } catch (e) {
            setStatus(st, T('❌ 消去に失敗：{0}', e.message), 'err');
        }
    }

    async function addCustomModel() {
        var inp = $('dscDbCustomModel');
        var v = inp ? inp.value.trim() : '';
        if (!v) { toast(T('モデル値を入力してください'), 'info'); return; }
        var cur = (S.cfg && S.cfg.customModels) || [];
        if (cur.indexOf(v) < 0) cur.push(v);
        try {
            var d = await api('/config', { method: 'POST', body: { customModels: cur } });
            S.cfg = d;
            S.catalog = (d.catalog && d.catalog.models) || S.catalog;
            renderModelList();
            purgeLegacyChatModels();
            syncDbModeUI();
            if (inp) inp.value = '';
            toast(T('カスタムモデルを追加しました：{0}', v), 'success');
        } catch (e) {
            toast(T('追加に失敗：{0}', e.message), 'error');
        }
    }

    // ------------------------------------------------------------
    // 音声生成（TTS）
    // ------------------------------------------------------------

    function openAudioGenModal() {
        ensureModal('dscDbAudioGenOverlay', buildAudioGenModal, false);
        loadConfig().catch(function (e) {
            setStatus($('dscDbAudioGenStatus'), '❌ ' + T('設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbAudioGenOverlay');
    }

    function buildAudioGenModal() {
        var md = buildModal('dscDbAudioGenOverlay', '🎬', '豆包オーディオ生成（Seed-Audio）', 'シーン描写から、セリフ・効果音・BGMを含む完全な音声をエンドツーエンドで生成（最長2分）');
        
        md.appendChild(field('オーディオシーンの説明（テキストプロンプト）', textarea('dscDbAudioGenPrompt', '例：優しい女性が夜に童話をそっと語り、背景にかすかな虫の声が聞こえる')));
        md.appendChild(field('音声ファイル名（任意）', input('dscDbAudioGenName', 'text', '例：童話')));
        md.appendChild(field('生成時間', select('dscDbAudioGenDuration', [
            { value: '0', label: '自動（モデルが決定）' },
            { value: '5', label: '5秒' },
            { value: '10', label: '10秒' },
            { value: '15', label: '15秒' },
            { value: '30', label: '30秒' },
            { value: '60', label: '60秒（1分）' },
            { value: '80', label: '80秒' },
            { value: '120', label: '120秒（2分）' }
        ], '0')));

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbAudioGenStatus';
        md.appendChild(st);
        
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbAudioGenResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('オフ'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('生成開始'));
        go.type = 'button';
        go.id = 'dscDbAudioGenGo';
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbAudioGenOverlay'); });
        go.addEventListener('click', async function () {
            var prompt = ($('dscDbAudioGenPrompt') || {}).value || '';
            if (!prompt.trim()) { setStatus(st, '⚠️ ' + T('音声シーン描写を入力してください'), 'err'); return; }
            
            go.disabled = true;
            setStatus(st, T('生成中…（最大2分ほどかかる場合があります）'), 'busy');
            
            try {
                var d = await api('/audio-generate', {
                    method: 'POST',
                    body: {
                        text_prompt: prompt.trim(),
                        name: (($('dscDbAudioGenName') || {}).value || '').trim(),
                        duration: parseInt((($('dscDbAudioGenDuration') || {}).value || '0'), 10)
                    }
                });
                var f = d.file || {};
                res.innerHTML = '';
                var au = document.createElement('audio');
                au.src = fileUrl(f) + '&_t=' + Date.now();
                au.controls = true;
                au.style.width = '100%';
                res.appendChild(au);
                res.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
                
                var row = el('div', 'dsc-db-row');
                row.style.marginTop = '10px';
                var dl = el('button', 'dsc-db-btn primary', T('音声をダウンロード'));
                dl.type = 'button';
                dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
                row.appendChild(dl);
                res.appendChild(row);
                
                setStatus(st, T('✅ 生成成功：{0}', f.name || ''), 'ok');
                toast(T('✅ 音声生成成功'), 'success');
                refreshFiles();
            } catch (e) {
                setStatus(st, '❌ ' + T('生成失敗：{0}', e.message), 'err');
                toast(T('生成失敗：{0}', e.message), 'error');
            } finally {
                go.disabled = false;
            }
        });
    }

    function openTtsModal() {
        ensureModal('dscDbTtsOverlay', buildTtsModal, S.ttsBusy);
        loadConfig().then(function (c) {
            var v = $('dscDbTtsVoice');
            if (v && !v.value) v.value = c.voice || '';
            return loadTtsModels();
        }).catch(function (e) {
            setStatus($('dscDbTtsStatus'), '❌ ' + T('設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbTtsOverlay');
    }

    function buildTtsModal() {
        var md = buildModal('dscDbTtsOverlay', '🔊', '豆包で音声生成',
            'テキストから音声を合成します。生成物は ds_files/blob に保存されます。');
        md.appendChild(field('読み上げるテキスト', textarea('dscDbTtsText', '例：こんにちは。今日はいい天気ですね。')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('音声のファイル名', input('dscDbTtsName', 'text', '例：ナレーション1')));
        grid.appendChild(field('話速', select('dscDbTtsSpeed', ['0.5', '0.75', '1.0', '1.25', '1.5', '2.0'], '1.0')));
        md.appendChild(grid);

        var grid2 = el('div', 'dsc-db-grid');
        grid2.appendChild(field('音色', input('dscDbTtsVoice', 'text', 'zh_female_xiaohe_uranus_bigtts')));
        grid2.appendChild(field('音声合成モデル', select('dscDbTtsPick', [])));
        md.appendChild(grid2);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbTtsStatus';
        md.appendChild(st);
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbTtsResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('音声を生成する'));
        go.type = 'button';
        go.id = 'dscDbTtsGo';
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbTtsOverlay'); });
        go.addEventListener('click', generateTts);
    }

    // 音声生成パネル専用のモデル選択。
    // 設定パネルにも「音声合成モデル」があり、以前は同じ id を使っていたため
    // document.getElementById が設定パネル側を返し、このパネルの select が
    // 空のまま残っていた。パネル内スコープで引くことで衝突を断つ。
    function ttsModelSel() {
        var ov = $('dscDbTtsOverlay');
        return ov ? ov.querySelector('#dscDbTtsPick') : null;
    }

    function fillTtsModels() {
        var sel = ttsModelSel();
        if (!sel) return;
        var items = modelsByCat('tts');
        // カタログが空でも選択肢をゼロにしない（必ず 1 件は選べる状態にする）
        if (!items.length) {
            items = [{ value: 'SeedAudio1.0', label: T('Doubao-音声生成-1.0（音声生成）') }];
        }
        var want = (S.cfg && S.cfg.ttsModel) || '';
        if (want && !items.some(function (m) { return m.value === want; })) {
            items.push({ value: want, label: want });
        }
        fillSelect(sel, items, want || items[0].value);
        if (!sel.value) sel.value = items[0].value;
    }

    // カタログ未取得のまま開かれた場合に備え、/models を取り直してから埋める
    function loadTtsModels() {
        fillTtsModels();
        if ((S.catalog || []).length) return Promise.resolve();
        return api('/models').then(function (d) {
            S.catalog = (d && d.models) || [];
            fillTtsModels();
        }).catch(function () {});
    }

    async function generateTts() {
        if (S.ttsBusy) return;
        var st = $('dscDbTtsStatus');
        var btn = $('dscDbTtsGo');
        var text = ($('dscDbTtsText') || {}).value || '';
        if (!text.trim()) { setStatus(st, '⚠️ ' + T('テキストを入力してください'), 'err'); return; }
        var body = {
            text: text,
            voice: dscEdgeVoiceOf(($('dscDbTtsVoice') || {}).value || '', lang()),
            model: (ttsModelSel() || {}).value || '',
            speed: (($('dscDbTtsSpeed') || {}).value || '1.0'),
            format: 'mp3',
            name: (($('dscDbTtsName') || {}).value || '').trim(),
            lang: lang()
        };
        S.ttsBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('合成中…'), 'busy');
        try {
            var d = await api('/tts', { method: 'POST', body: body });
            var f = d.file || {};
            var box = $('dscDbTtsResult');
            box.innerHTML = '';
            var au = document.createElement('audio');
            au.src = fileUrl(f) + '&_t=' + Date.now();
            au.controls = true;
            au.style.width = '100%';
            box.appendChild(au);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('音声をダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var again = el('button', 'dsc-db-btn ghost', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generateTts(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ 音声を生成しました：{0}', f.name || ''), 'ok');
            toast(T('✅ 音声を生成しました：{0}', f.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, '❌ ' + T('音声生成に失敗：{0}', e.message), 'err');
            toast(T('音声生成に失敗：{0}', e.message), 'error');
        } finally {
            S.ttsBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 録音ファイル認識（ASR）
    //   豆包の音声認識で文字起こしし、結果をそのまま現在の対話へ差し込む。
    //   ★ 認識は豆包（方舟の音声理解 → /audio/transcriptions → 失敗時ローカル whisper）、
    //     差し込みは既存のユーザーメッセージ保存端点のみを使う。
    //     ★ 認識は豆包（方舟）の用量を消費する。DeepSeek の用量は消費しない。
    // ------------------------------------------------------------
    function fmtSize(n) {
        n = Number(n) || 0;
        if (n < 1024) return n + ' B';
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
        return (n / (1024 * 1024)).toFixed(1) + ' MB';
    }

    function openAsrModal() {
        ensureModal('dscDbAsrOverlay', buildAsrModal, S.asrBusy);
        loadConfig().then(function (c) {
            var st = $('dscDbAsrStatus');
            if (st && !st.textContent) {
                setStatus(st, T('文字起こしに使うモデル：{0}（音声理解）／{1}（音声認識）。豆包の用量を消費し、DeepSeek の用量は消費しません。',
                    (c && c.chatModel) || 'doubao-seed', (c && c.asrModel) || 'Doubao_Seed_ASR_AUC_2.0'), '');
            }
        }).catch(function () {});
        openModal('dscDbAsrOverlay');
    }

    function buildAsrModal() {
        var md = buildModal('dscDbAsrOverlay', '🎤', '録音ファイルを豆包で認識',
            '録音ファイルを豆包で文字起こしします。結果は下の欄に表示されるので、そのままコピーできます。対話へは自動送信しません。');

        var pick = el('div', 'dsc-db-filepick');
        var file = document.createElement('input');
        file.type = 'file';
        file.id = 'dscDbAsrFile';
        file.className = 'dsc-db-file';
        file.accept = 'audio/*,.m4a,.amr,.mp3,.wav,.ogg,.aac,.flac,.webm,.opus';
        var pickBtn = el('button', 'dsc-db-btn', T('録音ファイルを選択'));
        pickBtn.type = 'button';
        pickBtn.id = 'dscDbAsrPick';
        var info = el('span', 'dsc-db-filename', T('まだ選択されていません'));
        info.id = 'dscDbAsrFileInfo';
        pickBtn.addEventListener('click', function () { file.click(); });
        file.addEventListener('change', function () {
            var f = file.files && file.files[0];
            info.textContent = f ? (f.name + ' · ' + fmtSize(f.size)) : T('まだ選択されていません');
        });
        pick.appendChild(file);
        pick.appendChild(pickBtn);
        pick.appendChild(info);
        md.appendChild(pick);

        md.appendChild(field('認識結果（そのままコピーできます。必要なら編集してください）',
            textarea('dscDbAsrText', '録音ファイルを選び「豆包で認識」を押してください')));

        var metaLine = el('div', 'dsc-db-hint');
        metaLine.id = 'dscDbAsrMeta';
        md.appendChild(metaLine);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbAsrStatus';
        md.appendChild(st);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var copy = el('button', 'dsc-db-btn', T('結果をコピー'));
        copy.type = 'button';
        copy.id = 'dscDbAsrCopy';
        var ins = el('button', 'dsc-db-btn ghost', T('対話に差し込む'));
        ins.type = 'button';
        ins.id = 'dscDbAsrInsert';
        var go = el('button', 'dsc-db-btn primary', T('豆包で認識'));
        go.type = 'button';
        go.id = 'dscDbAsrGo';
        foot.appendChild(copy);
        foot.appendChild(ins);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbAsrOverlay'); });
        copy.addEventListener('click', function () { copyAsrText(false); });
        ins.addEventListener('click', function () {
            var box = $('dscDbAsrText');
            deliverAsrToChat(box ? box.value : '', $('dscDbAsrStatus'));
        });
        go.addEventListener('click', recognizeAsrFile);
    }

    async function recognizeAsrFile() {
        if (S.asrBusy) return;
        var st = $('dscDbAsrStatus');
        var btn = $('dscDbAsrGo');
        var inp = $('dscDbAsrFile');
        var out = $('dscDbAsrText');
        var f = inp && inp.files && inp.files[0];
        if (!f) { setStatus(st, '⚠️ ' + T('録音ファイルを選択してください'), 'err'); return; }
        if (f.size < 200) { setStatus(st, '⚠️ ' + T('音声が短すぎます'), 'err'); return; }
        S.asrBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('豆包で認識中…（{0}）', fmtSize(f.size)), 'busy');
        try {
            var fd = new FormData();
            fd.append('audio', f, f.name || 'audio.m4a');
            var res = await fetch(API + '/asr', { method: 'POST', body: fd, cache: 'no-store' });
            var data = {};
            try { data = await res.json(); } catch (e) { data = {}; }
            if (!res.ok) throw new Error((data && (data.error || data.message)) || ('HTTP ' + res.status));
            var text = String((data && data.text) || '').trim();
            if (!text) throw new Error(T('豆包が空の認識結果を返しました'));
            if (out) out.value = text;
            var m = String((data && data.model) || '');
            var ep = String((data && data.endpoint) || '');
            var mt = $('dscDbAsrMeta');
            if (mt) mt.textContent = T('認識モデル：{0} · 端点：{1}', m || '-', ep || '-');
            setStatus(st, T('✅ 認識しました（{0} 文字）。下の欄からコピーできます（対話へは自動送信しません）', text.length), 'ok');
            toast(T('✅ 認識結果を表示しました（{0} 文字）', text.length), 'success');
            copyAsrText(true);
        } catch (e) {
            setStatus(st, '❌ ' + T('認識に失敗：{0}', e.message), 'err');
            toast(T('認識に失敗：{0}', e.message), 'error');
        } finally {
            S.asrBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // 認識結果をクリップボードへコピー（自動送信はしない。失敗時は選択コピーへ退避）
    async function copyAsrText(silent) {
        var out = $('dscDbAsrText');
        var st = $('dscDbAsrStatus');
        var txt = out ? String(out.value || '') : '';
        if (!txt.trim()) {
            if (!silent) setStatus(st, '⚠️ ' + T('先に認識してください'), 'err');
            return false;
        }
        var ok = false;
        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                await navigator.clipboard.writeText(txt);
                ok = true;
            }
        } catch (e) { ok = false; }
        if (!ok) {
            try {
                out.focus();
                out.select();
                ok = document.execCommand('copy');
            } catch (e) { ok = false; }
        }
        if (!silent) {
            setStatus(st, ok ? T('📋 結果をコピーしました（{0} 文字）', txt.length)
                : '⚠️ ' + T('コピーに失敗しました。長押しで選択してコピーしてください'),
                ok ? 'ok' : 'err');
        }
        return ok;
    }

    async function deliverAsrToChat(text, st) {
        var t = String(text || '').trim();
        if (!t) return;
        // 本命：現在の対話へユーザーメッセージとして差し込む（モデル呼び出しなし）
        if (typeof window.dscInjectUserMessage === 'function') {
            var r = await window.dscInjectUserMessage(t);
            if (r && r.ok) {
                setStatus(st, T('✅ 対話に差し込みました（{0} 文字）', t.length), 'ok');
                toast(T('✅ 認識結果を対話に差し込みました'), 'success');
                setTimeout(function () { closeModal('dscDbAsrOverlay'); }, 900);
                return;
            }
            setStatus(st, '⚠️ ' + T('対話への差し込みに失敗：{0}', (r && r.error) || 'unknown'), 'err');
        }
        // 代替：入力欄へ入れる（失敗を隠さない）
        var box = document.getElementById('dscInput');
        if (box) {
            box.value = box.value ? (box.value + '\n' + t) : t;
            try { box.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            setStatus(st, '⚠️ ' + T('自動差し込みに失敗したため入力欄へ入れました。送信は手動で行ってください'), 'err');
        } else {
            setStatus(st, '❌ ' + T('対話画面が見つかりません'), 'err');
        }
    }

    // ------------------------------------------------------------
    // 画像生成
    // ------------------------------------------------------------
    function openImageModal() {
        ensureModal('dscDbImageOverlay', buildImageModal, S.imgBusy);
        loadConfig().then(function () {
            fillImageModels();
        }).catch(function (e) {
            setStatus($('dscDbImgStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbImageOverlay');
    }

    function buildImageModal() {
        var md = buildModal('dscDbImageOverlay', '🎨', '豆包で画像を生成',
            'ファイル名・説明・比率・スタイルを指定して生成します。生成物は ds_files/blob に保存されます。');
        md.appendChild(field('画像のファイル名', input('dscDbImgName', 'text', '例：夏の夜景')));
        md.appendChild(field('画像の説明（プロンプト）', textarea('dscDbImgPrompt', '例：夕暮れの海辺を歩く少女、逆光、フィルムグレイン')));

        var ratioSel = select('dscDbImgRatio', RATIOS.concat([{ value: '__custom__', label: T('カスタム比率') }]), '16:9');
        md.appendChild(field('アスペクト比', ratioSel));
        var ratioCustom = input('dscDbImgRatioCustom', 'text', '例：7:5');
        ratioCustom.style.display = 'none';
        md.appendChild(field('', ratioCustom));
        ratioSel.addEventListener('change', function () {
            ratioCustom.style.display = ratioSel.value === '__custom__' ? 'block' : 'none';
        });

        // 表示名だけを翻訳する（value はモデルへ渡すプロンプト用の識別子なので日本語のまま）
        var styleSel = select('dscDbImgStyle', IMG_STYLES_JA.map(function (s) { return { value: s, label: T(s) }; })
            .concat([{ value: '__custom__', label: T('カスタムスタイル') }]), '日本アニメ風');
        md.appendChild(field('スタイル', styleSel));
        var styleCustom = input('dscDbImgStyleCustom', 'text', '例：水彩画風、柔らかい光');
        styleCustom.style.display = 'none';
        md.appendChild(field('', styleCustom));
        styleSel.addEventListener('change', function () {
            styleCustom.style.display = styleSel.value === '__custom__' ? 'block' : 'none';
        });

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('モデル', select('dscDbImgModel', [])));
        grid.appendChild(field('解像度', select('dscDbImgRes', ['2K', '4K'], '2K')));
        md.appendChild(grid);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbImgStatus';
        md.appendChild(st);

        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbImgResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var go = el('button', 'dsc-db-btn primary', T('生成する'));
        go.type = 'button';
        go.id = 'dscDbImgGo';
        var open = el('button', 'dsc-db-btn ghost', T('ファイル管理を開く'));
        open.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(open);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbImageOverlay'); });
        open.addEventListener('click', function () {
            closeModal('dscDbImageOverlay');
            var b = $('dscFilesToggle');
            if (b) b.click();
        });
        go.addEventListener('click', generateImage);
    }

    function fillImageModels() {
        var sel = $('dscDbImgModel');
        if (!sel) return;
        var items = modelsByCat('image');
        fillSelect(sel, items, S.cfg ? S.cfg.imageModel : '');
    }

    async function generateImage() {
        if (S.imgBusy) return;
        var st = $('dscDbImgStatus');
        var btn = $('dscDbImgGo');
        var prompt = ($('dscDbImgPrompt') || {}).value || '';
        if (!prompt.trim()) { setStatus(st, T('⚠️ 画像の説明を入力してください'), 'err'); return; }
        var ratio = ($('dscDbImgRatio') || {}).value || '16:9';
        if (ratio === '__custom__') {
            ratio = (($('dscDbImgRatioCustom') || {}).value || '').trim() || '1:1';
        }
        var style = ($('dscDbImgStyle') || {}).value || '';
        var customStyle = '';
        if (style === '__custom__') {
            customStyle = (($('dscDbImgStyleCustom') || {}).value || '').trim();
            style = '';
        }
        var body = {
            prompt: prompt.trim(),
            name: (($('dscDbImgName') || {}).value || '').trim(),
            ratio: ratio,
            style: style,
            customStyle: customStyle,
            model: ($('dscDbImgModel') || {}).value || '',
            resolution: ($('dscDbImgRes') || {}).value || '2K'
        };
        S.imgBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('生成中…（最大 1〜2 分かかります）'), 'busy');
        try {
            var d;
            try {
                d = await api('/image', { method: 'POST', body: body });
            } catch (e) {
                var em = (e && e.message) || '';
                var fb = (S.cfg && S.cfg.imageModel) ? S.cfg.imageModel : '';
                if (fb && body.model && body.model !== fb && /404|does not exist|not have access/i.test(em)) {
                    setStatus(st, T('⚠️ このモデルは未開通のため、{0} に自動切替して生成します…', fb), 'busy');
                    d = await api('/image', { method: 'POST', body: Object.assign({}, body, { model: fb }) });
                    toast(T('⚠️ このモデルは未開通のため、{0} で生成しました', fb), 'info');
                } else {
                    throw e;
                }
            }
            if (d && d.fallbackFrom) {
                toast(T('ℹ️ {0} は利用不可のため {1} で生成しました', d.fallbackFrom, d.model || ''), 'info');
            }
            var f = d.file || {};
            var box = $('dscDbImgResult');
            box.innerHTML = '';
            var img = document.createElement('img');
            img.src = fileUrl(f) + '&_t=' + Date.now();
            img.alt = f.name || 'doubao image';
            box.appendChild(img);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var again = el('button', 'dsc-db-btn', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generateImage(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ 生成しました · 比率 {0} · サイズ {1}', d.ratio || ratio, d.size || ''), 'ok');
            toast(T('✅ 画像を生成しました：{0}', f.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, T('❌ 生成に失敗：{0}', e.message), 'err');
            toast(T('画像生成に失敗：{0}', e.message), 'error');
        } finally {
            S.imgBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 豆包P图（画像編集）
    //   ローカル画像を豆包へ渡し、指示どおりに修正させる。
    //   ブラウザ側で長辺 2048 / JPEG 92% に縮小してから送る（大きすぎる画像で失敗しないように）。
    // ------------------------------------------------------------
    function openEditModal() {
        ensureModal('dscDbEditOverlay', buildEditModal, S.editBusy);
        loadConfig().then(fillEditModels).catch(function (e) {
            setStatus($('dscDbEditStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbEditOverlay');
    }

    function buildEditModal() {
        var md = buildModal('dscDbEditOverlay', '🖌️', '豆包画像編集',
            '画像をアップロードし、どう直すかを伝えると豆包が修正します。結果は ds_files/blob に保存されます。');

        var pick = el('div', 'dsc-db-filepick');
        var file = document.createElement('input');
        file.type = 'file';
        file.id = 'dscDbEditFile';
        file.className = 'dsc-db-file';
        file.accept = 'image/*';
        var pickBtn = el('button', 'dsc-db-btn', T('画像を選択'));
        pickBtn.type = 'button';
        pickBtn.id = 'dscDbEditPick';
        var info = el('span', 'dsc-db-filename', T('まだ選択されていません'));
        info.id = 'dscDbEditFileInfo';
        pickBtn.addEventListener('click', function () { file.click(); });
        file.addEventListener('change', function () {
            var f = file.files && file.files[0];
            info.textContent = f ? (f.name + ' · ' + fmtSize(f.size)) : T('まだ選択されていません');
            var box = $('dscDbEditPreview');
            if (box) {
                box.innerHTML = '';
                if (f) {
                    var im = document.createElement('img');
                    im.src = URL.createObjectURL(f);
                    box.appendChild(im);
                }
            }
        });
        pick.appendChild(file);
        pick.appendChild(pickBtn);
        pick.appendChild(info);
        md.appendChild(pick);

        var prev = el('div', 'dsc-db-preview');
        prev.id = 'dscDbEditPreview';
        md.appendChild(prev);

        md.appendChild(field('P图要求（どこをどう直すか）',
            textarea('dscDbEditPrompt', '例：背景を海辺に変える／人物をそのままに髪色を黒へ／服を白いシャツに')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('モデル', select('dscDbEditModel', [])));
        grid.appendChild(field('出力サイズ', select('dscDbEditRes', ['2K', '4K'], '2K')));
        md.appendChild(grid);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbEditStatus';
        md.appendChild(st);

        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbEditResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var open = el('button', 'dsc-db-btn ghost', T('ファイル管理を開く'));
        open.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('豆包にP图してもらう'));
        go.type = 'button';
        go.id = 'dscDbEditGo';
        foot.appendChild(open);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbEditOverlay'); });
        open.addEventListener('click', function () {
            closeModal('dscDbEditOverlay');
            var b = $('dscFilesToggle');
            if (b) b.click();
        });
        go.addEventListener('click', editImage);
    }

    function fillEditModels() {
        var sel = $('dscDbEditModel');
        if (!sel) return;
        var EDIT_DEFAULT = 'doubao-seedream-5-0-pro-260628';
        var all = modelsByCat('imageedit').concat(modelsByCat('image'));
        var head = all.filter(function (m) { return m.value === EDIT_DEFAULT; });
        var rest = all.filter(function (m) { return m.value !== EDIT_DEFAULT; });
        var items = head.concat(rest);
        if (!items.length) items = [{ value: '', label: T('既定（Seedream 5.0 pro）') }];
        var pick = items.some(function (m) { return m.value === EDIT_DEFAULT; }) ? EDIT_DEFAULT : items[0].value;
        fillSelect(sel, items, pick);
    }

    // 画像を長辺 maxSide に縮小して dataURL 化（縮小不要なら元の dataURL をそのまま返す）
    function readImageDataUrl(file, maxSide, quality) {
        return new Promise(function (resolve, reject) {
            var fr = new FileReader();
            fr.onerror = function () { reject(new Error(T('画像の読み込みに失敗しました'))); };
            fr.onload = function () {
                var src = String(fr.result || '');
                if (!src) { reject(new Error(T('画像の読み込みに失敗しました'))); return; }
                var img = new Image();
                img.onerror = function () { resolve(src); };
                img.onload = function () {
                    try {
                        var w = img.naturalWidth || img.width || 0;
                        var h = img.naturalHeight || img.height || 0;
                        var scale = (w > 0 && h > 0) ? Math.min(1, maxSide / Math.max(w, h)) : 1;
                        if (scale >= 1 && src.length <= 3.5 * 1024 * 1024) { resolve(src); return; }
                        var cv = document.createElement('canvas');
                        cv.width = Math.max(1, Math.round(w * scale));
                        cv.height = Math.max(1, Math.round(h * scale));
                        var ctx = cv.getContext('2d');
                        ctx.fillStyle = '#ffffff';
                        ctx.fillRect(0, 0, cv.width, cv.height);
                        ctx.drawImage(img, 0, 0, cv.width, cv.height);
                        resolve(cv.toDataURL('image/jpeg', quality || 0.92));
                    } catch (e) { resolve(src); }
                };
                img.src = src;
            };
            fr.readAsDataURL(file);
        });
    }

    async function editImage() {
        if (S.editBusy) return;
        var st = $('dscDbEditStatus');
        var btn = $('dscDbEditGo');
        var inp = $('dscDbEditFile');
        var f = inp && inp.files && inp.files[0];
        if (!f) { setStatus(st, '⚠️ ' + T('先に画像を選択してください'), 'err'); return; }
        var prompt = (($('dscDbEditPrompt') || {}).value || '').trim();
        if (!prompt) { setStatus(st, '⚠️ ' + T('P图要求を入力してください'), 'err'); return; }
        if (f.size > 12 * 1024 * 1024) { setStatus(st, '⚠️ ' + T('画像が大きすぎます（上限 12MB）'), 'err'); return; }
        S.editBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('豆包がP图中…（最大 1〜2 分かかります）'), 'busy');
        try {
            var dataUrl = await readImageDataUrl(f, 2048, 0.92);
            var d = await api('/image-edit', {
                method: 'POST',
                body: {
                    imageBase64: dataUrl,
                    fileName: f.name || 'image.png',
                    prompt: prompt,
                    model: ($('dscDbEditModel') || {}).value || '',
                    resolution: ($('dscDbEditRes') || {}).value || '2K'
                }
            });
            if (d && d.fallbackFrom) {
                toast(T('ℹ️ {0} は利用不可のため {1} で生成しました', d.fallbackFrom, d.model || ''), 'info');
            }
            var meta = d.file || {};
            var box = $('dscDbEditResult');
            box.innerHTML = '';
            var img = document.createElement('img');
            img.src = fileUrl(meta) + '&_t=' + Date.now();
            img.alt = meta.name || 'doubao edit';
            box.appendChild(img);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', meta.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(meta)); });
            var again = el('button', 'dsc-db-btn', T('もう一度P图'));
            again.type = 'button';
            again.addEventListener('click', function () { editImage(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ P图が完成しました：{0}', meta.name || ''), 'ok');
            toast(T('✅ P图が完成しました：{0}', meta.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, '❌ ' + T('P图に失敗：{0}', e.message), 'err');
            toast(T('P图に失敗：{0}', e.message), 'error');
        } finally {
            S.editBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 動画生成
    // ------------------------------------------------------------
    function openVideoModal() {
        ensureModal('dscDbVideoOverlay', buildVideoModal, S.vidBusy);
        loadConfig().then(fillVideoModels).catch(function (e) {
            setStatus($('dscDbVidStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbVideoOverlay');
    }

    function buildVideoModal() {
        var md = buildModal('dscDbVideoOverlay', '🎬', '豆包で動画を生成',
            'Seedance によるテキスト→動画。完了まで数十秒〜数分かかり、生成物は ds_files/blob に保存されます。');
        md.appendChild(field('動画のファイル名', input('dscDbVidName', 'text', '例：海辺の夕日')));
        md.appendChild(field('動画の説明（プロンプト）', textarea('dscDbVidPrompt', '例：夕暮れの海辺をゆっくり歩く少女、カメラは背後から追従')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('アスペクト比', select('dscDbVidRatio', RATIOS, '16:9')));
        grid.appendChild(field('解像度', select('dscDbVidRes', ['480p', '720p', '1080p', '4K'], '720p')));
        grid.appendChild(field('長さ（秒）', select('dscDbVidDur', ['4', '5', '6', '8', '10', '12', '15', '20', '25', '30'], '5')));
        grid.appendChild(field('モデル', select('dscDbVidModel', [])));
        md.appendChild(grid);
        md.appendChild(switchRow('dscDbVidAudio', '音声も生成する', 'セリフ・効果音つきの動画を生成（対応モデルのみ）', true));

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbVidStatus';
        md.appendChild(st);
        var prog = el('div', 'dsc-db-progress');
        prog.innerHTML = '<i></i>';
        md.appendChild(prog);
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbVidResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var cancel = el('button', 'dsc-db-btn ghost', T('ポーリング停止'));
        cancel.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('生成する'));
        go.type = 'button';
        go.id = 'dscDbVidGo';
        foot.appendChild(cancel);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbVideoOverlay'); });
        cancel.addEventListener('click', function () {
            if (S.pollTimer) { clearTimeout(S.pollTimer); S.pollTimer = null; }
            setStatus($('dscDbVidStatus'), T('ポーリングを停止しました（タスクはサーバー側で継続）'), 'busy');
        });
        go.addEventListener('click', createVideo);
    }

    function fillVideoModels() {
        var sel = $('dscDbVidModel');
        if (!sel) return;
        fillSelect(sel, modelsByCat('video'),
            S.cfg ? S.cfg.videoModel : '');
    }

    function setProgress(pct) {
        var bar = document.querySelector('#dscDbVideoOverlay .dsc-db-progress > i');
        if (bar) bar.style.width = Math.max(0, Math.min(100, pct)) + '%';
    }

    async function createVideo() {
        if (S.vidBusy) return;
        var st = $('dscDbVidStatus');
        var btn = $('dscDbVidGo');
        var prompt = ($('dscDbVidPrompt') || {}).value || '';
        if (!prompt.trim()) { setStatus(st, T('⚠️ 動画の説明を入力してください'), 'err'); return; }
        var body = {
            prompt: prompt.trim(),
            name: (($('dscDbVidName') || {}).value || '').trim(),
            ratio: ($('dscDbVidRatio') || {}).value || '16:9',
            resolution: ($('dscDbVidRes') || {}).value || '720p',
            duration: parseInt((($('dscDbVidDur') || {}).value || '5'), 10),
            generateAudio: !!(($('dscDbVidAudio') || {}).checked),
            model: ($('dscDbVidModel') || {}).value || ''
        };
        S.vidBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('タスクを作成中…'), 'busy');
        setProgress(6);
        try {
            var d = await api('/video', { method: 'POST', body: body });
            var task = d.task || {};
            setStatus(st, T('生成中… タスク {0}', task.id || ''), 'busy');
            pollVideo(task.id, 0);
        } catch (e) {
            setStatus(st, T('❌ 生成に失敗：{0}', e.message), 'err');
            toast(T('動画生成に失敗：{0}', e.message), 'error');
            S.vidBusy = false;
            if (btn) btn.disabled = false;
            setProgress(0);
        }
    }

    async function pollVideo(taskId, tries) {
        var st = $('dscDbVidStatus');
        var btn = $('dscDbVidGo');
        if (!taskId) return;
        if (tries > 150) {
            setStatus(st, T('⚠️ タイムアウトしました。タスクはサーバー側で継続中です：{0}', taskId), 'err');
            S.vidBusy = false;
            if (btn) btn.disabled = false;
            return;
        }
        try {
            var d = await api('/video/status?taskId=' + encodeURIComponent(taskId));
            var task = d.task || {};
            var status = d.status || task.status || '';
            setProgress(Math.min(94, 8 + tries * 3));
            setStatus(st, T('状態：{0} · 経過 {1} 秒', status || 'queued', tries * 5), 'busy');
            if (status === 'succeeded') {
                setProgress(100);
                var f = task.file || null;
                var box = $('dscDbVidResult');
                box.innerHTML = '';
                if (f && f.id) {
                    var v = document.createElement('video');
                    v.src = fileUrl(f);
                    v.controls = true;
                    v.playsInline = true;
                    v.preload = 'metadata';
                    box.appendChild(v);
                    box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
                    var row = el('div', 'dsc-db-row');
                    var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
                    dl.type = 'button';
                    dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
                    row.appendChild(dl);
                    box.appendChild(row);
                    setStatus(st, T('✅ 生成しました：{0}', f.name || ''), 'ok');
                    toast(T('✅ 動画を生成しました'), 'success');
                    refreshFiles();
                } else if (task.remoteUrl) {
                    // サーバー側の保存に失敗した場合はリモート URL を明示
                    box.innerHTML = '';
                    var a = document.createElement('a');
                    a.href = task.remoteUrl;
                    a.target = '_blank';
                    a.textContent = T('生成された動画を開く（保存に失敗したため一時 URL）');
                    a.style.fontSize = '0.8rem';
                    box.appendChild(a);
                    setStatus(st, T('⚠️ 生成は成功しましたが、保存に失敗しました'), 'err');
                } else {
                    setStatus(st, T('⚠️ 生成は成功しましたが、ファイル情報がありません'), 'err');
                }
                S.vidBusy = false;
                if (btn) btn.disabled = false;
                return;
            }
            if (status === 'failed') {
                setStatus(st, T('❌ 生成に失敗：{0}', task.error || 'failed'), 'err');
                S.vidBusy = false;
                if (btn) btn.disabled = false;
                setProgress(0);
                return;
            }
            S.pollTimer = setTimeout(function () { pollVideo(taskId, tries + 1); }, 5000);
        } catch (e) {
            setStatus(st, T('⚠️ 照会に失敗（再試行します）：{0}', e.message), 'err');
            S.pollTimer = setTimeout(function () { pollVideo(taskId, tries + 1); }, 7000);
        }
    }

    // ------------------------------------------------------------
    // ポッドキャスト
    // ------------------------------------------------------------
    function openPodcastModal() {
        ensureModal('dscDbPodcastOverlay', buildPodcastModal, S.podBusy);
        loadConfig().then(function (c) {
            var vs = $('dscDbPodVoiceSel');
            if (vs && !vs.value) vs.value = 'mizai_dayi';
        }).catch(function (e) {
            setStatus($('dscDbPodStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbPodcastOverlay');
    }

    function buildPodcastModal() {
        var md = buildModal('dscDbPodcastOverlay', '🎧', '豆包ポッドキャスト',
            '豆包ネイティブポッドキャスト · 中文双人対談 · 公式音色 · 全画面没入型');
        // ★ 播客全屏：整屏覆盖层，禁止弹窗
        md.classList.add('dsc-db-podcast-modal');
        var ov0 = $('dscDbPodcastOverlay');
        if (ov0) ov0.classList.add('dsc-db-podcast-overlay');

        var info = el('div', 'dsc-db-call-info');
        info.id = 'dscDbPodInfo';
        info.textContent = T('豆包ネイティブポッドキャスト · 中文双人 · 音声ポッドキャストクォータのみ消費');
        md.appendChild(info);

        var stage = el('div', 'dsc-db-podcast-stage');

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('生成方式', select('dscDbPodAction', [
            { value: '0', label: 'テキスト生成（素材ベース）' },
            { value: '3', label: '対話合成' },
            { value: '4', label: '話題ウェブ検索生成' }
        ], '0')));
        grid.appendChild(field('音色（双人）', select('dscDbPodVoiceSel', PODCAST_VOICE_PAIRS, 'mizai_dayi')));
        stage.appendChild(grid);

        var inputArea = el('div', 'dsc-db-podcast-input');
        inputArea.id = 'dscDbPodInputArea';
        stage.appendChild(inputArea);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbPodStatus';
        stage.appendChild(st);

        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbPodResult';
        stage.appendChild(res);

        // ★ 关键修复：stage 必须挂载到 md，否则生成方式/音色/输入框/状态/结果全部不可见
        md.appendChild(stage);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', '生成播客');
        go.type = 'button';
        go.id = 'dscDbPodGo';
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbPodcastOverlay'); });
        go.addEventListener('click', generatePodcast);

        var act = $('dscDbPodAction');
        if (act) act.addEventListener('change', renderPodInput);
        renderPodInput();
    }

    // 根据生成方式动态渲染输入区
    function renderPodInput() {
        var area = $('dscDbPodInputArea');
        if (!area) return;
        var action = ($('dscDbPodAction') || {}).value || '0';
        area.innerHTML = '';
        if (action === '0') {
            area.appendChild(field('入力テキスト / 素材', textarea('dscDbPodInputText', '例：今日は人工知能の発展史について、チューリングテストからディープラーニングまで語ります。')));
        } else if (action === '3') {
            area.appendChild(field('対話テキスト（1行1発話、形式 A:xxx / B:xxx。A/B は音色ペアの2人の話者に対応）', textarea('dscDbPodInputText', 'A: 皆さん、こんにちは。\nB: 今日はAIについて話しましょう。')));
        } else if (action === '4') {
            area.appendChild(field('話題（ウェブ検索生成）', textarea('dscDbPodInputText', '例：2025年の人工知能分野の最新動向')));
        }
        area.appendChild(field('目標時間（1〜10分）', select('dscDbPodMinutes', [
            { value: '1', label: '1分' },
            { value: '2', label: '2分' },
            { value: '3', label: '3分' },
            { value: '4', label: '4分' },
            { value: '5', label: '5分（既定）' },
            { value: '6', label: '6分' },
            { value: '7', label: '7分' },
            { value: '8', label: '8分' },
            { value: '9', label: '9分' },
            { value: '10', label: '10分' }
        ], '5')));
        area.appendChild(field('ファイル名（任意）', input('dscDbPodName2', 'text', '例：マイポッドキャスト')));
    }

    // 把「A: xxx / B: xxx」对话文本解析成官方 nlp_texts（每项含 text + speaker）
    function parsePodNlpTexts(raw, pair) {
        var speakers = (pair && pair.speakers && pair.speakers.length)
            ? pair.speakers : ['zh_female_mizaitongxue_v2_saturn_bigtts', 'zh_male_dayixiansheng_v2_saturn_bigtts'];
        var out = [];
        var lines = String(raw || '').split(/\r?\n/);
        var alt = 0;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line) continue;
            var m = line.match(/^([AB])\s*[:：]\s*(.+)$/);
            var speaker;
            var text;
            if (m) {
                speaker = (m[1].toUpperCase() === 'A') ? speakers[0] : speakers[1];
                text = m[2].trim();
            } else {
                speaker = speakers[alt % 2];
                text = line;
                alt++;
            }
            if (text) out.push({ text: text, speaker: speaker });
        }
        return out;
    }

    function fillPodcastModels() {
        var sel = $('dscDbPodModel');
        if (!sel) return;
        fillSelect(sel, modelsByCat('chat'), S.cfg ? S.cfg.chatModel : '');
    }

    async function generatePodcast() {
        if (S.podBusy) return;
        var st = $('dscDbPodStatus');
        var btn = $('dscDbPodGo');
        var action = ($('dscDbPodAction') || {}).value || '0';
        var inputText = ($('dscDbPodInputText') || {}).value || '';
        if (!inputText.trim()) { setStatus(st, T('⚠️ 内容を入力してください'), 'err'); return; }
        var pairId = ($('dscDbPodVoiceSel') || {}).value || 'mizai_dayi';
        var pair = null;
        for (var pi = 0; pi < PODCAST_VOICE_PAIRS.length; pi++) {
            if (PODCAST_VOICE_PAIRS[pi].value === pairId) { pair = PODCAST_VOICE_PAIRS[pi]; break; }
        }
        var body = {
            action: parseInt(action, 10),
            name: (($('dscDbPodName2') || {}).value || '').trim()
        };
        // 音色对通过顶层 speaker_info.speakers 透传（官方：播客音色 ID 列表，仅支持 2 位发音人）
        if (pair && pair.speakers && pair.speakers.length) {
            body.speaker_info = { speakers: pair.speakers };
        }
        var minutes = parseInt(($('dscDbPodMinutes') || {}).value || '5', 10);
        if (isNaN(minutes) || minutes < 1) minutes = 1;
        if (minutes > 10) minutes = 10;
        if (action === '0') body.input_text = T('約 {0} 分のポッドキャストを生成し、以下の素材をめぐって議論してください：', minutes) + '\n' + inputText.trim();
        else if (action === '3') body.nlp_texts = parsePodNlpTexts(inputText, pair);
        else if (action === '4') body.prompt_text = T('約 {0} 分のポッドキャストを生成してください。話題：', minutes) + inputText.trim();

        S.podBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('豆包ネイティブポッドキャストを生成中…（音声が長いため約1〜3分かかります。閉じないでください）'), 'busy');
        try {
            var d = await api('/podcast/sse', { method: 'POST', body: body });
            var f = d.file || {};
            var box = $('dscDbPodResult');
            box.innerHTML = '';
            var au = document.createElement('audio');
            au.src = fileUrl(f) + '&_t=' + Date.now();
            au.controls = true;
            au.style.width = '100%';
            box.appendChild(au);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            if (d.scriptText) {
                box.appendChild(el('div', 'dsc-db-script', d.scriptText));
            }
            var row = el('div', 'dsc-db-row');
            row.style.marginTop = '10px';
            var dl = el('button', 'dsc-db-btn primary', T('音声をダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var again = el('button', 'dsc-db-btn ghost', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generatePodcast(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            var kb = d.bytes ? Math.round(d.bytes / 1024) : 0;
            setStatus(st, T('✅ 生成成功') + (kb ? (' · ' + kb + ' KB') : '') + (d.sessionId ? (' · session ' + d.sessionId) : ''), 'ok');
            toast(T('✅ 豆包ポッドキャストを生成しました'), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, '❌ ' + T('生成失敗：{0}', (e && e.message ? e.message : e)), 'err');
            toast(T('ポッドキャスト生成に失敗：{0}', (e && e.message ? e.message : e)), 'error');
        } finally {
            S.podBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 音声通話
    // ------------------------------------------------------------
    function openCallModal() {
        ensureModal('dscDbCallOverlay', buildCallModal, !!(S.call && S.call.active));
        try { renderCallExtra(); } catch (e) {}
        loadConfig().then(function (c) {
            var info = $('dscDbCallInfo');
            if (info) {
                // ★ 语音通话只消耗豆包语音通话额度（Seeduplex 端到端），
                //   不再显示「对话/识别/合成」级联三额度文案（那是误导）。
                var hasVoice = !!(c && (c.hasDuplexKey || c.hasS2s));
                info.textContent = hasVoice
                    ? T('エンドツーエンド音声通話 · 豆包音声通話クォータのみ消費 · Vivi ネイティブ音色')
                    : T('⚠️ 先に設定で豆包音声 API Key を入力してください');
                info.classList.toggle('dsc-db-call-info-ok', hasVoice);
                info.classList.toggle('dsc-db-call-info-warn', !hasVoice);
            }
        }).catch(function () {});
        openModal('dscDbCallOverlay');
    }

    // ---- 通话模式专属面板：RTC 走服务端任务编排 ----
    function renderCallExtra(mode) {
        var box = $('dscDbCallExtra');
        if (!box) return;
        var sel = $('dscDbCallMode');
        var m = mode || (sel && sel.value) || readCallMode();
        while (box.firstChild) box.removeChild(box.firstChild);
        if (m !== 'rtc') return;

        var cfg = S.cfg || {};
        var hint = el('div', 'dsc-db-hint');
        hint.textContent = T('RTC はサーバー側で音声エージェントを起動します。ブラウザで実際に通話するには公式 RTC Web SDK で同じルームに参加してください（本アプリには同梱していません）。');
        box.appendChild(hint);

        var row1 = el('div', 'dsc-db-call-textrow');
        row1.appendChild(field(T('ルーム ID'), input('dscDbRtcRoom', 'text', 'RTC のルーム ID', cfg.rtcRoomId || '')));
        row1.appendChild(field(T('ユーザー ID'), input('dscDbRtcUser', 'text', '例：dsc_user', 'dsc_user')));
        box.appendChild(row1);

        var row2 = el('div', 'dsc-db-call-textrow');
        row2.appendChild(field(T('音色 ID'), input('dscDbRtcVoice', 'text', '空欄なら既定', cfg.duplexVoice || cfg.voice || '')));
        box.appendChild(row2);

        var acts = el('div', 'dsc-db-call-actions');
        var bStart = el('button', 'dsc-db-btn primary', T('RTC タスクを起動'));
        bStart.type = 'button';
        bStart.id = 'dscDbRtcStart';
        var bStop = el('button', 'dsc-db-btn danger', T('RTC タスクを停止'));
        bStop.type = 'button';
        bStop.id = 'dscDbRtcStop';
        var bProbe = el('button', 'dsc-db-btn', T('状態を確認'));
        bProbe.type = 'button';
        bProbe.id = 'dscDbRtcProbe';
        acts.appendChild(bStart);
        acts.appendChild(bStop);
        acts.appendChild(bProbe);
        box.appendChild(acts);

        var out = el('div', 'dsc-db-hint');
        out.id = 'dscDbRtcOut';
        out.textContent = T('未起動');
        box.appendChild(out);

        if (window.dscRtc) window.dscRtc.bind(addBubble, setCallStatus);

        function val(id) {
            var n = $(id);
            return n ? String(n.value || '').trim() : '';
        }

        bStart.addEventListener('click', async function () {
            if (!window.dscRtc) { addBubble('sys', T('RTC モジュールが読み込まれていません')); return; }
            if (!val('dscDbRtcRoom')) { addBubble('sys', T('ルーム ID を入力してください')); return; }
            bStart.disabled = true;
            try {
                var r = await window.dscRtc.start({
                    roomId: val('dscDbRtcRoom'),
                    userId: val('dscDbRtcUser') || 'dsc_user',
                    voice: val('dscDbRtcVoice'),
                    lang: cfg.duplexLang || 'zh',
                    llmModel: cfg.chatModel || ''
                });
                if (out) out.textContent = (r && r.ok) ? ('TaskId: ' + r.taskId) : T('起動失敗');
            } finally {
                bStart.disabled = false;
            }
        });

        bStop.addEventListener('click', async function () {
            if (!window.dscRtc) return;
            var r = await window.dscRtc.stop();
            if (out) out.textContent = (r && r.ok) ? T('待機中') : T('停止する RTC タスクがありません');
        });

        bProbe.addEventListener('click', async function () {
            if (!window.dscRtc) return;
            var d = await window.dscRtc.probe();
            var info = (d && d.rtc) || {};
            if (info.available) {
                addBubble('sys', T('RTC 設定は就緒しています（AppId: {0}）', info.appId || '-'));
            } else {
                // 服务端给的是「未設定：A / B」形式，去掉日文前缀后按当前语言显示
                var rs = String(info.reason || '').replace(/^未設定：/, '');
                addBubble('sys', T('RTC 設定が不足しています：{0}',
                    rs || T('不明なエラー')));
            }
            var dp = (d && d.duplex) || {};
            addBubble('sys', dp.available
                ? T('Seeduplex は就緒しています')
                : T('Seeduplex 未設定：{0}', T(String(dp.reason || '')) || T('不明なエラー')));
        });
    }

    function buildCallModal() {
        var md = buildModal('dscDbCallOverlay', '📞', '豆包音声通話',
            '全双工エンドツーエンド · 豆包 Vivi ネイティブ音色 · 同時通話・割り込み対応');
        // ★ 通话界面全屏：整屏沉浸式，不跳转任何页面（单页应用内联覆盖层）
        md.classList.add('dsc-db-call-modal');
        var ov0 = $('dscDbCallOverlay');
        if (ov0) ov0.classList.add('dsc-db-call-overlay');

        // 顶部状态条
        var info = el('div', 'dsc-db-call-info');
        info.id = 'dscDbCallInfo';
        md.appendChild(info);

        var stage = el('div', 'dsc-db-call-stage');

        // 中央主视觉：波形圆环
        var orbWrap = el('div', 'dsc-db-call-orbwrap');
        var orb = el('div', 'dsc-db-call-orb');
        orb.id = 'dscDbCallOrb';
        var wave = el('div', 'dsc-db-call-wave');
        for (var wi = 0; wi < 5; wi++) {
            var bar = el('span', 'dsc-db-call-wavebar');
            bar.style.animationDelay = (wi * 0.12) + 's';
            wave.appendChild(bar);
        }
        orb.appendChild(wave);
        orbWrap.appendChild(orb);
        stage.appendChild(orbWrap);

        // 状态文字
        var status = el('div', 'dsc-db-call-status', T('待機中'));
        status.id = 'dscDbCallStatus';
        stage.appendChild(status);

        // 字幕气泡
        var log = el('div', 'dsc-db-call-log');
        log.id = 'dscDbCallLog';
        stage.appendChild(log);

        // 底部控制区：三键通话布局（静音 / 挂断 / 打断）
        var actions = el('div', 'dsc-db-call-actions');
        var mic = el('button', 'dsc-db-call-btn mic');
        mic.type = 'button';
        mic.id = 'dscDbCallMic';
        mic.title = T('マイク');
        mic.appendChild(el('span', 'dsc-db-call-btn-ico', '🎙️'));
        mic.appendChild(el('span', 'dsc-db-call-btn-lbl', T('ミュート')));
        var hang = el('button', 'dsc-db-call-btn hang');
        hang.type = 'button';
        hang.id = 'dscDbCallHang';
        hang.title = T('通話を終了');
        hang.appendChild(el('span', 'dsc-db-call-btn-ico', '📞'));
        hang.appendChild(el('span', 'dsc-db-call-btn-lbl', T('通話終了')));
        var cxl = el('button', 'dsc-db-call-btn cxl');
        cxl.type = 'button';
        cxl.id = 'dscDbCallCancel';
        cxl.title = T('割り込み');
        cxl.appendChild(el('span', 'dsc-db-call-btn-ico', '⏹'));
        cxl.appendChild(el('span', 'dsc-db-call-btn-lbl', T('割り込み')));
        actions.appendChild(mic);
        actions.appendChild(hang);
        actions.appendChild(cxl);
        stage.appendChild(actions);

        // 开始通话大按钮（未连接时突出显示）
        var startWrap = el('div', 'dsc-db-call-startwrap');
        var start = el('button', 'dsc-db-call-start');
        start.type = 'button';
        start.id = 'dscDbCallStart';
        start.textContent = T('通話を開始');
        startWrap.appendChild(start);
        stage.appendChild(startWrap);

        // 模式切换（折叠到左下角，不抢视觉焦点）
        var modeRow = el('div', 'dsc-db-call-moderow');
        var voiceSel = select('dscDbCallVoiceSel', DUPLEX_VOICES,
            (S.cfg && S.cfg.duplexVoice) || 'zh_female_vv_uranus_bigtts');
        modeRow.appendChild(field('音色', voiceSel));
        var modeSel = select('dscDbCallMode', [
            { value: 'duplex', label: '全二重' },
            { value: 'rtc', label: 'RTC' }
        ], readCallMode());
        modeRow.appendChild(field('モード', modeSel));
        stage.appendChild(modeRow);
        var extra = el('div', 'dsc-db-call-extra');
        extra.id = 'dscDbCallExtra';
        stage.appendChild(extra);
        renderCallExtra();
        // 模式切换：保存选择并重绘对应面板（RTC 面板按需显示）
        modeSel.addEventListener('change', function () {
            writeCallMode(modeSel.value);
            renderCallExtra(modeSel.value);
        });

        md.appendChild(stage);

        var foot = el('div', 'dsc-db-footer');
        var hist = el('button', 'dsc-db-btn', T('通話履歴'));
        hist.type = 'button';
        hist.id = 'dscDbCallHistBtn';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(hist);
        foot.appendChild(close);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbCallOverlay'); });
        hist.addEventListener('click', function () { openVoiceHistoryModal(); });

        // 事件绑定
        start.addEventListener('click', startCall);
        hang.addEventListener('click', function () {
            stopCall();
            addBubble('sys', T('通話を終了しました'));
            setCallStatus(T('待機中'), '');
        });
        mic.addEventListener('click', toggleMic);
        cxl.addEventListener('click', function () {
            if (S.call && S.call.duplex && window.dscDuplex) {
                window.dscDuplex.cancel();
                addBubble('sys', T('現在の応答を割り込みました'));
            } else {
                toast(T('全二重モードでのみ使用できます'));
            }
        });
    }


    // ------------------------------------------------------------
    // 历史通话记录：查看 / 单选删除 / 批量删除 / 一键删除
    //   · 只读展示，不可修改
    //   · 后端真实删除 data/voice/*.sts 文件（无幽灵文件）
    // ------------------------------------------------------------
    function openVoiceHistoryModal() {
        ensureModal('dscDbVoiceHistOverlay', buildVoiceHistoryModal, false);
        openModal('dscDbVoiceHistOverlay');
        loadVoiceHistory();
    }

    function buildVoiceHistoryModal() {
        var md = buildModal('dscDbVoiceHistOverlay', '🗂️', '通話履歴',
            '閲覧のみ。個別削除・一括削除・全削除に対応（ファイルを実際に削除し、元に戻せません）。');
        md.classList.add('dsc-db-hist-modal');

        // 顶部操作栏
        var bar = el('div', 'dsc-db-hist-bar');
        var selAll = el('button', 'dsc-db-btn', T('すべて選択'));
        selAll.type = 'button';
        selAll.id = 'dscDbHistSelAll';
        var batchDel = el('button', 'dsc-db-btn danger', '🗑️ ' + T('一括削除'));
        batchDel.type = 'button';
        batchDel.id = 'dscDbHistBatchDel';
        var clearAll = el('button', 'dsc-db-btn danger', '🗑️ ' + T('すべて削除'));
        clearAll.type = 'button';
        clearAll.id = 'dscDbHistClearAll';
        var refresh = el('button', 'dsc-db-btn', T('更新'));
        refresh.type = 'button';
        refresh.id = 'dscDbHistRefresh';
        bar.appendChild(selAll);
        bar.appendChild(batchDel);
        bar.appendChild(clearAll);
        bar.appendChild(refresh);
        md.appendChild(bar);

        var list = el('div', 'dsc-db-hist-list');
        list.id = 'dscDbHistList';
        md.appendChild(list);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbHistStatus';
        md.appendChild(st);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(close);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbVoiceHistOverlay'); });
        selAll.addEventListener('click', function () {
            var boxes = list.querySelectorAll('.dsc-db-hist-check');
            var allChecked = true;
            boxes.forEach(function (b) { if (!b.checked) allChecked = false; });
            boxes.forEach(function (b) { b.checked = !allChecked; });
        });
        refresh.addEventListener('click', loadVoiceHistory);
        batchDel.addEventListener('click', function () { deleteVoiceHistory(selectedHistNames()); });
        clearAll.addEventListener('click', function () {
            if (!window.confirm(T('すべての通話履歴を完全に削除しますか？この操作は元に戻せません。'))) return;
            fetch('/api/doubao/voice/clear', { method: 'POST' })
                .then(function (r) { return r.json(); })
                .then(function (d) {
                    showHistDeleted((d && d.removed) || 0);
                    loadVoiceHistory();
                })
                .catch(function (e) { toast(T('削除に失敗：{0}', e.message), 'error'); });
        });
    }

    function selectedHistNames() {
        var list = $('dscDbHistList');
        var names = [];
        if (!list) return names;
        list.querySelectorAll('.dsc-db-hist-check').forEach(function (b) {
            if (b.checked) names.push(b.getAttribute('data-name'));
        });
        return names;
    }

    function deleteVoiceHistory(names) {
        if (!names || !names.length) {
            toast(T('削除する記録を先に選択してください'), 'info');
            return;
        }
        if (!window.confirm(T('選択した {0} 件の通話記録を削除しますか？この操作は元に戻せません。', names.length))) return;
        fetch('/api/doubao/voice/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ names: names })
        }).then(function (r) { return r.json(); }).then(function (d) {
            showHistDeleted((d && d.removed) || 0);
            loadVoiceHistory();
        }).catch(function (e) {
            toast(T('削除に失敗：{0}', e.message), 'error');
        });
    }

    // 删除后的显著提示：toast + 状态栏，明确提示共删除了多少条
    function showHistDeleted(n) {
        toast(T('✅ 削除成功：計 {0} 件の通話記録を削除しました', n), 'success');
        var st = $('dscDbHistStatus');
        if (st) setStatus(st, T('✅ {0} 件の通話記録を削除しました', n), 'ok');
    }

    // 把 .sts 原始行（数据1|数据2|数据3|数据4|数据5）渲染成人看的对话格式
    //   数据1=时间戳(ms) 数据2=角色(user/ai) 数据3=文本 数据4=序号 数据5=语言
    function renderHistLine(ln) {
        var parts = String(ln || '').split('|');
        var wrap = el('div', 'dsc-db-hist-msg');
        if (parts.length >= 3) {
            var ts = parseInt(parts[0], 10) || 0;
            var role = parts[1];
            var text = parts[2] || '';
            text = text.replace(/｜/g, '|');  // 保存时把 | 转义成 ｜，这里还原
            var roleLabel = role === 'user' ? T('自分') : (role === 'ai' ? T('豆包') : role);
            var head = el('div', 'dsc-db-hist-msg-head');
            head.appendChild(el('span', 'dsc-db-hist-role ' + (role === 'user' ? 'user' : 'ai'), roleLabel));
            var timeStr = fmtHistTime(ts);
            if (timeStr) head.appendChild(el('span', 'dsc-db-hist-time', timeStr));
            wrap.appendChild(head);
            wrap.appendChild(el('div', 'dsc-db-hist-text', text));
        } else {
            wrap.appendChild(el('div', 'dsc-db-hist-text', ln));
        }
        return wrap;
    }

    function fmtHistTime(ms) {
        if (!ms) return '';
        try {
            var d = new Date(ms);
            var p = function (n) { return (n < 10 ? '0' : '') + n; };
            return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
                ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
        } catch (e) { return ''; }
    }

    function loadVoiceHistory() {
        var list = $('dscDbHistList');
        var st = $('dscDbHistStatus');
        if (st) setStatus(st, T('読み込み中…'), 'busy');
        fetch('/api/doubao/voice/list', { cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                var records = (d && d.records) || [];
                if (!list) return;
                list.innerHTML = '';
                if (!records.length) {
                    list.appendChild(el('div', 'dsc-db-hist-empty', T('通話履歴がありません')));
                    if (st) setStatus(st, T('通話履歴がありません'), '');
                    return;
                }
                records.forEach(function (rec) {
                    var row = el('div', 'dsc-db-hist-item');
                    // 复选框（真实删除用文件名）
                    var chk = document.createElement('input');
                    chk.type = 'checkbox';
                    chk.className = 'dsc-db-hist-check';
                    chk.setAttribute('data-name', rec.name);
                    row.appendChild(chk);

                    var body = el('div', 'dsc-db-hist-body');
                    var head = el('div', 'dsc-db-hist-head');
                    head.appendChild(el('span', 'dsc-db-hist-preview', rec.preview || T('（空の記録）')));
                    head.appendChild(el('span', 'dsc-db-hist-meta',
                        (rec.lineCount || 0) + T(' 行 · ') + fmtHistTime(rec.mtime)));
                    body.appendChild(head);
                    // 展开/收起正文
                    var detail = el('div', 'dsc-db-hist-detail');
                    detail.style.display = 'none';
                    (rec.lines || []).forEach(function (ln) {
                        detail.appendChild(renderHistLine(ln));
                    });
                    body.appendChild(detail);
                    row.appendChild(body);

                    // 操作：查看 / 单选删除
                    var ops = el('div', 'dsc-db-hist-ops');
                    var view = el('button', 'dsc-db-btn ghost', T('表示'));
                    view.type = 'button';
                    var del = el('button', 'dsc-db-btn danger', '🗑️ ' + T('削除'));
                    del.type = 'button';
                    ops.appendChild(view);
                    ops.appendChild(del);
                    row.appendChild(ops);

                    view.addEventListener('click', function () {
                        var show = detail.style.display === 'none';
                        detail.style.display = show ? 'block' : 'none';
                        view.textContent = show ? T('閉じる') : T('表示');
                    });
                    del.addEventListener('click', function () {
                        deleteVoiceHistory([rec.name]);
                    });

                    list.appendChild(row);
                });
                if (st) setStatus(st, T('計 {0} 件の記録', records.length), 'ok');
            })
            .catch(function (e) {
                if (list) list.innerHTML = '';
                if (st) setStatus(st, T('読み込みに失敗：{0}', (e && e.message)), 'err');
            });
    }

    function setCallStatus(text, cls) {
        var n = $('dscDbCallStatus');
        if (n) n.textContent = text;
        var orb = $('dscDbCallOrb');
        if (orb) {
            orb.className = 'dsc-db-call-orb' + (cls ? ' ' + cls : '');
        }
    }

    function addBubble(kind, text) {
        var log = $('dscDbCallLog');
        if (!log) return;
        // 不画气泡框：纯文本字幕行（用户明确要求禁止气泡框）
        var b = el('div', 'dsc-call-line ' + kind, text);
        log.appendChild(b);
        log.scrollTop = log.scrollHeight;
    }

    var CALL_MODE_KEY = 'dsc_doubao_call_mode';

    function readCallMode() {
        try {
            var v = localStorage.getItem(CALL_MODE_KEY);
            return (v === 'duplex' || v === 'rtc') ? v : 'duplex';
        } catch (e) { return 'duplex'; }
    }

    function writeCallMode(m) {
        try { localStorage.setItem(CALL_MODE_KEY, (m === 'duplex' || m === 'rtc') ? m : 'duplex'); } catch (e) {}
    }

    function newCallState() {
        return {
            active: false,
            duplex: false,
            rtc: false,
            stream: null,
            ctx: null,
            analyser: null,
            recorder: null,
            chunks: [],
            recording: false,
            voiceFrames: 0,
            silenceMs: 0,
            loopTimer: null,
            audio: null,
            audioEl: null,      // 复用同一个音频元素，避免自动播放被拦截
            playing: false,
            thinking: false,
            micOn: true,
            history: []
        };
    }

    async function startCall() {
        if (S.call && S.call.active) return;
        
        S.call = newCallState();

        // 预解锁音频元素：用户刚点下「开始通话」的这一下就是可用手势，
        // 此时先让同一个 <audio> 播一段静音，后面所有语音都复用它，
        // 就不会被浏览器的自动播放策略拦住（那种情况的表现就是完全没声音）。
        try {
            var unlock = new Audio("data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA");
            unlock.preload = 'auto';
            S.call.audioEl = unlock;
            var up = unlock.play();
            if (up && up.catch) up.catch(function () {});
        } catch (e) {}
        S.call.active = true;
        S.call.micOn = true;
        S.call.duplex = true; 
        
        var logBox = $('dscDbCallLog');
        if (logBox) logBox.innerHTML = '';
        addBubble('sys', T('全二重サービスに接続中…'));

        if (!window.dscDuplex) {
            addBubble('sys', T('全二重モジュールが読み込まれていません'));
            return;
        }

        // ★ 全双工通话人声：优先用豆包端到端回传的原生 vivi 音色（dsc-duplex 内部 playPcm）。
        //   这里的 onText 只作为「豆包原生音频整轮没返回」时的 Edge TTS 兜底，
        //   避免 AI 全程哑巴；同一句重复、先半句后整句的去重由 dscSpeakCallText() 处理。
        window.dscDuplex.onText = function (text) {
            if (!S.call || !S.call.active) return;
            dscSpeakCallText(text);
        };

        // 音色选择：把用户在通话界面选的官方音色传给全双工模块
        var _vs = $('dscDbCallVoiceSel');
        if (_vs && _vs.value && window.dscDuplex && window.dscDuplex.setVoice) {
            window.dscDuplex.setVoice(_vs.value);
        }
        try {
            await window.dscDuplex.start();
            setCallStatus(T('接続済み（全二重）'), 'listening');
            addBubble('sys', T('接続成功。話しかけてください！'));
            // ★ 通话中隐藏「开始通话」大按钮，界面更沉浸
            var _sb = $('dscDbCallStart');
            if (_sb) _sb.style.display = 'none';
        } catch(e) {
            addBubble('sys', T('接続失敗：') + e.message);
            setCallStatus(T('接続エラー'), '');
        }
    }

    function stopCall() {
        var c = S.call;
        if (!c) return;
        var historyToSave = null;
        if (c.duplex && window.dscDuplex) {
            try {
                var h = window.dscDuplex.getHistory();
                if (h && h.length) historyToSave = h;
                window.dscDuplex.stop();
            } catch (e) {}
        }
        c.active = false;
        c.duplex = false;
        stopCallAudio();              // 停掉正在播放的人声
        CALL_SAY.lastText = '';       // 清空去重记录，下次通话重新开始
        CALL_SAY.lastAt = 0;
        CALL_SAY.recent = {};
        if (c.audio) { c.audio.pause(); c.audio = null; }
        c.audioEl = null;             // 释放复用的音频元素
        setCallStatus(T('待機中'), '');
        addBubble('sys', T('通話を終了しました。'));
        // ★ 断开后恢复「开始通话」按钮
        var _sb2 = $('dscDbCallStart');
        if (_sb2) _sb2.style.display = '';
        // ★ 一次通话 = 一次保存：把本次通话的纯文本记录写入 kewe/data/voice/*.sts
        if (historyToSave && historyToSave.length) {
            saveVoiceLog(historyToSave);
        }
    }

    // 保存通话记录（纯文本）到 kewe/data/voice/
    // 每行格式：数据1|数据2|数据3|数据4|数据5
    //   = 时间戳(ms)|角色(user/ai)|文本|序号|语言
    function saveVoiceLog(history) {
        var lines = history.map(function (h) {
            var text = String(h.text || '').replace(/\|/g, '｜').replace(/\r?\n/g, ' ');
            return [h.at, h.role, text, h.seq, lang()].join('|');
        });
        fetch('/api/doubao/voice/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ lines: lines })
        }).then(function (r) { return r.json(); }).then(function (d) {
            if (d && d.ok) {
                toast(T('✅ 通話記録を保存しました：') + (d.file || ''), 'success');
            }
        }).catch(function (e) {
            console.log('[CALL] 通话记录保存失败：', e && e.message);
        });
    }

    function toggleMic() {
        var c = S.call;
        if (c && c.duplex && window.dscDuplex) {
            var on = window.dscDuplex.setMic(!c.micOn);
            c.micOn = on;
            var mb = $('dscDbCallMic');
            if (mb) {
                var _lbl = mb.querySelector('.dsc-db-call-btn-lbl');
                if (_lbl) _lbl.textContent = on ? T('マイクON') : T('ミュート');
                else mb.textContent = on ? T('マイクON') : T('ミュート');
                mb.classList.toggle('dsc-db-mic-off', !on);
            }
            return;
        }
        if (!c || !c.stream) { toast(T('通話を開始してください'), 'info'); return; }
        c.micOn = !c.micOn;
        try { c.stream.getAudioTracks().forEach(function (t) { t.enabled = c.micOn; }); } catch (e) {}
        if (!c.micOn && c.recording) { try { c.recorder.stop(); } catch (e) {} }
        var b = $('dscDbCallMic');
        if (b) {
            var _lbl2 = b.querySelector('.dsc-db-call-btn-lbl');
            if (_lbl2) _lbl2.textContent = c.micOn ? T('マイクON') : T('ミュート');
            else b.textContent = c.micOn ? T('マイクON') : T('ミュート');
            b.classList.toggle('dsc-db-mic-off', !c.micOn);
        }
        setCallStatus(c.micOn ? T('聞き取り中…') : T('ミュート中'), c.micOn ? 'listening' : '');
    }

    function callLoop() {
        var c = S.call;
        if (!c || !c.active || c.playing || c.thinking || !c.micOn || !c.analyser || c.recording) return;
        
        var buf = new Uint8Array(c.analyser.fftSize);
        c.analyser.getByteTimeDomainData(buf);
        var sum = 0;
        for (var i = 0; i < buf.length; i++) {
            var v = (buf[i] - 128) / 128;
            sum += v * v;
        }
        var rms = Math.sqrt(sum / buf.length);
        
        // ★ 修复：降低阈值到 0.015，只要稍微有点声音就开始录音
        if (rms > 0.015) {
            c.voiceFrames = (c.voiceFrames || 0) + 1;
            if (c.voiceFrames >= 2 && !c.recording) {
                startRec();
            }
        } else {
            c.voiceFrames = 0;
            if (c.recording) {
                // 停顿 1.2 秒没有声音就切断
                c.silenceMs = (c.silenceMs || 0) + 200;
                if (c.silenceMs >= 1200) {
                    stopRec();
                }
            }
        }
    }

    function startRec() {
        var c = S.call;
        if (!c || !c.stream || c.recording) return;
        var options = {};
        try {
            var mimes = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];
            for (var i = 0; i < mimes.length; i++) {
                if (window.MediaRecorder && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(mimes[i])) {
                    options.mimeType = mimes[i];
                    break;
                }
            }
            c.recorder = new MediaRecorder(c.stream, options);
        } catch (e) {
            try { c.recorder = new MediaRecorder(c.stream); } catch (e2) { return; }
        }
        c.chunks = [];
        c.silenceMs = 0;
        c.recorder.ondataavailable = function (ev) {
            if (ev.data && ev.data.size > 0) c.chunks.push(ev.data);
        };
        c.recorder.onstop = function () {
            var mime = (c.recorder && c.recorder.mimeType) || 'audio/webm';
            var blob = new Blob(c.chunks, { type: mime });
            c.chunks = [];
            c.recording = false;
            c.silenceMs = 0;
            if (blob.size > 1200 && c.active) sendCallTurn(blob, '');
        };
        try {
            c.recorder.start(200);
            c.recording = true;
            setCallStatus(T('聞き取り中…'), 'listening');
        } catch (e) {
            c.recording = false;
        }
    }

    function stopRec() {
        var c = S.call;
        if (!c || !c.recorder || !c.recording) return;
        try { c.recorder.stop(); } catch (e) { c.recording = false; }
    }

    function blobToBase64(blob) {
        return new Promise(function (resolve, reject) {
            var r = new FileReader();
            r.onload = function () {
                var s = String(r.result || '');
                var i = s.indexOf(',');
                resolve(i >= 0 ? s.slice(i + 1) : '');
            };
            r.onerror = function () { reject(new Error('read error')); };
            r.readAsDataURL(blob);
        });
    }

    async function sendCallTurn(blob, text) {
        var c = S.call;
        if (!c || !c.active) return;
        if (c.thinking) return;
        c.thinking = true;
        setCallStatus(T('考えています…'), 'thinking');
        var body = {
            fileName: 'audio.webm',
            lang: lang(),
            voice: callVoice(),
            model: (S.cfg && S.cfg.chatModel) || '',
            history: c.history.slice(-12)
        };
        try {
            if (blob) {
                var b64 = await blobToBase64(blob);
                if (!b64) throw new Error('音声の読み取りに失敗しました');
                body.audioBase64 = b64;
            } else {
                body.text = text;
            }
            var d = await api('/voice/turn', { method: 'POST', body: body });
            if (!c.active) return;
            if (d.userText) addBubble('user', d.userText);
            if (d.reply) addBubble('ai', d.reply);
            c.history.push({ role: 'user', content: d.userText || text || '' });
            c.history.push({ role: 'assistant', content: d.reply || '' });
            if (d.ttsEngine === 'edge' && d.reply) {
                // 后端只回文字，声音由前端走 /api/tts 合成落盘后播放
                dscSpeakCallText(d.reply);
            } else if (d.audioUrl) {
                playCallAudio(d.audioUrl);
            } else {
                setCallStatus(T('聞き取り中…'), 'listening');
            }
        } catch (e) {
            addBubble('sys', T('通話でエラー：{0}', e.message));
            setCallStatus(T('聞き取り中…'), 'listening');
        } finally {
            c.thinking = false;
        }
    }

    /// 播放通话回复音频（落盘后的 audioUrl）
    //   复用同一个 <audio> 元素：它已在通话开始时被用户手势解锁过。
    //   每段语音都新建元素，更容易被浏览器自动播放策略拦截（表现就是完全没声音）。
    function playCallAudio(url) {
        var c = S.call;
        if (!c || !url) return;

        if (!c.audioEl) {
            c.audioEl = new Audio();
            c.audioEl.preload = 'auto';
        }
        var audio = c.audioEl;
        c.audio = audio;
        try { audio.pause(); } catch (e) {}
        audio.onended = null;
        audio.onerror = null;

        c.playing = true;
        setCallStatus(T('読み上げ中…'), 'speaking');

        // 播放或下载失败时统一收敛到这里，只报一次真实原因
        var failed = false;
        function fail(msg) {
            if (failed) return;
            failed = true;
            c.playing = false;
            addBubble('sys', msg);
            if (c.active) setCallStatus(T('聞き取り中…'), 'listening');
        }

        // ★ 先整段下载到内存，再用本地 blob: 地址播放。
        //   直接 audio.src 指向 /api/ds-files/download 时，媒体元素依赖服务端
        //   支持 Range 分段请求，一旦服务端不支持就会立刻触发 onerror，
        //   界面只会显示「音频加载失败」，看不出真正原因。
        //   改成完整下载再播放后：不依赖 Range、不产生两段竞态，稳定可预期。
        fetch(url, { cache: 'no-store' }).then(function (res) {
            if (!res.ok) throw new Error('下载音频失败（HTTP ' + res.status + '）');
            return res.blob();
        }).then(function (blob) {
            if (!c.active) return;
            var size = blob ? blob.size : 0;
            if (!size || size < 200) {
                throw new Error('下载到的音频为空（' + size + ' 字节）');
            }
            // 释放上一段语音的临时地址，避免内存一直涨
            if (c.lastObjUrl) {
                try { URL.revokeObjectURL(c.lastObjUrl); } catch (e) {}
                c.lastObjUrl = '';
            }
            c.lastObjUrl = URL.createObjectURL(blob);
            audio.src = c.lastObjUrl;

            audio.onended = function () {
                c.playing = false;
                if (c.active) setCallStatus(T('聞き取り中…'), 'listening');
            };
            audio.onerror = function () {
                fail('音频解码失败（已下载 ' + size + ' 字节，可能不是有效的音频）');
            };

            var p = audio.play();
            if (p && p.catch) {
                p.catch(function (e) {
                    var nm = (e && e.name) || '';
                    // 自动播放被拦截：换数据源也没用，必须让用户点一下面板
                    if (nm === 'NotAllowedError') {
                        fail('自动播放被拦截：请先点一下通话面板再试');
                        return;
                    }
                    // 其他情况（个别 WebView 不认 blob: 音频地址）：
                    // 兜底改成 data: 地址再播一次，这条路径几乎所有内核都支持。
                    try {
                        var fr = new FileReader();
                        fr.onload = function () {
                            audio.src = String(fr.result || '');
                            var p2 = audio.play();
                            if (p2 && p2.catch) {
                                p2.catch(function (e2) {
                                    fail('播放失败：' + ((e2 && e2.message) || e2));
                                });
                            }
                        };
                        fr.onerror = function () { fail('音频读取失败'); };
                        fr.readAsDataURL(blob);
                    } catch (e3) {
                        fail('播放失败：' + ((e3 && e3.message) || e3));
                    }
                });
            }
        }).catch(function (e) {
            fail('音频加载失败：' + ((e && e.message) || e));
        });
    }

    // ------------------------------------------------------------
    // 豆包モード：左上の「＋」の左側に置くトグル
    //   ON  → 送信・続き生成のモデルを豆包の会話モデルへ差し替え（豆包 API のトークンを消費）
    //   OFF → 従来どおり DeepSeek API（モデルは設定の DeepSeek モデル）
    // ------------------------------------------------------------
    var DB_MODE_KEY = 'dsc_doubao_mode';
    // ★ ST 维度：独立于 DeepSeek（ds）/ 豆包（db）的第三维度。
    //   同一个聊天窗口，三条消息流互不可见（后端按 dim=ds/db/st 过滤）。
    //   三个维度互斥：ST 开启时豆包模式必为 OFF，反之亦然。
    var ST_DIM_KEY = 'dsc_st_dim';

    function isStDim() {
        // ★ 停用整改：st 维度已下线，恒返回 false，杜绝刷新后被拽回 st。
        try { if (localStorage.getItem(ST_DIM_KEY) === '1') localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
        return false;
    }

    // 全画面统一的维度标识：'ds' | 'db' | 'st'
    window.dscDimOn = function () {
        try { if (isStDim()) return 'st'; } catch (e) {}
        try { if (isDbMode()) return 'db'; } catch (e) {}
        return 'ds';
    };

    function isDbMode() {
        try { return localStorage.getItem(DB_MODE_KEY) === '1'; } catch (e) { return false; }
    }

    // 入力欄のモデル選択器で選んだ豆包モデルは localStorage に保持する。
    //   ・後端 /api/doubao/config への単項目 POST は、実装が「全項目上書き」だった場合に
    //     API Key を空で潰す危険があるため行わない（安全側に倒す）。
    //   ・代わりにこのキーを最優先で参照し、送信モデルの解決に使う。
    var DB_CHAT_MODEL_OVERRIDE_KEY = 'dsc_doubao_chat_model';

    function dbChatModelOverride() {
        try { return String(localStorage.getItem(DB_CHAT_MODEL_OVERRIDE_KEY) || '').trim(); } catch (e) { return ''; }
    }

    function setDbChatModelOverride(v) {
        try {
            if (v) localStorage.setItem(DB_CHAT_MODEL_OVERRIDE_KEY, v);
            else localStorage.removeItem(DB_CHAT_MODEL_OVERRIDE_KEY);
        } catch (e) {}
    }

    function dbChatModel() {
        var ov = dbChatModelOverride();
        if (ov) return ov;
        var m = (S.cfg && S.cfg.chatModel) ? String(S.cfg.chatModel).trim() : '';
        return m || 'doubao-seed-2-1-pro-260628';
    }

    // 他モジュール（deepseek-chat.js）から参照する公開 API
    //   ・豆包モード中か ・この値が豆包系モデルか ・豆包の対話モデル値
    window.dscDoubaoModeOn = function () { return isDbMode(); };
    window.dscDoubaoChatModel = function () { return dbChatModel(); };
    window.dscIsDoubaoModelId = function (v) {
        v = String(v || '').trim();
        if (!v) return false;
        if (isDbModelValue(v)) return true;
        if (S.catalog && S.catalog.some(function (m) { return m.value === v; })) return true;
        return /^(doubao|glm|seed|volc)/i.test(v);
    };

    function syncDbModeUI() {
        var b = $('dscDbModeBtn');
        if (!b) return;
        var on = isDbMode();
        if (on) b.classList.add('active'); else b.classList.remove('active');
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
        qmSyncBtn();   // 入力欄のモデル選択器も同時に追従
        var lbl = b.querySelector('.dsc-db-mode-lbl');
        ensureDbModeIcon(lbl);
        // title は静的な文だけを翻訳対象にし、モデル値は識別子として連結する
        b.title = on
            ? T('豆包モード：オン（送信は豆包モデル）') + ' · ' + dbChatModel()
            : T('豆包モード：オフ（送信は DeepSeek）');
        b.setAttribute('aria-label', b.title);
        syncWikiBtnUI();   // 豆包模式切换时同步抖音百科按钮的显隐
    }

    function openDbSettings() {
        var sb = $('dscSettingsBtn');
        if (sb) sb.click();
        setTimeout(function () {
            var card = $('dscDbCard');
            if (card && card.scrollIntoView) {
                try { card.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
                catch (e) { card.scrollIntoView(); }
            }
        }, 280);
    }


    // ------------------------------------------------------------
    // 次元転送（ディメンション・ワープ）演出 v1 ─《ディメンション・ポータル》
    //   同じチャット窓のまま「別ディメンション」へ移動したことを、
    //   マイクラのポータル通過のようなフルスクリーン演出で伝える。
    //   構成：虚空背景 + 放射漩涡 + 翻滚线框立方体 + 上飘光粒子
    //         + 霓虹标题 + 进度条
    //   演出は DOM だけで完結し、本体のメッセージ再読込とは並行して走る。
    //
    //   ★ 两处技术修复（与视觉风格无关，回退后必须保留）：
    //     1) 遮罩 z-index 100080，高于聊天容器 100000 与豆包模态框 100050。
    //        低一层就会被整个盖住 —— 动画在播，但肉眼完全看不见。
    //     2) 消息重载推迟到 210ms（遮罩已实心后）再触发，并用双重 rAF
    //        等首帧样式落地。太早会在半透明遮罩下直播「清空→重填」，闪一下。
    // ------------------------------------------------------------
    var DB_WARP_MS = 1500;   // 演出总时长（含淡出）
    var DB_WARP_FADE = 260;  // 末尾淡出时长
    var DB_WARP_PARTICLES = 18;  // 上飘光粒子数量

    function dbWarpDim(toDim, load) {
        // toDim: 'db' | 'st' | 'ds'（'ds' = 回到 DeepSeek 主世界）
        var toDb = toDim === 'db';
        // ★ 動画の終了は固定タイマーではなく、「メッセージの読み込み完了」を待って決める。
        //   固定時間だと fetch が遅いとき、フェードアウト時に下層が空のまま表示され「一瞬光る」。
        return new Promise(function (resolve) {
            // 連打・重複対策：前回の演出が残っていれば取り除く
            var old = $('dscDimWarp');
            if (old && old.parentNode) old.parentNode.removeChild(old);

            var reduce = false;
            try {
                reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
            } catch (e) {}

            var mk = function (tag, cls) {
                var el = document.createElement(tag);
                if (cls) el.className = cls;
                return el;
            };

            var w = mk('div');
            w.id = 'dscDimWarp';
            w.className = toDim === 'db'
                ? 'dsc-warp-db'
                : (toDim === 'st' ? 'dsc-warp-st' : 'dsc-warp-ds');
            w.setAttribute('role', 'status');
            w.setAttribute('aria-live', 'polite');

            // 1. 虚空背景（最初の一フレームから CSS で実体表示）
            w.appendChild(mk('div', 'dsc-warp-bg'));

            // 2. 放射渦巻
            w.appendChild(mk('div', 'dsc-warp-vortex'));

            // 3. ワイヤーキューブ（六面）
            var cube = mk('div', 'dsc-warp-cube');
            for (var ci = 0; ci < 6; ci++) cube.appendChild(mk('s'));
            w.appendChild(cube);

            // 4. 上漂光粒子（動的を減らす設定のときは生成しない）
            if (!reduce) {
                var parts = mk('div', 'dsc-warp-p');
                for (var pi = 0; pi < DB_WARP_PARTICLES; pi++) {
                    var dot = mk('i');
                    dot.style.left = (Math.random() * 100).toFixed(2) + '%';
                    dot.style.bottom = (Math.random() * 28).toFixed(2) + '%';
                    dot.style.animationDelay = (Math.random() * 1.9).toFixed(2) + 's';
                    var sz = 2 + Math.random() * 3;
                    dot.style.width = sz.toFixed(1) + 'px';
                    dot.style.height = sz.toFixed(1) + 'px';
                    parts.appendChild(dot);
                }
                w.appendChild(parts);
            }

            // 5. 文字と進行バー
            var title = mk('div', 'dsc-warp-title');
            title.textContent = toDim === 'db'
                ? T('豆包ディメンション')
                : (toDim === 'st' ? T('ST ディメンション') : T('DeepSeek ディメンション'));

            var sub = mk('div', 'dsc-warp-sub');
            sub.textContent = toDim === 'ds'
                ? T('主世界へ戻っています')
                : T('ポータルを開いています');

            var bar = mk('div', 'dsc-warp-bar');
            var barIn = mk('b');
            bar.appendChild(barIn);

            var core = mk('div', 'dsc-warp-core');
            core.appendChild(title);
            core.appendChild(sub);
            core.appendChild(bar);
            w.appendChild(core);

            document.body.appendChild(w);
            void w.offsetWidth;   // レイアウト確定

            var startedAt = Date.now();
            var MIN_SHOW = reduce ? 420 : 900;   // 演出の最短表示時間
            var MAX_WAIT = 4000;                 // 読み込みが固まっても必ず抜ける

            // 二重 rAF：遮蔽が実際に描画されてから読み込みを開始する
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    w.classList.add('dsc-warp-in');
                    w.classList.add('dsc-warp-go');
                    barIn.style.width = '100%';

                    // 中盤で文言を差し替えて「読み込み中」感を出す
                    setTimeout(function () {
                        try {
                            sub.textContent = toDim === 'ds'
                                ? T('チャンクを読み込んでいます…')
                                : T('新しいディメンションを生成しています…');
                        } catch (e) {}
                    }, Math.round(MIN_SHOW * 0.62));

                    // メッセージ読み込み（Promise）を待ってからフェードアウト
                    var p = null;
                    try { p = (typeof load === 'function') ? load() : null; } catch (e) { p = null; }

                    var settled = Promise.resolve(p).catch(function () {});
                    var guard = new Promise(function (r) { setTimeout(r, MAX_WAIT); });

                    Promise.race([settled, guard]).then(function () {
                        var rest = Math.max(0, MIN_SHOW - (Date.now() - startedAt));
                        setTimeout(function () {
                            // ★ クロスフェード：下層のチャット領域を一旦 0 にし、
                            //   遮罩のフェードアウトと同時に 0→1 で浮かび上がらせる。
                            //   これにより下層がどのタイミングで描画されていても
                            //   白飛び／明滅が物理的に起こらない。
                            var appEl = document.getElementById('deepseekChatApp');
                            if (appEl) {
                                appEl.style.transition = 'none';
                                appEl.style.opacity = '0';
                            }
                            requestAnimationFrame(function () {
                                requestAnimationFrame(function () {
                                    if (appEl) {
                                        appEl.style.transition = 'opacity .4s linear';
                                        appEl.style.opacity = '1';
                                    }
                                    w.classList.add('dsc-warp-out');
                                    // チャット領域の opacity を元に戻す（インラインstyle を消す）
                                    setTimeout(function () {
                                        if (appEl) {
                                            appEl.style.transition = '';
                                            appEl.style.opacity = '';
                                        }
                                    }, 520);
                                    // 遮罩はクロスフェード完了後に取り除く
                                    setTimeout(function () {
                                        if (w.parentNode) w.parentNode.removeChild(w);
                                        resolve();
                                    }, Math.max(DB_WARP_FADE, 420) + 120);
                                });
                            });
                        }, rest);
                    });
                });
            });
        });
    }

    // ★ 对外暴露全屏维度切换动画（供 deepseek-chat.js 的模型切换动画复用）
    window.dscPlayDimWarp = dbWarpDim;

    function setDbMode(on, silent, noWarp) {
        try { localStorage.setItem(DB_MODE_KEY, on ? '1' : '0'); } catch (e) {}
        // ★ 维度互斥：进入豆包维度时，必须离开 ST 维度
        if (on) { try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {} }
        // ★ 离开豆包维度：残留的豆包模型切回 DeepSeek 模型
        if (!on) { try { window.dscEnsureDsModel && window.dscEnsureDsModel(); } catch (e) {} }
        syncDbModeUI();
        try { syncStModeUI(); } catch (e) {}
        // ★ 维度切换：同一个聊天窗口，豆包 / DeepSeek 的消息流互不可见
        //   ポータル演出を出しつつ、新ディメンションのメッセージを並行読込
        var reloadDim = function () {
            try {
                if (window.dscReloadMessagesForDim) return window.dscReloadMessagesForDim();
            } catch (e) { return null; }
            return null;
        };
        // ★ 演出の終了（＝メッセージ読み込み完了＋遮罩削除）を Promise で受け取る
        var warpDone;
        if (noWarp) {
            reloadDim();
            warpDone = Promise.resolve();
        } else {
            warpDone = dbWarpDim(on ? 'db' : 'ds', reloadDim);
        }
        // 遮罩（100080）が完全に消えてからトーストを出す
        var sayLater = function (fn) {
            warpDone.then(function () { try { fn(); } catch (e) {} });
        };
        if (silent) return;
        if (on) {
            if (S.cfg && S.cfg.hasKey === false) {
                sayLater(function () {
                    toast(T('⚠️ 豆包 API Key が未設定です。設定 → 豆包から入力してください'), 'error');
                    openDbSettings();
                });
            } else {
                sayLater(function () {
                    toast(T('豆包モードをオンにしました（モデル：{0}）', dbChatModel()), 'success');
                });
            }
        } else {
            sayLater(function () {
                toast(T('豆包モードをオフにしました（DeepSeek に戻ります）'), 'info');
            });
        }
    }

    // 豆包モードのアイコン：絵文字に依存せず必ず表示されるようインライン SVG を使う
    //   （U+1FAD8 は Emoji 13.0 以降。古い端末フォントでは豆腐になるため使用しない）
    var DB_MODE_ICON_SVG =
        '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">' +
        '<ellipse cx="12" cy="12" rx="8.4" ry="5.5" transform="rotate(-35 12 12)" fill="currentColor"/>' +
        '<path d="M8.4 8.2c1.3-1.8 3.7-2.5 5.9-1.9" stroke="#ffffff" stroke-width="1.7" ' +
        'stroke-linecap="round" stroke-linejoin="round" fill="none" opacity="0.9"/>' +
        '</svg>';

    function ensureDbModeIcon(lbl) {
        if (!lbl) return;
        if (lbl.querySelector('svg')) return;
        lbl.textContent = '';
        lbl.innerHTML = DB_MODE_ICON_SVG;
    }

    // ------------------------------------------------------------
    // ST 维度：右上「豆包モード」ボタンの左隣に置く
    //   ON  → 送信・履歴を ST 维度（dim=st）へ完全に切り替える
    //   OFF → 元の DeepSeek 主世界へ戻る
    //   豆包モードとは排他（片方を開くともう片方は必ず閉じる）
    // ------------------------------------------------------------
    var ST_MODE_ICON_SVG =
        '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">' +
        '<path d="M12 2.4l2.75 6.03 6.57.72-4.9 4.44 1.33 6.46L12 16.9l-5.75 3.15 1.33-6.46-4.9-4.44 6.57-.72z" ' +
        'fill="currentColor"/>' +
        '</svg>';

    function syncStModeUI() {
        var b = $('dscStModeBtn');
        if (!b) return;
        var on = isStDim();
        if (on) b.classList.add('active'); else b.classList.remove('active');
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
        var lbl = b.querySelector('.dsc-st-mode-lbl');
        if (lbl && !lbl.querySelector('svg')) {
            lbl.textContent = '';
            lbl.innerHTML = ST_MODE_ICON_SVG;
        }
        b.title = on ? T('ST ディメンション：オン（独立した会話）') : T('ST ディメンション：オフ');
        b.setAttribute('aria-label', b.title);
    }

    function setStDim(on, silent, noWarp) {
        // ★ 停用整改：禁止进入 st 维度。强制清除残留标志并弹窗报错。
        if (on) {
            try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
            window.dscRelayBlockedAlert();
            return;
        }
        try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
        // ★ 维度互斥：进入 ST 维度时，必须关闭豆包模式
        if (on) { try { localStorage.setItem(DB_MODE_KEY, '0'); } catch (e) {} }
        // ★ 离开 ST 维度：残留的中转站模型切回 DeepSeek 模型（否则 DeepSeek 维度会被判成 st）
        if (!on) { try { window.dscEnsureDsModel && window.dscEnsureDsModel(); } catch (e) {} }
        // ★ 进入 ST 维度：当前模型必须切为中转站模型（否则 ST 维度下仍是 DeepSeek 模型）
        if (on) { try { window.dscEnsureStModel && window.dscEnsureStModel(); } catch (e) {} }
        syncDbModeUI();
        syncStModeUI();
        // 维度切换：消息流立即换成目标维度（与ポータル演出并行）
        var reloadDim = function () {
            try {
                if (window.dscReloadMessagesForDim) return window.dscReloadMessagesForDim();
            } catch (e) { return null; }
            return null;
        };
        var warpDone;
        if (noWarp) {
            reloadDim();
            warpDone = Promise.resolve();
        } else {
            warpDone = dbWarpDim(on ? 'st' : 'ds', reloadDim);
        }
        if (silent) return;
        warpDone.then(function () {
            try {
                if (on) toast(T('ST ディメンションへ移動しました（会話は完全に独立しています）'), 'success');
                else toast(T('ST ディメンションを離れました'), 'info');
            } catch (e) {}
        });
    }

    // ------------------------------------------------------------
    // ★ 统一切换维度（供聊天框模型选择器 / deepseek-chat 调用）
    //   dim: 'ds' | 'st' | 'db'；模型与维度必须同时切换，否则会出现
    //   「UI 显示中转站模型，消息流却还在 DeepSeek 维度」这种串维度 bug。
    // ------------------------------------------------------------
    window.dscSetDimForModel = function (dim, model, silent) {
        // ★ 停用整改：任何试图切到 st 维度的调用一律拦截，强制回落到 ds。
        if (dim === 'st') {
            try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
            window.dscRelayBlockedAlert();
            dim = 'ds';
        }
        var target = (dim === 'db' || dim === 'st' || dim === 'ds') ? dim : 'ds';
        var cur = 'ds';
        try { cur = isDbMode() ? 'db' : (isStDim() ? 'st' : 'ds'); } catch (e) {}
        var crossDim = (cur !== target);
        // ★ 维度标志同步：同维度必须保持一致（避免刷新后维度判定错乱）；
        //   但「静默同步（silent）且跨维度」时一律不写 —— 任何「保存配置 / 同步模型」类的
        //   静默调用都不允许把用户悄悄拽进另一个维度（这是「点保存设置被切到 st 维度」的第二条根因）。
        if (!(silent && crossDim)) {
            try { localStorage.setItem(DB_MODE_KEY, target === 'db' ? '1' : '0'); } catch (e) {}
            try { localStorage.setItem(ST_DIM_KEY, target === 'st' ? '1' : '0'); } catch (e) {}
            try { syncDbModeUI(); syncStModeUI(); } catch (e) {}
        }
        // ★ 跨维度时重载消息；同维度切模型不重载（消息流不跨维度）
        var reload = function () {
            if (!crossDim) return Promise.resolve();
            try { if (window.dscReloadMessagesForDim) return window.dscReloadMessagesForDim(); } catch (e) {}
            return Promise.resolve();
        };
        // ★ 全屏切换动画：复用维度切换动画（dbWarpDim）。启动同步（silent）不播放
        // ★ 修复（同维度切模型误播维度动画）：
        //   只有「真正跨维度」（crossDim === true）时才播放全屏维度切换动画。
        //   同维度内仅切换模型（如豆包 A 模型 -> 豆包 B 模型、设置里保存豆包模型）时，
        //   维度标志已在上面无条件同步，消息流也无需重载，这里绝不能再播 dbWarpDim，
        //   否则用户只是换个模型却看到一整套「穿越维度」全屏动画。
        var warpDone = Promise.resolve();
        if (silent && crossDim) {
            // 静默且跨维度：什么都不做（不写标志、不重载消息、不播动画）
        } else if (silent || !crossDim) {
            try { reload(); } catch (e) {}
        } else {
            try {
                if (window.dscPlayDimWarp) {
                    warpDone = window.dscPlayDimWarp(target, reload);
                } else {
                    reload();
                }
            } catch (e) {
                try { reload(); } catch (e2) {}
            }
        }
        // ★ 仅跨维度切换才提示「ディメンションを切り替えました」；
        //   同维度切模型不打扰（模型切换本身的 toast 由各调用方负责）。
        if (!silent && crossDim) {
            var nm = target === 'db' ? '豆包' : (target === 'st' ? '中转站' : 'DeepSeek');
            warpDone.then(function () {
                try { toast(T('ディメンションを切り替えました：') + nm + (model ? (' · ' + model) : ''), 'info'); } catch (e) {}
            });
        }
        return target;
    };

    // 选择豆包模型：写 override + 立即进入 db 维度
    window.dscApplyDoubaoModel = function (model) {
        var v = String(model == null ? '' : model).trim();
        if (!v) return '';
        setDbChatModelOverride(v);
        window.dscSetDimForModel('db', v, false);
        try { qmSyncBtn(); } catch (e) {}
        return v;
    };

    function injectStDimButton() {
        // ★ 停用整改：st 维度入口按钮不再注入（物理下架）。
        //   若历史 DOM 中残留该按钮，一并移除。
        var oldBtn = $('dscStModeBtn');
        if (oldBtn && oldBtn.parentNode) { try { oldBtn.parentNode.removeChild(oldBtn); } catch (e) {} }
        try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
        return;
        // eslint-disable-next-line no-unreachable
        var dbBtn = $('dscDbModeBtn');
        if ($('dscStModeBtn')) { syncStModeUI(); return; }
        if (!dbBtn || !dbBtn.parentNode) return;
        var b = el('button', 'dsc-icon-btn dsc-st-mode-btn');
        b.id = 'dscStModeBtn';
        b.type = 'button';
        var lbl = el('span', 'dsc-st-mode-lbl');
        lbl.innerHTML = ST_MODE_ICON_SVG;
        b.appendChild(lbl);
        b.addEventListener('click', function () { setStDim(!isStDim()); });
        // 豆包ボタンの「左」へ挿入する
        dbBtn.parentNode.insertBefore(b, dbBtn);
        syncStModeUI();
    }

    function injectDbModeButton() {
        var nb = $('dscNewBtn');
        if ($('dscDbModeBtn')) { syncDbModeUI(); return; }
        if (!nb || !nb.parentNode) return;
        var b = el('button', 'dsc-icon-btn dsc-db-mode-btn');
        b.id = 'dscDbModeBtn';
        b.type = 'button';
        var lbl0 = el('span', 'dsc-db-mode-lbl');
        ensureDbModeIcon(lbl0);
        b.appendChild(lbl0);
        b.addEventListener('click', function () { setDbMode(!isDbMode()); });
        nb.parentNode.insertBefore(b, nb);
        syncDbModeUI();
    }

    // 送信・続き生成のモデルだけを豆包へ差し替える（既存の送信実装は変更しない）
    function installFetchHook() {
        if (window.__dscDbFetchHooked) return;
        window.__dscDbFetchHooked = true;
        var orig = window.fetch;
        if (typeof orig !== 'function') return;
        window.fetch = function (input, init) {
            try {
                var url = (typeof input === 'string') ? input : ((input && input.url) || '');
                if (init && typeof init.body === 'string' &&
                    /\/api\/ds-chat\/(send|continue|abort-save)(\?|$)/.test(url)) {
                    var body = JSON.parse(init.body);
                    if (body && typeof body === 'object') {
                        var cur = String(body.model || '');
                        if (isDbMode()) {
                            var want = dbChatModel();
                            if (cur !== want) {
                                body.__dscClientModel = cur;
                                body.model = want;
                                init = Object.assign({}, init, { body: JSON.stringify(body) });
                                console.log('[DB] 豆包モード送信: ' + (cur || '(なし)') + ' → ' + want);
                            }
                        } else if (isDbModelValue(cur)) {
                            // 豆包モードがオフなのに豆包モデルが残っている → DeepSeek へ戻す
                            var sel = $('dscModelSelect');
                            var fb = (sel && sel.value && !isDbModelValue(sel.value)) ? sel.value : 'deepseek-flash';
                            body.model = fb;
                            init = Object.assign({}, init, { body: JSON.stringify(body) });
                            console.log('[DB] 豆包モデルの残留を検出 → ' + fb + ' に戻しました');
                        }
                    }
                }
            } catch (e) { console.log('[DB] fetch hook error: ' + (e && e.message)); }
            return orig.call(this, input, init);
        };
    }

    // 旧版がバックエンド設定へ豆包モデルを保存していた場合の移行
    async function migrateLegacyModel() {
        try {
            var r = await fetch('/api/ds-chat/config', { cache: 'no-cache' });
            if (!r.ok) return;
            var d = await r.json();
            var m = (d && d.model) ? String(d.model) : '';
            if (!isDbModelValue(m)) return;
            await fetch('/api/ds-chat/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ model: 'deepseek-flash' })
            });
            try { localStorage.setItem('dsc_currentModel', 'deepseek-flash'); } catch (e) {}
            var sel = $('dscModelSelect');
            if (sel) sel.value = 'deepseek-flash';
            purgeLegacyChatModels();
            if (!isDbMode()) setDbMode(true, true, true);
            console.log('[DB] 旧設定の豆包モデル「' + m + '」を豆包モードへ移行しました');
        } catch (e) {}
    }

    // ------------------------------------------------------------
    // 入力欄のモデル選択器（DeepSeek harness 風）
    //   設定ダイアログを開かなくても、送信直前にその場で対話モデルを選ぶ。
    //   ・DeepSeek 系 / 自定义モデル → DeepSeek 通道（豆包モードは自動 OFF）
    //   ・豆包会話モデル           → 豆包モードを ON にして豆包通道で送信
    //   非対話モデル（画像/動画/音声など）は一切出さない。
    // ------------------------------------------------------------
    var QM_LOCAL_DB_KEY = 'dsc_doubao_custom_models';

    function qmLocalDbModels() {
        try {
            var raw = localStorage.getItem(QM_LOCAL_DB_KEY);
            var arr = raw ? JSON.parse(raw) : [];
            if (!Array.isArray(arr)) return [];
            var out = [];
            for (var i = 0; i < arr.length; i++) {
                if (typeof arr[i] === 'string' && arr[i].trim()) out.push(arr[i].trim());
            }
            return out;
        } catch (e) { return []; }
    }

    function qmAddLocalDbModel(name) {
        var arr = qmLocalDbModels();
        if (arr.indexOf(name) < 0) {
            arr.push(name);
            try { localStorage.setItem(QM_LOCAL_DB_KEY, JSON.stringify(arr)); } catch (e) {}
        }
    }

    function qmCurrentDeepSeek() {
        if (typeof window.dscGetChatModel === 'function') {
            try { var v = window.dscGetChatModel(); if (v) return String(v); } catch (e) {}
        }
        var sel = $('dscModelSelect');
        if (sel && sel.value) return String(sel.value);
        try { return String(localStorage.getItem('dsc_currentModel') || 'deepseek-flash'); } catch (e) { return 'deepseek-flash'; }
    }

    function qmListDeepSeek() {
        var arr = [];
        if (typeof window.dscListChatModels === 'function') {
            try { arr = window.dscListChatModels() || []; } catch (e) { arr = []; }
        }
        if (!arr.length) arr = [{ value: 'deepseek-flash', label: 'deepseek-flash', custom: false }];
        var cur = qmCurrentDeepSeek(), has = false;
        for (var i = 0; i < arr.length; i++) { if (arr[i].value === cur) { has = true; break; } }
        if (!has && cur) arr.unshift({ value: cur, label: cur, custom: true });
        return arr;
    }

    function qmListDoubao() {
        var out = [], seen = {};
        (S.catalog || []).forEach(function (m) {
            if (!m || m.category !== 'chat') return;
            var v = String(m.value || '').trim();
            if (!v || seen[v]) return;
            seen[v] = 1;
            out.push({ value: v, label: T(m.label || v), custom: !!m.custom });
        });
        qmLocalDbModels().forEach(function (v) {
            if (seen[v]) return;
            seen[v] = 1;
            out.push({ value: v, label: v + T('（自定义）'), custom: true });
        });
        var cur = dbChatModel(), has = false;
        for (var i = 0; i < out.length; i++) { if (out[i].value === cur) { has = true; break; } }
        if (!has && cur) out.unshift({ value: cur, label: cur + T('（自定义）'), custom: true });
        return out;
    }

    function qmShortName(name) {
        var s = String(name || '');
        s = s.replace(/^doubao-/, 'db-').replace(/^deepseek-/, 'ds-');
        return s.length > 14 ? s.slice(0, 13) + '…' : s;
    }

    function qmSyncBtn() {
        var b = $('dscQuickModelBtn');
        if (!b) return;
        var lbl = b.querySelector('.dsc-qm-name');
        var name = isDbMode() ? dbChatModel() : qmCurrentDeepSeek();
        if (lbl) lbl.textContent = qmShortName(name);
        var on = isDbMode();
        if (on) b.classList.add('db-on'); else b.classList.remove('db-on');
        b.title = (on ? T('対話モデル（豆包）：') : T('対話モデル（DeepSeek）：')) + name;
        b.setAttribute('aria-label', b.title);
        // 快捷选择器每次同步都顺带刷新设置面板的状态行，
        // 保证「聊天框下方切模型」与「设置里的对话模型」永远一致。
        refreshCfgStatus();
    }

    function qmEnsurePanel() {
        if ($('dscQmOverlay')) return;
        var ov = el('div', 'dsc-qm-overlay');
        ov.id = 'dscQmOverlay';
        var box = el('div', 'dsc-qm-box');
        var head = el('div', 'dsc-qm-head');
        head.appendChild(el('span', 'dsc-qm-title', T('対話モデル')));
        var cur = el('span', 'dsc-qm-cur');
        cur.id = 'dscQmCur';
        head.appendChild(cur);
        var cls = el('button', 'dsc-qm-close', '✕');
        cls.type = 'button';
        cls.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); qmClose(); });
        head.appendChild(cls);
        box.appendChild(head);

        var list = el('div', 'dsc-qm-list');
        list.id = 'dscQmList';
        box.appendChild(list);

        var add = el('div', 'dsc-qm-add');
        var inp = document.createElement('input');
        inp.id = 'dscQmNewInput';
        inp.type = 'text';
        inp.autocomplete = 'off';
        inp.placeholder = T('モデル名を追加（対話モデルのみ）');
        add.appendChild(inp);
        var ok = el('button', 'dsc-qm-add-ok', T('追加'));
        ok.type = 'button';
        ok.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); qmConfirmAdd(); });
        add.appendChild(ok);
        box.appendChild(add);

        ov.appendChild(box);
        ov.addEventListener('click', function (e) { if (e.target === ov) qmClose(); });
        document.body.appendChild(ov);

        inp.addEventListener('keydown', function (ev) {
            if (ev.key === 'Enter') { ev.preventDefault(); qmConfirmAdd(); }
        });
    }

    // ===== 三分区模型中心：DeepSeek（ds）/ 中转站（st）/ 豆包（db）=====
    //   三个分区各自独立，自定义模型只会写进它所属维度的存储：
    //     ds → data/displaymodels/*.sts        （POST /api/displaymodels）
    //     st → data/relay/relay_config.sts     （POST /api/relay/config）
    //     db → data/doubao/*.sts customModels  （POST /api/doubao/config）
    var qmAddKind = 'ds';
    var QM_KIND_META = {
        ds: { title: '🟦 DeepSeek · ds 维度', ph: 'DeepSeek 自定义模型名（例：my-deepseek-model）' },
        st: { title: '🔀 中转站 · st 维度', ph: '中转站自定义模型名（例：gpt-4o）' },
        db: { title: '🧩 豆包 · db 维度', ph: '豆包自定义模型名（例：doubao-seed-2-2-pro）' }
    };

    function qmHub() { return window.dscModelHub || {}; }

    function qmGroupHead(kind) {
        var meta = QM_KIND_META[kind] || QM_KIND_META.ds;
        var head = el('div', 'dsc-qm-group dsc-qm-group-head');
        head.appendChild(el('span', 'dsc-qm-group-name', T(meta.title)));
        var add = el('button', 'dsc-qm-group-add', '＋');
        add.type = 'button';
        add.title = T('この分区にカスタムモデルを追加');
        add.addEventListener('click', function (e) {
            if (e) { e.preventDefault(); e.stopPropagation(); }
            qmShowAdd(kind);
        });
        head.appendChild(add);
        return head;
    }

    function qmItem(kind, item, active) {
        var b = el('button', 'dsc-qm-item' + (active ? ' active' : ''));
        b.type = 'button';
        b.appendChild(el('span', 'dsc-qm-item-name', item.label || item.value));
        if (kind === 'st') b.appendChild(el('span', 'dsc-qm-tag', T('中转站')));
        else if (kind === 'db') b.appendChild(el('span', 'dsc-qm-tag', T('豆包')));
        else b.appendChild(el('span', 'dsc-qm-tag', T('DeepSeek')));
        if (item.custom) b.appendChild(el('span', 'dsc-qm-tag dsc-qm-tag-custom', T('カスタム')));
        if (active) b.appendChild(el('span', 'dsc-qm-check', '✓'));
        b.addEventListener('click', function (ev) {
            if (ev) { ev.preventDefault(); ev.stopPropagation(); }
            if (b.getAttribute('data-busy') === '1') return;
            b.setAttribute('data-busy', '1');
            b.classList.add('picked');
            setTimeout(function () { try { qmApply(kind, item.value); } catch (e) {} }, 90);
        });
        if (item.custom) {
            var del = el('span', 'dsc-qm-del', '×');
            del.title = T('このカスタムモデルを削除');
            del.addEventListener('click', function (ev) {
                if (ev) { ev.preventDefault(); ev.stopPropagation(); }
                qmRemoveCustom(kind, item.value);
            });
            b.appendChild(del);
        }
        return b;
    }

    function qmRender() {
        var list = $('dscQmList');
        if (!list) return;
        list.innerHTML = '';
        var hub = qmHub();
        var curDim = isDbMode() ? 'db' : (isStDim() ? 'st' : 'ds');
        var curModel = curDim === 'db' ? dbChatModel() : qmCurrentDeepSeek();
        var curEl = $('dscQmCur');
        if (curEl) {
            var dimName = curDim === 'db' ? '豆包' : (curDim === 'st' ? '中转站' : 'DeepSeek');
            curEl.textContent = T('現在：') + dimName + ' · ' + curModel;
        }

        // ---------- 1. DeepSeek（官方 + ds 自定义） ----------
        list.appendChild(qmGroupHead('ds'));
        var dsSeen = {};
        (hub.dsOfficial ? hub.dsOfficial() : ['deepseek-flash']).forEach(function (v) {
            var val = String(v == null ? '' : v).trim();
            if (!val || dsSeen[val]) return;
            dsSeen[val] = 1;
            list.appendChild(qmItem('ds', { value: val, label: val }, curDim === 'ds' && val === curModel));
        });
        (hub.dsCustom ? hub.dsCustom() : []).forEach(function (v) {
            var val = String(v == null ? '' : v).trim();
            if (!val || dsSeen[val]) return;
            dsSeen[val] = 1;
            list.appendChild(qmItem('ds', { value: val, label: val, custom: true }, curDim === 'ds' && val === curModel));
        });

        // ---------- 2. 中转站(st) ----------
        // ★ 停用整改：st 维度已全面下线，快捷选择器不再渲染任何中转站模型分组。
        //   （保留空占位注释，豆包分组序号不变）

        // ---------- 3. 豆包（方舟对话模型 + db 自定义） ----------
        list.appendChild(qmGroupHead('db'));
        qmListDoubao().forEach(function (it) {
            list.appendChild(qmItem('db', it, curDim === 'db' && it.value === curModel));
        });
    }

    function qmOpen() {
        qmEnsurePanel();
        qmRender();
        var ov = $('dscQmOverlay');
        if (ov) ov.classList.add('open');
    }

    function qmClose() {
        var ov = $('dscQmOverlay');
        if (ov) ov.classList.remove('open');
    }

    function qmToggle() {
        var ov = $('dscQmOverlay');
        if (ov && ov.classList.contains('open')) qmClose(); else qmOpen();
    }

    // 「＋」→ 把底部输入行切到指定分区
    function qmShowAdd(kind) {
        var meta = QM_KIND_META[kind] || QM_KIND_META.ds;
        qmAddKind = kind;
        var inp = $('dscQmNewInput');
        if (inp) {
            inp.placeholder = T(meta.ph);
            inp.value = '';
            try { inp.focus(); } catch (e) {}
        }
        var box = $('dscQmOverlay');
        if (box) {
            var list = $('dscQmList');
            if (list) { try { list.scrollTop = list.scrollHeight; } catch (e) {} }
        }
        toast(T('追加先：') + T(meta.title), 'info');
    }

    // 名称是否已在任意维度存在（避免同名模型跨维度串味）
    function qmModelExistsAnywhere(v) {
        var hub = qmHub();
        var arrs = [];
        if (hub.dsOfficial) arrs.push(hub.dsOfficial());
        if (hub.dsCustom) arrs.push(hub.dsCustom());
        if (hub.relayPreset) arrs.push(hub.relayPreset());
        if (hub.relayCustom) arrs.push(hub.relayCustom());
        arrs.push(qmListDoubao().map(function (x) { return x.value; }));
        for (var i = 0; i < arrs.length; i++) {
            var a = arrs[i] || [];
            for (var j = 0; j < a.length; j++) {
                if (String(a[j]) === v) return true;
            }
        }
        return false;
    }

    function qmApply(kind, value) {
        var v = String(value || '').trim();
        if (!v) return;
        // ★ 停用整改：任何 st 模型应用一律拦截弹窗。
        if (kind === 'st') {
            try { localStorage.setItem(ST_DIM_KEY, '0'); } catch (e) {}
            window.dscRelayBlockedAlert && window.dscRelayBlockedAlert();
            try { qmClose(); } catch (e2) {}
            return;
        }
        if (kind === 'db') {
            setDbChatModelOverride(v);
            // 持久化到后端（只提交 chatModel，其它字段后端沿用旧值）
            try {
                api('/config', { method: 'POST', body: { chatModel: v } }).then(function (d) {
                    if (d) { S.cfg = d; S.catalog = (d.catalog && d.catalog.models) || S.catalog; }
                    try { syncDbModeUI(); } catch (e1) {}
                    try { refreshCfgStatus(); } catch (e2) {}
                }).catch(function () {});
            } catch (e) {}
            // ★ 切换模型 ⇒ 同步 db 维度；同维度切模型不播全屏动画（跨维度才播）
            window.dscSetDimForModel('db', v, false);
            syncDbModeUI();
            qmSyncBtn();
            qmClose();
            toast(T('✅ 送信モデルを豆包に切り替えました：') + v, 'success');
            return;
        }
        // DeepSeek / 中转站：统一走 dscSetChatModel（内部会同步 ds / st 维度）
        if (typeof window.dscSetChatModel === 'function') {
            window.dscSetChatModel(v, true);
        } else {
            window.dscSetDimForModel(kind === 'st' ? 'st' : 'ds', v, false);
        }
        qmSyncBtn();
        qmClose();
        toast((kind === 'st' ? T('✅ 中转站モデルに切り替えました：') : T('✅ 送信モデルを切り替えました：')) + v, 'success');
    }

    function qmRemoveCustom(kind, v) {
        var hub = qmHub();
        if (kind === 'db') {
            var cur = (S.cfg && S.cfg.customModels) || [];
            var next = cur.filter(function (x) { return x !== v; });
            if (next.length === cur.length) { toast(T('削除対象が見つかりません'), 'info'); return; }
            api('/config', { method: 'POST', body: { customModels: next } }).then(function (d) {
                if (d) { S.cfg = d; S.catalog = (d.catalog && d.catalog.models) || S.catalog; }
                qmRender();
                toast(T('カスタムモデルを削除しました：') + v, 'success');
            }).catch(function (e) {
                toast(T('削除に失敗しました：') + (e && e.message ? e.message : ''), 'error');
            });
            return;
        }
        if (kind === 'st') {
            if (!hub.removeRelay) return;
            hub.removeRelay(v).then(function (ok) {
                qmRender();
                toast(ok ? (T('カスタムモデルを削除しました：') + v) : T('削除に失敗しました'), ok ? 'success' : 'error');
            });
            return;
        }
        if (hub.removeDs) {
            hub.removeDs(v);
            setTimeout(qmRender, 60);
        }
    }

    function qmConfirmAdd() {
        var inp = $('dscQmNewInput');
        var v = inp ? String(inp.value || '').trim() : '';
        if (!v) { toast(T('モデル名を入力してください'), 'info'); return; }
        if (/\s/.test(v)) { toast(T('モデル名に空白は使用できません'), 'error'); return; }
        if (v.length > 120) { toast(T('モデル名が長すぎます（最大 120 字）'), 'error'); return; }
        var kind = qmAddKind || 'ds';
        var hub = qmHub();
        if (qmModelExistsAnywhere(v)) {
            toast(T('そのモデル名は既に別の维度に存在します：') + v, 'error');
            return;
        }
        if (kind === 'db') {
            var cur = (S.cfg && S.cfg.customModels) || [];
            if (cur.indexOf(v) < 0) cur.push(v);
            if (inp) inp.value = '';
            api('/config', { method: 'POST', body: { customModels: cur } }).then(function (d) {
                if (d) { S.cfg = d; S.catalog = (d.catalog && d.catalog.models) || S.catalog; }
                qmRender();
                toast(T('✅ 豆包カスタムモデルを追加しました：') + v, 'success');
                qmApply('db', v);
            }).catch(function (e) {
                qmRender();
                toast(T('追加に失敗しました：') + (e && e.message ? e.message : ''), 'error');
            });
            return;
        }
        if (kind === 'st') {
            if (!hub.addRelay) { toast(T('中转站モジュールが未初期化です'), 'error'); return; }
            hub.addRelay(v).then(function (ok) {
                if (inp) inp.value = '';
                qmRender();
                if (ok) { toast(T('✅ 中转站カスタムモデルを追加しました：') + v, 'success'); qmApply('st', v); }
                else toast(T('追加に失敗しました：') + v, 'error');
            });
            return;
        }
        if (!hub.addDs) { toast(T('DeepSeek モデルモジュールが未初期化です'), 'error'); return; }
        hub.addDs(v).then(function (ok) {
            if (inp) inp.value = '';
            qmRender();
            if (ok) { toast(T('✅ DeepSeek カスタムモデルを追加しました：') + v, 'success'); qmApply('ds', v); }
            else toast(T('追加に失敗しました：') + v, 'error');
        }).catch(function () {
            if (inp) inp.value = '';
            qmRender();
            toast(T('追加に失敗しました：') + v, 'error');
        });
    }

    // ★ 对外：豆包对话模型清单（供模型弹窗 / 三分区列表使用）
    window.dscListDoubaoModels = function () {
        try { return qmListDoubao(); } catch (e) { return []; }
    };

    // ★ 对外：把自定义模型写进豆包维度（data/.../doubao 配置的 customModels）
    window.dscDbAddCustomModel = function (name) {
        var v = String(name == null ? '' : name).trim();
        if (!v) return Promise.resolve(false);
        var cur = (S.cfg && S.cfg.customModels) ? S.cfg.customModels.slice() : [];
        if (cur.indexOf(v) >= 0) return Promise.resolve(true);
        cur.push(v);
        return api('/config', { method: 'POST', body: { customModels: cur } })
            .then(function (d) {
                if (!d) return false;
                S.cfg = d;
                S.catalog = (d.catalog && d.catalog.models) || S.catalog;
                try { qmRender(); } catch (e) {}
                return true;
            })
            .catch(function () { return false; });
    };

    function injectQuickModelBtn() {
        var panel = $('dscToolsExtra');
        if (!panel) return;
        if (!$('dscQuickModelBtn')) {
            var b = el('button', 'dsc-switch-btn dsc-quick-model-btn');
            b.id = 'dscQuickModelBtn';
            b.type = 'button';
            var ic = el('span', 'ic');
            ic.textContent = '🤖';
            b.appendChild(ic);
            b.appendChild(el('span', 'dsc-qm-name', ''));
            // 去抖：WebView で注入ボタンが二重 click を起こすことがある
            var lastTap = 0;
            b.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                var now = Date.now();
                if (now - lastTap < 300) return;
                lastTap = now;
                qmToggle();
            });
            // 横向滚动区の末尾だと隠れるので先頭へ挿す
            panel.insertBefore(b, panel.firstChild);
        }
        qmSyncBtn();
    }

    // ------------------------------------------------------------
    // 起動処理
    // ------------------------------------------------------------
    function boot() {
        injectMenu();
        buildSettingsCard();
        injectDbModeButton();
        injectStDimButton();
        injectWikiBtn();
        injectQuickModelBtn();
        installFetchHook();
        // 言語切替時（再読込が無効化されている場合も）ボタンの title を追従させる
        document.addEventListener('dsc:langchange', function () {
            applyMenuLabels();   // メニュー文言の残留防止
            syncDbModeUI();      // 豆包モードボタンの title 追従
            try { syncStModeUI(); } catch (e) {}   // ST ボタンの title 追従
            // 入力欄モデル選択器：ボタン名とパネル文言も追従（開いていれば再描画）
            qmSyncBtn();
            var ovv = $('dscQmOverlay');
            if (ovv && ovv.classList.contains('open')) qmRender();
        });
        purgeLegacyChatModels();
        loadConfig().then(function () {
            renderModelList();
            fillCfgForm();
            purgeLegacyChatModels();
            syncDbModeUI();
            try { syncStModeUI(); } catch (e) {}
            migrateLegacyModel();
        }).catch(function (e) {
            console.log('[DB] config load failed:', e.message);
            migrateLegacyModel();
        });
        // 設定を開くたびに最新化
        var sbtn = $('dscSettingsBtn');
        if (sbtn) {
            sbtn.addEventListener('click', function () {
                buildSettingsCard();
                loadConfig(true).then(function () {
                    fillCfgForm();
                    purgeLegacyChatModels();
                    syncDbModeUI();
                }).catch(function () {});
            });
        }
        // 送信完了時に豆包ルーティングを通知（deepseek-chat.js から呼ばれる）
        window.dscDoubaoRouteToast = function (payload) {
            try {
                if (!payload || !payload.doubaoRoute) return;
                var r = payload.doubaoRoute;
                if (!r.routed) return;
                toast(T('🔀 録音ファイルを検出したため豆包へ自動ルーティングしました（{0}）', r.to || ''), 'info');
            } catch (e) {}
        };
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }

    
    // ------------------------------------------------------------
    // 豆包機械翻訳（支持32国语言，全功能版）
    // ------------------------------------------------------------
    var TRANSLATE_LANGS = [
        { value: 'zh', label: '中文（简体）' }, { value: 'zh-Hant', label: '中文（繁体）' },
        { value: 'en', label: '英语' }, { value: 'ja', label: '日语' },
        { value: 'ko', label: '韩语' }, { value: 'fr', label: '法语' },
        { value: 'de', label: '德语' }, { value: 'es', label: '西班牙语' },
        { value: 'ru', label: '俄语' }, { value: 'pt', label: '葡萄牙语' },
        { value: 'it', label: '意大利语' }, { value: 'ar', label: '阿拉伯语' },
        { value: 'th', label: '泰语' }, { value: 'vi', label: '越南语' },
        { value: 'id', label: '印尼语' }, { value: 'ms', label: '马来语' },
        { value: 'hi', label: '印地语' }, { value: 'tr', label: '土耳其语' },
        { value: 'nl', label: '荷兰语' }, { value: 'pl', label: '波兰语' },
        { value: 'uk', label: '乌克兰语' }, { value: 'ro', label: '罗马尼亚语' },
        { value: 'el', label: '希腊语' }, { value: 'cs', label: '捷克语' },
        { value: 'sv', label: '瑞典语' }, { value: 'da', label: '丹麦语' },
        { value: 'fi', label: '芬兰语' }, { value: 'hu', label: '匈牙利语' },
        { value: 'bg', label: '保加利亚语' }, { value: 'sk', label: '斯洛伐克语' },
        { value: 'he', label: '希伯来语' }, { value: 'fa', label: '波斯语' }
    ];

    function getTTSVoiceForLang(langCode) {
        var map = {
            'zh': 'zh-CN-XiaoyiNeural', 'zh-Hant': 'zh-TW-HsiaoChenNeural',
            'en': 'en-US-AriaNeural', 'ja': 'ja-JP-NanamiNeural',
            'ko': 'ko-KR-SunHiNeural', 'fr': 'fr-FR-DeniseNeural',
            'de': 'de-DE-KatjaNeural', 'es': 'es-ES-ElviraNeural',
            'ru': 'ru-RU-SvetlanaNeural', 'pt': 'pt-BR-FranciscaNeural',
            'it': 'it-IT-ElsaNeural', 'ar': 'ar-SA-ZariyahNeural',
            'th': 'th-TH-PremwadeeNeural', 'vi': 'vi-VN-HoaiMyNeural',
            'id': 'id-ID-GadisNeural', 'ms': 'ms-MY-YasminNeural',
            'hi': 'hi-IN-SwaraNeural', 'tr': 'tr-TR-EmelNeural',
            'nl': 'nl-NL-ColetteNeural', 'pl': 'pl-PL-ZofiaNeural',
            'uk': 'uk-UA-PolinaNeural', 'ro': 'ro-RO-EmilNeural',
            'el': 'el-GR-AthinaNeural', 'cs': 'cs-CZ-VlastaNeural',
            'sv': 'sv-SE-SofieNeural', 'da': 'da-DK-ChristelNeural',
            'fi': 'fi-FI-NooraNeural', 'hu': 'hu-HU-NoemiNeural',
            'bg': 'bg-BG-KalinaNeural', 'sk': 'sk-SK-ViktoriaNeural',
            'he': 'he-IL-HilaNeural', 'fa': 'fa-IR-DilaraNeural'
        };
        return map[langCode] || 'zh-CN-XiaoxiaoNeural';
    }

    // ------------------------------------------------------------
    // 汎用コピー（WebView でも確実に動く三段フォールバック）
    //   1) navigator.clipboard.writeText（https / localhost でのみ有効）
    //   2) 不可視 textarea + document.execCommand('copy')
    //   3) copy イベントを手動発火して execCommand('copy')
    //   成功した時だけ「✅ 已复制」を出し、失敗時は必ず失敗を通知する（捏造しない）
    // ------------------------------------------------------------
    function escHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function legacyCopyText(t) {
        var ok = false;
        var ta = document.createElement('textarea');
        ta.value = t;
        ta.setAttribute('readonly', 'readonly');
        ta.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0;';
        document.body.appendChild(ta);
        try {
            var sel = document.getSelection ? document.getSelection() : null;
            var prev = (sel && sel.rangeCount > 0) ? sel.getRangeAt(0) : null;
            ta.focus();
            ta.select();
            try { ta.setSelectionRange(0, ta.value.length); } catch (e0) {}
            ok = (document.execCommand('copy') === true);
            if (prev && sel) { sel.removeAllRanges(); sel.addRange(prev); }
        } catch (e) { ok = false; }
        try { if (ta.parentNode) ta.parentNode.removeChild(ta); } catch (e1) {}

        if (!ok) {
            // 最終手段：copy イベントにデータを載せてから実行
            try {
                var handler = function (e) {
                    try {
                        if (e.clipboardData) {
                            e.clipboardData.setData('text/plain', t);
                            e.preventDefault();
                        }
                    } catch (e2) {}
                };
                document.addEventListener('copy', handler, true);
                ok = (document.execCommand('copy') === true);
                document.removeEventListener('copy', handler, true);
            } catch (e3) { ok = false; }
        }
        return ok;
    }

    function copyTextToClipboard(text) {
        var t = String(text == null ? '' : text);
        if (navigator.clipboard && navigator.clipboard.writeText) {
            try {
                var p = navigator.clipboard.writeText(t);
                if (p && typeof p.then === 'function') {
                    return p.then(function () { return true; }, function () { return legacyCopyText(t); });
                }
            } catch (e) {}
        }
        return Promise.resolve(legacyCopyText(t));
    }

    function flashCopied(btn) {
        if (!btn) return;
        var old = btn.innerHTML;
        btn.innerHTML = '✅ 已复制';
        btn.classList.add('is-copied');
        btn.disabled = true;
        setTimeout(function () {
            btn.innerHTML = old;
            btn.classList.remove('is-copied');
            btn.disabled = false;
        }, 1200);
    }

    // 他のモジュール / 旧キャッシュからも呼べるよう公開
    window.dscCopyText = function (btn, text) {
        return copyTextToClipboard(text).then(function (ok) {
            if (ok) {
                flashCopied(btn);
                toast(T('📋 已复制到剪贴板'), 'success');
            } else {
                toast(T('复制失败：请长按文本手动选择复制'), 'error');
            }
            return ok;
        });
    };

    function openTranslateModal() {
        ensureModal('dscDbTranslateOverlay', buildTranslateModal, false);
        openModal('dscDbTranslateOverlay');
    }

    function buildTranslateModal() {
        var md = buildModal('dscDbTranslateOverlay', '🌐', '豆包機械翻訳', '32 言語の相互翻訳に対応。');
        var langRow = el('div', 'dsc-db-grid');
        langRow.appendChild(field('ソース言語（未選択なら自動検出）', select('dscDbTransSrcLang', 
            [{ value: '', label: '自動検出' }].concat(TRANSLATE_LANGS), '')));
        langRow.appendChild(field('ターゲット言語（必須）', select('dscDbTransTgtLang', TRANSLATE_LANGS, 'zh')));
        md.appendChild(langRow);

        md.appendChild(field('翻訳するテキスト（1行1件）', textarea('dscDbTransText', 'テキストを入力...')));
        
        var st = el('div', 'dsc-db-status'); st.id = 'dscDbTransStatus'; md.appendChild(st);
        var res = el('div', 'dsc-db-result'); res.id = 'dscDbTransResult'; md.appendChild(res);
        
        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        var go = el('button', 'dsc-db-btn primary', T('翻訳'));
        foot.appendChild(close); foot.appendChild(go); md.appendChild(foot);
        
        close.onclick = function () { closeModal('dscDbTranslateOverlay'); };
        go.onclick = function () {
            var raw = $('dscDbTransText').value;
            var lines = raw.split('\n').filter(function(s){return s.trim().length>0;});
            if (!lines.length) return;

            go.disabled = true; setStatus(st, T('翻訳中…'), 'busy');
            var tgtLang = $('dscDbTransTgtLang').value;
            api('/translate', { method: 'POST', body: { target_language: tgtLang, text_list: lines, source_language: $('dscDbTransSrcLang').value } }).then(function(d){
                var list = (d && d.data && d.data.translation_list) || [];
                var outTexts = [];
                var html = '<div class="dsc-db-trans-result">';
                list.forEach(function(item, i){
                    var text = (item && item.translation != null) ? String(item.translation) : '';
                    outTexts.push(text);
                    /* 原文与译文一律走 escHtml：< > & 不会被当成标签，
                       也不会再破坏按钮的属性（旧版内联 onclick 拼接就是这么坏的）。 */
                    html += '<div class="dsc-db-trans-item">';
                    html += '<div class="dsc-db-trans-src">' + escHtml(lines[i] || '') + '</div>';
                    html += '<div class="dsc-db-trans-tgt">' + escHtml(text) + '</div>';
                    html += '<div class="dsc-db-trans-ops">';
                    html += '<button type="button" class="dsc-db-btn dsc-btn-anim dsc-trans-copy" data-idx="' + i + '">📋 ' + T('コピー') + '</button>';
                    html += '<button type="button" class="dsc-db-btn dsc-btn-anim dsc-trans-speak" data-idx="' + i + '">🔊 ' + T('読み上げ') + '</button>';
                    html += '</div></div>';
                });
                html += '</div>';
                var host = $('dscDbTransResult');
                host.innerHTML = html;
                /* 结果文本不进 DOM 属性，只留在闭包数组里，点击时按索引取，
                   任何引号 / 换行 / 反斜杠都不会让按钮失效。 */
                var copyBtns = host.querySelectorAll('.dsc-trans-copy');
                for (var ci = 0; ci < copyBtns.length; ci++) {
                    (function (b) {
                        b.addEventListener('click', function (ev) {
                            if (ev) { ev.preventDefault(); ev.stopPropagation(); }
                            var idx = parseInt(b.getAttribute('data-idx'), 10) || 0;
                            window.dscCopyText(b, outTexts[idx] || '');
                        });
                    })(copyBtns[ci]);
                }
                var speakBtns = host.querySelectorAll('.dsc-trans-speak');
                for (var si = 0; si < speakBtns.length; si++) {
                    (function (b) {
                        b.addEventListener('click', function (ev) {
                            if (ev) { ev.preventDefault(); ev.stopPropagation(); }
                            var idx = parseInt(b.getAttribute('data-idx'), 10) || 0;
                            window.dscSpeakTrans(b, outTexts[idx] || '', tgtLang);
                        });
                    })(speakBtns[si]);
                }
                setStatus(st, T('✅ 翻訳成功'), 'ok');
            }).catch(function(e){ 
                setStatus(st, '❌ ' + (e && e.message ? e.message : T('翻訳失敗')), 'err'); 
            }).finally(function(){ go.disabled = false; });
        };
    }

    

    // ------------------------------------------------------------
    // 语音朗读（下载落盘播放版）
    //   流程：POST /api/tts → 后端用 Edge TTS 合成完整音频并落成文件
    //        → 返回 audioUrl → 前端 <audio> 下载后播放。
    //   说明：之前试过「边合成边播」的流式方案，在部分 WebView 里不稳定
    //        （音频被自动播放策略静默拦截、mp3 分片追加失败导致无声），
    //        现按要求回退到最稳妥的落盘播放，行为可预期、出错能看见。
    // ------------------------------------------------------------
    var TRANS_AUDIO = { audio: null };

    /// 停掉通话中正在播放的人声（换新语音前必须先停，避免两段叠在一起）
    function stopCallAudio() {
        var c = S.call;
        try {
            if (c && c.audio) {
                c.audio.pause();
                c.audio.removeAttribute('src');
                try { c.audio.load(); } catch (e2) {}
            }
        } catch (e) {}
        if (c) {
            // 释放上一段下载到内存的音频，避免长时间通话内存持续增长
            if (c.lastObjUrl) {
                try { URL.revokeObjectURL(c.lastObjUrl); } catch (e3) {}
                c.lastObjUrl = '';
            }
            c.audio = null;
            c.playing = false;
        }
    }

    /// 停掉翻译朗读正在播放的音频
    function stopTransAudio() {
        try {
            if (TRANS_AUDIO.audio) {
                TRANS_AUDIO.audio.pause();
                TRANS_AUDIO.audio.src = '';
            }
        } catch (e) {}
        TRANS_AUDIO.audio = null;
    }

    /// 朗读翻译结果：合成落盘 → 下载播放（回退到稳定方案）
    window.dscSpeakTrans = function (btn, text, lang) {
        var orig = btn.innerHTML;
        btn.innerHTML = '⏳ 播放中...';
        btn.classList.add('is-playing');
        btn.disabled = true;
        function restore() {
            btn.innerHTML = orig;
            btn.classList.remove('is-playing');
            btn.disabled = false;
        }

        api('/tts', {
            method: 'POST',
            body: { text: text, voice: getTTSVoiceForLang(lang), lang: lang }
        }).then(function (d) {
            if (!d.audioUrl) {
                toast('合成失败：后端没有返回音频地址', 'error');
                restore();
                return;
            }
            stopTransAudio();
            var audio = new Audio(d.audioUrl);
            TRANS_AUDIO.audio = audio;
            audio.onended = restore;
            audio.onerror = function () { toast('音频加载失败，请稍后重试', 'error'); restore(); };
            audio.play().catch(function () {
                toast('播放被浏览器拦截，请先点一下页面再重试', 'error');
                restore();
            });
        }).catch(function (e) {
            toast('语音服务错误：' + e.message, 'error');
            restore();
        });
    };

    // ------------------------------------------------------------
    // 全双工通话的人声朗读（下载落盘播放版）
    //   豆包账号没有可用的对话音色，声音统一交给 Edge TTS 渲染：
    //   先请求 /api/tts 合成落盘拿到 audioUrl，再用 <audio> 播放。
    //   音色必须经过 dscEdgeVoiceOf() 转换：直接把豆包音色 ID 丢给
    //   Edge 合成会失败，表现就是「完全没有声音」，这正是之前的病根。
    //   每段新语音开始前先停掉上一段，杜绝两段声音重叠、同一句读两遍。
    // ------------------------------------------------------------
    // 通话人声固定音色：爽快思思（豆包音色 ID）→ Edge 清晰女声。
    //   豆包账号没有开通对话音色，voice 直接传豆包 ID 给 Edge 会合成失败（表现为完全没声音），
    //   所以这里先按映射表转成合法的 Edge 女声名再发请求。
    var CALL_VOICE_ID = 'zh_female_shuangkuaisisi_moon_bigtts';
    function callVoice() { return dscEdgeVoiceOf(CALL_VOICE_ID, 'zh') || 'zh-CN-XiaoxiaoNeural'; }

    // 去重表：记录最近朗读过的句子与时间，挡住「同一句读两遍」
    var CALL_SAY = { lastText: '', lastAt: 0, recent: {} };

    /// 归一化：去掉空白与标点，只留文字，用于重复判定
    function normalizeSayText(s) {
        return String(s == null ? '' : s)
            .replace(/[\s\u3000]/g, '')
            .replace(/[，。！？、；：,.!?;:"'“”‘’（）()【】\[\]—…·~～]/g, '');
    }

    /// 全双工通话中朗读一句回复
    function dscSpeakCallText(text) {
        var c = S.call;
        if (!c || !c.active) return;
        var t = String(text == null ? '' : text).trim();
        if (!t) return;

        var key = normalizeSayText(t);
        if (!key) return;
        var now = Date.now();

        // 去重一：完全相同的句子，8 秒内只读一次。
        //   服务端在一轮里可能连发两次 response.done，或把同一句重复推送，
        //   只读一次就不会出现「一句话说两次」。
        var seen = CALL_SAY.recent[key];
        if (seen && now - seen < 8000) {
            console.log('[CALL] 跳过重复语音：' + t.slice(0, 24));
            return;
        }
        // 去重二：先发半句、再发整句时，整句已包含刚读过的半句，迟到的半句丢掉
        if (CALL_SAY.lastText && key.length < CALL_SAY.lastText.length &&
            CALL_SAY.lastText.indexOf(key) === 0 && now - CALL_SAY.lastAt < 4000) {
            return;
        }
        CALL_SAY.lastText = key;
        CALL_SAY.lastAt = now;
        CALL_SAY.recent[key] = now;
        // 清理超过 8 秒的记录，防止表无限增长
        Object.keys(CALL_SAY.recent).forEach(function (k) {
            if (now - CALL_SAY.recent[k] > 8000) delete CALL_SAY.recent[k];
        });

        stopCallAudio();
        c.playing = true;
        setCallStatus(T('読み上げ中…'), 'speaking');

        var sayLang = 'zh';
        api('/tts', {
            method: 'POST',
            body: {
                text: t,
                // 固定使用爽快思思对应的 Edge 女声，不再跟随设置里的豆包音色
                //（账号没有该音色权限，跟随后会合成失败）
                voice: callVoice(),
                lang: sayLang
            }
        }).then(function (d) {
            if (!S.call || !S.call.active) return;
            if (!d.audioUrl) {
                addBubble('sys', T('音声合成に失敗：バックエンドが音声アドレスを返しませんでした'));
                S.call.playing = false;
                setCallStatus(T('聞き取り中…'), 'listening');
                return;
            }
            playCallAudio(d.audioUrl);
        }).catch(function (e) {
            addBubble('sys', T('音声合成エラー：') + e.message);
            if (S.call) S.call.playing = false;
            setCallStatus(T('聞き取り中…'), 'listening');
        });
    }

    function openGlossaryModal() {
        ensureModal('dscDbGlossaryOverlay', buildGlossaryModal, false);
        openModal('dscDbGlossaryOverlay');
        loadGlossaryTableListInModal();
    }

    function buildGlossaryModal() {
        var md = buildModal('dscDbGlossaryOverlay', '📖', '用語集管理',
            '用語集はサーバーに保存され、.sts 形式で 1 行 1 用語（id|原語|訳語|ソース言語|ターゲット言語）。');

        // 现有术语表列表
        var listRow = el('div', 'dsc-db-glossary-row');
        var sel = select('dscDbGlossarySelect', [{ value: '', label: '— 選択してください —' }], '');
        sel.id = 'dscDbGlossarySelect';
        listRow.appendChild(field('用語集を選択', sel));
        var delBtn = el('button', 'dsc-db-btn danger', T('削除'));
        delBtn.type = 'button';
        delBtn.id = 'dscDbGlossaryDelBtn';
        listRow.appendChild(delBtn);
        md.appendChild(listRow);

        // 新建术语表
        md.appendChild(field('新規用語集名', input('dscDbGlossaryNewName', 'text', '例：ai_terms')));
        var createBtn = el('button', 'dsc-db-btn', T('作成 / 保存'));
        createBtn.type = 'button';
        createBtn.id = 'dscDbGlossaryCreateBtn';
        md.appendChild(createBtn);

        // 术语编辑区（JSON 文本框）
        md.appendChild(field('用語エントリ（JSON 配列、各項目 {source, target, sourceLang?, targetLang?}）',
            textarea('dscDbGlossaryEntries', '[\n  {"source":"AI","target":"人工智能"}\n]')));

        // 状态 & 底部按钮
        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbGlossaryStatus';
        md.appendChild(st);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(close);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbGlossaryOverlay'); });
        createBtn.addEventListener('click', saveGlossaryFromModal);
        delBtn.addEventListener('click', deleteGlossaryFromModal);
        sel.addEventListener('change', function () {
            var name = sel.value;
            if (!name) {
                $('dscDbGlossaryEntries').value = '';
                return;
            }
            api('/glossary/get?name=' + encodeURIComponent(name)).then(function (d) {
                var entries = d.entries || [];
                $('dscDbGlossaryEntries').value = JSON.stringify(entries.map(function (e) {
                    return { source: e.source, target: e.target, sourceLang: e.sourceLang, targetLang: e.targetLang };
                }), null, 2);
            }).catch(function (e) {
                setStatus(st, '❌ ' + T('用語集の読み込みに失敗：{0}', e.message), 'err');
            });
        });
    }

    function loadGlossaryTableListInModal() {
        var sel = $('dscDbGlossarySelect');
        if (!sel) return;
        api('/glossary/list').then(function (d) {
            var tables = d.tables || [];
            sel.innerHTML = '<option value="">' + T('— 選択してください —') + '</option>';
            tables.forEach(function (name) {
                var o = document.createElement('option');
                o.value = name;
                o.textContent = name;
                sel.appendChild(o);
            });
        }).catch(function () {});
    }

    function saveGlossaryFromModal() {
        var st = $('dscDbGlossaryStatus');
        var nameInput = $('dscDbGlossaryNewName');
        var entriesArea = $('dscDbGlossaryEntries');
        var name = (nameInput ? nameInput.value : '').trim();
        if (!name) {
            setStatus(st, T('⚠️ 用語集名を入力してください'), 'err');
            return;
        }
        var raw = entriesArea ? entriesArea.value.trim() : '';
        var entries;
        try {
            entries = JSON.parse(raw);
        } catch (e) {
            setStatus(st, T('⚠️ 用語エントリが有効な JSON ではありません：{0}', e.message), 'err');
            return;
        }
        if (!Array.isArray(entries)) {
            setStatus(st, T('⚠️ 用語エントリは JSON 配列である必要があります'), 'err');
            return;
        }
        api('/glossary/save', {
            method: 'POST',
            body: { name: name, entries: entries }
        }).then(function (d) {
            setStatus(st, T('✅ 用語集「{0}」を保存しました。計 {1} 件', name, (d.count || 0)), 'ok');
            toast(T('✅ 用語集を保存しました'), 'success');
            loadGlossaryTableListInModal();
            loadGlossaryTableList(); // 同步翻译弹窗的下拉框
        }).catch(function (e) {
            setStatus(st, '❌ ' + T('保存に失敗：{0}', e.message), 'err');
        });
    }

    function deleteGlossaryFromModal() {
        var sel = $('dscDbGlossarySelect');
        var name = sel ? sel.value : '';
        if (!name) {
            setStatus($('dscDbGlossaryStatus'), T('⚠️ 削除する用語集を先に選択してください'), 'err');
            return;
        }
        if (!window.confirm(T('用語集「{0}」を削除しますか？', name))) return;
        api('/glossary/delete?name=' + encodeURIComponent(name), { method: 'DELETE' }).then(function (d) {
            setStatus($('dscDbGlossaryStatus'), d.deleted ? T('✅ 削除しました') : T('⚠️ 用語集が存在しません'), d.deleted ? 'ok' : 'err');
            toast(T('用語集を削除しました'), 'info');
            loadGlossaryTableListInModal();
            loadGlossaryTableList();
        }).catch(function (e) {
            setStatus($('dscDbGlossaryStatus'), '❌ ' + T('削除に失敗：{0}', e.message), 'err');
        });
    }

})();

