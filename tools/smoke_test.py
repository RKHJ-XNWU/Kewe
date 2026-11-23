#!/usr/bin/env python3
"""Kewe 本地无付费冒烟测试：静态资源、输出档位、模型目录与上下文接口。"""
from __future__ import annotations

import argparse
import json
from urllib.error import HTTPError
from urllib.request import Request, urlopen

OPTIONS = (65536, 131072, 262144, 393216)


def request(base: str, path: str, method: str = "GET", payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    req = Request(base + path, data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urlopen(req, timeout=15) as res:
            raw = res.read()
            return res.status, json.loads(raw) if raw else {}
    except HTTPError as exc:
        raw = exc.read()
        try:
            data = json.loads(raw)
        except Exception:
            data = {"raw": raw.decode("utf-8", "replace")}
        return exc.code, data


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:9999")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    # 静态页单独读取；API 统一走 JSON request()。
    with urlopen(base + "/", timeout=15) as res:
        page = res.read().decode("utf-8")
        check(res.status == 200, "首页不可访问")
    for asset in ("dscOutputLimitBtn", "dscContextBtn", "kewe-ui.css", "dsc-control-center.js"):
        check(asset in page, f"首页缺少 {asset}")

    status, original = request(base, "/api/ds-chat/output-limit")
    check(status == 200, "输出档位 GET 失败")
    original_value = original["maxOutput"]
    try:
        check(original_value in OPTIONS, "服务端返回非法输出档位")
        check(original["contextWindow"] == 1048576, "上下文不是 1024K")
        check(len(original["options"]) == 4, "输出档位不是四档")

        status, error = request(base, "/api/ds-chat/output-limit", "POST", {"tokens": 777})
        check(status == 400, "非法档位未被 HTTP 400 拒绝")

        for option in OPTIONS:
            status, saved = request(base, "/api/ds-chat/output-limit", "POST", {"tokens": option})
            check(status == 200 and saved.get("success") is True, f"保存 {option} 失败")
            check(saved["maxOutput"] == option, f"保存后返回值不是 {option}")

            status, ds_config = request(base, "/api/ds-chat/config")
            check(status == 200 and ds_config["maxOutput"] == option, f"DeepSeek 配置未同步 {option}")
            status, db_config = request(base, "/api/doubao/config")
            check(status == 200, "豆包配置读取失败")
            catalog = db_config.get("catalog", {})
            check(catalog.get("forcedMaxOutputTokens") == option, f"豆包目录未同步 {option}")
            models = [m for m in catalog.get("models", []) if m.get("category") == "chat"]
            check(models, "豆包对话模型目录为空")
            for model in models:
                check(model.get("maxOutput") == option, f"模型 {model.get('value')} 未同步 {option}")
                check(model.get("contextWindow") == 1048576, f"模型 {model.get('value')} 上下文异常")
            print(f"PASS tier {option // 1024}K: {len(models)} Doubao chat models + DeepSeek config")

        status, context = request(base, "/api/ds-chat/context?sessionId=")
        check(status == 200 and context["messages"] == 0, "空会话上下文接口异常")
        check(context["contextWindow"] == 1048576, "上下文接口容量异常")
    finally:
        request(base, "/api/ds-chat/output-limit", "POST", {"tokens": original_value})

    print("PASS: static assets, output API, model catalogs, context API; original tier restored.")


if __name__ == "__main__":
    main()
