from __future__ import annotations

import asyncio
import importlib.util
import sys
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK_PATH = (
    ROOT
    / "litellm-guardrails-safety"
    / "scripts"
    / "custom_hooks"
    / "proxy_policy_hook.py"
)


class StubHTTPException(Exception):
    def __init__(self, status_code: int, detail: object) -> None:
        super().__init__(str(detail))
        self.status_code = status_code
        self.detail = detail


class StubCustomLogger:
    pass


def load_hook_module():
    fastapi = types.ModuleType("fastapi")
    fastapi.HTTPException = StubHTTPException
    litellm = types.ModuleType("litellm")
    integrations = types.ModuleType("litellm.integrations")
    custom_logger = types.ModuleType("litellm.integrations.custom_logger")
    custom_logger.CustomLogger = StubCustomLogger

    stubs = {
        "fastapi": fastapi,
        "litellm": litellm,
        "litellm.integrations": integrations,
        "litellm.integrations.custom_logger": custom_logger,
    }
    previous = {name: sys.modules.get(name) for name in stubs}
    sys.modules.update(stubs)
    try:
        spec = importlib.util.spec_from_file_location("proxy_policy_hook_test", HOOK_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError("無法載入 proxy policy hook")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        for name, original in previous.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original


class ProxyPolicyHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_hook_module()

    def invoke(self, handler, data):
        return asyncio.run(
            handler.async_pre_call_hook(
                user_api_key_dict=None,
                cache=None,
                data=data,
                call_type="responses",
            )
        )

    def test_normal_request_is_returned_without_model_rewrite(self) -> None:
        handler = self.module.ProxyPolicyHandler({"backend-a"})
        data = {"model": "public-alias", "input": [{"type": "message"}]}
        result = self.invoke(handler, data)
        self.assertIs(result, data)
        self.assertEqual(result["model"], "public-alias")

    def test_configured_request_alias_blocks_custom_tool_call_replay(self) -> None:
        handler = self.module.ProxyPolicyHandler({"public-alias"})
        data = {"model": "public-alias", "input": [{"type": "custom_tool_call"}]}
        with self.assertRaises(StubHTTPException) as caught:
            self.invoke(handler, data)
        self.assertEqual(caught.exception.status_code, 400)
        self.assertNotIn(str(data), str(caught.exception.detail))

    def test_unconfigured_request_model_is_not_blocked(self) -> None:
        handler = self.module.ProxyPolicyHandler({"backend-a"})
        data = {"model": "backend-b", "input": [{"type": "custom_tool_call"}]}
        self.assertIs(self.invoke(handler, data), data)

    def test_backend_name_is_not_inferred_from_request_alias(self) -> None:
        handler = self.module.ProxyPolicyHandler({"backend-a"})
        data = {"model": "public-alias", "input": [{"type": "custom_tool_call"}]}
        self.assertIs(self.invoke(handler, data), data)

    def test_malformed_input_is_not_treated_as_custom_tool_call(self) -> None:
        handler = self.module.ProxyPolicyHandler({"backend-a"})
        for payload in (None, "text", {"type": "custom_tool_call"}, [None, "bad"]):
            data = {"model": "backend-a", "input": payload}
            self.assertIs(self.invoke(handler, data), data)


if __name__ == "__main__":
    unittest.main()
