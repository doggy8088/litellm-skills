---
name: litellm-cost-governance
description: 設計或審查 LiteLLM virtual keys、spend tracking、budgets、rate limits、request tags 與 provider budget routing。當任務涉及用量限制、模型 allowlist、成本歸因或報表時使用；一般 Proxy 拓樸與觀測平台設定改用對應專門技能。
---

# LiteLLM Cost Governance

## 工作流程

1. 定義 key、user、team、tag、model 與 provider 的治理邊界及可信任來源。
2. 查核 LiteLLM 版本、授權方案、Postgres／Redis 需求及 budget 語意。
3. 建立 virtual key，設定 model allowlist、hard budget、duration 或 expiry、rate limits 與 owner。
4. 由可信任伺服器端注入治理用 tags；用戶端 tags 只可用於非安全關鍵觀測。
5. 查詢 spend logs，對齊時區、token 類型、cache tokens 與 model cost map。
6. 測試超額、到期、未授權模型及撤銷後行為。
7. 課程結束撤銷 key，保存不含 secret 的稽核證據。

需要 key payload、安全設定與核心實驗時，讀取 [實驗與參考](references/guide.md)；涉及 virtual key 生命週期、輪替或批次變更時，讀取 [Virtual key 維運](references/virtual-key-operations.md)，並優先使用已審查版本的官方 LiteLLM skills／API。

## 安全底線

- 不把 master key 當學生或一般應用程式 key。
- 不信任用戶端可修改的 metadata、user 或 tag 作為授權與預算邊界。
- 治理用 tags 應由 key/team metadata、可信任 hook 或伺服器端注入。
- 每把暫時性 key 都必須有 expiry、owner、model allowlist 與最小預算。

## 驗收

- Key 建立後可查到 expiry、models、budget 與 owner。
- 到期、超額、撤銷與未授權模型請求均被拒絕。
- 報表能回答誰、哪個 team、哪項活動、哪個模型花費多少。
- 用戶端無法偽造安全關鍵成本歸因。
