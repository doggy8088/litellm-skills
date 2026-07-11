---
name: litellm-proxy-gateway
description: 建立或審查 LiteLLM Proxy 的基礎拓樸、model alias、config.yaml、啟動方式與 OpenAI-compatible client。當任務是架設集中式模型入口或遷移既有 OpenAI client 時使用；成本治理、觀測、安全、可靠性與 MCP 細節必須搭配對應專門技能。
---

# LiteLLM Proxy Gateway

## 工作流程

1. 判斷單一應用程式是否使用 SDK 即可；只有集中權限、治理或共用入口才採 Proxy。
2. 查核 LiteLLM 版本與 config schema。
3. 建立最小 `model_list`，以穩定 `model_name` 對應 provider-prefixed model。
4. 從環境變數注入 provider key、master key、database URL 與 Redis secret。
5. 啟動 Proxy，以 OpenAI SDK 驗證 alias 與錯誤路徑。
6. 依需求載入 `litellm-routing-reliability`、`litellm-cost-governance`、`litellm-observability`、`litellm-guardrails-safety` 或 `litellm-mcp-skills-gateway`。
7. 交付開發、測試、正式環境差異及驗證證據。

需要 config、client smoke test 或版本注意事項時，讀取 [實驗與參考](references/guide.md)。

## 安全底線

- 不在設定、程式碼、命令歷史或教材中放真實 secret。
- 正式 client 不使用 master key。
- 不把 provider key 與 Proxy virtual key 視為同一權限層。
- 對外服務使用 TLS、受控網路與最小公開端點；本機 HTTP 範例不得直接沿用到正式環境。

## 驗收

- Config 可載入且沒有真實 secret。
- OpenAI-compatible client 能透過 alias 完成 smoke request。
- 未授權 key 被拒絕。
- 專門治理需求已路由到對應 skill，而非在本技能內自行簡化。
