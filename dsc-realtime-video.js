/* ============================================================
 * dsc-realtime-video.js
 * 豆包 Doubao-Seed-Realtime-1.0 端到端实时音视频通话（全屏单页覆盖层）
 *
 *   · 浏览器 ⇄ 本地 Dart 服务 WebSocket 代理 ⇄ 火山引擎 /api/v3/realtime
 *   · 20ms PCM16/16k 上行、24k PCM 下行；摄像头 JPEG 2 FPS 上行
 *   · 摄像头上/下/前后切换、静音、打断、文字输入由豆包语音回答
 *   · 文字输入走同一实时会话，仅计实时音视频分钟额度；不回退文本/TTS 额度
 *   · 通话结束（挂断/退出）才把五段格式 .sts 记录写入当前账号 data/jilmtshx
 *   · 六语 UI（zh/ja/en/ko/ru/fr），不新增页面，保持单页应用
 * ============================================================ */
(function () {
    'use strict';

    var IN_RATE = 16000;
    var OUT_RATE = 24000;
    var FRAME = 320;                 // 20ms @ 16k
    var MAX_BUFFERED = 2 * 1024 * 1024;
    var VIDEO_W = 720;
    var VIDEO_H = 1280;
    var VIDEO_FPS_MS = 500;          // 官方上限 2 FPS
    var RATE_VIDEO = 0.4;            // 元/分钟
    var RATE_VOICE = 0.2;            // 元/分钟
    var VOICES = [
        { id: 'zh_female_vv_uranus_bigtts', name: 'Vivi 2.0', names: { zh:'Vivi 2.0', ja:'Vivi 2.0', en:'Vivi 2.0', ko:'Vivi 2.0', ru:'Vivi 2.0', fr:'Vivi 2.0' }, gender: 'female', def: true },
        { id: 'zh_female_xiaohe_uranus_bigtts', name: '小何 2.0', names: { zh:'小何 2.0', ja:'シャオホー 2.0', en:'Xiaohe 2.0', ko:'샤오허 2.0', ru:'Сяохэ 2.0', fr:'Xiaohe 2.0' }, gender: 'female', def: false },
        { id: 'zh_male_m191_uranus_bigtts', name: '云舟 2.0', names: { zh:'云舟 2.0', ja:'ユンジョウ 2.0', en:'Yunzhou 2.0', ko:'윈저우 2.0', ru:'Юньчжоу 2.0', fr:'Yunzhou 2.0' }, gender: 'male', def: false },
        { id: 'zh_male_taocheng_uranus_bigtts', name: '小天 2.0', names: { zh:'小天 2.0', ja:'シャオティエン 2.0', en:'Xiaotian 2.0', ko:'샤오티엔 2.0', ru:'Сяотянь 2.0', fr:'Xiaotian 2.0' }, gender: 'male', def: false }
    ];

    var V = {
        open: false,
        active: false,
        connecting: false,
        finished: false,
        ws: null,
        wsUrl: '',
        voice: VOICES[0].id,
        lang: 'zh',
        userName: '',
        status: null,
        turns: [],
        seq: 0,
        durationSec: 0,
        costFen: 0,
        startedAt: 0,
        timer: null,
        micStream: null,
        micOn: true,
        camStream: null,
        camOn: false,
        camFacing: 'user',
        camToken: 0,
        camTimer: null,
        frameSeq: 0,
        ac: null,
        inRate: 48000,
        proc: null,
        src: null,
        pend: [],
        skipFrames: 0,
        playCtx: null,
        sources: [],
        nextTime: 0,
        gotAudio: false,
        speaking: false,
        curText: '',
        curUserText: '',
        lastUserFinal: '',
        lastUserDelta: '',
        userDeltaCumulative: false,
        liveUserTurn: null,
        liveAiTurn: null,
        userItemId: '',
        userStarted: false,
        userOpen: false,
        subsTimer: null,
        audioText: '',
        audioFinal: '',
        audioTextSeen: false,
        textFinal: '',
        lastAssistantText: '',
        nativeTimer: null,
        responseSeen: false,
        textToken: 0,
        histOpen: false,
        histRecords: [],
        histSelected: {},
        histDetail: null,
        savePromise: null,
        pageHideBound: false,
        connectTimer: null
    };

    // ------------------------------------------------------------
    // 六语文案
    // ------------------------------------------------------------
    var L = {
        zh: {
            title: '豆包实时视频通话', subtitle: '端到端实时音视频 · 全屏 · 四种官方 2.0 音色',
            voiceTitle: '选择音色', female: '女声', male: '男声', defaultTag: '默认',
            rate: '视频 ¥0.40/分钟 · 语音 ¥0.20/分钟', start: '开始视频通话',
            history: '通话记录', close: '关闭', connecting: '正在连接…', connected: '已连接',
            listening: '正在聆听…', speaking: '豆包正在说话…', muted: '已静音',
            mic: '静音', unmute: '取消静音', camera: '摄像头', cameraOff: '摄像头已关闭',
            switchCam: '切换摄像头', switchShort: '切换', interrupt: '打断', hangup: '挂断',
            textPlaceholder: '输入文字，豆包会用语音回答…', send: '发送',
            you: '你', doubao: '豆包', noHistory: '暂无通话记录',
            selectAll: '全选', deleteSelected: '删除所选', clearAll: '清空全部',
            cancel: '取消', delete: '删除',
            confirmDelete: '删除选中的 {0} 条通话记录？此操作不可恢复。',
            confirmClear: '清空全部通话记录？此操作不可恢复。',
            deleted: '已删除 {0} 条记录', cleared: '已清空 {0} 条记录',
            readonly: '只读记录，不能修改', detail: '通话详情', back: '返回',
            saveFail: '通话记录保存失败：{0}', camFail: '无法打开摄像头：{0}',
            micFail: '无法使用麦克风：{0}', connFail: '连接失败：{0}',
            upstreamFail: '实时音视频服务连接失败：{0}', endedRemote: '通话已断开',
            loading: '正在检查配置…', network: '网络异常', mins: '分钟', secs: '秒',
            noRecords: '暂无记录', historySub: '只读 · 支持单条/批量删除与一键清空',
            userFallback: '用户', saved: '通话记录已保存', selected: '已选 {0} 条',
            camUnsupported: '当前环境不支持摄像头（需要 HTTPS 或 localhost）',
            textMode: '文字输入', cameraOn: '打开摄像头', retry: '重试'
        },
        ja: {
            title: '豆包リアルタイム映像通話', subtitle: '端末間リアルタイム映像音声 · 全画面 · 公式 2.0 音色 4 種',
            voiceTitle: '音色を選択', female: '女性', male: '男性', defaultTag: '既定',
            rate: '映像 ¥0.40/分 · 音声 ¥0.20/分', start: '映像通話を開始',
            history: '通話履歴', close: '閉じる', connecting: '接続中…', connected: '接続済み',
            listening: '聞き取り中…', speaking: '豆包が話しています…', muted: 'ミュート中',
            mic: 'ミュート', unmute: 'ミュート解除', camera: 'カメラ', cameraOff: 'カメラはオフです',
            switchCam: 'カメラ切替', switchShort: '切替', interrupt: '割り込み', hangup: '終了',
            textPlaceholder: '文字を入力すると、豆包が音声で回答します…', send: '送信',
            you: 'あなた', doubao: '豆包', noHistory: '通話履歴がありません',
            selectAll: 'すべて選択', deleteSelected: '選択を削除', clearAll: 'すべて削除',
            cancel: 'キャンセル', delete: '削除',
            confirmDelete: '選択した {0} 件の通話記録を削除しますか？元に戻せません。',
            confirmClear: 'すべての通話記録を削除しますか？元に戻せません。',
            deleted: '{0} 件の記録を削除しました', cleared: '{0} 件の記録を消去しました',
            readonly: '閲覧専用・編集不可', detail: '通話詳細', back: '戻る',
            saveFail: '通話記録の保存に失敗：{0}', camFail: 'カメラを開けません：{0}',
            micFail: 'マイクを使用できません：{0}', connFail: '接続に失敗：{0}',
            upstreamFail: 'リアルタイム映像通話サービスに接続できません：{0}', endedRemote: '通話が切断されました',
            loading: '設定を確認しています…', network: 'ネットワーク異常', mins: '分', secs: '秒',
            noRecords: '記録なし', historySub: '閲覧専用・単件/一括削除と全削除に対応',
            userFallback: 'ユーザー', saved: '通話記録を保存しました', selected: '{0} 件選択中',
            camUnsupported: 'この環境ではカメラを使用できません（HTTPS または localhost が必要）',
            textMode: '文字入力', cameraOn: 'カメラを開く', retry: '再試行'
        },
        en: {
            title: 'Doubao realtime video call', subtitle: 'End-to-end realtime audio & video · Full screen · Four official 2.0 voices',
            voiceTitle: 'Choose a voice', female: 'Female', male: 'Male', defaultTag: 'Default',
            rate: 'Video ¥0.40/min · Voice ¥0.20/min', start: 'Start video call',
            history: 'Call history', close: 'Close', connecting: 'Connecting…', connected: 'Connected',
            listening: 'Listening…', speaking: 'Doubao is speaking…', muted: 'Muted',
            mic: 'Mute', unmute: 'Unmute', camera: 'Camera', cameraOff: 'Camera is off',
            switchCam: 'Switch camera', switchShort: 'Switch', interrupt: 'Interrupt', hangup: 'Hang up',
            textPlaceholder: 'Type a message; Doubao will answer with voice…', send: 'Send',
            you: 'You', doubao: 'Doubao', noHistory: 'No call records',
            selectAll: 'Select all', deleteSelected: 'Delete selected', clearAll: 'Clear all',
            cancel: 'Cancel', delete: 'Delete',
            confirmDelete: 'Delete {0} selected call records? This cannot be undone.',
            confirmClear: 'Clear all call records? This cannot be undone.',
            deleted: 'Deleted {0} records', cleared: 'Cleared {0} records',
            readonly: 'Read-only; editing is disabled', detail: 'Call details', back: 'Back',
            saveFail: 'Failed to save call record: {0}', camFail: 'Cannot open camera: {0}',
            micFail: 'Cannot use microphone: {0}', connFail: 'Connection failed: {0}',
            upstreamFail: 'Realtime video service connection failed: {0}', endedRemote: 'Call disconnected',
            loading: 'Checking configuration…', network: 'Network error', mins: 'min', secs: 'sec',
            noRecords: 'No records', historySub: 'Read-only · single/batch delete and clear all',
            userFallback: 'User', saved: 'Call record saved', selected: '{0} selected',
            camUnsupported: 'Camera is unavailable in this environment (HTTPS or localhost required)',
            textMode: 'Text input', cameraOn: 'Turn camera on', retry: 'Retry'
        },
        ko: {
            title: '豆包 실시간 영상 통화', subtitle: '종단 간 실시간 영상·음성 · 전체 화면 · 공식 2.0 음색 4종',
            voiceTitle: '음색 선택', female: '여성', male: '남성', defaultTag: '기본',
            rate: '영상 ¥0.40/분 · 음성 ¥0.20/분', start: '영상 통화 시작',
            history: '통화 기록', close: '닫기', connecting: '연결 중…', connected: '연결됨',
            listening: '듣는 중…', speaking: '豆包가 말하고 있습니다…', muted: '음소거됨',
            mic: '음소거', unmute: '음소거 해제', camera: '카메라', cameraOff: '카메라가 꺼져 있습니다',
            switchCam: '카메라 전환', switchShort: '전환', interrupt: '중단', hangup: '종료',
            textPlaceholder: '문자를 입력하면 豆包가 음성으로 답합니다…', send: '보내기',
            you: '나', doubao: '豆包', noHistory: '통화 기록이 없습니다',
            selectAll: '모두 선택', deleteSelected: '선택 삭제', clearAll: '모두 지우기',
            cancel: '취소', delete: '삭제',
            confirmDelete: '선택한 통화 기록 {0}개를 삭제하시겠습니까? 되돌릴 수 없습니다.',
            confirmClear: '모든 통화 기록을 지우시겠습니까? 되돌릴 수 없습니다.',
            deleted: '{0}개의 기록을 삭제했습니다', cleared: '{0}개의 기록을 지웠습니다',
            readonly: '읽기 전용, 수정 불가', detail: '통화 상세', back: '뒤로',
            saveFail: '통화 기록 저장 실패: {0}', camFail: '카메라를 열 수 없습니다: {0}',
            micFail: '마이크를 사용할 수 없습니다: {0}', connFail: '연결 실패: {0}',
            upstreamFail: '실시간 영상 통화 서비스 연결 실패: {0}', endedRemote: '통화가 끊겼습니다',
            loading: '설정 확인 중…', network: '네트워크 오류', mins: '분', secs: '초',
            noRecords: '기록 없음', historySub: '읽기 전용 · 단일/일괄 삭제 및 전체 삭제 지원',
            userFallback: '사용자', saved: '통화 기록이 저장되었습니다', selected: '{0}개 선택됨',
            camUnsupported: '현재 환경에서는 카메라를 사용할 수 없습니다(HTTPS 또는 localhost 필요)',
            textMode: '문자 입력', cameraOn: '카메라 켜기', retry: '다시 시도'
        },
        ru: {
            title: 'Видеозвонок Doubao в реальном времени', subtitle: 'Сквозной обмен видео и аудио · Полный экран · Четыре официальных голоса 2.0',
            voiceTitle: 'Выберите голос', female: 'Женский', male: 'Мужской', defaultTag: 'По умолчанию',
            rate: 'Видео ¥0.40/мин · Голос ¥0.20/мин', start: 'Начать видеозвонок',
            history: 'История звонков', close: 'Закрыть', connecting: 'Подключение…', connected: 'Подключено',
            listening: 'Слушаю…', speaking: 'Doubao говорит…', muted: 'Микрофон выключен',
            mic: 'Без звука', unmute: 'Вкл. звук', camera: 'Камера', cameraOff: 'Камера выключена',
            switchCam: 'Сменить камеру', switchShort: 'Сменить', interrupt: 'Стоп', hangup: 'Конец',
            textPlaceholder: 'Введите текст — Doubao ответит голосом…', send: 'Отправить',
            you: 'Вы', doubao: 'Doubao', noHistory: 'Нет записей звонков',
            selectAll: 'Выбрать все', deleteSelected: 'Удалить выбранные', clearAll: 'Очистить все',
            cancel: 'Отмена', delete: 'Удалить',
            confirmDelete: 'Удалить выбранные записи ({0})? Это нельзя отменить.',
            confirmClear: 'Очистить всю историю звонков? Это нельзя отменить.',
            deleted: 'Удалено записей: {0}', cleared: 'Очищено записей: {0}',
            readonly: 'Только чтение, редактирование запрещено', detail: 'Детали звонка', back: 'Назад',
            saveFail: 'Не удалось сохранить запись: {0}', camFail: 'Не удалось открыть камеру: {0}',
            micFail: 'Не удалось использовать микрофон: {0}', connFail: 'Ошибка подключения: {0}',
            upstreamFail: 'Нет подключения к сервису видеозвонка: {0}', endedRemote: 'Звонок прерван',
            loading: 'Проверка настроек…', network: 'Ошибка сети', mins: 'мин', secs: 'сек',
            noRecords: 'Нет записей', historySub: 'Только чтение · удаление по одной, пакетно и полностью',
            userFallback: 'Пользователь', saved: 'Запись звонка сохранена', selected: 'Выбрано: {0}',
            camUnsupported: 'Камера недоступна в этой среде (нужен HTTPS или localhost)',
            textMode: 'Текст', cameraOn: 'Включить камеру', retry: 'Повторить'
        },
        fr: {
            title: 'Appel vidéo Doubao en temps réel', subtitle: 'Audio et vidéo de bout en bout · Plein écran · Quatre voix officielles 2.0',
            voiceTitle: 'Choisir une voix', female: 'Féminine', male: 'Masculine', defaultTag: 'Par défaut',
            rate: 'Vidéo ¥0.40/min · Voix ¥0.20/min', start: 'Démarrer l’appel vidéo',
            history: 'Historique des appels', close: 'Fermer', connecting: 'Connexion…', connected: 'Connecté',
            listening: 'Écoute…', speaking: 'Doubao parle…', muted: 'Micro coupé',
            mic: 'Micro', unmute: 'Micro', camera: 'Caméra', cameraOff: 'Caméra désactivée',
            switchCam: 'Changer de caméra', switchShort: 'Changer', interrupt: 'Stop', hangup: 'Fin',
            textPlaceholder: 'Tapez un message ; Doubao répondra par la voix…', send: 'Envoyer',
            you: 'Vous', doubao: 'Doubao', noHistory: 'Aucun appel enregistré',
            selectAll: 'Tout sélectionner', deleteSelected: 'Supprimer la sélection', clearAll: 'Tout effacer',
            cancel: 'Annuler', delete: 'Supprimer',
            confirmDelete: 'Supprimer les {0} appels sélectionnés ? Action irréversible.',
            confirmClear: 'Effacer tout l’historique des appels ? Action irréversible.',
            deleted: '{0} enregistrements supprimés', cleared: '{0} enregistrements effacés',
            readonly: 'Lecture seule, modification interdite', detail: 'Détails de l’appel', back: 'Retour',
            saveFail: 'Échec de l’enregistrement : {0}', camFail: 'Impossible d’ouvrir la caméra : {0}',
            micFail: 'Impossible d’utiliser le micro : {0}', connFail: 'Échec de connexion : {0}',
            upstreamFail: 'Connexion au service vidéo impossible : {0}', endedRemote: 'Appel interrompu',
            loading: 'Vérification de la configuration…', network: 'Erreur réseau', mins: 'min', secs: 's',
            noRecords: 'Aucun enregistrement', historySub: 'Lecture seule · suppression unitaire, groupée et totale',
            userFallback: 'Utilisateur', saved: 'Appel enregistré', selected: '{0} sélectionné(s)',
            camUnsupported: 'Caméra indisponible dans cet environnement (HTTPS ou localhost requis)',
            textMode: 'Texte', cameraOn: 'Activer la caméra', retry: 'Réessayer'
        }
    };

    function curLang() {
        try {
            var l = String((window.I18N && I18N.getLang && I18N.getLang()) || 'zh');
            l = l.slice(0, 2);
            return L[l] ? l : 'zh';
        } catch (e) {
            return 'zh';
        }
    }

    function tr(key) {
        var lang = curLang();
        var pack = L[lang] || L.zh;
        var s = pack[key];
        if (s == null) s = (L.zh[key] == null ? key : L.zh[key]);
        var args = Array.prototype.slice.call(arguments, 1);
        return String(s).replace(/\{(\d+)\}/g, function (m, i) {
            return args[i] == null ? m : args[i];
        });
    }

    function $(id) { return document.getElementById(id); }

    function newId() {
        return 'ev_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 8);
    }

    function b64FromBytes(u8) {
        var s = '';
        for (var i = 0; i < u8.length; i += 0x8000) {
            s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        }
        return btoa(s);
    }

    function bytesFromB64(b64) {
        var s = atob(b64);
        var u8 = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
        return u8;
    }

    function downsample(buf, from, to) {
        if (to >= from) return buf;
        var ratio = from / to;
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
    // 页面骨架
    // ------------------------------------------------------------
    function buildUi() {
        if ($('dscVideoCallOverlay')) return;
        var ov = document.createElement('div');
        ov.id = 'dscVideoCallOverlay';
        ov.className = 'dsc-vc-overlay';
        ov.innerHTML = [
            '<video id="dscVcVideo" class="dsc-vc-video" autoplay playsinline muted></video>',
            '<div class="dsc-vc-scrim"></div>',
            '<div class="dsc-vc-camoff" id="dscVcCamOff">',
            '  <div class="dsc-vc-orb">豆</div>',
            '  <div class="dsc-vc-camoff-text" data-vt="cameraOff">摄像头已关闭</div>',
            '</div>',
            '<div class="dsc-vc-call" id="dscVcCall">',
            '  <header class="dsc-vc-top">',
            '    <button class="dsc-vc-round" id="dscVcBack" type="button" title="关闭">‹</button>',
            '    <div class="dsc-vc-titlewrap">',
            '      <div class="dsc-vc-name">豆包</div>',
            '      <div class="dsc-vc-meter"><span id="dscVcTime">00:00</span><span class="dot">·</span><span id="dscVcCost">¥0.00</span></div>',
            '    </div>',
            '    <div class="dsc-vc-topright">',
            '      <button class="dsc-vc-round" id="dscVcHistIcon" type="button" title="通话记录">🕘</button>',
            '      <button class="dsc-vc-round" id="dscVcSwitchTop" type="button" title="切换摄像头">🔄</button>',
            '    </div>',
            '  </header>',
            '  <div class="dsc-vc-centerstatus" id="dscVcCenterStatus">正在连接…</div>',
            '  <div class="dsc-vc-subs" id="dscVcSubs"></div>',
            '  <div class="dsc-vc-textpanel" id="dscVcTextPanel">',
            '    <input id="dscVcTextInput" type="text" autocomplete="off" placeholder="输入文字…">',
            '    <button id="dscVcTextSend" type="button">发送</button>',
            '  </div>',
            '  <div class="dsc-vc-controls" id="dscVcControls">',
            '    <button class="dsc-vc-ctrl" id="dscVcCamBtn" type="button"><span class="ico">📷</span><span class="lbl" data-vt="camera">摄像头</span></button>',
            '    <button class="dsc-vc-ctrl" id="dscVcSwitchBtn" type="button"><span class="ico">🔄</span><span class="lbl" data-vt="switchShort">切换</span></button>',
            '    <button class="dsc-vc-ctrl" id="dscVcMuteBtn" type="button"><span class="ico">🎙️</span><span class="lbl" data-vt="mic">静音</span></button>',
            '    <button class="dsc-vc-ctrl" id="dscVcKbBtn" type="button"><span class="ico">⌨️</span><span class="lbl" data-vt="textMode">文字</span></button>',
            '    <button class="dsc-vc-ctrl" id="dscVcIntBtn" type="button"><span class="ico">⏹</span><span class="lbl" data-vt="interrupt">打断</span></button>',
            '    <button class="dsc-vc-hang" id="dscVcHangBtn" type="button"><span class="ico">📞</span><span class="lbl" data-vt="hangup">挂断</span></button>',
            '  </div>',
            '</div>',
            '<div class="dsc-vc-start" id="dscVcStart">',
            '  <div class="dsc-vc-startcard">',
            '    <div class="dsc-vc-startorb">豆</div>',
            '    <h1 class="dsc-vc-h1" data-vt="title">豆包实时视频通话</h1>',
            '    <p class="dsc-vc-intro" data-vt="subtitle"></p>',
            '    <div class="dsc-vc-vlabel" data-vt="voiceTitle">选择音色</div>',
            '    <div class="dsc-vc-voices" id="dscVcVoices"></div>',
            '    <div class="dsc-vc-rate" id="dscVcRate"></div>',
            '    <div class="dsc-vc-startbtns">',
            '      <button class="dsc-vc-startbtn" id="dscVcStartBtn" type="button" data-vt="start">开始视频通话</button>',
            '      <div class="dsc-vc-startlinks">',
            '        <button class="dsc-vc-link" id="dscVcHistBtn" type="button" data-vt="history">通话记录</button>',
            '        <button class="dsc-vc-link" id="dscVcCloseBtn" type="button" data-vt="close">关闭</button>',
            '      </div>',
            '    </div>',
            '    <div class="dsc-vc-hint" id="dscVcHint"></div>',
            '  </div>',
            '</div>',
            '<div class="dsc-vc-sheet" id="dscVcHistSheet">',
            '  <div class="dsc-vc-sheetcard">',
            '    <div class="dsc-vc-sheethead">',
            '      <div class="dsc-vc-sheettitle" id="dscVcHistTitle">通话记录</div>',
            '      <button class="dsc-vc-sheetclose" id="dscVcHistClose" type="button">×</button>',
            '    </div>',
            '    <div class="dsc-vc-sheetsub" id="dscVcHistSub"></div>',
            '    <div class="dsc-vc-histbar" id="dscVcHistBar">',
            '      <button id="dscVcSelAll" type="button"></button>',
            '      <button id="dscVcDelSel" type="button" class="danger"></button>',
            '      <button id="dscVcClearAll" type="button" class="danger"></button>',
            '    </div>',
            '    <div class="dsc-vc-histlist" id="dscVcHistList"></div>',
            '    <div class="dsc-vc-sheetfoot"><span id="dscVcHistCount"></span></div>',
            '  </div>',
            '</div>',
            '<div class="dsc-vc-toast" id="dscVcToast"></div>'
        ].join('');
        document.body.appendChild(ov);

        bindUi();
        applyLang();
        renderVoices();
    }

    function applyLang() {
        V.lang = curLang();
        var nodes = document.querySelectorAll('#dscVideoCallOverlay [data-vt]');
        for (var i = 0; i < nodes.length; i++) {
            nodes[i].textContent = tr(nodes[i].getAttribute('data-vt'));
        }
        var ri = $('dscVcRate');
        if (ri) ri.textContent = tr('rate');
        var ti = $('dscVcTextInput');
        if (ti) ti.placeholder = tr('textPlaceholder');
        var ts = $('dscVcTextSend');
        if (ts) ts.textContent = tr('send');
        var ht = $('dscVcHistTitle');
        if (ht) ht.textContent = V.histDetail ? tr('detail') : tr('history');
        var hs = $('dscVcHistSub');
        if (hs) hs.textContent = V.histDetail ? tr('readonly') : tr('historySub');
        var sa = $('dscVcSelAll');
        if (sa) sa.textContent = tr('selectAll');
        var ds = $('dscVcDelSel');
        if (ds) ds.textContent = tr('deleteSelected');
        var ca = $('dscVcClearAll');
        if (ca) ca.textContent = tr('clearAll');
        var hb = $('dscVcHistIcon');
        if (hb) hb.title = tr('history');
        var st = $('dscVcStartBtn');
        if (st && V.connecting) st.textContent = tr('connecting');
        var bt = $('dscVcBack');
        if (bt) bt.title = tr('close');
        var sb = $('dscVcSwitchTop');
        if (sb) sb.title = tr('switchCam');
        renderVoices();
        updateCameraUi();
        updateMicUi();
    }

    // ------------------------------------------------------------
    // 开始界面
    // ------------------------------------------------------------
    function renderVoices() {
        var wrap = $('dscVcVoices');
        if (!wrap) return;
        wrap.innerHTML = '';
        VOICES.forEach(function (v) {
            var b = document.createElement('button');
            b.type = 'button';
            b.className = 'dsc-vc-voice' + (V.voice === v.id ? ' active' : '');
            b.setAttribute('data-voice', v.id);
            var nm = document.createElement('span');
            nm.className = 'vname';
            nm.textContent = (v.names && v.names[curLang()]) || v.name;
            var sub = document.createElement('span');
            sub.className = 'vsub';
            sub.textContent = (v.gender === 'female' ? tr('female') : tr('male')) +
                (v.def ? ' · ' + tr('defaultTag') : '');
            b.appendChild(nm);
            b.appendChild(sub);
            b.addEventListener('click', function () {
                if (V.active) {
                    setVoice(v.id);
                } else {
                    V.voice = v.id;
                    try { localStorage.setItem('dsc_video_voice', v.id); } catch (e) {}
                    renderVoices();
                }
            });
            wrap.appendChild(b);
        });
    }

    function loadSavedVoice() {
        var saved = '';
        try { saved = localStorage.getItem('dsc_video_voice') || ''; } catch (e) {}
        V.voice = VOICES.some(function (v) { return v.id === saved; }) ? saved : VOICES[0].id;
    }

    function setVoice(id) {
        if (!VOICES.some(function (v) { return v.id === id; })) return;
        V.voice = id;
        try { localStorage.setItem('dsc_video_voice', id); } catch (e) {}
        renderVoices();
        if (V.active) {
            // 官方 session.update：只更新音色，下一轮生效。
            sendWs({
                type: 'session.update',
                event_id: newId(),
                session: { audio: { output: { voice: id } } }
            });
            var cur = VOICES.filter(function (v) { return v.id === id; })[0] || {};
            vcToast((cur.names && cur.names[curLang()]) || cur.name, 'info');
        }
    }

    function open() {
        buildUi();
        V.open = true;
        V.finished = false;
        V.turns = [];
        V.seq = 0;
        V.durationSec = 0;
        V.costFen = 0;
        V.histDetail = null;
        V.histSelected = {};
        var ov = $('dscVideoCallOverlay');
        ov.classList.add('show');
        $('dscVcStart').style.display = '';
        $('dscVcCall').style.display = 'none';
        $('dscVcHistSheet').classList.remove('show');
        $('dscVcSubs').innerHTML = '';
        $('dscVcHint').textContent = '';
        $('dscVcStartBtn').disabled = true;
        $('dscVcStartBtn').textContent = tr('loading');
        $('dscVcTime').textContent = '00:00';
        $('dscVcCost').textContent = '¥0.00';
        loadSavedVoice();
        renderVoices();
        applyLang();
        resetStateForCall();
        fetchStatus();
        fetchUser();
        document.documentElement.classList.add('dsc-vc-lock');
        bindViewport();
    }

    function closeOverlay() {
        var ov = $('dscVideoCallOverlay');
        if (ov) ov.classList.remove('show');
        $('dscVcTextInput').blur();
        document.documentElement.classList.remove('dsc-vc-lock');
        V.open = false;
        V.histOpen = false;
        unbindViewport();
    }

    function fetchStatus() {
        fetch('/api/doubao/realtime-video/status', { credentials: 'same-origin', cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                V.status = (d && d.video) || null;
                var sb = $('dscVcStartBtn');
                if (!sb) return;
                if (V.status && V.status.available) {
                    sb.disabled = false;
                    sb.textContent = tr('start');
                    $('dscVcHint').textContent = '';
                } else {
                    sb.disabled = true;
                    sb.textContent = tr('start');
                    $('dscVcHint').textContent = (V.status && V.status.reason) ? V.status.reason : tr('configMissing');
                }
            })
            .catch(function () {
                var sb = $('dscVcStartBtn');
                if (sb) { sb.disabled = true; sb.textContent = tr('start'); }
                $('dscVcHint').textContent = tr('network');
            });
    }

    function fetchUser() {
        fetch('/api/auth/status', { credentials: 'same-origin', cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                var u = d && d.user;
                V.userName = (u && (u.username || u.name)) || '';
            })
            .catch(function () {});
    }

    // ------------------------------------------------------------
    // 通话启动
    // ------------------------------------------------------------
    function resetStateForCall() {
        V.active = false;
        V.connecting = false;
        V.finished = false;
        V.ws = null;
        V.startedAt = 0;
        V.timer = null;
        V.turns = [];
        V.seq = 0;
        V.micOn = true;
        V.camOn = false;
        V.camFacing = 'user';
        V.camToken++;
        V.camTimer = null;
        V.pend = [];
        V.skipFrames = 0;
        V.curText = '';
        V.curUserText = '';
        V.lastAssistantText = '';
        V.lastUserFinal = '';
        V.lastUserDelta = '';
        V.userDeltaCumulative = false;
        V.liveUserTurn = null;
        V.liveAiTurn = null;
        V.userItemId = '';
        V.userStarted = false;
        V.userOpen = false;
        if (V.subsTimer) { clearTimeout(V.subsTimer); V.subsTimer = null; }
        V.audioText = '';
        V.audioFinal = '';
        V.audioTextSeen = false;
        V.textFinal = '';
        V.responseSeen = false;
        V.textToken++;
        V.speaking = false;
        V.savePromise = null;
    }

    async function startCall() {
        if (V.active || V.connecting) return;
        if (!V.status || !V.status.available) {
            $('dscVcHint').textContent = (V.status && V.status.reason) ? V.status.reason : tr('configMissing');
            return;
        }
        V.connecting = true;
        V.finished = false;
        V.turns = [];
        V.seq = 0;
        V.durationSec = 0;
        V.costFen = 0;
        $('dscVcStart').style.display = 'none';
        $('dscVcCall').style.display = 'flex';
        $('dscVcTime').textContent = '00:00';
        $('dscVcCost').textContent = '¥0.00';
        $('dscVcSubs').innerHTML = '';
        setCenterStatus(tr('connecting'));

        var mic = null;
        try {
            mic = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: true,
                    noiseSuppression: true,
                    autoGainControl: true,
                    channelCount: 1
                },
                video: false
            });
        } catch (e) {
            V.connecting = false;
            vcToast(tr('micFail', e && e.message ? e.message : e), 'error');
            endToStart();
            return;
        }
        V.micStream = mic;
        try { initAudio(mic); } catch (e) {
            V.connecting = false;
            vcToast(tr('micFail', e && e.message ? e.message : e), 'error');
            cleanupAudio();
            endToStart();
            return;
        }

        // 摄像头是可选能力：拒绝也不阻断语音，只显示“摄像头已关闭”。
        await tryCamera(V.camFacing, true);

        var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        var q = 'lang=' + encodeURIComponent(curLang()) +
            '&voice=' + encodeURIComponent(V.voice);
        var url = proto + '//' + location.host + '/api/doubao/realtime-video?' + q;
        var ws;
        try {
            ws = new WebSocket(url);
        } catch (e) {
            V.connecting = false;
            vcToast(tr('connFail', e && e.message ? e.message : e), 'error');
            endToStart();
            return;
        }
        V.ws = ws;
        ws.binaryType = 'arraybuffer';
        if (V.connectTimer) clearTimeout(V.connectTimer);
        V.connectTimer = setTimeout(function () {
            if (V.connecting && !V.active) {
                try { ws.close(); } catch (e) {}
                V.connecting = false;
                vcToast(tr('upstreamFail', 'timeout'), 'error');
                endToStart();
            }
        }, 18000);

        ws.onopen = function () {
            if (ws !== V.ws) return;
            sendWs({
                type: 'session.create',
                event_id: newId(),
                session: {
                    model: '1.3.0.0',
                    audio: {
                        input: { format: { type: 'pcm', rate: IN_RATE } },
                        output: { format: { type: 'pcm_s16le', rate: OUT_RATE }, voice: V.voice }
                    }
                },
                extension: { video: { frame_format: 'JPEG', frame_rate: 2 } }
            });
        };
        ws.onmessage = function (ev) {
            if (ws !== V.ws) return;
            onWsMessage(ev);
        };
        ws.onerror = function () {
            if (ws !== V.ws) return;
            if (!V.active) setCenterStatus(tr('network'));
        };
        ws.onclose = function (ev) {
            if (ws !== V.ws) return;
            if (V.finished) return;
            if (V.active) {
                finishCall('remote', tr('endedRemote'));
            } else if (V.connecting) {
                V.connecting = false;
                vcToast(tr('upstreamFail', 'WebSocket ' + (ev && ev.code ? ev.code : '')), 'error');
                endToStart();
            }
        };
    }

    function endToStart() {
        if (V.connectTimer) { clearTimeout(V.connectTimer); V.connectTimer = null; }
        cleanupAudio();
        stopCamera();
        var st = $('dscVcStart');
        if (st) st.style.display = '';
        var cl = $('dscVcCall');
        if (cl) cl.style.display = 'none';
        var sb = $('dscVcStartBtn');
        if (sb) { sb.disabled = false; sb.textContent = tr('start'); }
        V.connecting = false;
        V.active = false;
    }

    // ------------------------------------------------------------
    // 音频采集 / 播放
    // ------------------------------------------------------------
    function initAudio(stream) {
        var AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) throw new Error('AudioContext unavailable');
        V.ac = new AC();
        V.inRate = V.ac.sampleRate || 48000;
        V.src = V.ac.createMediaStreamSource(stream);
        V.proc = V.ac.createScriptProcessor(2048, 1, 1);
        V.proc.onaudioprocess = onAudioProcess;
        V.src.connect(V.proc);
        V.proc.connect(V.ac.destination);
        V.playCtx = new AC();
        V.nextTime = 0;
        V.sources = [];
        if (V.ac.state === 'suspended' && V.ac.resume) { try { V.ac.resume(); } catch (e) {} }
        if (V.playCtx.state === 'suspended' && V.playCtx.resume) { try { V.playCtx.resume(); } catch (e) {} }
    }

    function onAudioProcess(ev) {
        if (!V.active || !V.micOn) return;
        if (V.skipFrames > 0) { V.skipFrames--; return; }
        var input = ev.inputBuffer.getChannelData(0);
        var f32 = downsample(input, V.inRate, IN_RATE);
        for (var i = 0; i < f32.length; i++) V.pend.push(f32[i]);
        while (V.pend.length >= FRAME) {
            var chunk = V.pend.slice(0, FRAME);
            V.pend = V.pend.slice(FRAME);
            sendPcm(chunk);
        }
    }

    function sendPcm(f32) {
        if (!V.ws || V.ws.readyState !== 1) return;
        if (V.ws.bufferedAmount > MAX_BUFFERED) return;
        var i16 = new Int16Array(f32.length);
        for (var i = 0; i < f32.length; i++) {
            var v = Math.max(-1, Math.min(1, f32[i]));
            i16[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
        }
        sendWs({
            type: 'input_audio_buffer.append',
            event_id: newId(),
            audio: b64FromBytes(new Uint8Array(i16.buffer))
        });
    }

    function playPcm(b64) {
        var ctx = V.playCtx;
        if (!ctx) return;
        var u8;
        try { u8 = bytesFromB64(b64); } catch (e) { return; }
        if (u8.length < 2) return;
        var n = u8.length >> 1;
        var buf = ctx.createBuffer(1, n, OUT_RATE);
        var ch = buf.getChannelData(0);
        for (var i = 0; i < n; i++) {
            var v = u8[2 * i] | (u8[2 * i + 1] << 8);
            if (v >= 0x8000) v -= 0x10000;
            ch[i] = v / 32768;
        }
        var src = ctx.createBufferSource();
        src.buffer = buf;
        src.connect(ctx.destination);
        var t = Math.max(ctx.currentTime + 0.03, V.nextTime || 0);
        try { src.start(t); } catch (e) { return; }
        V.nextTime = t + buf.duration;
        V.sources.push(src);
        src.onended = function () {
            var k = V.sources.indexOf(src);
            if (k >= 0) V.sources.splice(k, 1);
        };
    }

    function stopPlayback() {
        for (var i = 0; i < V.sources.length; i++) {
            try { V.sources[i].stop(); } catch (e) {}
        }
        V.sources = [];
        V.nextTime = 0;
    }

    function cleanupAudio() {
        try { if (V.proc) { V.proc.onaudioprocess = null; V.proc.disconnect(); } } catch (e) {}
        V.proc = null;
        try { if (V.src) V.src.disconnect(); } catch (e) {}
        V.src = null;
        try { if (V.ac && V.ac.close) V.ac.close(); } catch (e) {}
        V.ac = null;
        try { if (V.playCtx && V.playCtx.close) V.playCtx.close(); } catch (e) {}
        V.playCtx = null;
        try { if (V.micStream) V.micStream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        V.micStream = null;
        V.pend = [];
        stopPlayback();
    }

    // ------------------------------------------------------------
    // 摄像头：开关 / 前后切换 / 2 FPS 上行
    // ------------------------------------------------------------
    async function tryCamera(facing, silent) {
        try {
            await openCamera(facing);
            return true;
        } catch (e) {
            if (!silent) vcToast(tr('camFail', e && e.message ? e.message : e), 'error');
            V.camOn = false;
            updateCameraUi();
            return false;
        }
    }

    async function openCamera(facing) {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            throw new Error(tr('camUnsupported'));
        }
        stopCameraTracks();
        var token = ++V.camToken;
        var stream = null;
        try {
            // 先用 exact，确保前后摄像头真正切换；部分机型不支持 exact 时逐级回退。
            stream = await navigator.mediaDevices.getUserMedia({
                video: { facingMode: { exact: facing }, width: { ideal: 1280 }, height: { ideal: 720 } },
                audio: false
            });
        } catch (e1) {
            try {
                stream = await navigator.mediaDevices.getUserMedia({
                    video: { facingMode: { ideal: facing }, width: { ideal: 1280 }, height: { ideal: 720 } },
                    audio: false
                });
            } catch (e2) {
                // 某些机型完全不支持 facingMode，回退到任意摄像头（此时切换可能无效）。
                stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
            }
        }
        if (token !== V.camToken) {
            try { stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
            return;
        }
        V.camStream = stream;
        V.camFacing = facing;
        V.camOn = true;
        var v = $('dscVcVideo');
        if (v) {
            try { v.pause(); } catch (e) {}
            v.srcObject = null;
            v.srcObject = stream;
            v.classList.toggle('mirror', facing === 'user');
            try { await v.play(); } catch (e) {}
        }
        stream.getVideoTracks().forEach(function (t) {
            t.addEventListener('ended', function () {
                if (V.camOn) { V.camOn = false; stopCameraTracks(); updateCameraUi(); }
            });
        });
        V.camErrCount = 0;
        updateCameraUi();
        if (V.active) startFrameTimer();
    }

    function stopCameraTracks() {
        V.camToken++;
        if (V.camTimer) { clearInterval(V.camTimer); V.camTimer = null; }
        try { if (V.camStream) V.camStream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        V.camStream = null;
        var v = $('dscVcVideo');
        if (v) {
            try { v.pause(); } catch (e) {}
            v.srcObject = null;
        }
    }

    function stopCamera() {
        stopCameraTracks();
        V.camOn = false;
        updateCameraUi();
    }

    function toggleCamera() {
        if (V.camOn) {
            stopCamera();
            return;
        }
        tryCamera(V.camFacing || 'user', false);
    }

    function switchCamera() {
        var next = V.camFacing === 'user' ? 'environment' : 'user';
        if (!V.camOn) { tryCamera(next, false); return; }
        openCamera(next).catch(function (e) {
            V.camOn = false;
            updateCameraUi();
            vcToast(tr('camFail', e && e.message ? e.message : e), 'error');
        });
    }

    function startFrameTimer() {
        if (V.camTimer) clearInterval(V.camTimer);
        V.camTimer = setInterval(function () {
            sendCameraFrame().catch(function () {});
        }, VIDEO_FPS_MS);
        sendCameraFrame().catch(function () {});
    }

    async function sendCameraFrame() {
        if (!V.active || !V.camOn || !V.camStream || !V.ws || V.ws.readyState !== 1) return;
        if (V.ws.bufferedAmount > MAX_BUFFERED) return;
        var v = $('dscVcVideo');
        if (!v || v.readyState < 2 || !v.videoWidth || !v.videoHeight) return;
        var canvas = V.camCanvas;
        if (!canvas) { canvas = document.createElement('canvas'); V.camCanvas = canvas; }
        canvas.width = VIDEO_W;
        canvas.height = VIDEO_H;
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, VIDEO_W, VIDEO_H);
        var vw = v.videoWidth, vh = v.videoHeight;
        var scale = Math.max(VIDEO_W / vw, VIDEO_H / vh);
        var dw = vw * scale, dh = vh * scale;
        ctx.drawImage(v, (VIDEO_W - dw) / 2, (VIDEO_H - dh) / 2, dw, dh);
        var b64 = '';
        try { b64 = canvas.toDataURL('image/jpeg', 0.72).split(',')[1] || ''; } catch (e) { return; }
        if (!b64) return;
        sendWs({
            type: 'input_image_buffer.append',
            event_id: newId(),
            image: b64,
            frame_id: 'frame_' + (++V.frameSeq)
        });
    }

    function updateCameraUi() {
        var v = $('dscVcVideo');
        var off = $('dscVcCamOff');
        var cb = $('dscVcCamBtn');
        var sb = $('dscVcSwitchBtn');
        var st = $('dscVcSwitchTop');
        if (v) v.classList.toggle('on', !!V.camOn);
        if (off) off.style.display = V.camOn ? 'none' : 'flex';
        if (cb) {
            cb.classList.toggle('off', !V.camOn);
            var lbl = cb.querySelector('.lbl');
            if (lbl) lbl.textContent = tr('camera');
            cb.querySelector('.ico').textContent = V.camOn ? '📷' : '🚫';
        }
        if (sb) sb.classList.toggle('disabled', !V.camOn);
        if (st) st.classList.toggle('disabled', !V.camOn);
    }

    // ------------------------------------------------------------
    // WebSocket 事件
    // ------------------------------------------------------------
    function sendWs(obj) {
        if (!V.ws || V.ws.readyState !== 1) return false;
        try { V.ws.send(JSON.stringify(obj)); return true; } catch (e) { return false; }
    }

    function onWsMessage(ev) {
        var m;
        try { m = JSON.parse(ev.data); } catch (e) { return; }
        var t = m.type || '';

        if (t === 'session.created') {
            if (V.connectTimer) { clearTimeout(V.connectTimer); V.connectTimer = null; }
            V.connecting = false;
            V.active = true;
            V.finished = false;
            V.startedAt = Date.now();
            startTimer();
            setCenterStatus(tr('connected'));
            setCallStatusUi('listening');
            if (V.camOn && !V.camTimer) startFrameTimer();
            setTimeout(function () { if (V.active) setCenterStatus(''); }, 1600);
            return;
        }
        if (t === 'session.closed') {
            if (V.active) finishCall('server', tr('endedRemote'));
            return;
        }
        if (t === 'response.created') {
            // 用户最终转写有可能比 response.created 更晚到，不能提前丢掉用户
            // 气泡引用；只把光标收掉，等 completed 到达后就地替换成最终文本。
            if (V.liveUserTurn) {
                V.liveUserTurn.live = false;
                renderSubs();
            }
            // 上一轮豆包若因网络/取消没有收到 done，先把残留的实时气泡收口。
            if (V.liveAiTurn) closeLiveTurn('liveAiTurn');
            V.speaking = true;
            V.responseSeen = true;
            V.audioText = '';
            V.audioFinal = '';
            V.audioTextSeen = false;
            V.textFinal = '';
            if (V.nativeTimer) { clearTimeout(V.nativeTimer); V.nativeTimer = null; }
            setCallStatusUi('speaking');
            return;
        }
        // ★ 以「实际播报的音频字幕」为准：实时模型的文本流和语音内容可能
        //   有细微差异；优先用 response.output_audio_transcript，确保气泡
        //   与用户听到的语音一致。没有该事件时才回退 output_text。
        if (t === 'response.output_audio_transcript.delta' || t === 'response.audio_transcript.delta') {
            var atd = (typeof m.delta === 'string') ? m.delta : ((typeof m.text === 'string') ? m.text : '');
            if (atd) {
                V.audioTextSeen = true;
                // 语音字幕与用户转写一样，部分服务端会发累计全文而不是增量。
                V.audioText = mergeTranscript(V.audioText, atd);
                showLiveAssistant(V.audioText);
            }
            return;
        }
        if (t === 'response.output_audio_transcript.done' || t === 'response.audio_transcript.done') {
            var atFinal = String(m.transcript || m.text || '');
            V.audioFinal = mergeTranscript(V.audioText, atFinal);
            V.audioText = '';
            if (V.audioFinal) {
                V.audioTextSeen = true;
                showLiveAssistant(V.audioFinal);
            }
            return;
        }
        if (t === 'response.output_text.delta' || t === 'response.text.delta') {
            var dl = (typeof m.delta === 'string') ? m.delta : ((typeof m.text === 'string') ? m.text : '');
            if (dl) {
                V.curText = mergeTranscript(V.curText, dl);
                // 有真实语音字幕时以语音字幕为准，文本流仅作兜底保存；
                // 没有语音字幕时，文本流也必须实时上屏，不能等 done。
                if (!V.audioTextSeen) showLiveAssistant(V.curText);
            }
            return;
        }
        if (t === 'response.output_text.done' || t === 'response.text.done') {
            V.textFinal = mergeTranscript(V.curText, String(m.text || ''));
            V.curText = '';
            if (!V.audioTextSeen && V.textFinal) showLiveAssistant(V.textFinal);
            return;
        }
        if (t === 'response.output_audio.started' || t === 'response.audio.started') {
            V.speaking = true;
            setCallStatusUi('speaking');
            return;
        }
        if (t === 'response.output_audio.delta' || t === 'response.audio.delta') {
            var a = m.delta || m.audio || '';
            if (a) { V.gotAudio = true; playPcm(a); }
            return;
        }
        if (t === 'response.output_audio.done' || t === 'response.audio.done') {
            return;
        }
        if (t === 'response.done') {
            V.speaking = false;
            // 优先实际播报的语音字幕；语音字幕为空时才回退文本流。
            var spoken = String(V.audioFinal || V.audioText || '').trim();
            if (!spoken) spoken = String(V.textFinal || V.curText || '').trim();
            if (!spoken && V.liveAiTurn) spoken = String(V.liveAiTurn.text || '').trim();
            if (spoken) {
                if (V.liveAiTurn) finalizeLiveTurn('liveAiTurn', spoken);
                else addTurn('assistant', spoken);
            } else {
                closeLiveTurn('liveAiTurn');
            }
            V.audioText = '';
            V.audioFinal = '';
            V.audioTextSeen = false;
            V.textFinal = '';
            V.curText = '';
            setCallStatusUi('listening');
            setCenterStatus('');
            return;
        }
        if (t === 'response.canceled') {
            V.speaking = false;
            // 被打断时保留豆包已经说出口的部分；用户这边的转写仍在继续，
            // 不能在这里提前收口，否则下一段 delta 会新建出第二个用户气泡。
            if (V.liveAiTurn) {
                closeLiveTurn('liveAiTurn', V.liveAiTurn.text);
            }
            V.curText = '';
            V.audioText = '';
            V.audioFinal = '';
            V.audioTextSeen = false;
            V.textFinal = '';
            stopPlayback();
            setCallStatusUi('listening');
            setCenterStatus('');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.started') {
            // 新一句开始：上一句只撤掉流式光标，保留气泡引用，
            // 迟到的 completed 仍能就地更新上一句，而不是在末尾再追加一条。
            if (V.liveUserTurn) {
                V.liveUserTurn.live = false;
                renderSubs();
            }
            V.curUserText = '';
            V.lastUserFinal = '';
            V.lastUserDelta = '';
            V.userDeltaCumulative = false;
            V.userItemId = '';
            V.userStarted = true;
            V.userOpen = false;
            setCenterStatus('');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.delta') {
            // 只使用服务端真正的转写字段；部分实现会发「累计文本」而不是增量，
            // 这里做前缀识别，避免把同一句听写重复拼接成“请问啊？请问一下…”。
            var ud = (typeof m.delta === 'string') ? m.delta : '';
            if (ud) {
                V.lastUserDelta = ud;
                if (!V.curUserText) {
                    V.curUserText = ud;
                } else {
                    var kPrev = transcriptKey(V.curUserText);
                    var kNew = transcriptKey(ud);
                    if (kNew && kPrev && kNew.indexOf(kPrev) >= 0) {
                        // 服务端下发的是“累计全文”，不是增量：直接替换。
                        V.curUserText = ud;
                        V.userDeltaCumulative = true;
                    } else if (kNew !== kPrev) {
                        V.curUserText += ud;
                    }
                }
                // 用户还在说话时就把识别结果放进字幕气泡，和豆包语音通话一致。
                showLiveUser(V.curUserText, m.item_id || m.itemId || '');
            }
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.completed') {
            // 最终字幕必须使用服务端原样返回的 transcript；
            // 不能退到 m.text（那可能是别的字段/模型文本），否则会出现
            // “显示的字和用户说的不一致”。仅在 transcript 缺失时用本地增量兜底。
            var ut;
            if (typeof m.transcript === 'string' && m.transcript.trim()) {
                ut = m.transcript;
                // 完成事件是服务端最终、修正后的整句；中途 delta 只是临时
                // 识别结果，绝不能用它反向覆盖最终 transcript，否则就会出现
                // “显示的字和用户实际说的不一致”。
            } else {
                // 累计式转写时，最后一个 delta 才是完整原句；增量式才用拼接结果。
                ut = V.userDeltaCumulative ? V.lastUserDelta : V.curUserText;
            }
            V.curUserText = '';
            ut = String(ut || '').replace(/\r/g, '').trim();
            if (ut) {
                var kFinal = transcriptKey(ut);
                var kLast = transcriptKey(V.lastUserFinal);
                var iid = m.item_id || m.itemId || '';
                var target = iid ? findUserTurnByItem(iid) : null;
                if (!target) target = V.liveUserTurn;
                if (target) {
                    // 就地把同一句的流式气泡替换成最终 transcript。
                    // 即使 completed 比 response.created / response.done 晚到，
                    // 也只更新原来那一条，绝不能在豆包回答后再追加一条。
                    target.text = ut.length > 2000 ? ut.slice(0, 2000) : ut;
                    target.at = Date.now();
                    target.live = false;
                    if (iid) target.itemId = iid;
                    renderSubs();
                } else {
                    var prevUser = lastUserTurn();
                    if (kLast && kFinal && kFinal.indexOf(kLast) >= 0 && prevUser) {
                        // 同一句话的多个 completed 事件兜底：更新最后一条用户气泡。
                        prevUser.text = ut.length > 2000 ? ut.slice(0, 2000) : ut;
                        prevUser.at = Date.now();
                        prevUser.live = false;
                        renderSubs();
                    } else {
                        addTurn('user', ut);
                    }
                }
                V.lastUserFinal = ut;
            }
            V.userStarted = false;
            V.userOpen = false;
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.failed') {
            if (V.liveUserTurn) {
                V.liveUserTurn.live = false;
                renderSubs();
            }
            V.userStarted = false;
            V.userOpen = false;
            setCenterStatus('');
            return;
        }
        if (t === 'error') {
            var msg = m.message || (m.error && (m.error.message || m.error)) || tr('network');
            vcToast(msg, 'error');
            return;
        }
    }

    function setCenterStatus(txt) {
        var el = $('dscVcCenterStatus');
        if (!el) return;
        el.textContent = txt || '';
        el.classList.toggle('show', !!txt && !V.speaking);
    }

    function setCallStatusUi(state) {
        var el = $('dscVcCenterStatus');
        if (!el) return;
        if (state === 'speaking') {
            el.classList.add('show');
            el.textContent = tr('speaking');
        } else if (state === 'listening') {
            el.classList.remove('show');
            el.textContent = '';
        }
    }

    // 语音转写归一化：去掉空格/标点后再比较，用来识别「累计式转写」。
    // 只用于显示去重，不改动任何音频或计费逻辑。
    function transcriptKey(s) {
        return String(s || '').toLowerCase()
            .replace(/[\s，,。.？?！!、；;：:…·\-—~～'"“”‘’（）()\[\]【】]/g, '');
    }

    // 合并流式转写：服务端可能发增量，也可能发累计全文；两种都兼容。
    function mergeTranscript(prev, incoming) {
        prev = String(prev || '').replace(/\r/g, '');
        incoming = String(incoming || '').replace(/\r/g, '');
        if (!incoming) return prev;
        if (!prev) return incoming;
        var a = transcriptKey(prev);
        var b = transcriptKey(incoming);
        if (b && a && b.indexOf(a) >= 0) return incoming; // 累计全文
        if (b && a && b === a) return incoming.length > prev.length ? incoming : prev;
        return prev + incoming;
    }

    function scheduleRenderSubs() {
        if (V.subsTimer) return;
        V.subsTimer = setTimeout(function () {
            V.subsTimer = null;
            renderSubs();
        }, 36);
    }

    function ensureLiveTurn(role, itemId) {
        var key = role === 'user' ? 'liveUserTurn' : 'liveAiTurn';
        var t = V[key];
        if (t && V.turns.indexOf(t) >= 0) return t;
        t = {
            at: Date.now(),
            role: role === 'user' ? 'user' : 'assistant',
            text: '',
            seq: ++V.seq,
            lang: curLang(),
            itemId: itemId || '',
            live: true
        };
        V.turns.push(t);
        V[key] = t;
        return t;
    }

    function findUserTurnByItem(itemId) {
        if (!itemId) return null;
        for (var i = V.turns.length - 1; i >= 0; i--) {
            var t = V.turns[i];
            if (t.role === 'user' && t.itemId === itemId) return t;
        }
        return null;
    }

    function lastUserTurn() {
        for (var i = V.turns.length - 1; i >= 0; i--) {
            if (V.turns[i].role === 'user') return V.turns[i];
        }
        return null;
    }

    function applyLiveText(t, text) {
        text = String(text || '').replace(/\r/g, '').trim();
        if (!t || !text) return;
        t.text = text.length > 2000 ? text.slice(0, 2000) : text;
        t.live = true;
        scheduleRenderSubs();
    }

    function showLiveUser(text, itemId) {
        var cur = V.liveUserTurn;
        var forceNew = false;
        if (cur) {
            if (itemId && cur.itemId && cur.itemId !== itemId) forceNew = true;
            if (V.userStarted) forceNew = true;
            else if (!V.userOpen && !cur.live) {
                // 没有 started 事件时，用文本包含关系兜底区分“新一句”和
                // “同一句迟到的累计 delta”。
                var a = transcriptKey(cur.text);
                var b = transcriptKey(text);
                if (a && b && !(b.indexOf(a) >= 0 || a.indexOf(b) >= 0)) forceNew = true;
            }
            if (forceNew) {
                cur.live = false;
                V.liveUserTurn = null;
            }
        }
        V.userStarted = false;
        V.userOpen = true;
        if (itemId) V.userItemId = itemId;
        var t = ensureLiveTurn('user', itemId || V.userItemId);
        applyLiveText(t, text);
    }

    function showLiveAssistant(text) {
        var t = ensureLiveTurn('assistant');
        applyLiveText(t, text);
    }

    function finalizeLiveTurn(key, text) {
        var t = V[key];
        if (!t) {
            if (text) addTurn(key === 'liveUserTurn' ? 'user' : 'assistant', text);
            return;
        }
        if (text) {
            text = String(text || '').replace(/\r/g, '').trim();
            if (text) t.text = text.length > 2000 ? text.slice(0, 2000) : text;
        }
        t.live = false;
        V[key] = null;
        if (t.role === 'assistant') V.lastAssistantText = t.text;
        if (!String(t.text || '').trim()) {
            var i = V.turns.indexOf(t);
            if (i >= 0) V.turns.splice(i, 1);
        }
        renderSubs();
    }

    function closeLiveTurn(key, text) {
        var t = V[key];
        if (!t) return;
        if (text) {
            text = String(text || '').replace(/\r/g, '').trim();
            if (text) t.text = text.length > 2000 ? text.slice(0, 2000) : text;
        }
        t.live = false;
        V[key] = null;
        if (t.role === 'assistant' && t.text) V.lastAssistantText = t.text;
        if (t.role === 'user' && t.text) V.lastUserFinal = t.text;
        if (!String(t.text || '').trim()) {
            var i = V.turns.indexOf(t);
            if (i >= 0) V.turns.splice(i, 1);
        }
        renderSubs();
    }

    function flushLiveTurns() {
        closeLiveTurn('liveUserTurn');
        closeLiveTurn('liveAiTurn');
        if (V.subsTimer) { clearTimeout(V.subsTimer); V.subsTimer = null; }
    }

    function addTurn(role, text) {
        text = String(text || '').trim();
        if (!text) return;
        if (role === 'assistant' && text === V.lastAssistantText) return;
        var prev = V.turns.length ? V.turns[V.turns.length - 1] : null;
        if (prev && prev.role === (role === 'user' ? 'user' : 'assistant') && prev.text === text) return;
        if (role === 'assistant') V.lastAssistantText = text;
        V.turns.push({
            at: Date.now(),
            role: role === 'user' ? 'user' : 'assistant',
            text: text.length > 2000 ? text.slice(0, 2000) : text,
            seq: ++V.seq,
            lang: curLang()
        });
        renderSubs();
    }

    function renderSubs() {
        var box = $('dscVcSubs');
        if (!box) return;
        var recent = V.turns.slice(-5);
        var rows = box.children;
        var same = rows.length === recent.length;
        if (same) {
            for (var i = 0; i < recent.length; i++) {
                if (rows[i].getAttribute('data-seq') !== String(recent[i].seq)) {
                    same = false;
                    break;
                }
            }
        }
        if (same) {
            // 流式更新时只改文字/class，不重建节点，避免每个 token 触发
            // backdrop-filter 和入场动画，手机上会闪烁、掉帧。
            recent.forEach(function (t, i) {
                var row = rows[i];
                var cls = 'dsc-vc-sub ' + (t.role === 'user' ? 'me' : 'ai') + (t.live ? ' live' : '');
                if (row.className !== cls) row.className = cls;
                var who = row.querySelector('.who');
                var whoText = t.role === 'user' ? (V.userName || tr('you')) : tr('doubao');
                if (who && who.textContent !== whoText) who.textContent = whoText;
                var txt = row.querySelector('.txt');
                var shown = t.text.length > 180 ? t.text.slice(-180) : t.text;
                if (txt && txt.textContent !== shown) txt.textContent = shown;
            });
        } else {
            box.innerHTML = '';
            recent.forEach(function (t) {
                var row = document.createElement('div');
                row.className = 'dsc-vc-sub ' + (t.role === 'user' ? 'me' : 'ai') + (t.live ? ' live' : '');
                row.setAttribute('data-seq', String(t.seq));
                var who = document.createElement('span');
                who.className = 'who';
                who.textContent = t.role === 'user' ? (V.userName || tr('you')) : tr('doubao');
                var txt = document.createElement('span');
                txt.className = 'txt';
                txt.textContent = t.text.length > 180 ? t.text.slice(-180) : t.text;
                row.appendChild(who);
                row.appendChild(txt);
                box.appendChild(row);
            });
        }
        var hasLive = false;
        for (var j = 0; j < recent.length; j++) if (recent[j].live) { hasLive = true; break; }
        box.classList.toggle('has-live', hasLive);
        box.scrollTop = box.scrollHeight;
    }

    // ------------------------------------------------------------
    // 通话控制
    // ------------------------------------------------------------
    function setMic(on) {
        V.micOn = !!on;
        sendWs({
            type: on ? 'input_audio_unmute.commit' : 'input_audio_mute.commit',
            event_id: newId()
        });
        try {
            if (V.micStream) V.micStream.getAudioTracks().forEach(function (t) { t.enabled = V.micOn; });
        } catch (e) {}
        updateMicUi();
        if (!on) setCenterStatus(tr('muted'));
        else setCenterStatus('');
    }

    function updateMicUi() {
        var b = $('dscVcMuteBtn');
        if (!b) return;
        b.classList.toggle('off', !V.micOn);
        var lbl = b.querySelector('.lbl');
        if (lbl) lbl.textContent = V.micOn ? tr('mic') : tr('unmute');
        var ico = b.querySelector('.ico');
        if (ico) ico.textContent = V.micOn ? '🎙️' : '🔇';
    }

    function interrupt() {
        if (!V.active) return;
        V.speaking = false;
        V.curText = '';
        stopPlayback();
        V.pend = [];
        V.skipFrames = 10;
        sendWs({ type: 'response.cancel', event_id: newId() });
        setCallStatusUi('listening');
        setCenterStatus('');
    }

    function toggleKeyboard() {
        var p = $('dscVcTextPanel');
        if (!p) return;
        var open = p.classList.toggle('show');
        var ov = $('dscVideoCallOverlay');
        if (ov) ov.classList.toggle('kb', open);
        if (open) {
            adjustViewport();
            setTimeout(function () { $('dscVcTextInput').focus(); }, 80);
        } else {
            $('dscVcTextInput').blur();
            adjustViewport();
        }
    }

    function startTimer() {
        if (V.timer) clearInterval(V.timer);
        updateMeter();
        V.timer = setInterval(updateMeter, 1000);
    }

    function updateMeter() {
        if (!V.startedAt) return;
        var sec = Math.max(0, Math.floor((Date.now() - V.startedAt) / 1000));
        V.durationSec = sec;
        V.costFen = Math.round(sec * RATE_VIDEO * 100 / 60);
        var tm = $('dscVcTime');
        var cm = $('dscVcCost');
        if (tm) tm.textContent = fmtDuration(sec);
        if (cm) cm.textContent = '¥' + (V.costFen / 100).toFixed(2);
    }

    function fmtDuration(sec) {
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        function p(n) { return n < 10 ? '0' + n : '' + n; }
        return (h > 0 ? p(h) + ':' : '') + p(m) + ':' + p(s);
    }

    // ------------------------------------------------------------
    // 文字输入：直接注入实时会话（input_text），由实时音视频模型生成语音回答。
    // 不再回退到普通文本模型 / 独立 TTS：这样只消耗实时音视频分钟额度，
    // 不消耗文本 token 额度，也不消耗语音通话 token 额度。
    // ------------------------------------------------------------
    function sendTyped() {
        var input = $('dscVcTextInput');
        if (!input) return;
        var text = String(input.value || '').trim();
        if (!text) return;
        input.value = '';
        addTurn('user', text);
        V.responseSeen = false;
        V.curText = '';
        V.textToken++;
        var token = V.textToken;

        // 火山实时音视频标准协议：conversation.item.create 使用单数 item，
        // content.type = input_text 表示“文本提问”，服务端会按语音对话回答。
        // interrupt_mode=1：用户打字发送时立即打断当前播报并处理新问题。
        sendWs({
            type: 'conversation.item.create',
            event_id: newId(),
            item: {
                type: 'message',
                role: 'user',
                content: [{ type: 'input_text', text: text }],
                interrupt_mode: 1
            }
        });

        // server_vad 模式通常会自动创建 response；若服务端没有自动触发，
        // 短暂等待后显式 response.create，仍走同一条实时音视频链路。
        if (V.nativeTimer) clearTimeout(V.nativeTimer);
        V.nativeTimer = setTimeout(function () {
            V.nativeTimer = null;
            if (token !== V.textToken || V.responseSeen || !V.active) return;
            sendWs({ type: 'response.create', event_id: newId() });
        }, 650);
        setCenterStatus('');
    }

    // ------------------------------------------------------------
    // 结束 / 保存
    // ------------------------------------------------------------
    async function finishCall(reason, message) {
        if (V.finished) return;
        V.finished = true;
        if (V.connectTimer) { clearTimeout(V.connectTimer); V.connectTimer = null; }
        V.active = false;
        V.connecting = false;
        if (V.timer) { clearInterval(V.timer); V.timer = null; }
        updateMeter();

        try {
            if (V.ws && V.ws.readyState === 1) {
                sendWs({ type: 'session.close', event_id: newId() });
            }
        } catch (e) {}
        try { if (V.ws) V.ws.close(1000, 'client close'); } catch (e) {}
        V.ws = null;
        stopPlayback();
        cleanupAudio();
        stopCamera();
        if (V.nativeTimer) { clearTimeout(V.nativeTimer); V.nativeTimer = null; }
        V.textToken++;
        // 挂断时收口最后一个流式气泡，避免空行写入通话记录。
        flushLiveTurns();

        var payload = buildSavePayload();
        if (payload) {
            try { await savePayload(payload); } catch (e) { vcToast(tr('saveFail', e && e.message ? e.message : e), 'error'); }
        }
        closeOverlay();
        if (message) vcToast(message, reason === 'remote' || reason === 'server' ? 'error' : 'info');
        resetStateForCall();
    }

    function buildSavePayload() {
        if (!V.turns.length) return null;
        var lines = V.turns.map(function (t) {
            var text = String(t.text || '').replace(/\|/g, '｜').replace(/\r?\n/g, ' ').trim();
            return [t.at, t.role, text, t.seq, t.lang || curLang()].join('|') + '|';
        });
        return {
            lines: lines,
            durationSec: Math.max(1, V.durationSec),
            costFen: V.costFen,
            mode: 'video',
            voice: V.voice
        };
    }

    function savePayload(payload) {
        if (V.savePromise) return V.savePromise;
        V.savePromise = fetch('/api/doubao/realtime-video/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            credentials: 'same-origin',
            body: JSON.stringify(payload)
        }).then(function (r) {
            return r.json().then(function (d) {
                if (!r.ok || !d || !d.ok) throw new Error((d && (d.error || d.message)) || ('HTTP ' + r.status));
                return d;
            });
        }).then(function (d) {
            V.savePromise = null;
            vcToast(tr('saved'), 'success');
            return d;
        }).catch(function (e) {
            V.savePromise = null;
            throw e;
        });
        return V.savePromise;
    }

    function saveBeacon() {
        var payload = buildSavePayload();
        if (!payload) return;
        try {
            var blob = new Blob([JSON.stringify(payload)], { type: 'application/json' });
            navigator.sendBeacon('/api/doubao/realtime-video/save', blob);
        } catch (e) {}
    }

    // ------------------------------------------------------------
    // 历史记录（只读 + 单删/批量删/清空）
    // ------------------------------------------------------------
    function openHistory() {
        V.histDetail = null;
        V.histSelected = {};
        V.histOpen = true;
        var sheet = $('dscVcHistSheet');
        if (sheet) sheet.classList.add('show');
        loadHistory();
    }

    function closeHistory() {
        V.histOpen = false;
        var sheet = $('dscVcHistSheet');
        if (sheet) sheet.classList.remove('show');
    }

    function loadHistory() {
        var list = $('dscVcHistList');
        if (list) list.innerHTML = '<div class="dsc-vc-histempty">' + tr('loading') + '</div>';
        fetch('/api/doubao/realtime-video/list', { credentials: 'same-origin', cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                V.histRecords = (d && d.records) || [];
                V.histSelected = {};
                renderHistory();
            })
            .catch(function (e) {
                if (list) list.innerHTML = '<div class="dsc-vc-histempty">' + tr('network') + '</div>';
            });
    }

    function renderHistory() {
        var list = $('dscVcHistList');
        if (!list) return;
        list.innerHTML = '';
        var title = $('dscVcHistTitle');
        if (title) title.textContent = V.histDetail ? tr('detail') : tr('history');
        var sub = $('dscVcHistSub');
        if (sub) sub.textContent = V.histDetail ? tr('readonly') : tr('historySub');
        var bar = $('dscVcHistBar');
        if (bar) bar.style.display = V.histDetail ? 'none' : '';
        var foot = $('dscVcHistCount');
        if (foot) foot.textContent = V.histDetail ? '' : (V.histRecords.length + ' · ' + tr('selected', Object.keys(V.histSelected).length));

        if (V.histDetail) {
            renderDetail(list, V.histDetail);
            return;
        }
        if (!V.histRecords.length) {
            var empty = document.createElement('div');
            empty.className = 'dsc-vc-histempty';
            empty.textContent = tr('noHistory');
            list.appendChild(empty);
            return;
        }
        V.histRecords.forEach(function (r) {
            var row = document.createElement('div');
            row.className = 'dsc-vc-histrow';
            var cb = document.createElement('input');
            cb.type = 'checkbox';
            cb.checked = !!V.histSelected[r.name];
            cb.addEventListener('change', function () {
                if (cb.checked) V.histSelected[r.name] = true;
                else delete V.histSelected[r.name];
                if (foot) foot.textContent = V.histRecords.length + ' · ' + tr('selected', Object.keys(V.histSelected).length);
            });
            var main = document.createElement('button');
            main.type = 'button';
            main.className = 'dsc-vc-histmain';
            var pv = document.createElement('div');
            pv.className = 'pv';
            pv.textContent = r.preview || tr('noRecords');
            var meta = document.createElement('div');
            meta.className = 'meta';
            var date = r.mtime ? new Date(r.mtime).toLocaleString() : '';
            meta.textContent = date + ' · ' + fmtDuration(r.durationSec || 0) +
                ' · ¥' + ((r.costFen || 0) / 100).toFixed(2) + ' · ' + (r.lineCount || 0);
            main.appendChild(pv);
            main.appendChild(meta);
            main.addEventListener('click', function () {
                V.histDetail = r;
                renderHistory();
            });
            var del = document.createElement('button');
            del.type = 'button';
            del.className = 'dsc-vc-histdel';
            del.textContent = tr('delete');
            del.addEventListener('click', function (e) {
                e.stopPropagation();
                deleteOne(r.name);
            });
            row.appendChild(cb);
            row.appendChild(main);
            row.appendChild(del);
            list.appendChild(row);
        });
    }

    function renderDetail(list, r) {
        var wrap = document.createElement('div');
        wrap.className = 'dsc-vc-histdetail';
        var back = document.createElement('button');
        back.type = 'button';
        back.className = 'dsc-vc-detailback';
        back.textContent = '‹ ' + tr('back');
        back.addEventListener('click', function () {
            V.histDetail = null;
            renderHistory();
        });
        wrap.appendChild(back);
        var meta = document.createElement('div');
        meta.className = 'dsc-vc-detailmeta';
        meta.textContent = (r.mtime ? new Date(r.mtime).toLocaleString() : '') +
            ' · ' + fmtDuration(r.durationSec || 0) + ' · ¥' + ((r.costFen || 0) / 100).toFixed(2);
        wrap.appendChild(meta);
        var turns = r.turns || [];
        if (!turns.length) {
            var empty = document.createElement('div');
            empty.className = 'dsc-vc-histempty';
            empty.textContent = tr('noRecords');
            wrap.appendChild(empty);
        }
        turns.forEach(function (t) {
            var line = document.createElement('div');
            line.className = 'dsc-vc-detailline ' + (t.role === 'user' ? 'me' : 'ai');
            var who = document.createElement('span');
            who.className = 'who';
            who.textContent = t.role === 'user' ? (V.userName || tr('you')) : tr('doubao');
            var tx = document.createElement('span');
            tx.className = 'txt';
            tx.textContent = t.text || '';
            line.appendChild(who);
            line.appendChild(tx);
            wrap.appendChild(line);
        });
        list.appendChild(wrap);
    }

    function deleteOne(name) {
        if (!name) return;
        if (!window.confirm(tr('confirmDelete', 1))) return;
        fetch('/api/doubao/realtime-video/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            credentials: 'same-origin',
            body: JSON.stringify({ names: [name] })
        }).then(function (r) { return r.json(); }).then(function (d) {
            vcToast(tr('deleted', (d && d.removed) || 0), 'success');
            loadHistory();
        }).catch(function () { vcToast(tr('network'), 'error'); });
    }

    function deleteSelected() {
        var names = Object.keys(V.histSelected);
        if (!names.length) return;
        if (!window.confirm(tr('confirmDelete', names.length))) return;
        fetch('/api/doubao/realtime-video/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            credentials: 'same-origin',
            body: JSON.stringify({ names: names })
        }).then(function (r) { return r.json(); }).then(function (d) {
            vcToast(tr('deleted', (d && d.removed) || 0), 'success');
            loadHistory();
        }).catch(function (e) { vcToast(tr('network'), 'error'); });
    }

    function clearAllHistory() {
        if (!V.histRecords.length) return;
        if (!window.confirm(tr('confirmClear'))) return;
        fetch('/api/doubao/realtime-video/clear', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            credentials: 'same-origin',
            body: '{}'
        }).then(function (r) { return r.json(); }).then(function (d) {
            vcToast(tr('cleared', (d && d.removed) || 0), 'success');
            V.histSelected = {};
            loadHistory();
        }).catch(function (e) { vcToast(tr('network'), 'error'); });
    }

    function selectAllHistory() {
        var all = Object.keys(V.histSelected).length !== V.histRecords.length;
        V.histSelected = {};
        if (all) V.histRecords.forEach(function (r) { V.histSelected[r.name] = true; });
        renderHistory();
    }

    // ------------------------------------------------------------
    // Toast / 视口 / 事件
    // ------------------------------------------------------------
    function vcToast(msg, type) {
        var el = $('dscVcToast');
        if (!el) {
            el = document.createElement('div');
            el.id = 'dscVcToast';
            el.className = 'dsc-vc-toast';
            document.body.appendChild(el);
        }
        el.textContent = msg;
        el.className = 'dsc-vc-toast show ' + (type || 'info');
        clearTimeout(el._t);
        el._t = setTimeout(function () { el.className = 'dsc-vc-toast'; }, 2600);
    }

    function adjustViewport() {
        var ov = $('dscVideoCallOverlay');
        if (!ov) return;
        var vv = window.visualViewport;
        if (vv && V.open) {
            ov.style.height = vv.height + 'px';
            ov.style.top = vv.offsetTop + 'px';
        } else {
            ov.style.height = '';
            ov.style.top = '';
        }
    }

    function bindViewport() {
        if (!window.visualViewport) return;
        window.visualViewport.addEventListener('resize', adjustViewport);
        window.visualViewport.addEventListener('scroll', adjustViewport);
        adjustViewport();
    }

    function unbindViewport() {
        if (!window.visualViewport) return;
        window.visualViewport.removeEventListener('resize', adjustViewport);
        window.visualViewport.removeEventListener('scroll', adjustViewport);
        var ov = $('dscVideoCallOverlay');
        if (ov) { ov.style.height = ''; ov.style.top = ''; }
    }

    function bindUi() {
        $('dscVcStartBtn').addEventListener('click', startCall);
        $('dscVcCloseBtn').addEventListener('click', function () {
            if (V.active) finishCall('user', '');
            else closeOverlay();
        });
        $('dscVcBack').addEventListener('click', function () {
            if (V.active) finishCall('user', '');
            else closeOverlay();
        });
        $('dscVcHangBtn').addEventListener('click', function () {
            if (V.active || V.connecting) finishCall('user', '');
            else closeOverlay();
        });
        $('dscVcCamBtn').addEventListener('click', toggleCamera);
        $('dscVcSwitchBtn').addEventListener('click', switchCamera);
        $('dscVcSwitchTop').addEventListener('click', switchCamera);
        $('dscVcMuteBtn').addEventListener('click', function () { setMic(!V.micOn); });
        $('dscVcIntBtn').addEventListener('click', interrupt);
        $('dscVcKbBtn').addEventListener('click', toggleKeyboard);
        $('dscVcTextSend').addEventListener('click', sendTyped);
        $('dscVcTextInput').addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); sendTyped(); }
        });
        $('dscVcHistBtn').addEventListener('click', openHistory);
        $('dscVcHistIcon').addEventListener('click', openHistory);
        $('dscVcHistClose').addEventListener('click', closeHistory);
        $('dscVcHistSheet').addEventListener('click', function (e) {
            if (e.target === $('dscVcHistSheet')) closeHistory();
        });
        $('dscVcSelAll').addEventListener('click', selectAllHistory);
        $('dscVcDelSel').addEventListener('click', deleteSelected);
        $('dscVcClearAll').addEventListener('click', clearAllHistory);

        document.addEventListener('dsc:langchange', function () {
            applyLang();
            if (V.histOpen) renderHistory();
        });

        document.addEventListener('visibilitychange', function () {
            if (!V.open || !V.camOn) return;
            if (document.hidden) {
                if (V.camTimer) { clearInterval(V.camTimer); V.camTimer = null; }
            } else {
                var tracks = V.camStream ? V.camStream.getVideoTracks() : [];
                var alive = tracks.length > 0 && tracks.every(function (t) { return t.readyState === 'live'; });
                if (!alive) {
                    // 部分手机切后台会直接回收摄像头轨，必须重新取流，不能只重挂旧 srcObject。
                    tryCamera(V.camFacing || 'user', true);
                    return;
                }
                var v = $('dscVcVideo');
                if (v && V.camStream) {
                    v.srcObject = V.camStream;
                    try { v.play(); } catch (e) {}
                }
                if (V.active && !V.camTimer) startFrameTimer();
            }
        });

        if (!V.pageHideBound) {
            V.pageHideBound = true;
            window.addEventListener('pagehide', function () {
                if (V.active) saveBeacon();
            });
        }
    }

    window.dscVideoCall = {
        open: open,
        close: function () {
            if (V.active || V.connecting) finishCall('user', '');
            else closeOverlay();
        },
        isActive: function () { return V.active; }
    };
})();
