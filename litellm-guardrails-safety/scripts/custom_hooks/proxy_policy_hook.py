"""Narrow LiteLLM Proxy compatibility policy hook.

Mount this directory into the LiteLLM Proxy container and reference
`custom_hooks.proxy_policy_hook.proxy_handler_instance` from
`litellm_settings.callbacks`.

Optional environment variable:
- LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS: comma-separated request-visible model
  names or aliases (the values received in data["model"]) that cannot replay
  Responses API input items with type=custom_tool_call.

Pricing and alias routing intentionally stay in LiteLLM's native configuration so
this security hook cannot bypass key model allowlists, budgets, or router policy.
"""

from __future__ import annotations

import os
from typing import Any

from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger


def _load_csv_env(name: str) -> set[str]:
    return {item.strip() for item in os.getenv(name, "").split(",") if item.strip()}


def _contains_custom_tool_call(input_payload: Any) -> bool:
    if not isinstance(input_payload, list):
        return False
    return any(
        isinstance(item, dict) and item.get("type") == "custom_tool_call"
        for item in input_payload
    )


class ProxyPolicyHandler(CustomLogger):
    def __init__(self, blocked_request_models: set[str] | None = None) -> None:
        super().__init__()
        self.blocked_request_models = (
            set(blocked_request_models)
            if blocked_request_models is not None
            else _load_csv_env("LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS")
        )

    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict[str, Any],
        call_type: str,
    ) -> dict[str, Any]:
        target_model = data.get("model")
        if (
            isinstance(target_model, str)
            and target_model in self.blocked_request_models
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

        return data


proxy_handler_instance = ProxyPolicyHandler()
