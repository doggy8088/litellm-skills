"""Generic LiteLLM Proxy policy hook.

Mount this directory into the LiteLLM Proxy container and reference
`custom_hooks.proxy_policy_hook.proxy_handler_instance` from
`litellm_settings.callbacks`.

Optional environment variables:
- LITELLM_CUSTOM_PRICING_JSON: JSON object passed to litellm.register_model().
- LITELLM_MODEL_ALIAS_MAP_JSON: JSON object mapping public aliases to backend models.
- LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS: comma-separated model names that cannot
  replay Responses API input items with type=custom_tool_call.
"""

from __future__ import annotations

import json
import os
from typing import Any, Literal

import litellm
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.proxy_server import DualCache, UserAPIKeyAuth


def _load_json_env(name: str) -> dict[str, Any]:
    raw = os.getenv(name, "").strip()
    if not raw:
        return {}
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be a JSON object")
    return value


def _load_csv_env(name: str) -> set[str]:
    return {item.strip() for item in os.getenv(name, "").split(",") if item.strip()}


def _register_model_pricing() -> None:
    pricing = _load_json_env("LITELLM_CUSTOM_PRICING_JSON")
    if pricing:
        litellm.register_model(pricing)


def _resolve_target_model(model_name: Any) -> Any:
    if not isinstance(model_name, str):
        return model_name
    alias_map = _load_json_env("LITELLM_MODEL_ALIAS_MAP_JSON")
    return alias_map.get(model_name, model_name)


def _contains_custom_tool_call(input_payload: Any) -> bool:
    if not isinstance(input_payload, list):
        return False
    return any(
        isinstance(item, dict) and item.get("type") == "custom_tool_call"
        for item in input_payload
    )


class ProxyPolicyHandler(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: DualCache,
        data: dict,
        call_type: Literal[
            "completion",
            "text_completion",
            "embeddings",
            "image_generation",
            "moderation",
            "audio_transcription",
        ],
    ):
        _register_model_pricing()

        target_model = _resolve_target_model(data.get("model"))
        blocked_models = _load_csv_env("LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS")
        if (
            isinstance(target_model, str)
            and target_model in blocked_models
            and _contains_custom_tool_call(data.get("input"))
        ):
            raise HTTPException(
                status_code=400,
                detail={
                    "error": (
                        "This model does not support replaying Responses API "
                        "input items with type=custom_tool_call. Use supported "
                        "function_call/function_call_output items or remove the "
                        "custom_tool_call replay item."
                    )
                },
            )

        if isinstance(target_model, str):
            data["model"] = target_model
        return data


proxy_handler_instance = ProxyPolicyHandler()
