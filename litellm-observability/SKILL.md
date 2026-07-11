---
name: litellm-observability
description: 設定或審查 LiteLLM callbacks、logging、OpenTelemetry、request correlation、spend logs 與故障診斷。當任務要追蹤延遲、tokens、cost、provider、fallback 或 guardrail 事件時使用；權限政策與 guardrail 規則改用安全技能。
---

# LiteLLM Observability

## 工作流程

1. 定義診斷問題、必要欄位、資料分類、保留期限與存取者。
2. 選擇 SDK callback、Proxy logging、OpenTelemetry 或外部平台。
3. 查核 LiteLLM 版本、callback schema、OpenTelemetry v1/v2 與額外套件。
4. 預設不傳完整 prompt、response、secret 或敏感 metadata 到第三方。
5. 建立 request ID 關聯 client、Proxy、provider、guardrail、MCP 與 DB 事件。
6. 測試成功、provider error、timeout、budget exceeded、fallback 與 guardrail blocked。
7. 交付查詢方式、重現步驟與實際 trace 證據。

需要安全設定、OpenTelemetry 注意事項與實驗規格時，讀取 [實驗與參考](references/guide.md)。

## 安全底線

- 第三方觀測預設關閉 message logging。
- 不把 API key、Authorization header、資料庫 URL 或完整敏感內容寫入 log。
- 啟用內容記錄前必須完成資料分類、遮罩、保留期限及第三方資料處理審查。
- Failure callback 也必須套用相同的遮罩政策。

## 驗收

- 每個請求可由 request ID 關聯必要事件。
- 成功與至少四種失敗類型可查。
- Trace 或 log 不包含測試 secret 與未遮罩敏感資料。
- 查詢結果能解釋一次 fallback 或 guardrail 事件。
