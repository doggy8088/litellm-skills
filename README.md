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

## 使用情境與提示詞範例

以下為本技能組在實際開發與教學時的 3 種使用情境與對應的 AI 提示詞（Prompt）範例：

### 1. `litellm-sdk-basics` (LiteLLM SDK 基礎)
*   **情境 1：基礎 Completion 與異常處理**
    *   *提示詞範例*：「幫我用 LiteLLM Python SDK 寫一個基礎 of completion 腳本，使用 `openai/gpt-4o-mini`，並且要包含 rate limit 和 authentication 錯誤的 exception handling，不要將 API key 硬編碼在程式碼中。」
*   **情境 2：結構化輸出 (Structured Outputs)**
    *   *提示詞範例*：「我需要使用 LiteLLM SDK 設計一個 structured output 的範例，定義一個 Pydantic schema 來解析新聞摘要（包含 `title`、`summary`、`tags`），並確保模型輸出符合該 schema，且在 Python 層進行再次驗證。」
*   **情境 3：函式呼叫 (Function Calling)**
    *   *提示詞範例*：「請幫我撰寫一個 LiteLLM 函式呼叫（Function Calling）的完整練習。定義一個可以查詢天氣的 `get_weather` 工具，並示範模型決定調用該工具、執行工具後將結果加回 messages，再取得最終模型回覆的完整 round-trip 流程。」

### 2. `litellm-proxy-gateway` (LiteLLM Proxy Gateway)
*   **情境 1：建立基本 `config.yaml` 與多模型 Alias**
    *   *提示詞範例*：「幫我設計一個 LiteLLM Proxy 的 `config.yaml`。我需要設定兩個模型 alias：`course-gpt` 指向 `openai/gpt-4o-mini`，`course-claude` 指向 `anthropic/claude-3-5-haiku`。所有的 API keys 都必須從環境變數讀取。」
*   **情境 2：使用 OpenAI SDK 測試 Proxy 連線**
    *   *提示詞範例*：「我已經啟動了本地的 LiteLLM Proxy（`http://localhost:4000`）。請幫我寫一個 Python 測試腳本，使用標準的 `openai` SDK，搭配虛擬的金鑰（test-key），來呼叫我們在 proxy 中設定好的 `course-gpt` 模型。」
*   **情境 3：虛擬金鑰（Virtual Keys）與權限控管**
    *   *提示詞範例*：「我想在 LiteLLM Proxy 中啟用虛擬金鑰功能。請幫我寫一份教學，說明如何在 config 中啟用資料庫儲存 spend tracking，並寫出如何使用 admin key 透過 API 建立一個限制只能使用 `course-gpt` 且每日額度為 $1 USD 的虛擬金鑰。」

### 3. `litellm-routing-reliability` (路由與可靠性)
*   **情境 1：負載平衡與 Router 設定**
    *   *提示詞範例*：「我想為 `gpt-4o-mini` 設計一個負載平衡（Load Balancing）的 Router 設定。請幫我寫一個 `config.yaml`，配置兩個不同的 API keys（以環境變數形式）分別對應到相同的模型，並說明 LiteLLM 是如何進行請求分流的。」
*   **情境 2：自動容錯備援（Failover / Fallback）**
    *   *提示詞範例*：「請幫我設計一個具備容錯備援機制的 LiteLLM Proxy 設定。當主模型 `openai/gpt-4o` 發生 Rate Limit 或 Service Unavailable 時，能自動 fallback 到備用模型 `anthropic/claude-3-5-sonnet`，並提供測試此備援機制的 Python 範例。」
*   **情境 3：重試與逾時控制 (Retries & Timeout)**
    *   *提示詞範例*：「我需要在 LiteLLM Router 設定中加入全域的重試（Retries）與逾時（Timeout）限制。請修改我的 `config.yaml`，設定連線逾時為 10 秒，且在遇到 5xx 錯誤時自動重試 3 次，並在 Python SDK 端示範如何也設定個別呼叫的 timeout。」

### 4. `litellm-cost-governance` (成本管理與治理)
*   **情境 1：專案與團隊成本歸因（Spend Tracking by Tags / Teams）**
    *   *提示詞範例*：「請教我如何在 LiteLLM Proxy 中透過 `tags` 或 `team_id` 來追蹤不同學生成員或專案的 API 呼叫成本。我需要看到如何在呼叫 API 時傳遞這些 metadata，以及如何在 Proxy 端進行成本統計。」
*   **情境 2：設定預算限制與額度警報（Budgets & Rate Limiting）**
    *   *提示詞範例*：「我想為某個特定的虛擬金鑰設定每週預算限制（Weekly Budget）。請寫出相關的 `config.yaml` 配置，或是使用管理 API 設定虛擬金鑰預算的步驟，並說明當預算超額時 LiteLLM 會回傳什麼錯誤碼。」
*   **情境 3：基礎成本估算與 Callback 整合**
    *   *提示詞範例*：「我不想用資料庫，但想在 Python SDK 呼叫完成後直接在終端機印出該次呼叫的 Token 用量與估算花費。請幫我用 `completion_cost()` 寫一個實作範例，說明它是如何計算不同 Provider 模型的價格。」

### 5. `litellm-observability` (可觀測性與監控)
*   **情境 1：設定全域 Logging 與 Webhook Callbacks**
    *   *提示詞範例*：「我想在 LiteLLM Proxy 中加入自訂的 logging callback。當每次 API 呼叫成功或失敗時，能將請求與回應的 token 用量、模型名稱發送到我指定的 Slack webhook。請幫我設計這個 config 與實作邏輯。」
*   **情境 2：與 OpenTelemetry / Langfuse 整合**
    *   *提示詞範例*：「為了教學展示，我想將 LiteLLM Proxy 的呼叫軌跡（Traces）同步到 Langfuse 進行可觀測性分析。請提供完整的 `config.yaml` 設定範例，包含如何安全地傳遞 Langfuse 的 public key 和 secret key。」
*   **情境 3：使用內建 Prometheus 指標監控**
    *   *提示詞範例*：「我想在 Kubernetes 部署 LiteLLM Proxy 並使用 Prometheus 來監控請求延遲（latency）和錯誤率。請教我如何在 `config.yaml` 中啟用 Prometheus telemetry 指標，並列出常用的 Prometheus query 語法。」

### 6. `litellm-guardrails-safety` (安全防護與護欄)
*   **情境 1：設定輸入過濾與內容審查（Content Moderation）**
    *   *提示詞範例*：「我想要在 LiteLLM Proxy 層阻擋學生的敏感詞輸入。請幫我設定 Llama Guard 或 OpenAI Moderation 作為 guardrail，在請求送達 LLM 之前進行內容審查，並拒絕不合規的請求。」
*   **情境 2：虛擬金鑰的模型權限白名單（Model Access Control）**
    *   *提示詞範例*：「為了避免學生濫用昂貴模型，我需要設計一個安全護欄：限制某個虛擬金鑰只能呼叫 `gpt-4o-mini`，如果該金鑰試圖呼叫 `gpt-4o` 則直接回傳權限錯誤。請寫出具體的配置與測試方法。」
*   **情境 3：使用 Proxy Call Hooks 自訂防護邏輯**
    *   *提示詞範例*：「我想在 LiteLLM Proxy 中寫一個自訂 of Python Hook（例如 `pre_call_hook`），用來檢查請求的 prompt 長度，如果超過 2000 個字元就直接攔截並拒絕呼叫。請提供這個 Python Hook 的寫法與掛載設定。」

### 7. `litellm-mcp-skills-gateway` (MCP 與技能閘道)
*   **情境 1：在 LiteLLM 中配置 MCP Servers**
    *   *提示詞範例*：「我想讓 LiteLLM Proxy 整合 Model Context Protocol (MCP)。請在 `config.yaml` 中配置一個 MCP server（例如連接到本地 sqlite 資料庫的 server），並示範如何讓 Proxy 底下的模型能動態使用該 MCP 工具。」
*   **情境 2：設定 MCP 工具的權限與過濾（MCP Permissions）**
    *   *提示詞範例*：「我們有很多 MCP 工具，但我想限制特定的虛擬金鑰只能使用讀取類型的 MCP 工具，不能執行寫入或刪除。請教我如何在 LiteLLM Gateway 中設定 MCP 工具的權限控管。」
*   **情境 3：Skills Gateway 與官方技能評估**
    *   *提示詞範例*：「請幫我分析 LiteLLM 官方的 Skills Gateway 與一般的 MCP gateway 有何不同？並寫出如何使用官方 `litellm-skills` 來讓 Agent 能自主管理 Proxy 中的 users 和 keys 的架構與安全性評估。」

## 使用原則

- 需要版本、模型、價格、功能支援狀態時，必須重新查 LiteLLM 官方文件或官方 GitHub。
- 不要在教材、投影片或 repo 中提交 API key、proxy master key、virtual key 或資料庫連線密碼。
- 學生練習應使用本機 proxy、測試 key、低成本模型與極小 budgets。
- 若要管理 live proxy，優先參考官方 `litellm-skills`，並將 admin key 權限、操作審計與回復流程納入課堂要求。
