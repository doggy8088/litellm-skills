# Routing 實驗與參考

最後查證日期：2026-07-11。參考 [Fallbacks](https://docs.litellm.ai/docs/proxy/reliability)、[Routing](https://docs.litellm.ai/docs/routing) 與 [Health Checks](https://docs.litellm.ai/docs/proxy/health)。

## Fallback 設定

```yaml
router_settings:
  num_retries: 2
  timeout: 30
  fallbacks:
    - course-chat: [course-chat-fallback]
```

`mock_testing_fallbacks` 是請求欄位，不是 config 或環境變數：

```json
{
  "model": "course-chat",
  "messages": [{"role": "user", "content": "ping"}],
  "mock_testing_fallbacks": true
}
```

## 核心實驗

- 固定發送 20 筆 mock requests，記錄 deployment 分布。
- 各執行一次 429、timeout、primary failure、all-failed fixture。
- 驗收：fallback fixture 必須命中指定 fallback；all-failed 必須回傳非 2xx 且不洩漏 secret。
- `/health` 會實際呼叫模型；一般編排 probe 使用 `/health/readiness` 與 `/health/liveliness`。
