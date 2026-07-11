---
name: litellm-guardrails-safety
description: 設定或審查 LiteLLM 內容安全、PII masking、prompt injection、tool permission、MCP guardrails 與 call hooks。當任務需要修改、拒絕或限制 LLM／tool／MCP 請求時使用；MCP server 註冊與一般 virtual-key 預算改用對應專門技能。
---

# LiteLLM Guardrails Safety

## 工作流程

1. 建立 threat model，分類輸入、輸出、tool、MCP、資料外洩與越權風險。
2. 查核 LiteLLM 版本、guardrail provider、mode、授權與失敗語意。
3. 選擇 `pre_call`、`post_call`、`pre_mcp_call` 等正確執行點。
4. 必須執行的防護設為 default-on；工具權限採預設拒絕及最小 allowlist。
5. 對工具名稱與參數同時限制，避免只允許名稱卻放任高風險 arguments。
6. 明確定義 provider error 與 guardrail error 的 fail-open 或 fail-closed 行為。
7. 測試 allow、deny、mask、rewrite、provider error 與 guardrail error。

需要 tool permission config、PII config 與測試規格時，讀取 [實驗與參考](references/guide.md)。

## 安全底線

- 高風險安全控制採 fail-closed，除非 threat model 明確證明可降級。
- 不以 guardrail 取代 key、team、model access、sandbox 或 audit log。
- Allow 規則不得使用無限制的 `.*`。
- 自訂 hook 不記錄 secret、完整敏感 prompt 或未遮罩個資。

## 驗收

- Threat model 與每條規則可追溯。
- 未匹配工具預設拒絕。
- 參數限制有合法與違規 fixture。
- Guardrail 故障行為可重現，且高風險路徑不會靜默放行。
