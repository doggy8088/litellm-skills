#!/usr/bin/env python3
"""Generate LiteLLM YAML examples from the checked-in provider catalog."""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "litellm-byok-forge"
CATALOG_PATH = EXAMPLES / "catalog.json"
OLLAMA_CLOUD_TAGS_URL = "https://ollama.com/api/tags"
OLLAMA_CLOUD_DOCS_URL = "https://docs.ollama.com/cloud"


def slug(value: str) -> str:
    """Return a stable filesystem/model-alias slug."""

    result = re.sub(r"[^a-zA-Z0-9]+", "-", value).strip("-").lower()
    if not result:
        raise ValueError(f"無法為模型產生 slug：{value!r}")
    return result


def quote(value: str) -> str:
    """Quote a YAML scalar without requiring a YAML writer dependency."""

    return json.dumps(value, ensure_ascii=False)


def model_alias(provider: dict[str, Any], model: str) -> str:
    """Use provider-prefixed aliases so the combined file has no collisions."""

    return f"{provider['id']}__{slug(model)}"


def model_entry(provider: dict[str, Any], model: str) -> list[str]:
    alias = model_alias(provider, model)
    routed_model = f"{provider['prefix']}/{model}"
    lines = [
        f'  - model_name: {quote(alias)}',
        "    litellm_params:",
        f"      model: {quote(routed_model)}",
    ]
    if not provider.get("keyless"):
        lines.append(f"      api_key: os.environ/{provider['env']}")
    if provider.get("needs_base"):
        lines.append(f"      api_base: {quote(provider['base_default'])}")
    if provider.get("needs_version"):
        lines.append(f"      api_version: {quote(provider['version_default'])}")
    return lines


def refresh_ollama_cloud_catalog(catalog: dict[str, Any]) -> int:
    """Refresh the Ollama Cloud model snapshot from Ollama's first-party API."""

    provider = next(
        (item for item in catalog["providers"] if item.get("id") == "ollama_cloud"),
        None,
    )
    if provider is None:
        raise ValueError("catalog.json 缺少 ollama_cloud provider")

    request = urllib.request.Request(
        OLLAMA_CLOUD_TAGS_URL,
        headers={"Accept": "application/json", "User-Agent": "litellm-skills-catalog/1.0"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)

    names = sorted(
        {
            str(item.get("name") or item.get("model"))
            for item in payload.get("models", [])
            if isinstance(item, dict) and (item.get("name") or item.get("model"))
        }
    )
    if not names:
        raise ValueError("Ollama Cloud API 未回傳任何模型")

    provider["models"] = names
    provider["source"] = {
        "type": "ollama-api-tags",
        "url": OLLAMA_CLOUD_TAGS_URL,
        "docs": OLLAMA_CLOUD_DOCS_URL,
        "retrieved_at": datetime.now(ZoneInfo("Asia/Taipei")).date().isoformat(),
    }
    return len(names)


def config_text(
    catalog: dict[str, Any],
    entries: list[tuple[dict[str, Any], str]],
    *,
    title: str,
) -> str:
    source = catalog["source"]
    lines = [
        f"# {title}",
        f"# Source: {source['repository']} / {source['file']}",
        f"# Source commit: {source['commit']}",
        "# API keys are loaded at runtime from environment variables.",
    ]
    entry_provider_ids = {id(provider) for provider, _ in entries}
    provider_sources = {
        provider_source["url"]: provider_source
        for provider in catalog["providers"]
        if id(provider) in entry_provider_ids
        and (provider_source := provider.get("source"))
        and provider_source.get("url")
    }
    for provider_source in provider_sources.values():
        retrieved_at = provider_source.get("retrieved_at", "unknown")
        lines.append(
            f"# Provider model source: {provider_source['url']} (retrieved {retrieved_at})"
        )
    lines.extend(
        [
            "",
            "model_list:",
        ]
    )
    for index, (provider, model) in enumerate(entries):
        if index:
            lines.append("")
        lines.extend(model_entry(provider, model))
    lines.extend(
        [
            "",
            "litellm_settings:",
            "  drop_params: true",
            "",
            "general_settings:",
            "  master_key: os.environ/LITELLM_MASTER_KEY",
            "",
        ]
    )
    return "\n".join(lines)


def env_example(catalog: dict[str, Any]) -> str:
    envs: list[str] = []
    for provider in catalog["providers"]:
        env = provider.get("env")
        if env and env not in envs:
            envs.append(env)

    lines = [
        "# Copy to .env and replace every placeholder before starting LiteLLM.",
        "# Never commit .env or real provider credentials.",
        "LITELLM_MASTER_KEY=sk-local-change-this-value",
        "",
    ]
    for env in envs:
        lines.append(f"{env}=replace-with-{env.lower()}-value")
    lines.extend(
        [
            "",
            "# Azure api_base/api_version and local api_base values are kept in YAML.",
            "# Ollama Cloud uses OLLAMA_API_KEY with https://ollama.com; local Ollama is keyless.",
            "# For Docker, replace localhost with host.docker.internal when needed.",
            "",
        ]
    )
    return "\n".join(lines)


def model_catalog_text(
    catalog: dict[str, Any], entries: list[tuple[dict[str, Any], str]]
) -> str:
    """Render a human-readable snapshot of every generated provider/model route."""

    source = catalog["source"]
    lines = [
        "# LiteLLM provider/model 模型目錄",
        "",
        (
            f"本文件是 {len(catalog['providers'])} 個 providers、{len(entries)} 組"
            " provider/model 設定的可讀版快照。模型清單會變動，請依各 provider 官方文件"
            " 與來源端點重新查核。"
        ),
        "",
        "## 來源",
        "",
        (
            f"- BYOK Forge：[{source['repository']} 的 `litellm.html`]"
            f"({source['page']})，commit `{source['commit']}`。"
        ),
    ]
    for provider in catalog["providers"]:
        provider_source = provider.get("source")
        if provider_source:
            lines.append(
                f"- {provider['name']}：官方模型 API [來源端點]({provider_source['url']})，"
                f"擷取日期 `{provider_source.get('retrieved_at', 'unknown')}`。"
            )

    for provider in catalog["providers"]:
        provider_entries = [model for current, model in entries if current is provider]
        lines.extend(
            [
                "",
                f"## {provider['name']}",
                "",
                f"- LiteLLM prefix：`{provider['prefix']}`",
                f"- 模型數：{len(provider_entries)}",
                "",
                "| 模型 | model alias | API base |",
                "| --- | --- | --- |",
            ]
        )
        base = provider.get("base_default", "provider 預設端點")
        for model in provider_entries:
            lines.append(
                f"| `{model}` | `{model_alias(provider, model)}` | `{base}` |"
            )

    return "\n".join(lines) + "\n"


def ollama_cloud_catalog_text(catalog: dict[str, Any]) -> str:
    """Render direct API names and local signed-in cloud variants."""

    providers = [
        item
        for item in catalog["providers"]
        if item.get("id") in {"ollama_cloud", "ollama_cloud_local"}
    ]
    if not providers:
        raise ValueError("catalog.json 缺少 Ollama Cloud provider")

    total = sum(len(provider["models"]) for provider in providers)
    lines = [
        "# Ollama Cloud 模型清單",
        "",
        (
            f"本文件列出 {len(providers)} 種 Ollama Cloud 存取方式、{total} 個模型名稱；"
            "直接 API 名稱與本機登入後的 `:cloud` 變體不能互換。"
        ),
        "",
    ]
    for provider in providers:
        source = provider["source"]
        lines.extend(
            [
                "",
                f"## {provider['name']}",
                "",
                f"- 查核日期：`{source['retrieved_at']}`",
                f"- API base：`{provider['base_default']}`",
                f"- LiteLLM prefix：`{provider['prefix']}`",
                (
                    "- API key 環境變數：`OLLAMA_API_KEY`"
                    if not provider.get("keyless")
                    else "- 驗證：本機 Ollama 需先執行 `ollama signin`"
                ),
                f"- 來源：[Ollama Cloud 官方來源]({source['url']})",
                f"- 官方說明：[Ollama Cloud 官方文件]({source['docs']})",
                "",
                "| 模型 | LiteLLM model route | model alias |",
                "| --- | --- | --- |",
            ]
        )
        for model in provider["models"]:
            lines.append(
                f"| `{model}` | `{provider['prefix']}/{model}` | "
                f"`{model_alias(provider, model)}` |"
            )
        lines.extend(
            [
                "",
            ]
        )
    lines.extend(
        [
            "",
            "> Ollama Cloud 模型會隨官方 API 與模型庫變更；重新產生前請再次查核模型可用性、"
            "帳戶方案與區域限制。這份檔案不是 Ollama 公開 model library 的永久快照。",
            "",
        ]
    )
    return "\n".join(lines)


def render_outputs(catalog: dict[str, Any]) -> dict[Path, str]:
    """Render every generated artifact without touching the working tree."""

    providers = catalog["providers"]
    entries = [(provider, model) for provider in providers for model in provider["models"]]

    aliases = [model_alias(provider, model) for provider, model in entries]
    if len(aliases) != len(set(aliases)):
        raise ValueError("產生的 model_name 有重複值")

    provider_ids = [provider["id"] for provider in providers]
    if len(provider_ids) != len(set(provider_ids)):
        raise ValueError("catalog.json 有重複 provider id")

    outputs: dict[Path, str] = {}
    for provider, model in entries:
        relative_path = Path("providers") / provider["id"] / f"{slug(model)}.yaml"
        outputs[relative_path] = config_text(
            catalog,
            [(provider, model)],
            title=f"{provider['name']} — {model}",
        )

    outputs[Path("all-models.yaml")] = config_text(
        catalog,
        entries,
        title="All LiteLLM provider/model combinations",
    )
    outputs[Path(".env.example")] = env_example(catalog)
    outputs[Path("model-catalog.md")] = model_catalog_text(catalog, entries)
    outputs[Path("ollama-cloud-models.md")] = ollama_cloud_catalog_text(catalog)
    return outputs


def check_outputs(outputs: dict[Path, str]) -> list[str]:
    """Return generated-artifact drift without modifying files."""

    errors: list[str] = []
    expected_provider_files = {
        path for path in outputs if path.parts and path.parts[0] == "providers"
    }
    actual_provider_files = {
        path.relative_to(EXAMPLES)
        for path in (EXAMPLES / "providers").glob("*/*.yaml")
    }
    for path in sorted(expected_provider_files - actual_provider_files):
        errors.append(f"缺少生成檔：{path}")
    for path in sorted(actual_provider_files - expected_provider_files):
        errors.append(f"多餘生成檔：{path}")

    for path, expected in sorted(outputs.items(), key=lambda item: str(item[0])):
        target = EXAMPLES / path
        if not target.is_file():
            if path not in expected_provider_files:
                errors.append(f"缺少生成檔：{path}")
            continue
        if target.read_text(encoding="utf-8") != expected:
            errors.append(f"生成內容不同步：{path}")
    return errors


def write_outputs(outputs: dict[Path, str]) -> None:
    """Write rendered outputs using the legacy direct-update behavior."""

    provider_root = EXAMPLES / "providers"
    provider_root.mkdir(parents=True, exist_ok=True)
    for old_file in provider_root.glob("*/*.yaml"):
        old_file.unlink()

    for relative_path, content in outputs.items():
        target = EXAMPLES / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="產生 LiteLLM provider/model 範例")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--refresh-ollama-cloud",
        action="store_true",
        help="先從 Ollama Cloud 官方 /api/tags 重新擷取模型清單",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="唯讀檢查 catalog 與所有生成物是否同步",
    )
    args = parser.parse_args()

    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    if args.refresh_ollama_cloud:
        count = refresh_ollama_cloud_catalog(catalog)
        CATALOG_PATH.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"已從 Ollama Cloud 官方 API 更新 {count} 個模型")

    outputs = render_outputs(catalog)
    if args.check:
        errors = check_outputs(outputs)
        if errors:
            for error in errors:
                print(f"- {error}")
            return 1
        print(f"生成物檢查通過：{len(outputs)} 份檔案")
        return 0

    write_outputs(outputs)
    model_count = sum(len(provider["models"]) for provider in catalog["providers"])
    print(
        f"已產生 {len(catalog['providers'])} 個 providers、"
        f"{model_count} 個 provider/model 範例"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
