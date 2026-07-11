---
name: litellm-routing-reliability
description: 設計或審查 LiteLLM Router、load balancing、retry、timeout、fallback、rate-limit routing 與 health checks。當任務要求多 deployment、跨 provider 備援或可靠性測試時使用；預算政策交由成本治理技能，trace 後端交由觀測技能。
---

# LiteLLM Routing Reliability

## 工作流程

1. 定義 user-facing model group、deployments、region、容量與故障域。
2. 查核目前支援的 routing strategy、retry、timeout 與 fallback schema。
3. 設定有限重試與整體 timeout，再定義有順序的 fallback。
4. 多 instance 共享路由或 health 狀態時評估 Redis。
5. 分別測試正常路由、429、timeout、primary 失敗與全 deployments 失敗。
6. 使用 readiness 作為接流量判斷、liveliness 作為重啟判斷；不要把會實際呼叫模型的 `/health` 當高頻免費 probe。
7. 回報實際命中的 deployment、重試次數、延遲與成本影響。

需要設定範例、fallback mock 或 health endpoint 細節時，讀取 [實驗與參考](references/guide.md)。

## 安全底線

- Fallback 不得繞過模型權限、資料區域、guardrail 或預算限制。
- 不以同一 provider、同一 region 作為唯一災難備援。
- 不設定無限重試或無上限 timeout。
- 測試不得用大量付費流量製造 429。

## 驗收

- Primary、retry、fallback 的順序可由 log 或 trace 證明。
- `mock_testing_fallbacks` 明確放在 request body 或 SDK 呼叫參數。
- 全部 provider 失敗時回傳受控錯誤。
- Health probes 的用途、頻率、認證與成本均有定義。
