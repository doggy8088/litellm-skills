---
name: litellm-observability
description: 設定、教學或審查 LiteLLM logging、callbacks、OpenTelemetry、request/response observability、spend logs 與除錯流程時使用。
---

# LiteLLM Observability

## 使用時機

當任務需要知道 LiteLLM 請求怎麼走、哪個模型慢、哪個 key 花錢、哪個 guardrail 或 provider 失敗，或要串接 Langfuse、MLflow、Helicone、Lunary、OpenTelemetry、Datadog 等工具時，使用此技能。

## 官方依據

- Getting Started - Logging & Observability：https://docs.litellm.ai/docs/
- Proxy Logging：https://docs.litellm.ai/docs/proxy/logging
- OpenTelemetry integration：https://docs.litellm.ai/docs/observability/opentelemetry_integration
- Custom callbacks：https://docs.litellm.ai/docs/observability/custom_callback
- Modify / Reject Incoming Requests：https://docs.litellm.ai/docs/proxy/call_hooks
- Spend Tracking：https://docs.litellm.ai/docs/proxy/cost_tracking
- Life of a Request：https://docs.litellm.ai/docs/proxy/architecture

## 工作流程

1. 先決定觀測層級：SDK callback、Proxy callback、Proxy logging、OpenTelemetry trace、spend logs 或外部觀測平台。
2. 定義必須追蹤的欄位：request id、user、team、key alias、model alias、provider、latency、tokens、cost、status、fallback、guardrail result。
3. SDK 任務可用 `litellm.success_callback` 或自訂 callback 擷取 `response_cost`。
4. Proxy 任務可在 `config.yaml` 設定 `litellm_settings.success_callback`、`failure_callback` 或 `callbacks`。
5. 若要全請求 trace，評估 OpenTelemetry v2，並以環境變數啟用。
6. 若紀錄 request/response，先確認是否包含個資、商業資料、學生作業或 secret。
7. 對大型 payload 設定截斷策略，避免 debug log 造成成本與資料外洩。
8. 建立錯誤分類：auth、rate limit、provider error、timeout、budget exceeded、guardrail blocked、MCP failure。
9. 建立課堂儀表板或輸出表格，讓學生能看見同一任務在不同模型上的 latency、tokens 與 cost。
10. 交付時附上「如何重現與查詢」步驟，而不只附截圖。

## Proxy 設定範例

```yaml
model_list:
  - model_name: course-chat
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]
```

## OpenTelemetry 檢查

- 設定 OTEL exporter、endpoint 與 headers。
- 若使用 LiteLLM Proxy 的 OpenTelemetry v2，確認 `LITELLM_OTEL_V2=true`。
- 確認 trace 能串起 HTTP request、auth、guardrails、LLM call 與 DB writes。
- 在非正式環境先測試 request/response attributes 是否符合隱私政策。

## 教學練習

- 寫一個 SDK success callback，印出 cost、model 與 total tokens。
- 在 proxy 開啟一個 logging callback，讓學生比較成功與失敗請求的欄位。
- 用 tags 分組後，查詢每個 lab 的 spend。
- 模擬 rate limit 與 budget exceeded，要求學生從 logs 判斷失敗原因。

## 驗收檢查

- 每個請求能被追到 key、user 或 team。
- 成本、latency、model、provider 與錯誤類型可查。
- logging 不會永久保存未遮罩 secret 或敏感內容。
- OpenTelemetry 設定有實際 trace 證據，不只是環境變數。
- 學生能用觀測資料解釋一次 fallback 或 guardrail 事件。

## 常見錯誤

- 把 debug log 當正式觀測方案。
- 只紀錄成功請求，導致無法分析 provider error 或 budget exceeded。
- 沒有 request id，無法把 client log、proxy log 與 provider log 串起來。
- 把完整 prompt/response 傳到第三方平台前未做資料分類。
