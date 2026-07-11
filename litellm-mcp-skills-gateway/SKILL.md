---
name: litellm-mcp-skills-gateway
description: 設計或審查 LiteLLM MCP Gateway、MCP permissions、toolsets、MCP REST API、Skills Gateway 與官方管理 skills。當任務要註冊工具來源、授權 agent 工具或發布 skills 時使用；一般 tool calling 與 guardrail 規則分別搭配 SDK 或安全技能。
---

# LiteLLM MCP Skills Gateway

## 工作流程

1. 區分 agent 使用 MCP tool、直接呼叫 MCP REST API、發布 skill，以及管理 LiteLLM Proxy 四種任務。
2. 查核 LiteLLM 版本、transport、auth、permissions、toolsets 與 Skills Gateway schema。
3. 註冊 MCP server 前審查來源、認證、資料流、可用工具與健康狀態。
4. 以 key、team、organization 與 agent 權限的交集建立最小 toolset。
5. 高風險工具搭配 `litellm-guardrails-safety` 限制 input 與執行行為。
6. 外部 skill 固定至已審查 commit SHA，記錄內容雜湊與所需權限。
7. 在隔離 Proxy 測試 list、allowed call、denied call、來源更新與撤銷。

需要供應鏈規則、Skills Gateway 流程與實驗規格時，讀取 [實驗與參考](references/guide.md)。

## 安全底線

- 不把整個 MCP server 的所有 tools 預設開放。
- 不讓學生持有正式 Proxy admin key。
- 管理 users、keys、models 或 agents 的 skill 使用最小權限與人工核准。
- Git branch 或可變 tag 不視為可審查的正式 skill 來源。

## 驗收

- 每個 agent 可用工具可追溯至 key、team、organization 與 agent 設定。
- 未授權工具不可見且不可呼叫。
- Skill 來源、commit SHA、雜湊、權限與升級紀錄完整。
- 測試不對正式 Proxy 或正式 MCP 資料執行寫入。
