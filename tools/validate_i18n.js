#!/usr/bin/env node
/* 六语运行时校验：加载真实 i18n 引擎和全部字典，逐键翻译并核对占位符。 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.resolve(__dirname, '..');
const langs = ['ja', 'zh', 'en', 'ko', 'ru', 'fr'];
const store = Object.create(null);
const document = {
    readyState: 'loading',
    title: '',
    body: null,
    documentElement: { setAttribute() {}, getAttribute() { return 'ja'; } },
    addEventListener() {},
    getElementById() { return null; },
    querySelectorAll() { return []; }
};
const window = {
    document,
    location: { href: 'http://localhost/', reload() {} },
    history: { replaceState() {} },
    dispatchEvent() {},
    addEventListener() {},
    requestAnimationFrame(fn) { fn(); }
};
const context = vm.createContext({
    window,
    document,
    navigator: { language: 'ja' },
    localStorage: { getItem(k) { return store[k] || null; }, setItem(k, v) { store[k] = String(v); } },
    CustomEvent: function CustomEvent(type, init) { return { type, detail: init && init.detail }; },
    URL,
    NodeFilter: { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 },
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval
});
function load(file) { vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context, { filename: file }); }
load('i18n/i18n.js');
// VM 中 window 与全局对象分离；浏览器里二者天然相同，这里显式桥接。
context.I18N = window.I18N;
context.t = window.t;
for (const lang of langs) {
    load(`i18n/locales/${lang}.js`);
    load(`i18n/locales/${lang}-extra.js`);
}
const api = window.I18N;
if (!api) throw new Error('I18N 未初始化');
const expectedKeys = Object.keys(api.dict('zh')).sort();
if (expectedKeys.length < 2000) throw new Error(`字典数量异常: ${expectedKeys.length}`);
const placeholder = value => (String(value).match(/\{\d+\}/g) || []).sort().join(',');
for (const lang of langs) {
    const dict = api.dict(lang);
    const keys = Object.keys(dict).sort();
    if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) throw new Error(`${lang} 键集合不一致`);
    if (api.coverage(lang) !== expectedKeys.length) throw new Error(`${lang} coverage 异常`);
    api.setLang(lang, { silent: true, reload: false });
    for (const key of expectedKeys) {
        const actual = api.t(key);
        if (actual !== dict[key]) throw new Error(`${lang} 精确翻译失败: ${key}`);
        if (placeholder(key) !== placeholder(actual)) throw new Error(`${lang} 占位符不一致: ${key}`);
        if (lang !== 'ja' && /[\u3040-\u309f\u30a0-\u30ff]/.test(key) && actual === key) {
            throw new Error(`${lang} 存在未翻译日语: ${key}`);
        }
    }
    const sample = api.t('削除に失敗：{0}', 'sample.txt');
    if (sample.includes('{0}') || !sample.includes('sample.txt')) throw new Error(`${lang} 插值失败`);
    console.log(`${lang}: ${keys.length}/${expectedKeys.length} keys, exact lookup + interpolation OK`);
}
console.log(`PASS: ${langs.length} languages, ${expectedKeys.length} keys each, ${langs.length * expectedKeys.length} exact lookups.`);
