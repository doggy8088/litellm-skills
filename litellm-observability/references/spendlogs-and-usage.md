# SpendLogs 與用量語意

最後查證日期：2026-07-12。分析用量、資料品質或觀測需求時使用；表格 schema 與 API 欄位需依目標 LiteLLM 版本重新查核 [Spend tracking](https://docs.litellm.ai/docs/proxy/cost_tracking)。實際 export、import、restore 與 retention delete 一律交由 `litellm-operations-runbook`。

## 資料語意

- 以 UTC 處理月份與日界線；報表需明確顯示 timezone，不以本機日期替代。
- 區分 input、output、cache 與 reasoning tokens；缺值不得默認為零而隱藏 upstream error。
- Key rotation 前後可能有多個 hash；成本歸因應使用可信任 alias／owner／team，並避免重複計算。
- Model cost map、cache pricing 與 provider metadata 可能變動，報表需記錄 LiteLLM 版本及查證日期。
- Archive manifest 的 row count、request-ID 集合與 UTC range 是資料品質證據，不代表來源真實性或加密保護。

## Schema 與版本漂移

- 分析前核對 `LiteLLM_SpendLogs` 實際欄位、型別、unique constraint 與 nullable 規則。
- 固定欄位的 archive 只能匯回相容 schema；不相容時先做 migration rehearsal。
- 每筆 `startTime` 都必須落在報表或 manifest 宣告的半開 UTC 區間。
- API timeout、認證失敗與 schema mismatch 必須回報 unavailable／upstream error，不得顯示為零用量。

## 敏感資料

SpendLogs 可能包含 `messages`、`response`、`proxy_server_request`、requester IP、user、team、organization、agent、tool 與 metadata。啟用內容記錄前先定義資料分類、遮罩、合法用途、存取者與保留期限；分享報表時移除 virtual key／hash、prompt／response、IP、客戶資訊、admin token 與 SAS URL。

## 驗收

- 報表可由 request ID 回溯來源，且明確區分成功、零用量與資料不可用。
- UTC window、schema 版本、來源查詢與成本估算依據均可查。
- 抽樣資料列與聚合值一致，rotation／fallback 不造成遺漏或重複。
- 觀測輸出不含未遮罩敏感內容。
