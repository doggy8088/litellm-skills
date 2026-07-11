#!/usr/bin/env python3
"""Generate LiteLLM YAML examples from the checked-in BYOK Forge catalog."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "litellm-byok-forge"
CATALOG_PATH = EXAMPLES / "catalog.json"


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
        "",
        "model_list:",
    ]
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
            "# For Docker, replace localhost with host.docker.internal when needed.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    providers = catalog["providers"]
    entries = [(provider, model) for provider in providers for model in provider["models"]]

    aliases = [model_alias(provider, model) for provider, model in entries]
    if len(aliases) != len(set(aliases)):
        raise ValueError("產生的 model_name 有重複值")

    provider_ids = [provider["id"] for provider in providers]
    if len(provider_ids) != len(set(provider_ids)):
        raise ValueError("catalog.json 有重複 provider id")

    provider_root = EXAMPLES / "providers"
    provider_root.mkdir(parents=True, exist_ok=True)
    for old_file in provider_root.glob("*/*.yaml"):
        old_file.unlink()

    for provider, model in entries:
        provider_dir = provider_root / provider["id"]
        provider_dir.mkdir(parents=True, exist_ok=True)
        output = provider_dir / f"{slug(model)}.yaml"
        output.write_text(
            config_text(
                catalog,
                [(provider, model)],
                title=f"{provider['name']} — {model}",
            ),
            encoding="utf-8",
        )

    (EXAMPLES / "all-models.yaml").write_text(
        config_text(catalog, entries, title="All BYOK Forge LiteLLM provider/model combinations"),
        encoding="utf-8",
    )
    (EXAMPLES / ".env.example").write_text(env_example(catalog), encoding="utf-8")

    print(f"已產生 {len(providers)} 個 providers、{len(entries)} 個 provider/model 範例")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
