# LiteLLM 教學 Agent Skills

本目錄是一組給學生使用的 LiteLLM agent skills。定位是「教學與實作引導」，不是直接取代官方的 live proxy 管理技能。

## 官方現況

LiteLLM 官方已提供 `litellm-skills`，用途是讓支援 Agent Skills 標準的工具透過 `curl` 管理 live LiteLLM proxy。官方技能涵蓋 users、teams、keys、orgs、models、MCP servers、agents 與 usage 查詢。

官方來源：

- LiteLLM Skills 文件：https://docs.litellm.ai/docs/tutorials/claude_code_skills
- 官方 GitHub repo：https://github.com/BerriAI/litellm-skills
- Skills Gateway：https://docs.litellm.ai/docs/skills_gateway

## 本技能組

| 技能 | 教學用途 |
| --- | --- |
| `litellm-sdk-basics` | 使用 LiteLLM Python SDK 建立 completion、streaming、structured output 與 tool calling 練習 |
| `litellm-proxy-gateway` | 設計 OpenAI-compatible LiteLLM Proxy 與 `config.yaml` |
| `litellm-routing-reliability` | 練習 Router、load balancing、fallback、retry、timeout 與健康檢查 |
| `litellm-cost-governance` | 建立 spend tracking、virtual keys、budgets、tags 與成本歸因流程 |
| `litellm-observability` | 設定 callbacks、logging、OpenTelemetry 與成本/請求追蹤 |
| `litellm-guardrails-safety` | 設定 guardrails、tool permission、MCP guardrails 與 proxy call hooks |
| `litellm-mcp-skills-gateway` | 練習 MCP Gateway、MCP permissions、toolsets、Skills Gateway 與 official skills 評估 |

## 建議教學順序

1. `litellm-sdk-basics`
2. `litellm-proxy-gateway`
3. `litellm-routing-reliability`
4. `litellm-cost-governance`
5. `litellm-observability`
6. `litellm-guardrails-safety`
7. `litellm-mcp-skills-gateway`

## 使用原則

- 需要版本、模型、價格、功能支援狀態時，必須重新查 LiteLLM 官方文件或官方 GitHub。
- 不要在教材、投影片或 repo 中提交 API key、proxy master key、virtual key 或資料庫連線密碼。
- 學生練習應使用本機 proxy、測試 key、低成本模型與極小 budgets。
- 若要管理 live proxy，優先參考官方 `litellm-skills`，並將 admin key 權限、操作審計與回復流程納入課堂要求。
