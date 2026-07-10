# Example Routing Patterns

Use this when a task depends on multi-region LiteLLM routing, endpoint-mode selection, or deployment-affinity behavior.

## Alias Styles

- Repeated `model_name` entries imply a load-balanced model group.
- Region-suffixed aliases such as `-eu2`, `-sc`, `-ae`, `-je`, `-sn`, `-kc`, `-ce`, or `-uks` expose explicit routing choices.
- Treat names in deployment examples as local aliases. Do not assume they are public model names or official availability.

## Endpoint Modes

- Chat-style aliases can be tested with `/chat/completions`.
- `model_info.mode: responses` aliases should be tested with `/v1/responses`.
- `model_info.mode: image_generation` aliases need image-generation compatible tests and cost fields such as `output_cost_per_image`.
- Transcription aliases should be tested with multipart `/v1/audio/transcriptions`, not chat completions.

## Router Controls In Example Deployments

- `enable_loadbalancing_on_batch_endpoints: true` broadens load-balancing behavior to batch-style endpoints.
- `router_config.optional_pre_call_checks` contains:
  - `responses_api_deployment_check`
  - `deployment_affinity`
  - `session_affinity`
  - `encrypted_content_affinity`

Use these as clues that requests may be pinned or filtered before normal routing.

## Route Matrix Template

When changing or reviewing routing, produce a compact matrix:

| Alias | Provider | Region | Mode | Primary/Fallback | Cost Class | Test Endpoint |
| --- | --- | --- | --- | --- | --- | --- |
| `course-chat` | Azure | East US 2 | chat | primary | low | `/chat/completions` |

## Failure Tests

- Disable or misconfigure one deployment and confirm the alias still succeeds if another deployment exists.
- Send a Responses API request to a chat-only alias and confirm the error is clear.
- Simulate a timeout and confirm the client does not hang indefinitely.
- Verify expensive or scarce fallback aliases are budget-limited.
- Check logs for which deployment actually served the request.
