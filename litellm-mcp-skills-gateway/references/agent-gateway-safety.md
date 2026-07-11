# Agent Gateway 安全參考

最後查證日期：2026-07-12。整合 MCP、Skills Gateway、agent 與 LiteLLM 維運控制時，精確 schema 請重新查核 [MCP](https://docs.litellm.ai/docs/mcp) 與 [Skills Gateway](https://docs.litellm.ai/docs/skills_gateway)。

## MCP 設定缺口

若缺少可用的 MCP server 設定，先依官方 LiteLLM MCP 文件確認 schema，再套用 key、budget、log 與 backup 等維運控制。

## 控制層

- virtual key allowlist 限制 agent 可呼叫的 model alias。
- budget 與 `budget_duration` 限制事故影響範圍。
- MCP permission 限制可見的 server 與 tool。
- tool permission guardrail 限制產生的 tool call。
- MCP guardrail 檢查 MCP input 與 execution。
- observability 應能以 key、team、agent、request 與 tool 追溯操作。
- backup 與 export manifest 為管理異動保留 rollback 證據。

## 安全使用官方 Skills

官方 `litellm-skills` 可管理實際 Proxy 資源，使用時應：

1. 先在測試 Proxy 安裝或執行。
2. 儘可能使用最低權限的管理憑證。
3. 破壞性操作必須先 dry-run，或提供明確 change list。
4. 記錄 user、team、key、model、MCP server、agent 與 usage 的變更。
5. 操作旁應附 rollback 步驟，尤其是刪除 key 或 model 時。

## 審查清單

- agent 只能看見任務所需的 MCP tool。
- write、delete 與 external-send tool 具有參數限制。
- tool-call log 不包含原始 secret 或非必要的 prompt 內容。
- 管理操作與一般推論 key 分離。
- budget 與 usage report 可快速辨識失控的 agent 行為。
