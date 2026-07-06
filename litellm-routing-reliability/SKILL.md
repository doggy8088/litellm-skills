---
name: litellm-routing-reliability
description: 設計、教學或審查 LiteLLM Router、load balancing、fallback、retry、timeout、rate limits、health checks 與可靠性策略時使用。
---

# LiteLLM Routing Reliability

## 使用時機

當任務需要讓 LiteLLM 在多個 deployments、regions、providers 或 model groups 之間可靠地路由時，使用此技能。

## 官方依據

- Router - Load Balancing：https://docs.litellm.ai/docs/routing
- Proxy - Load Balancing：https://docs.litellm.ai/docs/proxy/load_balancing
- Fallbacks：https://docs.litellm.ai/docs/proxy/reliability
- Reliable completions：https://docs.litellm.ai/docs/completion/reliable_completions
- Health Checks：https://docs.litellm.ai/docs/proxy/health
- Life of a Request：https://docs.litellm.ai/docs/proxy/architecture

## 核心判斷

- Load balancing：同一個 user-facing `model_name` 底下有多個 deployments，LiteLLM 依策略分流。
- Retry：同一個請求失敗後，針對目前 deployment 或策略設定重試。
- Fallback：重試仍失敗後，切到另一個 model group 或 fallback model。
- Rate limit routing：用 `rpm`、`tpm`、Redis 與 routing strategy 避開已滿載 deployments。
- Health check：用 proxy 健康端點判斷服務本身、readiness、liveliness 與 provider health。

## 工作流程

1. 建立 `model_list`，把同一個對外 alias 對應到多個 deployments。
2. 為每個 deployment 寫清楚 `rpm`、`tpm`、region、provider、api_base 與用途。
3. 在 `router_settings` 設定 `routing_strategy`，常見值包含 `simple-shuffle`、`least-busy`、`usage-based-routing`、`latency-based-routing`。
4. 設定 `num_retries` 與 `timeout`，避免長時間卡住 agent 工作流。
5. 設定 `fallbacks`，清楚標示 primary model group 與 fallback model group。
6. 若多個 proxy instance 共用路由狀態，設定 Redis；不要只依賴單一 instance 記憶體。
7. 若要把 `rpm`、`tpm` 變成硬性限制，評估 `enforce_model_rate_limits`。
8. 建立測試：正常路由、rate limit 模擬、fallback 模擬、provider timeout、全部 provider 失敗。
9. 在正式環境加入 `/health`、`/health/readiness`、`/health/liveliness` 監控。
10. 交付時輸出一張路由矩陣，列出每個 alias 的 provider、region、fallback 與成本層級。

## Config 範例

```yaml
model_list:
  - model_name: course-chat
    litellm_params:
      model: azure/course-gpt-eu
      api_base: os.environ/AZURE_EU_API_BASE
      api_key: os.environ/AZURE_EU_API_KEY
      rpm: 60
  - model_name: course-chat
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY
      rpm: 120
  - model_name: course-chat-fallback
    litellm_params:
      model: anthropic/claude-3-5-haiku-latest
      api_key: os.environ/ANTHROPIC_API_KEY

router_settings:
  routing_strategy: least-busy
  num_retries: 2
  timeout: 30
  fallbacks:
    - course-chat: ["course-chat-fallback"]
```

## 教學練習

- 讓學生用同一個 `model_name` 建立兩個 deployments，觀察路由分布。
- 用 `mock_testing_fallbacks=true` 驗證 fallback 是否真的被觸發。
- 設定很低的 `rpm`，觀察 routing decision 與 429 行為。
- 模擬一個 provider timeout，要求學生解釋 retry 與 fallback 的差異。

## 驗收檢查

- 每個 user-facing alias 都有明確 primary 與 fallback 策略。
- `num_retries`、`timeout`、fallback 順序不互相矛盾。
- 多 instance 部署時有 Redis 或等效共享狀態設計。
- health endpoint 已納入部署檢查。
- 成本較高的 fallback 不會在未限制情況下被大量流量打爆。

## 常見錯誤

- 用 fallback 補救所有問題，卻沒有處理 timeout 與 retry。
- fallback 指到成本高很多的模型，沒有 budget 或告警。
- 用同一個 provider、同一個 region 當唯一 fallback，無法抵抗 provider 或區域故障。
- 沒有測試 rate limit 情境，只測 happy path。
