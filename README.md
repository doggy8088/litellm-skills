# LiteLLM 教學 Agent Skills

本專案提供 7 個以教學與實作引導為目的的 LiteLLM Agent Skills。它們不取代 LiteLLM 官方用於管理 live proxy 的 skills。

* * *

## 安裝與確認

將各 `litellm-*` 目錄複製或符號連結到 Agent Skills 相容客戶端的專案層或使用者層 skills 目錄。不同客戶端的搜尋路徑不完全相同，應以該客戶端文件為準。

安裝後，以代表性提示詞確認 agent 能載入對應技能，例如：

```text
使用 litellm-sdk-basics，設計一個不含真實 API key 的 completion 練習。
```

維護者執行以下命令驗證全部技能：

```sh
python scripts/validate_skills.py
```

外部連結由每週排程執行 `python scripts/check_links.py`；一般 pull request 不受暫時性網路錯誤影響。

* * *

## 技能路由

| 技能 | 主責範圍 | 不主責的範圍 |
| --- | --- | --- |
| `litellm-sdk-basics` | Python SDK、completion、streaming、structured output、tool calling | Proxy 維運與多租戶治理 |
| `litellm-proxy-gateway` | Proxy 啟動、model alias、基礎 config、OpenAI-compatible client | 成本、觀測、安全與可靠性細節 |
| `litellm-routing-reliability` | Router、load balancing、retry、timeout、fallback、health | 預算政策與 trace 後端 |
| `litellm-cost-governance` | Virtual keys、budgets、rate limits、成本歸因 | 一般 Proxy 拓樸與觀測平台 |
| `litellm-observability` | Callbacks、logging、OpenTelemetry、trace 與除錯 | 存取控制與 guardrail 規則 |
| `litellm-guardrails-safety` | 內容、PII、tool、MCP guardrails 與 call hooks | MCP server 註冊與一般 key 預算 |
| `litellm-mcp-skills-gateway` | MCP Gateway、permissions、toolsets、Skills Gateway | 一般 LLM tool calling 與 guardrail 實作細節 |

複合任務可同時使用多個技能：先以 `litellm-proxy-gateway` 決定基礎拓樸，再依需求加入可靠性、成本、觀測、安全或 MCP 專門技能。

* * *

## 教學路徑

| 階段 | Skill | 先備能力 | 核心成果 |
| --- | --- | --- | --- |
| 1 | `litellm-sdk-basics` | Python 與環境變數 | 可安全呼叫、驗證與處理 SDK 回應 |
| 2 | `litellm-proxy-gateway` | HTTP 與 YAML | 可啟動 Proxy 並透過 alias 呼叫模型 |
| 3 | `litellm-routing-reliability` | Proxy 基礎 | 可重現 retry、timeout 與 fallback |
| 4 | `litellm-cost-governance` | Proxy 與 virtual key | 可限制並歸因學生用量 |
| 5 | `litellm-observability` | Proxy 請求生命週期 | 可用 trace 與 log 解釋失敗 |
| 6 | `litellm-guardrails-safety` | 權限與威脅模型 | 可驗證 allow、deny、mask 與 fail-closed |
| 7 | `litellm-mcp-skills-gateway` | Proxy、安全與工具概念 | 可建立最小權限 MCP 工具集合 |

完成七個核心實驗後，使用 [跨技能整合實驗](curriculum/capstone.md) 驗證端到端治理能力。

* * *

## 共通安全與維護原則

- 需要版本、模型、價格、功能或授權方案資訊時，重新查核 LiteLLM 官方文件或官方 GitHub。
- 不提交 API key、proxy master key、virtual key、資料庫連線密碼或觀測平台 secret。
- 學生練習使用本機或隔離 proxy、測試 key、低成本模型及極小預算。
- 不以用戶端可控制的 metadata 作為可信任的授權或預算邊界。
- 管理型 skills 與外部 Git 來源固定到已審查的 commit SHA；更新後重新審查。
- 管理 live proxy 時優先採用 LiteLLM 官方 skills，並納入最小權限、操作稽核與回復流程。

官方來源：[LiteLLM 文件](https://docs.litellm.ai/)、[LiteLLM Skills](https://docs.litellm.ai/docs/tutorials/claude_code_skills)、[Skills Gateway](https://docs.litellm.ai/docs/skills_gateway)、[Agent Skills 規格](https://agentskills.io/specification)。
