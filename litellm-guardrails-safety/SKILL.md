---
name: litellm-guardrails-safety
description: 設定、教學或審查 LiteLLM guardrails、prompt injection detection、PII masking、tool permission、MCP guardrails、call hooks 與安全策略時使用。
---

# LiteLLM Guardrails Safety

## 使用時機

當任務涉及內容安全、個資遮罩、prompt injection、tool permission、MCP tool 防護、代理工具權限限制、或在 Proxy 上修改/拒絕請求時，使用此技能。

## 官方依據

- Guardrails Quick Start：https://docs.litellm.ai/docs/proxy/guardrails/quick_start
- LiteLLM Tool Permission Guardrail：https://docs.litellm.ai/docs/proxy/guardrails/tool_permission
- MCP Guardrails：https://docs.litellm.ai/docs/mcp_guardrail
- Modify / Reject Incoming Requests：https://docs.litellm.ai/docs/proxy/call_hooks
- MCP Zero Trust Auth：https://docs.litellm.ai/docs/mcp_zero_trust
- v1.83.3 release notes：https://docs.litellm.ai/release_notes/v1.83.3/v1-83-3-stable

## 工作流程

1. 先分類風險：輸入內容、輸出內容、tool call、MCP call、資料外洩、越權模型、越權 provider、prompt injection。
2. 選擇執行時機：`pre_call`、`during_call`、`post_call`、`pre_mcp_call`、`during_mcp_call`。
3. 對必須每次執行的防護設定 `default_on: true`，避免 client 忘記傳 guardrails。
4. 對 PII 使用 masking 或 blocking，並明確定義哪些 entity 是 block、mask 或 allow。
5. 對工具呼叫使用 Tool Permission Guardrail，預設採 deny，再逐一 allow。
6. 若工具允許但參數需受限，使用 `allowed_param_patterns` 約束收件人、路徑、repository、ticket project 等欄位。
7. 對 MCP 工具使用 MCP guardrails，保護 tool input 與執行期間行為。
8. 需要客製化修改或拒絕請求時，用 proxy call hooks，例如 `async_pre_call_hook`。
9. 對非關鍵 guardrail 評估 `on_error` 行為：是硬性阻擋，還是記錄失敗後繼續。
10. 每個 guardrail 必須有測試案例：允許、拒絕、遮罩、provider error、guardrail error。

## Tool Permission 範例

```yaml
guardrails:
  - guardrail_name: "course-tool-permission"
    litellm_params:
      guardrail: tool_permission
      mode: "post_call"
      rules:
        - id: "allow-github-search"
          tool_name: "^mcp__github_.*search.*$"
          decision: "allow"
        - id: "deny-shell"
          tool_name: "Bash"
          decision: "deny"
      default_action: "deny"
      on_disallowed_action: "block"
```

## MCP Guardrail 範例

```yaml
guardrails:
  - guardrail_name: "mcp-input-validation"
    litellm_params:
      guardrail: presidio
      mode: "pre_mcp_call"
      pii_entities_config:
        CREDIT_CARD: "BLOCK"
        EMAIL_ADDRESS: "MASK"
        PHONE_NUMBER: "MASK"
      default_on: true
```

## 教學練習

- 建立一個 pre-call PII guardrail，測試 credit card block 與 email mask。
- 建立 tool permission guardrail，允許 `search_code`，拒絕任意 shell command。
- 對 `send_email` tool 限制收件網域，驗證模型輸出違規參數時會被拒絕。
- 用 call hook 強制每個請求都要有 `user` 欄位。

## 驗收檢查

- 防護策略有 threat model，不是只貼 config。
- 預設工具權限清楚，敏感工具不得預設 allow。
- PII block/mask 規則有測試資料與預期結果。
- guardrail failure 的行為有定義，不能默默放行高風險請求。
- MCP tool call 有獨立於一般 LLM call 的防護。

## 常見錯誤

- 只做 output moderation，忽略 tool call 與 MCP call。
- `default_on` 未設定，導致 client 不傳 guardrails 時完全沒防護。
- allow rule 太寬，例如 `.*` 或整個 MCP server 全開。
- 把 guardrail 當唯一安全層，沒有 key、team、model access 與 audit logs。

## 使用情境與提示詞範例

- **情境 1：設定輸入過濾與內容審查（Content Moderation）**
  * *提示詞*：「我想要在 LiteLLM Proxy 層阻擋學生的敏感詞輸入。請幫我設定 Llama Guard 或 OpenAI Moderation 作為 guardrail，在請求送達 LLM 之前進行內容審查，並拒絕不合規的請求。」
- **情境 2：虛擬金鑰的模型權限白名單（Model Access Control）**
  * *提示詞*：「為了避免學生濫用昂貴模型，我需要設計一個安全護欄：限制某個虛擬金鑰只能呼叫 `gpt-4o-mini`，如果該金鑰試圖呼叫 `gpt-4o` 則直接回傳權限錯誤。請寫出具體的配置與測試方法。」
- **情境 3：使用 Proxy Call Hooks 自訂防護邏輯**
  * *提示詞*：「我想在 LiteLLM Proxy 中寫一個自訂 of Python Hook（例如 `pre_call_hook`），用來檢查請求的 prompt 長度，如果超過 2000 個字元就直接攔截並拒絕呼叫。請提供這個 Python Hook 的寫法與掛載設定。」
