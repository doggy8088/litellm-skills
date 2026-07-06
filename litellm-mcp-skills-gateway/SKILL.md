---
name: litellm-mcp-skills-gateway
description: 設計、教學或審查 LiteLLM MCP Gateway、MCP REST API、MCP permissions、toolsets、Skills Gateway、official litellm-skills 與 agent gateway 整合時使用。
---

# LiteLLM MCP Skills Gateway

## 使用時機

當任務需要讓 agents 使用 MCP tools、限制 tool 權限、建立 toolsets、透過 Skills Gateway 發布/探索 skills，或評估官方 `litellm-skills` 是否適合課堂或 live proxy 管理時，使用此技能。

## 官方依據

- MCP Overview：https://docs.litellm.ai/docs/mcp
- Using your MCP：https://docs.litellm.ai/docs/mcp_usage
- MCP REST API：https://docs.litellm.ai/docs/mcp_rest_api
- MCP Permission Management：https://docs.litellm.ai/docs/mcp_control
- MCP Guardrails：https://docs.litellm.ai/docs/mcp_guardrail
- Skills Gateway：https://docs.litellm.ai/docs/skills_gateway
- LiteLLM Skills：https://docs.litellm.ai/docs/tutorials/claude_code_skills
- LiteLLM Agent Platform Introduction：https://docs.litellm-agent-platform.ai/introduction
- v1.83.3 release notes：https://docs.litellm.ai/release_notes/v1.83.3/v1-83-3-stable

## 核心概念

- MCP Gateway：用固定 endpoint 管理多個 MCP servers，並以 key、team、organization 或 agent 權限控管工具。
- MCP REST API：當已知要呼叫哪個工具時，可直接用 HTTP list/call tools。
- MCP permissions：權限應採交集思維；key、team、agent 自身限制都可能縮小可用工具。
- Toolsets：把多個 MCP servers 的部分工具整理成可授權的工具集合。
- Skills Gateway：作為 skills registry，讓組織註冊、發布、探索 Claude Code skills。
- Official `litellm-skills`：官方 live proxy 管理技能組，可建立 users、teams、keys、models、MCP servers、agents 並查 usage。

## 工作流程

1. 先判斷需求是「agent 使用工具」還是「agent 管理 LiteLLM proxy」。
2. 若是使用工具，先註冊 MCP server，確認 transport、auth、tool list 與 health。
3. 設定 key/team/agent 的 MCP server 與 tool permissions，避免整個 server 無限制開放。
4. 若工具很多，建立 toolset，只授權課堂任務需要的工具。
5. 若 client 使用 Responses API 或 Chat Completions，確認 `tools` 參數格式與 `allowed_tools`。
6. 若要直接呼叫工具，使用 MCP REST API 的 list/call endpoints，保留 request/response log。
7. 對高風險 MCP tool 加上 MCP guardrails 與 tool permission guardrail。
8. 若要管理 live LiteLLM proxy，優先引用官方 `litellm-skills`，不要自己拼未驗證 curl。
9. 若要發布課堂 skills，使用 Skills Gateway 註冊 GitHub URL，並透過 Skill Hub 發布。
10. 交付時列出每個 agent 可用 MCP server、tools、toolsets、guardrails、budgets 與 audit 路徑。

## 官方 LiteLLM Skills 摘要

官方 `litellm-skills` 目前包含以下類別：

- Users：`/add-user`、`/update-user`、`/delete-user`
- Teams：`/add-team`、`/update-team`、`/delete-team`
- API Keys：`/add-key`、`/update-key`、`/delete-key`
- Organizations：`/add-org`、`/delete-org`
- Models：`/add-model`、`/update-model`、`/delete-model`
- MCP Servers：`/add-mcp`、`/update-mcp`、`/delete-mcp`
- Agents：`/add-agent`、`/update-agent`、`/delete-agent`
- Usage：`/view-usage`

課堂使用時，先在測試 proxy 操作，不要讓學生直接拿正式 proxy admin key。

## 教學練習

- 註冊一個只讀 MCP server，讓學生列出 tools 並呼叫單一安全工具。
- 建立 agent-specific MCP permission，驗證 agent 只能看到允許的工具。
- 建立一個 toolset，讓兩組學生拿到不同工具組合。
- 用 Skills Gateway 註冊一個 GitHub skill URL，發布到 Skill Hub。
- 安裝官方 `litellm-skills` 到測試環境，執行 `/view-usage` 查詢課堂用量。

## 驗收檢查

- 每個 agent 的工具權限可從 key/team/agent 設定追溯。
- 高風險工具沒有全域開放。
- MCP tool list 與 allowed tools 有測試證據。
- Skills Gateway 發布的 skill 來源是可審查的 GitHub URL。
- 官方 live proxy 管理技能只用在測試 proxy 或受控正式流程。

## 常見錯誤

- 把 MCP server 接上後就把所有 tools 開給所有 keys。
- 忽略 agent 自身權限，導致 autonomous agent 可用工具過多。
- 未對 MCP tool input 做 PII 或資料外洩檢查。
- 讓學生使用正式 admin key 練習 `/add-model` 或 `/delete-key`。

## 使用情境與提示詞範例

- **情境 1：在 LiteLLM 中配置 MCP Servers**
  * *提示詞*：「我想讓 LiteLLM Proxy 整合 Model Context Protocol (MCP)。請在 `config.yaml` 中配置一個 MCP server（例如連接到本地 sqlite 資料庫的 server），並示範如何讓 Proxy 底下的模型能動態使用該 MCP 工具。」
- **情境 2：設定 MCP 工具的權限與過濾（MCP Permissions）**
  * *提示詞*：「我們有很多 MCP 工具，但我想限制特定的虛擬金鑰只能使用讀取類型的 MCP 工具，不能執行寫入或刪除。請教我如何在 LiteLLM Gateway 中設定 MCP 工具的權限控管。」
- **情境 3：Skills Gateway 與官方技能評估**
  * *提示詞*：「請幫我分析 LiteLLM 官方的 Skills Gateway 與一般的 MCP gateway 有何不同？並寫出如何使用官方 `litellm-skills` 來讓 Agent 能自主管理 Proxy 中的 users 和 keys 的架構與安全性評估。」
