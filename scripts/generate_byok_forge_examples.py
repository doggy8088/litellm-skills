#!/usr/bin/env python3
"""Generate LiteLLM YAML examples from the checked-in provider catalog."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import tempfile
import urllib.request
from datetime import date, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "litellm-byok-forge"
CATALOG_PATH = EXAMPLES / "catalog.json"
OLLAMA_CLOUD_TAGS_URL = "https://ollama.com/api/tags"
OLLAMA_CLOUD_DOCS_URL = "https://docs.ollama.com/cloud"
MODEL_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,199}")
PROVIDER_ID_PATTERN = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*")
PROVIDER_PREFIX_PATTERN = re.compile(r"[a-z][a-z0-9_]*")
ENVIRONMENT_NAME_PATTERN = re.compile(r"[A-Z][A-Z0-9_]*")
COMMIT_PATTERN = re.compile(r"[0-9a-fA-F]{40}")
ISO_DATE_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x1f\x7f]")
NAME_CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00\r\n]")

ROOT_FIELDS = frozenset({"source", "providers"})
ROOT_SOURCE_FIELDS = frozenset(
    {"repository", "commit", "file", "page", "extracted_at"}
)
PROVIDER_FIELDS = frozenset(
    {
        "id",
        "name",
        "prefix",
        "env",
        "models",
        "keyless",
        "needs_base",
        "needs_version",
        "base_default",
        "version_default",
        "source",
    }
)
PROVIDER_REQUIRED_FIELDS = frozenset({"id", "name", "prefix", "env", "models"})
PROVIDER_SOURCE_FIELDS = frozenset({"type", "url", "docs", "retrieved_at"})


def validate_model_name(value: object) -> str:
    """Validate a model name before using it in paths, YAML, or Markdown."""

    if not isinstance(value, str):
        raise ValueError("模型名稱必須是字串")
    if MODEL_NAME_PATTERN.fullmatch(value) is None:
        raise ValueError("模型名稱包含不允許的字元或長度超過 200 字元")
    return value


def _validate_mapping(
    value: object,
    path: str,
    *,
    required: frozenset[str],
    allowed: frozenset[str],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{path} 必須是物件")

    missing = sorted(required - value.keys())
    if missing:
        raise ValueError(f"{path}.{missing[0]} 是必要欄位")

    unknown = [key for key in value if key not in allowed]
    if unknown:
        field = unknown[0]
        if isinstance(field, str):
            raise ValueError(f"{path}.{field} 是未知欄位")
        raise ValueError(f"{path} 包含非字串欄位：{field!r}")
    return value


def _validate_text(
    value: object,
    path: str,
    *,
    control_pattern: re.Pattern[str] = CONTROL_CHARACTER_PATTERN,
) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{path} 必須是非空字串")
    if control_pattern.search(value) is not None:
        raise ValueError(f"{path} 不得包含控制字元")
    return value


def _validate_http_url(value: object, path: str) -> str:
    text = _validate_text(value, path)
    try:
        parsed = urlparse(text)
        hostname = parsed.hostname
    except ValueError as error:
        raise ValueError(f"{path} 必須是具有 host 的 HTTP 或 HTTPS URL") from error
    if parsed.scheme not in {"http", "https"} or not hostname:
        raise ValueError(f"{path} 必須是具有 host 的 HTTP 或 HTTPS URL")
    return text


def _validate_iso_date(value: object, path: str) -> str:
    text = _validate_text(value, path)
    if ISO_DATE_PATTERN.fullmatch(text) is None:
        raise ValueError(f"{path} 必須是 YYYY-MM-DD 日期")
    try:
        date.fromisoformat(text)
    except ValueError as error:
        raise ValueError(f"{path} 必須是有效的 YYYY-MM-DD 日期") from error
    return text


def validate_catalog(catalog: object) -> None:
    """Validate the complete checked-in catalog before rendering or refreshing."""

    root = _validate_mapping(
        catalog,
        "catalog",
        required=ROOT_FIELDS,
        allowed=ROOT_FIELDS,
    )
    source = _validate_mapping(
        root["source"],
        "source",
        required=ROOT_SOURCE_FIELDS,
        allowed=ROOT_SOURCE_FIELDS,
    )
    for field in ("repository", "file"):
        _validate_text(source[field], f"source.{field}")
    commit = _validate_text(source["commit"], "source.commit")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("source.commit 必須是 40 位十六進位字串")
    _validate_http_url(source["page"], "source.page")
    _validate_iso_date(source["extracted_at"], "source.extracted_at")

    providers = root["providers"]
    if not isinstance(providers, list) or not providers:
        raise ValueError("providers 必須是非空陣列")

    provider_ids: set[str] = set()
    aliases: set[str] = set()
    for index, raw_provider in enumerate(providers):
        provider_path = f"providers[{index}]"
        if not isinstance(raw_provider, dict):
            raise ValueError(f"{provider_path} 必須是物件")
        raw_id = raw_provider.get("id")
        provider_id = (
            raw_id
            if isinstance(raw_id, str)
            and PROVIDER_ID_PATTERN.fullmatch(raw_id) is not None
            else None
        )
        try:
            provider = _validate_mapping(
                raw_provider,
                provider_path,
                required=PROVIDER_REQUIRED_FIELDS,
                allowed=PROVIDER_FIELDS,
            )
            provider_id_value = _validate_text(
                provider["id"],
                f"{provider_path}.id",
            )
            if PROVIDER_ID_PATTERN.fullmatch(provider_id_value) is None:
                raise ValueError(
                    f"{provider_path}.id 必須是安全的小寫 snake_case 識別字"
                )
            provider_id = provider_id_value
            if provider_id in provider_ids:
                raise ValueError(f"{provider_path}.id 與既有 provider 重複")
            provider_ids.add(provider_id)

            _validate_text(
                provider["name"],
                f"{provider_path}.name",
                control_pattern=NAME_CONTROL_CHARACTER_PATTERN,
            )
            prefix = _validate_text(provider["prefix"], f"{provider_path}.prefix")
            if PROVIDER_PREFIX_PATTERN.fullmatch(prefix) is None:
                raise ValueError(
                    f"{provider_path}.prefix 必須是小寫 provider prefix"
                )

            for flag in ("keyless", "needs_base", "needs_version"):
                if flag in provider and type(provider[flag]) is not bool:
                    raise ValueError(f"{provider_path}.{flag} 必須是布林值")
            keyless = provider.get("keyless", False)
            needs_base = provider.get("needs_base", False)
            needs_version = provider.get("needs_version", False)

            env = provider["env"]
            if not isinstance(env, str):
                raise ValueError(f"{provider_path}.env 必須是字串")
            if keyless:
                if env:
                    raise ValueError(f"{provider_path}.env 在 keyless 模式必須為空字串")
            elif ENVIRONMENT_NAME_PATTERN.fullmatch(env) is None:
                raise ValueError(
                    f"{provider_path}.env 必須是有效的大寫環境變數名稱"
                )

            if needs_base and "base_default" not in provider:
                raise ValueError(f"{provider_path}.base_default 是必要欄位")
            if "base_default" in provider:
                _validate_http_url(
                    provider["base_default"],
                    f"{provider_path}.base_default",
                )

            if needs_version and "version_default" not in provider:
                raise ValueError(f"{provider_path}.version_default 是必要欄位")
            if "version_default" in provider:
                _validate_text(
                    provider["version_default"],
                    f"{provider_path}.version_default",
                )

            models = provider["models"]
            if not isinstance(models, list) or not models:
                raise ValueError(f"{provider_path}.models 必須是非空陣列")
            seen_models: set[str] = set()
            for model_index, raw_model in enumerate(models):
                model_path = f"{provider_path}.models[{model_index}]"
                try:
                    model = validate_model_name(raw_model)
                except ValueError as error:
                    raise ValueError(f"{model_path}：{error}") from error
                if model in seen_models:
                    raise ValueError(f"{model_path} 與同 provider 的模型重複")
                seen_models.add(model)
                alias = model_alias(provider, model)
                if alias in aliases:
                    raise ValueError(f"{model_path} 產生重複 model alias：{alias}")
                aliases.add(alias)

            if "source" in provider:
                source_path = f"{provider_path}.source"
                provider_source = _validate_mapping(
                    provider["source"],
                    source_path,
                    required=PROVIDER_SOURCE_FIELDS,
                    allowed=PROVIDER_SOURCE_FIELDS,
                )
                _validate_text(provider_source["type"], f"{source_path}.type")
                _validate_http_url(provider_source["url"], f"{source_path}.url")
                _validate_http_url(provider_source["docs"], f"{source_path}.docs")
                _validate_iso_date(
                    provider_source["retrieved_at"],
                    f"{source_path}.retrieved_at",
                )
        except ValueError as error:
            if provider_id is not None:
                raise ValueError(f"{error}；provider id：{provider_id}") from error
            raise


def markdown_table_code(value: str) -> str:
    """Render a value as code without allowing Markdown table injection."""

    normalized = value.replace("\r", " ").replace("\n", " ")
    if any(character in normalized for character in "`|<>&"):
        escaped = html.escape(normalized, quote=False).replace("|", "&#124;")
        return f"<code>{escaped}</code>"
    return f"`{normalized}`"


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

    if not isinstance(payload, dict) or not isinstance(payload.get("models"), list):
        raise ValueError("Ollama Cloud API 回應缺少 models 陣列")

    names: set[str] = set()
    for item in payload["models"]:
        if not isinstance(item, dict):
            raise ValueError("Ollama Cloud API 的模型項目必須是物件")
        raw_name = item.get("name")
        if raw_name is None:
            raw_name = item.get("model")
        names.add(validate_model_name(raw_name))
    sorted_names = sorted(names)
    if not sorted_names:
        raise ValueError("Ollama Cloud API 未回傳任何模型")

    provider["models"] = sorted_names
    provider["source"] = {
        "type": "ollama-api-tags",
        "url": OLLAMA_CLOUD_TAGS_URL,
        "docs": OLLAMA_CLOUD_DOCS_URL,
        "retrieved_at": datetime.now(ZoneInfo("Asia/Taipei")).date().isoformat(),
    }
    return len(sorted_names)


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
                f"| {markdown_table_code(model)} | "
                f"{markdown_table_code(model_alias(provider, model))} | "
                f"{markdown_table_code(base)} |"
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
            route = f"{provider['prefix']}/{model}"
            lines.append(
                f"| {markdown_table_code(model)} | {markdown_table_code(route)} | "
                f"{markdown_table_code(model_alias(provider, model))} |"
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

    validate_catalog(catalog)
    providers = catalog["providers"]

    entries: list[tuple[dict[str, Any], str]] = []
    for provider in providers:
        entries.extend((provider, model) for model in provider["models"])

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


def _provider_yaml_files(examples: Path) -> set[Path]:
    """Return provider YAML paths without following symlinked directories."""

    provider_root = examples / "providers"
    if provider_root.is_symlink() or not provider_root.is_dir():
        return set()

    provider_files: set[Path] = set()
    for directory, directory_names, filenames in os.walk(
        provider_root,
        followlinks=False,
    ):
        current_directory = Path(directory)
        directory_names[:] = [
            name
            for name in directory_names
            if not (current_directory / name).is_symlink()
        ]
        for filename in filenames:
            path = current_directory / filename
            if path.suffix == ".yaml":
                provider_files.add(path.relative_to(examples))
    return provider_files


def check_outputs(outputs: dict[Path, str]) -> list[str]:
    """Return generated-artifact drift without modifying files."""

    errors: list[str] = []
    expected_provider_files = {
        path for path in outputs if path.parts and path.parts[0] == "providers"
    }
    actual_provider_files = _provider_yaml_files(EXAMPLES)
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


def _safe_target(root: Path, relative_path: Path) -> Path:
    """Resolve a generated path and reject paths outside its intended root."""

    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"生成檔路徑必須位於目標目錄內：{relative_path}")
    target = root / relative_path
    try:
        target.resolve(strict=False).relative_to(root.resolve())
    except ValueError as error:
        raise ValueError(f"生成檔路徑超出目標目錄：{relative_path}") from error
    return target


def _remove_empty_directories(directories: set[Path]) -> None:
    """Remove directories created by or made obsolete by a generation run."""

    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        try:
            directory.rmdir()
        except (FileNotFoundError, OSError):
            pass


def write_outputs_atomically(
    outputs: dict[Path, str],
    *,
    examples: Path = EXAMPLES,
    catalog_text: str | None = None,
) -> None:
    """Stage all outputs, then replace them with rollback on failure."""

    payloads = dict(outputs)
    if catalog_text is not None:
        payloads[Path("catalog.json")] = catalog_text

    expected_provider_files = {
        path for path in outputs if path.parts and path.parts[0] == "providers"
    }
    provider_root = examples / "providers"
    actual_provider_files = _provider_yaml_files(examples)
    stale_provider_files = actual_provider_files - expected_provider_files
    touched_paths = set(payloads) | stale_provider_files

    for relative_path in touched_paths:
        target = _safe_target(examples, relative_path)
        if target.is_symlink():
            raise ValueError(f"生成檔目標不得為符號連結：{relative_path}")

    with tempfile.TemporaryDirectory(
        prefix=".byok-forge-",
        dir=examples.parent,
    ) as temporary_directory:
        temporary_root = Path(temporary_directory)
        staged_root = temporary_root / "staged"
        backup_root = temporary_root / "backup"

        # Finish every render-to-disk operation before changing the target tree.
        for relative_path, content in sorted(
            payloads.items(), key=lambda item: str(item[0])
        ):
            staged_target = _safe_target(staged_root, relative_path)
            staged_target.parent.mkdir(parents=True, exist_ok=True)
            staged_target.write_text(content, encoding="utf-8")

        existing_paths: set[Path] = set()
        for relative_path in sorted(touched_paths, key=str):
            target = _safe_target(examples, relative_path)
            if target.exists():
                backup_target = _safe_target(backup_root, relative_path)
                backup_target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup_target)
                existing_paths.add(relative_path)

        created_directories: set[Path] = set()
        try:
            for relative_path in sorted(stale_provider_files, key=str):
                _safe_target(examples, relative_path).unlink()

            for relative_path in sorted(payloads, key=str):
                target = _safe_target(examples, relative_path)
                missing_parents = []
                parent = target.parent
                while parent != examples and not parent.exists():
                    missing_parents.append(parent)
                    parent = parent.parent
                target.parent.mkdir(parents=True, exist_ok=True)
                created_directories.update(missing_parents)
                os.replace(_safe_target(staged_root, relative_path), target)
        except BaseException as error:
            rollback_errors: list[str] = []
            for relative_path in sorted(touched_paths, key=str):
                target = _safe_target(examples, relative_path)
                try:
                    if relative_path in existing_paths:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(
                            _safe_target(backup_root, relative_path),
                            target,
                        )
                    else:
                        target.unlink(missing_ok=True)
                except OSError as rollback_error:
                    rollback_errors.append(f"{relative_path}: {rollback_error}")
            _remove_empty_directories(created_directories)
            if rollback_errors:
                details = "; ".join(rollback_errors)
                raise RuntimeError(f"生成失敗且無法完整回復：{details}") from error
            raise

        obsolete_directories: set[Path] = set()
        for path in stale_provider_files:
            parent = _safe_target(examples, path).parent
            while parent != provider_root:
                obsolete_directories.add(parent)
                parent = parent.parent
        _remove_empty_directories(obsolete_directories)


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
    validate_catalog(catalog)
    refreshed_model_count: int | None = None
    if args.refresh_ollama_cloud:
        refreshed_model_count = refresh_ollama_cloud_catalog(catalog)

    outputs = render_outputs(catalog)
    if args.check:
        errors = check_outputs(outputs)
        if errors:
            for error in errors:
                print(f"- {error}")
            return 1
        print(f"生成物檢查通過：{len(outputs)} 份檔案")
        return 0

    catalog_text = (
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
        if refreshed_model_count is not None
        else None
    )
    write_outputs_atomically(outputs, catalog_text=catalog_text)
    if refreshed_model_count is not None:
        print(f"已從 Ollama Cloud 官方 API 更新 {refreshed_model_count} 個模型")
    model_count = sum(len(provider["models"]) for provider in catalog["providers"])
    print(
        f"已產生 {len(catalog['providers'])} 個 providers、"
        f"{model_count} 個 provider/model 範例"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
