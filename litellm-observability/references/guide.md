# 可觀測性實驗與參考

最後查證日期：2026-07-11。參考 [Proxy Logging](https://docs.litellm.ai/docs/proxy/logging) 與 [OpenTelemetry integration](https://docs.litellm.ai/docs/observability/opentelemetry_integration)。OpenTelemetry v2 目前為 opt-in；使用前查核相容版本。

## 隱私優先範例

```yaml
litellm_settings:
  success_callback: [langfuse]
  failure_callback: [langfuse]
  turn_off_message_logging: true
```

不同 callback 對設定鍵的支援可能不同，必須以實際版本文件與 trace 驗證，不能只確認環境變數存在。

## OpenTelemetry v2

在相容版本中以 `LITELLM_OTEL_V2=true` 啟用完整 request trace。OTLP HTTP 與 gRPC 的套件、protocol、endpoint 與 headers 不同；使用官方文件對應設定。

## 核心實驗

- 使用固定 request ID 執行成功、timeout、fallback、budget blocked、guardrail blocked。
- 驗收 trace 能關聯事件順序、model、provider、latency 與 status。
- 在 prompt 放入明確測試字串，確認第三方事件中不存在該字串。
- 保存查詢步驟與已遮罩的 trace 證據，不只保存截圖。
