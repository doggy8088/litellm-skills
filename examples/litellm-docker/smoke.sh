#!/usr/bin/env sh
set -eu

BASE_URL="${LITELLM_BASE_URL:-http://localhost:${LITELLM_PORT:-4000}}"
KEY="${LITELLM_MASTER_KEY:?請先設定 LITELLM_MASTER_KEY，或從 .env 載入}"

printf '%s\n' "== readiness =="
curl --fail-with-body --silent --show-error "$BASE_URL/health/readiness"
printf '\n%s\n' "== chat completion =="
curl --fail-with-body --silent --show-error \
  -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"local-gpt","messages":[{"role":"user","content":"Reply with exactly: LiteLLM OK"}],"max_tokens":16}'
printf '\n'
