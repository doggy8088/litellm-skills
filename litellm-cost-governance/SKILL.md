---
name: litellm-cost-governance
description: 設計、教學或審查 LiteLLM spend tracking、virtual keys、budgets、rate limits、request tags、provider budget routing 與成本治理流程時使用。
---

# LiteLLM Cost Governance

## 使用時機

當任務與團隊成本控管、學生用量限制、每人/每隊 budgets、API key 權限、成本歸因、用量報表或 provider budget routing 有關時，使用此技能。

## 官方依據

- Spend Tracking：https://docs.litellm.ai/docs/proxy/cost_tracking
- Virtual Keys：https://docs.litellm.ai/docs/proxy/virtual_keys
- Budgets, Rate Limits：https://docs.litellm.ai/docs/proxy/users
- Team Budgets：https://docs.litellm.ai/docs/proxy/team_budgets
- Tag Budgets：https://docs.litellm.ai/docs/proxy/tag_budgets
- Request Tags：https://docs.litellm.ai/docs/proxy/request_tags
- Provider Budget Routing：https://docs.litellm.ai/docs/proxy/provider_budget_routing

## 成本治理模型

把成本歸因分成以下層級：

- Key：單一 virtual key 的模型權限、budget、expiry、spend。
- User：個人用量與個人 key 的預算。
- Team：課堂分組、專案小組或部門層級的 budget 與 rate limits。
- Tag：課程、任務、功能、成本中心或實驗代碼。
- Model：昂貴模型與便宜模型的使用界線。
- Provider：OpenAI、Azure、Anthropic、Bedrock 等 provider-level budget。

## 工作流程

1. 確認 proxy 已接上 Postgres 或官方文件要求的資料庫；沒有資料庫就不能完整做 spend tracking 與 budgets。
2. 定義治理邊界：每位學生、每組、每個練習、每個模型 alias 的預算與 rate limit。
3. 建立 virtual key，設定可用 models、`max_budget`、`budget_duration`、expiry 與 team/user。
4. 對課堂練習加 request tags，例如 `course:litellm`、`lab:router`、`team:team-a`。
5. 需要多期間限制時使用 budget windows，例如每日上限加月度上限。
6. 對高成本模型設定更嚴格的 model-specific budget 或禁止學生 key 存取。
7. 若 provider 也要控管，使用 provider budget routing；確認 Redis 需求與 provider 名稱。
8. 建立報表：按 key、user、team、tag、model 彙整 requests、tokens、spend。
9. 若成本與 provider 帳單不一致，對齊時間範圍、token 類型、cache token 與 model cost map。
10. 課堂結束後撤銷學生 key 或把 budget 調成 0。

## 學生實驗建議

```json
{
  "models": ["course-chat", "course-cheap"],
  "max_budget": 1.0,
  "budget_duration": "24h",
  "metadata": {
    "course": "litellm-cost-governance",
    "lab": "budget-window"
  }
}
```

## 教學練習

- 建立一把每日 1 美元上限的 virtual key，測試超額後請求是否被拒絕。
- 建立 team budget，讓兩把 key 共用同一個 team limit。
- 用 request tags 將同一把 key 的請求分成兩個 lab，查詢 spend logs。
- 建立一個 provider budget routing 練習，觀察 provider 超額後的路由行為。

## 驗收檢查

- 每把學生 key 都有 expiry、model allowlist 與 budget。
- 不使用 master key 當學生或一般應用程式 key。
- 所有練習請求都有 user 或 tag 供成本歸因。
- 報表能回答「誰、哪個 team、哪個 lab、哪個 model 花了多少」。
- 高成本模型有明確存取限制或 budget。

## 常見錯誤

- 沒有資料庫就宣稱能做完整 spend tracking。
- 只設全域 budget，無法追到個人或課堂練習。
- 忘記 key expiry，導致課後仍可使用。
- 沒有 request tags，最後只能看到總花費。
- 把 soft budget 當 hard stop。

## 使用情境與提示詞範例

- **情境 1：專案與團隊成本歸因（Spend Tracking by Tags / Teams）**
  * *提示詞*：「請教我如何在 LiteLLM Proxy 中透過 `tags` 或 `team_id` 來追蹤不同學生成員或專案的 API 呼叫成本。我需要看到如何在呼叫 API 時傳遞這些 metadata，以及如何在 Proxy 端進行成本統計。」
- **情境 2：設定預算限制與額度警報（Budgets & Rate Limiting）**
  * *提示詞*：「我想為某個特定的虛擬金鑰設定每週預算限制（Weekly Budget）。請寫出相關的 `config.yaml` 配置，或是使用管理 API 設定虛擬金鑰預算的步驟，並說明當預算超額時 LiteLLM 會回傳什麼錯誤碼。」
- **情境 3：基礎成本估算與 Callback 整合**
  * *提示詞*：「我不想用資料庫，但想在 Python SDK 呼叫完成後直接在終端機印出該次呼叫的 Token 用量與估算花費。請幫我用 `completion_cost()` 寫一個實作範例，說明它是如何計算不同 Provider 模型的價格。」
