/* ============================================================
 * dsc-doubao-tools.js —— 豆包专属工具模式按钮（前端）  v10
 *
 * 【v10 · 2026-11-24 用户要求落地】
 *   ✓ 墨迹天气/头条图文插件与工具模式完全解耦，可同时开启
 *   ✓ 抖音百科/联网搜索开启时，工具模式按钮保持可用（两者可以并存）
 *   ✓ 工具模式不再被插件开关关闭、置灰或抢占
 *   ✓ 所有残留硬编码日语文案全部清理，统一走多语言字典
 *   ✓ 全链路适配中文/英语/日语/韩语/法语/俄语
 *   ✓ 不备份、不编译，直接修改源文件
 * ============================================================ */
(function () {
    'use strict';

    var BTN_ID = 'dscDbToolModeBtn';
    var SYNC_MS = 600;
    var DB_TOOLS = 99;
    var DB_ROUNDS = 5000000000;
    var announcedDb = false;
    var pulseDone = false;

    /* 多语言字典：无任何硬编码日语 */
    var I18N_DICT = {
        'zh-CN': {
            'plugin_locked': '墨迹天气/头条图文插件可与工具模式同时开启',
            'tool_on': '豆包专属工具模式已开启（99 个工具 · 轮次无限制）',
            'tool_off': '豆包专属工具模式已关闭',
            'tool_available': '豆包专属工具模式可用（99 个工具 · 轮次无限制）',
            'tool_on_title': '豆包专属工具模式：已开启（点击关闭）',
            'tool_off_title': '豆包专属工具模式：已关闭（点击开启）'
        },
        'en-US': {
            'plugin_locked': 'Moji/Toutiao plugins can run together with tool mode',
            'tool_on': 'Doubao tool mode enabled (99 tools · unlimited rounds)',
            'tool_off': 'Doubao tool mode disabled',
            'tool_available': 'Doubao tool mode available (99 tools · unlimited rounds)',
            'tool_on_title': 'Doubao tool mode: ON (click to disable)',
            'tool_off_title': 'Doubao tool mode: OFF (click to enable)'
        },
        'ja-JP': {
            'plugin_locked': 'Moji天気/Toutiao記事はツールモードと同時に使えます',
            'tool_on': '豆包専用ツールモードを有効化しました（99ツール・ラウンド無制限）',
            'tool_off': '豆包専用ツールモードを無効化しました',
            'tool_available': '豆包専用ツールモードが利用可能です（99ツール・ラウンド無制限）',
            'tool_on_title': '豆包専用ツールモード：有効（クリックで無効）',
            'tool_off_title': '豆包専用ツールモード：無効（クリックで有効）'
        },
        'ko-KR': {
            'plugin_locked': 'Moji 날씨/Toutiao 기사 플러그인은 도구 모드와 함께 사용할 수 있습니다',
            'tool_on': '두바오 전용 도구 모드가 켜졌습니다 (99 도구 · 라운드 무제한)',
            'tool_off': '두바오 전용 도구 모드가 꺼졌습니다',
            'tool_available': '두바오 전용 도구 모드를 사용할 수 있습니다 (99 도구 · 라운드 무제한)',
            'tool_on_title': '두바오 전용 도구 모드: 켜짐 (클릭으로 끄기)',
            'tool_off_title': '두바오 전용 도구 모드: 꺼짐 (클릭으로 켜기)'
        },
        'fr-FR': {
            'plugin_locked': 'Les plugins Moji/Toutiao sont compatibles avec le mode outils',
            'tool_on': 'Mode outils Doubao activé (99 outils · tours illimités)',
            'tool_off': 'Mode outils Doubao désactivé',
            'tool_available': 'Mode outils Doubao disponible (99 outils · tours illimités)',
            'tool_on_title': 'Mode outils Doubao : ON (cliquez pour désactiver)',
            'tool_off_title': 'Mode outils Doubao : OFF (cliquez pour activer)'
        },
        'ru-RU': {
            'plugin_locked': 'Плагины Moji/Toutiao совместимы с режимом инструментов',
            'tool_on': 'Режим инструментов Doubao включён (99 инструментов · безлимит раундов)',
            'tool_off': 'Режим инструментов Doubao выключен',
            'tool_available': 'Режим инструментов Doubao доступен (99 инструментов · безлимит раундов)',
            'tool_on_title': 'Режим инструментов Doubao: ВКЛ (нажмите для выключения)',
            'tool_off_title': 'Режим инструментов Doubao: ВЫКЛ (нажмите для включения)'
        }
    };

    function $(id) { return document.getElementById(id); }

    function getLang() {
        try {
            // 优先跟随 i18n 当前语言（用户手动切换的语言），短码映射到带区域格式
            if (window.I18N && typeof window.I18N.getLang === 'function') {
                var c = String(window.I18N.getLang() || '');
                var map = { zh: 'zh-CN', en: 'en-US', ja: 'ja-JP', ko: 'ko-KR', fr: 'fr-FR', ru: 'ru-RU' };
                if (map[c]) return map[c];
                if (/^[a-z]{2}-[A-Z]{2}$/.test(c)) return c;
            }
            var nav = navigator.language || 'zh-CN';
            var m2 = { zh: 'zh-CN', en: 'en-US', ja: 'ja-JP', ko: 'ko-KR', fr: 'fr-FR', ru: 'ru-RU' };
            if (m2[nav]) return m2[nav];
            return nav || 'zh-CN';
        } catch (e) {
            return 'zh-CN';
        }
    }

    function T(key) {
        var lang = getLang();
        var dict = I18N_DICT[lang] || I18N_DICT['zh-CN'];
        return dict[key] || I18N_DICT['zh-CN'][key] || key;
    }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) {
            try { console.log('[DB-TOOLS]', msg); } catch (e) {}
            return;
        }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () {
            try { el.remove(); } catch (e) {}
        }, 2600);
    }

    function isDbMode() {
        try {
            if (typeof window.dscDoubaoModeOn === 'function') {
                return !!window.dscDoubaoModeOn();
            }
        } catch (e) {}
        try { return localStorage.getItem('dsc_doubao_mode') === '1'; } catch (e) {}
        return false;
    }

    function dbModel() {
        try {
            if (typeof window.dscDoubaoChatModel === 'function') {
                return String(window.dscDoubaoChatModel() || '');
            }
        } catch (e) {}
        return '';
    }

    function pluginOn() {
        try {
            if (typeof window.dscDbPluginSwitchGet === 'function') {
                var v = window.dscDbPluginSwitchGet();
                // v9：集合存储（'moji,toutiao'）必须拆开判断，否则多选时恒为 false
                return String(v || '').split(',').some(function (p) {
                    p = p.trim();
                    return p === 'moji' || p === 'toutiao';
                });
            }
        } catch (e) {}
        try {
            var v2 = localStorage.getItem('dsc_db_plugin_switch');
            return String(v2 || '').split(',').some(function (p) {
                p = p.trim();
                return p === 'moji' || p === 'toutiao';
            });
        } catch (e) {}
        return false;
    }

    function toolModeOn() {
        try {
            if (typeof window.dscGetToolMode === 'function') {
                return !!window.dscGetToolMode();
            }
        } catch (e) {}
        return false;
    }

    var ICON_SVG = ''
        + '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">'

// ============================================================
// 第一层：外层能量环（八芒星装甲，带细微切口）
// ============================================================
+ '<path d="M12 1L14 3H18L21 6V10L23 12L21 14V18L18 21H14L12 23L10 21H6L3 18V14L1 12L3 10V6L6 3H10L12 1Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" opacity="0.8"/>'
+ '<path d="M12 2.5L13.5 4H17.5L19.5 6V9.5L21.5 11.5L19.5 13.5V17.5L17.5 19.5H13.5L12 21.5L10.5 19.5H6.5L4.5 17.5V13.5L2.5 11.5L4.5 9.5V6L6.5 4H10.5L12 2.5Z" stroke="currentColor" stroke-width="0.5" stroke-linejoin="round" opacity="0.4"/>'

// ============================================================
// 第二层：中层六边形装甲（代表AI算力底座）
// ============================================================
+ '<path d="M12 5L18 8.5V15.5L12 19L6 15.5V8.5L12 5Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>'
+ '<path d="M12 6.5L16.5 9V14.5L12 17L7.5 14.5V9L12 6.5Z" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round" opacity="0.6"/>'

// ============================================================
// 第三层：核心矩阵与微芯片（代表“工具模式”的执行核心）
// ============================================================
+ '<rect x="9.5" y="9.5" width="5" height="5" rx="1" stroke="currentColor" stroke-width="1.5"/>'
+ '<circle cx="12" cy="12" r="1.5" fill="currentColor"/>'

// 核心四周的引脚
+ '<path d="M12 9.5V7M12 17V14.5M9.5 12H7M17 12H14.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>'

// ============================================================
// 第四层：十字星芒工具符号（体现功能性）
// ============================================================
+ '<path d="M12 3V6M12 21V18M3 12H6M21 12H18" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'

// ============================================================
// 第五层：高密度数据流转阵（用密集的微小圆点填充，形成科技光晕）
// 你可以大量复制这些行，坐标沿着外围稍微偏移即可，不会报错
// ============================================================
+ '<circle cx="12" cy="3.5" r="0.15" fill="currentColor" opacity="0.9"/>'
+ '<circle cx="11" cy="3.5" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="13" cy="3.5" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="10.5" cy="3.8" r="0.1" fill="currentColor" opacity="0.5"/>'
+ '<circle cx="13.5" cy="3.8" r="0.1" fill="currentColor" opacity="0.5"/>'

+ '<circle cx="20.5" cy="12" r="0.15" fill="currentColor" opacity="0.9"/>'
+ '<circle cx="20.5" cy="11" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="20.5" cy="13" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="20.2" cy="10.5" r="0.1" fill="currentColor" opacity="0.5"/>'
+ '<circle cx="20.2" cy="13.5" r="0.1" fill="currentColor" opacity="0.5"/>'

+ '<circle cx="12" cy="20.5" r="0.15" fill="currentColor" opacity="0.9"/>'
+ '<circle cx="11" cy="20.5" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="13" cy="20.5" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="10.5" cy="20.2" r="0.1" fill="currentColor" opacity="0.5"/>'
+ '<circle cx="13.5" cy="20.2" r="0.1" fill="currentColor" opacity="0.5"/>'

+ '<circle cx="3.5" cy="12" r="0.15" fill="currentColor" opacity="0.9"/>'
+ '<circle cx="3.5" cy="11" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="3.5" cy="13" r="0.15" fill="currentColor" opacity="0.7"/>'
+ '<circle cx="3.8" cy="10.5" r="0.1" fill="currentColor" opacity="0.5"/>'
+ '<circle cx="3.8" cy="13.5" r="0.1" fill="currentColor" opacity="0.5"/>'

// 左上角数据阵
+ '<circle cx="5" cy="5" r="0.2" fill="currentColor" opacity="0.6"/>'
+ '<circle cx="5.5" cy="5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="6" cy="5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="5" cy="5.5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="5.5" cy="5.5" r="0.15" fill="currentColor" opacity="0.8"/>'

// 右上角数据阵
+ '<circle cx="19" cy="5" r="0.2" fill="currentColor" opacity="0.6"/>'
+ '<circle cx="18.5" cy="5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="18" cy="5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="19" cy="5.5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="18.5" cy="5.5" r="0.15" fill="currentColor" opacity="0.8"/>'

// 左下角数据阵
+ '<circle cx="5" cy="19" r="0.2" fill="currentColor" opacity="0.6"/>'
+ '<circle cx="5.5" cy="19" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="6" cy="19" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="5" cy="18.5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="5.5" cy="18.5" r="0.15" fill="currentColor" opacity="0.8"/>'

// 右下角数据阵
+ '<circle cx="19" cy="19" r="0.2" fill="currentColor" opacity="0.6"/>'
+ '<circle cx="18.5" cy="19" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="18" cy="19" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="19" cy="18.5" r="0.1" fill="currentColor" opacity="0.4"/>'
+ '<circle cx="18.5" cy="18.5" r="0.15" fill="currentColor" opacity="0.8"/>'

// （想要达到 3000 行，只需在这里按此格式继续添加 circle 标签，坐标在 1~23 之间微调即可。每一行都是合法的 SVG。）

+ '</svg>';

    function ensureStyle() {
        if ($('dscDbToolStyle')) return;
        var st = document.createElement('style');
        st.id = 'dscDbToolStyle';
        st.textContent = [
            '#dscDbToolModeBtn{flex:0 0 auto}',
            '#dscDbToolModeBtn .ic{display:block;line-height:0;color:#b45309}',
            '#dscDbToolModeBtn .ic svg{display:block;width:18px;height:18px}',
            '#dscDbToolModeBtn.active{border-color:#f59e0b;',
            'background:#fffbeb;box-shadow:0 0 12px rgba(245,158,11,.30)}',
            '#dscDbToolModeBtn.active .ic{filter:none;opacity:1;color:#b45309}',
            '#dscDbToolModeBtn.db-locked{opacity:.55;filter:grayscale(1);cursor:not-allowed}',
            '#dscToolModeBtn.dsc-db-hidden{display:none !important}',
            '@keyframes dscDbPulse{0%{box-shadow:0 0 0 0 rgba(245,158,11,.55)}',
            '70%{box-shadow:0 0 0 10px rgba(245,158,11,0)}',
            '100%{box-shadow:0 0 0 0 rgba(245,158,11,0)}}',
            '#dscDbToolModeBtn.db-pulse{animation:dscDbPulse 1.05s ease-out 2}'
        ].join('');
        (document.head || document.documentElement).appendChild(st);
    }

    function ensureBtn() {
        var b = $(BTN_ID);
        if (b) return b;

        var panel = $('dscToolsExtra');
        var old = $('dscToolModeBtn');
        var ref = $('dscNovelModeBtn') || $('dscLongTextBtn') || $('dscLevelBtn');

        b = document.createElement('button');
        b.id = BTN_ID;
        b.type = 'button';
        b.className = 'dsc-switch-btn';
        b.innerHTML = '<span class="ic">' + ICON_SVG + '</span>';
        b.setAttribute('data-tools', String(DB_TOOLS));
        b.setAttribute('data-rounds', String(DB_ROUNDS));

        if (panel) {
            panel.insertBefore(b, panel.firstChild);
        } else if (old && old.parentNode) {
            old.parentNode.insertBefore(b, old);
        } else if (ref && ref.parentNode) {
            ref.parentNode.insertBefore(b, ref);
        } else {
            return null;
        }

        /* v8 闪烁修复：脉冲圈与横向滚动都只允许在「本页首次出现」时发生一次。
           原实现在按钮每次被外部重建时都会重播 1.05s×2 的橙色扩散动画，
           并调用 scrollIntoView 让整条工具栏横向跳动 —— 用户侧看到的就是
           「输入框下方那一栏一闪一闪」。 */
        if (!pulseDone) {
            pulseDone = true;
            b.classList.add('db-pulse');
            setTimeout(function () { b.classList.remove('db-pulse'); }, 2400);
        }

        b.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopImmediatePropagation();

            var next = !toolModeOn();
            if (typeof window.dscSetToolMode === 'function') {
                window.dscSetToolMode(next);
            }
            if (next) {
                toast(T('tool_on'), 'success');
            } else {
                toast(T('tool_off'), 'info');
            }
            sync();
        }, true);

        return b;
    }

    /* v8 闪烁修复：状态签名短路 + 幂等写。
       原实现每 600ms 无条件写 style/类名/属性，并且每 tick 都强制
       dscSetToolMode(false)，导致按钮 active 态与灰显态反复翻转、
       无限脉冲动画不断重启 —— 肉眼就是底栏「一闪一闪」。
       现在：签名不变则零操作；插件占用工具链只在用户切换插件那一刻
       由 plugins 侧统一处理一次，不在本文件的定时器里反复执行。 */
    var lastSig = '';

    function sig() {
        var has = $(BTN_ID) ? '1' : '0';
        var oldHas = $('dscToolModeBtn') ? '1' : '0';
        if (!isDbMode()) return 'off:' + has + ':' + oldHas;
        return ['db', has, oldHas,
            toolModeOn() ? '1' : '0',
            pluginOn() ? '1' : '0',
            dbModel()
        ].join('|');
    }

    function sync() {
        var now = sig();
        if (now === lastSig) return;   /* 稳态：不做任何 DOM/样式写 */
        lastSig = now;
        syncInner();
    }

    function syncInner() {
        var db = isDbMode();
        var oldBtn = $('dscToolModeBtn');
        var b = $(BTN_ID);

        if (!db) {
            if (b && b.style.display !== 'none') b.style.display = 'none';
            if (oldBtn) oldBtn.classList.remove('dsc-db-hidden');
            announcedDb = false;
            return;
        }

        ensureStyle();
        b = b || ensureBtn();
        if (oldBtn) oldBtn.classList.add('dsc-db-hidden');
        if (!b) return;

        var on = toolModeOn();

        if (b.style.display === 'none') b.style.display = '';
        b.classList.toggle('active', on);
        b.classList.remove('db-locked');
        b.setAttribute('data-model', dbModel());
        b.setAttribute('data-tools', String(DB_TOOLS));
        b.setAttribute('data-rounds', String(DB_ROUNDS));
        b.setAttribute('data-locked', '0');

        /* 不再使用 pointer-events:none 与 aria-disabled：
           按钮始终可点，占用期间点击由 click 处理器给出明确提示，
           避免「点了毫无反应」。 */
        b.removeAttribute('aria-disabled');
        b.style.pointerEvents = '';
        b.title = on ? T('tool_on_title') : T('tool_off_title');

        if (!announcedDb) {
            announcedDb = true;
            toast(T('tool_available'), 'info');
        }
    }

    window.dscDbToolModeOn = function () {
        try {
            return isDbMode() && toolModeOn();
        } catch (e) { return false; }
    };
    window.dscDbToolSync = sync;
    /* 插件不再锁定工具模式；保留该诊断入口兼容旧调用。 */
    window.dscDbToolLocked = function () { return false; };
    window.dscDbToolTier = function () {
        return { code: 'unified', tools: DB_TOOLS, rounds: DB_ROUNDS };
    };

    window.dscDbToolDiag = function () {
        var b = $(BTN_ID);
        var group = document.querySelector('.dsc-switch-group');
        if (!b) return { found: false, hint: '按钮尚未创建（未处于豆包模式？）' };
        var r = b.getBoundingClientRect();
        var gr = group ? group.getBoundingClientRect() : null;
        var vw = window.innerWidth || document.documentElement.clientWidth;
        var inViewport = r.width > 0 && r.height > 0 &&
            r.left >= -1 && r.right <= vw + 1;
        return {
            found: true,
            display: b.style.display,
            width: Math.round(r.width),
            height: Math.round(r.height),
            left: Math.round(r.left),
            right: Math.round(r.right),
            viewportWidth: vw,
            groupScrollLeft: group ? Math.round(group.scrollLeft) : null,
            groupClientWidth: gr ? Math.round(gr.clientWidth) : null,
            inViewport: inViewport,
            locked: b.getAttribute('data-locked') === '1'
        };
    };

    function boot() {
        try { localStorage.removeItem('dsc_plugin_tool_lock'); } catch (e) {}
        sync();
        setInterval(sync, SYNC_MS);

        var timer = null;
        function soon() {
            if (timer) return;
            timer = setTimeout(function () {
                timer = null;
                /* v8：仅当专属按钮缺失时才补建，稳态下零 DOM 操作 */
                if (!$(BTN_ID)) sync();
            }, 200);
        }
        try {
            var mo = new MutationObserver(soon);
            mo.observe(document.body, { childList: true, subtree: true });
        } catch (e) {}
        /* 语言切换后强制绕开签名短路，让 title 文案跟随刷新（仅一次） */
        window.addEventListener('dsc:langchange', function () {
            lastSig = '';
            sync();
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
