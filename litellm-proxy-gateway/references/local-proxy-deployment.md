# Proxy Deployment Reference

Use this when a task involves Compose-based LiteLLM deployment, Postgres-backed state, mounted config, or custom callback loading.

## Deployment Shape

- Use an explicit LiteLLM image tag, preferably a currently verified stable tag, and expose the proxy on port `4000` unless the deployment requires a different port.
- `postgres:16-alpine` is the backing database with a named Docker volume.
- A typical deployment mounts a local proxy config file to `/app/config.yaml` and mounts custom hook modules to `/app/custom_hooks`.
- The command uses `--config /app/config.yaml --detailed_debug --port 4000`.
- Compose waits for Postgres health and limits json-file logs with `max-size: 10g` and `max-file: 2`.

## Config Patterns

- Azure entries use `litellm_params.model: azure/<deployment-name>`.
- Multiple entries can share a `model_name` for load balancing; suffixes such as `-eu2`, `-sc`, or `-sn` can also expose explicit region aliases.
- Several entries set `model_info.mode: responses`; image entries use `mode: image_generation`.
- OpenAI-compatible non-OpenAI backends use `custom_llm_provider: openai`, `api_base`, `api_key`, and explicit token pricing.
- `general_settings.store_model_in_db: true` supports database-managed models.
- `general_settings.store_prompts_in_spend_logs: true` is powerful but sensitive; warn about prompt/response retention before copying this setting.
- `litellm_settings.upperbound_key_generate_params` sets a default generated-key budget ceiling.
- `litellm_settings.callbacks` can load a mounted hook instance such as `custom_hooks.proxy_policy_hook.proxy_handler_instance`.
- `router_config.optional_pre_call_checks` includes responses deployment, deployment affinity, session affinity, and encrypted content affinity checks.

## Custom Hook Integration

The bundled template in the `litellm-guardrails-safety` skill at `scripts/custom_hooks/proxy_policy_hook.py`, or an equivalent mounted hook, can register custom pricing, rewrite user-facing aliases to backend model names, and block `input[].type=custom_tool_call` for models that do not support that Responses API replay shape.

When editing this pattern:

- Keep pricing registration idempotent.
- Fail with a clear `HTTPException` for blocked request shapes.
- Avoid hardcoded personal allowlists; move temporary exceptions to configuration.
- Test hook import inside the container before assuming the callback is active.

## Security Notes

Operational repositories often accumulate secret-like material: virtual keys in CSVs, hardcoded admin-token examples in scripts, SAS URLs in upload helpers, and browser/API captures. Do not paste those values into generated examples. If the user plans to publish or share a repository, recommend scrubbing or rotating exposed credentials.

## Verification

- `docker compose ps` shows LiteLLM and Postgres healthy.
- `/health`, `/health/readiness`, or the configured health endpoint responds.
- A virtual key can call a cheap alias through OpenAI SDK.
- Spend tracking writes rows only after Postgres is reachable.
- Custom hook behavior is observable with one allowed request and one intentionally blocked request.
