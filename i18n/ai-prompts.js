/* i18n/ai-prompts.js —— AI 输出语言规则（默认跟随界面语言）
 * ------------------------------------------------------------
 * ja / zh / en / ko / ru / fr 各自返回对应语言的输出规则。
 * 代码、命令、URL、路径、API 名、变量名与原始工具输出保持原文。
 * 用户在当前轮显式指定另一种语言时，遵循用户的显式指定。
 *
 * ★ 语义须与 lib/src/globals.dart 的 DS_JA_ONLY_SYSTEM_PROMPT 保持一致。
 *   修正任意一端时，必须同步另一端。
 *
 * ★ 翻译按钮（/api/ds-chat/translate）使用独立 systemPrompt，
 *   因此本文件不会影响翻译结果的目标语言。
 */
(function () {
  'use strict';

  var LANGUAGE_NAME = {
    ja: 'Japanese (日本語)',
    zh: 'Simplified Chinese (简体中文)',
    en: 'English',
    ko: 'Korean (한국어)',
    ru: 'Russian (русский)',
    fr: 'French (français)'
  };

  function buildPrompt(code) {
    var name = LANGUAGE_NAME[code] || LANGUAGE_NAME.zh;
    return [
      '【OUTPUT LANGUAGE LOCK · HIGHEST PRIORITY】',
      'Current UI language: ' + name + '.',
      '',
      'Your entire natural-language answer MUST be written in ' + name + '. This includes',
      'the user-visible reasoning summary, explanations, headings, lists, tables,',
      'code comments, conclusions, status text and error messages.',
      'Do not answer in Chinese merely because the user message, quoted material,',
      'source code, system/tool text, or an earlier assistant message is Chinese.',
      'If the user explicitly requests a different answer language in the current turn,',
      'follow that explicit request.',
      '',
      'Keep code, commands, URLs, file paths, API names, package names, variable names,',
      'and quoted raw tool output unchanged when translation would break them.',
      'For translation tasks, the translated content must use its target language;',
      'the surrounding explanation uses ' + name + '.',
      '',
      'This output-language rule is the default for every response in this project.'
    ].join('\n');
  }

  window.DSC_I18N_PROMPTS = {
    ja: buildPrompt('ja'),
    zh: buildPrompt('zh'),
    en: buildPrompt('en'),
    ko: buildPrompt('ko'),
    ru: buildPrompt('ru'),
    fr: buildPrompt('fr')
  };
})();
