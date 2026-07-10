# Custom Hooks And Secret Hygiene

Use this when reviewing proxy callbacks, request rewriting, unsupported payload blocking, or sensitive operational artifacts.

## Hook Pattern

The bundled `scripts/custom_hooks/proxy_policy_hook.py` template defines a `CustomLogger` subclass with `async_pre_call_hook`.

The hook:

- Calls `litellm.register_model()` for custom OpenAI-compatible backend pricing when `LITELLM_CUSTOM_PRICING_JSON` is set.
- Maps selected user-facing aliases to backend model aliases when `LITELLM_MODEL_ALIAS_MAP_JSON` is set.
- Blocks Responses API inputs containing `input[].type=custom_tool_call` for models known not to support that replay shape.
- Reads the blocked model list from `LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS`.
- Raises a FastAPI `HTTPException(status_code=400)` with a clear user-facing error.
- Returns the modified `data` dict to LiteLLM.

## Safe Hook Rules

- Keep hook initialization idempotent; callbacks may run many times.
- Validate request shape before rewriting models.
- Keep model alias maps in configuration when they change often.
- Avoid hardcoded personal key aliases or allowlists in code.
- Fail closed for unsupported payloads that can corrupt state or produce misleading model behavior.
- Add tests for hook import, alias rewrite, blocked payload, and unaffected normal calls.

## Secret Inventory

Operational LiteLLM repositories often contain several secret-like patterns:

- Virtual keys in `Key_List*.csv` and generated result CSVs.
- Hardcoded bearer-token defaults in scripts.
- SAS URLs/signatures in upload helper scripts.
- Browser or API captures with request data.
- Config references to many API-key environment variables.

Do not quote or copy these values. If the user wants to publish or share the repository, recommend scrubbing the files and rotating any exposed credentials.

## Prompt And Response Storage

`store_prompts_in_spend_logs: true` means operational logs and archives can contain prompt/response content. Treat spend-log exports as sensitive datasets and set retention deliberately.

## Security Review Questions

- What exact condition should block the request?
- Which identities, teams, or keys can bypass the block, and where is that exception stored?
- Is the block visible in logs without exposing the sensitive payload?
- Does the hook behave correctly for chat, responses, image, audio, and embeddings call types?
- What is the rollback path if the hook breaks production traffic?
