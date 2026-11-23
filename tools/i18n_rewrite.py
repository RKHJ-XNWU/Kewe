#!/usr/bin/env python3
"""重写并校验 Kewe 六语字典：去重、保序、补齐、统一文件格式。

用法：python3 tools/i18n_rewrite.py
源语言键保持不变；重复键采用原文件中最后生效的值，首次出现的位置保持不变。
"""
from __future__ import annotations

import re
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ROOT / "i18n" / "locales"
LANGS = ("ja", "zh", "en", "ko", "ru", "fr")

# 原字典的缺项与本轮新增后端提示，六种语言全部显式翻译。
MISSING = {
    "データディレクトリ：kewe/data/displaymodels": {
        "ja": "データディレクトリ：kewe/data/displaymodels", "zh": "数据目录：kewe/data/displaymodels",
        "en": "Data directory: kewe/data/displaymodels", "ko": "데이터 디렉터리: kewe/data/displaymodels",
        "ru": "Каталог данных: kewe/data/displaymodels", "fr": "Répertoire des données : kewe/data/displaymodels",
    },
    "削除に失敗：{0}": {
        "ja": "削除に失敗：{0}", "zh": "删除失败：{0}", "en": "Deletion failed: {0}",
        "ko": "삭제 실패: {0}", "ru": "Не удалось удалить: {0}", "fr": "Échec de la suppression : {0}",
    },
    "モデルの保存に失敗:": {
        "ja": "モデルの保存に失敗:", "zh": "模型保存失败：", "en": "Failed to save the model:",
        "ko": "모델 저장 실패:", "ru": "Не удалось сохранить модель:", "fr": "Échec de l’enregistrement du modèle :",
    },
    "読み込みに失敗：{0}": {
        "ja": "読み込みに失敗：{0}", "zh": "加载失败：{0}", "en": "Loading failed: {0}",
        "ko": "로드 실패: {0}", "ru": "Не удалось загрузить: {0}", "fr": "Échec du chargement : {0}",
    },
    "確定された：https://ark.cn-beijing.volces.com/api/v3": {
        "ja": "確定された：https://ark.cn-beijing.volces.com/api/v3", "zh": "已确定：https://ark.cn-beijing.volces.com/api/v3",
        "en": "Confirmed: https://ark.cn-beijing.volces.com/api/v3", "ko": "확인됨: https://ark.cn-beijing.volces.com/api/v3",
        "ru": "Подтверждено: https://ark.cn-beijing.volces.com/api/v3", "fr": "Confirmé : https://ark.cn-beijing.volces.com/api/v3",
    },
    "保存に失敗：{0}": {
        "ja": "保存に失敗：{0}", "zh": "保存失败：{0}", "en": "Saving failed: {0}",
        "ko": "저장 실패: {0}", "ru": "Не удалось сохранить: {0}", "fr": "Échec de l’enregistrement : {0}",
    },
    "融合信息搜索 API Key（开启内蔵ウェブ検索后需配置）": {
        "ja": "統合情報検索 API Key（内蔵ウェブ検索の有効時に設定が必要）", "zh": "融合信息搜索 API Key（开启内置联网搜索后需配置）",
        "en": "Fused information search API Key (required when built-in web search is enabled)",
        "ko": "융합 정보 검색 API Key(내장 웹 검색 활성화 시 설정 필요)",
        "ru": "API Key объединённого информационного поиска (требуется при включённом встроенном веб-поиске)",
        "fr": "Clé API de recherche d’informations fusionnées (requise avec la recherche web intégrée)",
    },
    "墨迹天気/頭条記事プラグインが有効中のため、ツールモードは利用できません": {
        "ja": "墨迹天気/頭条記事プラグインが有効中のため、ツールモードは利用できません",
        "zh": "墨迹天气/头条图文插件启用中，无法使用工具模式",
        "en": "Tool mode is unavailable while the Moji Weather or Toutiao Article plugin is enabled",
        "ko": "墨迹天气/头条图文 플러그인이 활성화되어 있어 도구 모드를 사용할 수 없습니다",
        "ru": "Режим инструментов недоступен при включённом плагине Moji Weather или Toutiao Article",
        "fr": "Le mode Outil est indisponible lorsque le plugin Moji Weather ou Toutiao Article est activé",
    },
    "対話への保存に失敗:": {
        "ja": "対話への保存に失敗:", "zh": "保存到会话失败：", "en": "Failed to save to the conversation:",
        "ko": "대화에 저장하지 못했습니다:", "ru": "Не удалось сохранить в диалог:", "fr": "Échec de l’enregistrement dans la conversation :",
    },
    "例：こんにちは / 皆さんこんにちは": {
        "ja": "例：こんにちは / 皆さんこんにちは", "zh": "例：你好 / 大家好", "en": "Example: Hello / Hello everyone",
        "ko": "예: 안녕하세요 / 여러분 안녕하세요", "ru": "Пример: Привет / Привет всем", "fr": "Exemple : Bonjour / Bonjour à tous",
    },
    "ST ディメンションをオフにしました": {
        "ja": "ST ディメンションをオフにしました", "zh": "已关闭 ST 维度", "en": "ST dimension disabled",
        "ko": "ST 차원을 껐습니다", "ru": "Измерение ST отключено", "fr": "Dimension ST désactivée",
    },
    "🤖 第 {0} ラウンド ·": {
        "ja": "🤖 第 {0} ラウンド ·", "zh": "🤖 第 {0} 轮 ·", "en": "🤖 Round {0} ·",
        "ko": "🤖 {0}라운드 ·", "ru": "🤖 Раунд {0} ·", "fr": "🤖 Tour {0} ·",
    },
    "翻訳を隠す": {
        "ja": "翻訳を隠す", "zh": "隐藏翻译", "en": "Hide translation",
        "ko": "번역 숨기기", "ru": "Скрыть перевод", "fr": "Masquer la traduction",
    },
    "このメッセージをコピー": {
        "ja": "このメッセージをコピー", "zh": "复制此消息", "en": "Copy this message",
        "ko": "이 메시지 복사", "ru": "Копировать это сообщение", "fr": "Copier ce message",
    },
    "最大出力は 64K / 128K / 256K / 384K から選択してください": {
        "ja": "最大出力は 64K / 128K / 256K / 384K から選択してください", "zh": "请选择 64K / 128K / 256K / 384K 最大输出档位",
        "en": "Choose a maximum output of 64K, 128K, 256K or 384K", "ko": "최대 출력을 64K / 128K / 256K / 384K 중에서 선택하세요",
        "ru": "Выберите максимальный вывод: 64K, 128K, 256K или 384K", "fr": "Choisissez une sortie maximale de 64K, 128K, 256K ou 384K",
    },
    "最大出力レベルの保存に失敗しました": {
        "ja": "最大出力レベルの保存に失敗しました", "zh": "最大输出档位保存失败", "en": "Failed to save the maximum output tier",
        "ko": "최대 출력 단계를 저장하지 못했습니다", "ru": "Не удалось сохранить уровень максимального вывода", "fr": "Impossible d’enregistrer le niveau de sortie maximale",
    },
}


def parse(path: Path) -> tuple[list[str], dict[str, str]]:
    text = path.read_text(encoding="utf-8")
    matches = list(re.finditer(r"I18N\.add\('[a-z]{2}',\s*`(.*?)`\s*\)\s*;", text, re.S))
    if not matches:
        if re.search(r"I18N\.add\('[a-z]{2}',\s*\{\s*\}\s*\)", text):
            return [], {}
        raise ValueError(f"找不到字典块: {path}")
    order: list[str] = []
    values: dict[str, str] = {}
    for match in matches:
        for raw in match.group(1).splitlines():
            line = raw.strip()
            if not line or line.startswith(("#", "/*", "*")) or "|" not in line:
                continue
            key, value = line.split("|", 1)
            if key not in values:
                order.append(key)
            values[key] = value
    return order, values


def emit(path: Path, lang: str, keys: list[str], values: dict[str, str], label: str) -> None:
    def safe(value: str) -> str:
        return value.replace("`", "\\`").replace("${", "\\${")

    lines = [
        "// ============================================================",
        f"// Kewe i18n — {label} / {lang}",
        "// 规范重写版：键顺序稳定、无重复项、六语键集合一致。",
        "// 维护工具：python3 tools/i18n_rewrite.py",
        "// ============================================================",
        f"I18N.add('{lang}',`",
    ]
    lines.extend(f"    {safe(key)}|{safe(values[key])}" for key in keys)
    lines.extend(["`);", ""])
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    original: dict[tuple[str, str], tuple[list[str], dict[str, str]]] = {}
    for lang in LANGS:
        for suffix in ("", "-extra"):
            original[(lang, suffix)] = parse(LOCALES / f"{lang}{suffix}.js")

    base_keys = list(original[("zh", "")][0])
    extra_keys = list(original[("zh", "-extra")][0])
    for key in MISSING:
        if key not in base_keys and key not in extra_keys:
            extra_keys.append(key)

    all_values: dict[tuple[str, str], dict[str, str]] = {}
    for lang in LANGS:
        for suffix, keys in (("", base_keys), ("-extra", extra_keys)):
            _, current = original[(lang, suffix)]
            values: dict[str, str] = {}
            for key in keys:
                if key in current:
                    values[key] = current[key]
                elif key in MISSING:
                    values[key] = MISSING[key][lang]
                elif lang == "ja":
                    # 日语源键显式恒等映射，消除 tCore 的日语特殊分支。
                    values[key] = key
                elif lang == "zh":
                    raise ValueError(f"中文缺少键且未提供译文: {key}")
                else:
                    raise ValueError(f"{lang} 缺少键且未提供译文: {key}")
            if len(values) != len(keys):
                raise AssertionError(f"键数不一致: {lang}{suffix}")
            all_values[(lang, suffix)] = values

    # 全量键集合与占位符校验。
    reference = set(base_keys) | set(extra_keys)
    placeholders = lambda value: set(re.findall(r"\{\d+\}", value))
    for lang in LANGS:
        combined = all_values[(lang, "")] | all_values[(lang, "-extra")]
        if set(combined) != reference:
            raise AssertionError(f"{lang} 键集合不一致")
        for key, value in combined.items():
            if placeholders(key) != placeholders(value):
                raise AssertionError(f"{lang} 占位符不一致: {key}")

    for lang in LANGS:
        emit(LOCALES / f"{lang}.js", lang, base_keys, all_values[(lang, "")], "主字典")
        emit(LOCALES / f"{lang}-extra.js", lang, extra_keys, all_values[(lang, "-extra")], "扩展字典")
        print(f"{lang}: {len(reference)} keys / 0 duplicates / 100% key coverage")
    print(f"完成：{len(LANGS)} 种语言，{len(base_keys)} 主键，{len(extra_keys)} 扩展键。")


if __name__ == "__main__":
    main()
