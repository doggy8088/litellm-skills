# LiteLLM 教學整合實驗

## 目標

在隔離環境建立一個具備 alias、fallback、virtual key、成本歸因、trace、guardrail 與只讀 MCP tool 的最小 LiteLLM Proxy，並提交可重現證據。

* * *

## 先備與限制

- 已完成七個 skills 的核心實驗。
- 預設使用 mock provider、測試 Postgres／Redis 及只讀測試 MCP server。
- 不連線正式 Proxy，不使用正式資料或正式 admin key。
- 真實 provider smoke test 為選跑，最多一筆低成本請求。

* * *

## 必備能力

| 能力 | 最小要求 | 驗收證據 |
| --- | --- | --- |
| Proxy | `course-chat` alias | OpenAI-compatible client 成功回應 |
| Reliability | Primary timeout 後 fallback | Trace 顯示順序與命中的 deployment |
| Cost | 24 小時測試 key、單一模型、極小預算 | Key info 與遮罩後 spend log |
| Observability | Request ID 串接成功與失敗事件 | 不含 prompt 測試敏感字串的 trace |
| Guardrail | 未知工具預設拒絕 | 規則 ID、狀態碼與 audit event |
| MCP | 單一只讀 toolset | Allowed call 成功、denied call 失敗 |

* * *

## 執行順序

1. 固定 LiteLLM 與測試服務版本，記錄查證日期。
2. 啟動測試資料庫、Redis、mock provider 與只讀 MCP server。
3. 載入 Proxy config，建立限時 virtual key。
4. 執行正常請求並確認 alias、spend 與 trace。
5. 觸發 primary timeout，確認 fallback 與 request ID 關聯。
6. 觸發未知工具、違規參數、未授權 MCP tool、偽造 tag 與 budget exceeded。
7. 搜尋 log 與 trace，確認沒有 key、Authorization header 或指定敏感測試字串。
8. 撤銷 key、移除 MCP 註冊、清除測試資料並停止服務。

* * *

## 完成定義

- 所有成功與拒絕案例都有命令、預期結果、實際狀態碼及 request ID。
- Fallback 沒有繞過模型 allowlist、guardrail、資料區域或預算。
- 用戶端無法改寫安全關鍵成本歸因。
- 證據包不含任何可用 secret 或未遮罩敏感內容。
- 另一位執行者可只靠提交內容重現離線測試。
