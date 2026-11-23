/* ============================================================
 * kewe-toplang.js —— 首页右上角语言选择器
 * 选择后写入 dsc_ui_lang2 并立即 location.reload()。
 * ============================================================ */
(function (global) {
  'use strict';

  var META = {
    ja: { flag: '🇯🇵', label: '日本語', code: 'JA' },
    zh: { flag: '🇨🇳', label: '中文', code: 'ZH' },
    en: { flag: '🇬🇧', label: 'English', code: 'EN' },
    ko: { flag: '🇰🇷', label: '한국어', code: 'KO' },
    ru: { flag: '🇷🇺', label: 'Русский', code: 'RU' },
    fr: { flag: '🇫🇷', label: 'Français', code: 'FR' }
  };

  var TEXT = {
    ja: { title: '言語を切り替え', hint: '選択後すぐに再読み込みします' },
    zh: { title: '切换语言', hint: '选择后立即刷新页面' },
    en: { title: 'Switch language', hint: 'The page reloads immediately' },
    ko: { title: '언어 변경', hint: '선택하면 즉시 새로고침됩니다' },
    ru: { title: 'Сменить язык', hint: 'Страница перезагрузится сразу' },
    fr: { title: 'Changer de langue', hint: 'La page se recharge immédiatement' }
  };

  var state = { lang: 'zh', panel: null, btn: null, wrapper: null };

  function currentLang() {
    try {
      var saved = localStorage.getItem('dsc_ui_lang2');
      if (saved && META[saved]) return saved;
    } catch (e) {}
    if (global.I18N && global.I18N.getLang) {
      var code = global.I18N.getLang();
      if (META[code]) return code;
    }
    return 'zh';
  }

  function tx(key) {
    var t = TEXT[state.lang] || TEXT.zh;
    return t[key] || TEXT.en[key] || key;
  }

  function setLang(code) {
    if (!META[code]) return;
    try { localStorage.setItem('dsc_ui_lang2', code); } catch (e) {}
    if (global.I18N && global.I18N.setLang) {
      // setLang 自带 reload；显式要求立即刷新。
      global.I18N.setLang(code, { reload: true });
    } else {
      global.location.reload();
    }
  }

  function buildPanel() {
    var wrap = state.wrapper;
    if (!wrap || state.panel) return;
    var panel = document.createElement('div');
    panel.className = 'dsc-toplang-panel';
    panel.id = 'dscTopLangPanel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', tx('title'));

    var head = document.createElement('div');
    head.className = 'dsc-toplang-head';
    var strong = document.createElement('strong');
    strong.textContent = tx('title');
    var count = document.createElement('span');
    count.textContent = '6 LANGUAGES';
    head.appendChild(strong);
    head.appendChild(count);
    panel.appendChild(head);

    var grid = document.createElement('div');
    grid.className = 'dsc-toplang-grid';
    var order = ['ja', 'zh', 'en', 'ko', 'ru', 'fr'];
    order.forEach(function (code) {
      var item = document.createElement('button');
      item.type = 'button';
      item.className = 'dsc-toplang-item' + (code === state.lang ? ' active' : '');
      item.setAttribute('data-lang', code);
      item.setAttribute('role', 'option');
      item.setAttribute('aria-selected', code === state.lang ? 'true' : 'false');
      item.innerHTML =
        '<span class="flag">' + META[code].flag + '</span>' +
        '<span class="name">' + META[code].label + '</span>' +
        '<span class="code">' + META[code].code + '</span>';
      item.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        setLang(code);
      });
      grid.appendChild(item);
    });
    panel.appendChild(grid);

    var hint = document.createElement('div');
    hint.className = 'dsc-toplang-hint';
    hint.innerHTML = '<span class="bolt">⚡</span><span>' + tx('hint') + '</span>';
    panel.appendChild(hint);

    wrap.appendChild(panel);
    state.panel = panel;
  }

  function placePanel() {
    if (!state.btn || !state.panel) return;
    var r = state.btn.getBoundingClientRect();
    var pw = state.panel.offsetWidth || 286;
    var ph = state.panel.offsetHeight || 240;
    var left = Math.max(8, Math.min(r.right - pw, global.innerWidth - pw - 8));
    var top = r.bottom + 9;
    if (top + ph > global.innerHeight - 8) top = Math.max(8, r.top - ph - 9);
    state.panel.style.left = left + 'px';
    state.panel.style.top = top + 'px';
  }

  function close() {
    if (!state.panel) return;
    state.panel.classList.remove('open');
    if (state.btn) state.btn.setAttribute('aria-expanded', 'false');
  }

  function open() {
    if (!state.panel) buildPanel();
    if (!state.panel) return;
    state.panel.classList.add('open');
    placePanel();
    if (state.btn) state.btn.setAttribute('aria-expanded', 'true');
  }

  function sync() {
    if (!state.btn) return;
    state.lang = currentLang();
    var code = META[state.lang].code;
    var codeEl = state.btn.querySelector('.dsc-toplang-code');
    if (codeEl) codeEl.textContent = code;
    state.btn.title = tx('title') + ' · ' + META[state.lang].label;
    state.btn.setAttribute('aria-label', state.btn.title);
    if (!state.panel) return;
    var items = state.panel.querySelectorAll('.dsc-toplang-item');
    for (var i = 0; i < items.length; i++) {
      var on = items[i].getAttribute('data-lang') === state.lang;
      items[i].classList.toggle('active', on);
      items[i].setAttribute('aria-selected', on ? 'true' : 'false');
    }
    var strong = state.panel.querySelector('.dsc-toplang-head strong');
    if (strong) strong.textContent = tx('title');
    var hint = state.panel.querySelector('.dsc-toplang-hint span:last-child');
    if (hint) hint.textContent = tx('hint');
    state.panel.setAttribute('aria-label', tx('title'));
  }

  function init() {
    var btn = document.getElementById('dscLangQuickBtn');
    if (!btn) return;
    state.btn = btn;
    state.wrapper = document.querySelector('.dsc-toplang');
    state.lang = currentLang();
    var globe = '<svg class="dsc-toplang-globe" viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
      '<circle cx="12" cy="12" r="8.2" stroke="#bae6fd" stroke-width="1.25" opacity=".65"/>' +
      '<ellipse cx="12" cy="12" rx="4" ry="8.2" stroke="#bae6fd" stroke-width="1" opacity=".5"/>' +
      '<path d="M4.4 9h15.2M4.4 15h15.2" stroke="#bae6fd" stroke-width="1" opacity=".5"/>' +
      '</svg>';
    btn.innerHTML = globe + '<span class="dsc-toplang-code">' + META[state.lang].code + '</span>';

    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      if (state.panel && state.panel.classList.contains('open')) close();
      else open();
    });

    document.addEventListener('click', function (e) {
      if (!state.panel || !state.panel.classList.contains('open')) return;
      if (state.panel.contains(e.target) || btn.contains(e.target)) return;
      close();
    }, true);
    global.addEventListener('resize', function () {
      if (state.panel && state.panel.classList.contains('open')) placePanel();
    });
    global.addEventListener('scroll', function () {
      if (state.panel && state.panel.classList.contains('open')) placePanel();
    }, true);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') close();
    });
    global.addEventListener('dsc:langchange', sync);
    sync();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})(window);
