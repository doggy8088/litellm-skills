# Virtual key 維運參考

最後查證日期：2026-07-12。管理 endpoint、request schema、授權方案與輪替語意可能隨 LiteLLM 版本變動；執行前必須查核 [Virtual Keys](https://docs.litellm.ai/docs/proxy/virtual_keys) 與 [LiteLLM 官方 skills](https://docs.litellm.ai/docs/tutorials/claude_code_skills)。本 repo 不提供自製 admin client。

## 工具邊界

- Live proxy 優先使用固定到已審查 commit SHA 的官方 LiteLLM skills，或依目標 proxy 版本產生的 OpenAPI client。
- Admin credential 只從 secret store 或 process environment 取得，不放在命令列、CSV、URL query、log 或聊天內容。
- 單一 alias 操作不得先列舉全租戶 keys；使用版本支援的精確 alias 查詢或 body-based endpoint。
- 若該版本只能把 key hash 放入 URL path／query，必須先確認 reverse proxy、APM 與 access log 的遮罩政策。

## 變更前政策

每把新 key 至少明確定義：

- owner 與 team／organization 範圍；
- model allowlist；空 allowlist 的實際語意必須以目前版本測試；
- expiry、hard budget、budget window；
- RPM、TPM、parallel request 等流量上限；
- guardrail、MCP／tool、route 與其他 object permissions；
- 稽核 ID、變更核准者與 rollback 條件。

不得從 template 複製 owner、user ID 或成本歸屬。Server defaults 也必須在建立後重新讀取並保存非機密證據。

## 安全輪替

1. 以精確 alias 讀取並保存遮罩後的完整政策快照。
2. 建立受限權限、僅目前使用者可讀的新 secret sink；輸出路徑不得位於 Git worktree。
3. 使用目前版本明確支援的 grace period／overlap 機制，或先建立第二把 key。
4. 每成功一把立即持久化並 `flush`，不得等整批完成才寫檔。
5. 用一筆低成本或 mock request 驗證新 key 的 allowlist、budget 與 guardrail。
6. 完成 consumer cutover 後才撤銷舊 key；失敗時保留舊 key 並停止後續目標。
7. 重新查詢 key info，核對所有政策欄位與 expiry，再清除本機 secret 暫存。

## 批次更新

- 預設只允許明列 aliases；全量操作需獨立的 `All` 確認與期望筆數。
- 在第一筆 mutation 前解析全部目標，遇到 missing、duplicate 或 inventory error 就整批停止。
- 預算必須是有限、非負數；未要求變更時保留原 `budget_duration`。
- Model 變更需區分 add/remove/replace；不得把代表 all-model access 的空值誤當一般空集合。
- 每筆寫入後重新讀取驗證；結果報告使用 create-new／atomic rename，不覆寫輸入或既有報告。
- Paid smoke test 必須另行明確核准，且不得以 key 出現在 process argv 的方式呼叫。

## 唯讀用量與報表

- 優先使用目標 LiteLLM 版本的官方 Admin UI、固定到已審查 commit 的官方 skill，或由該版本 OpenAPI schema 產生的 client；本 repo 不另做 admin usage client。
- 查詢前明確固定 alias／team／user、半開區間的 UTC 起訖時間與預期資料量。完整走完目前版本的 pagination／cursor，保存頁數、遮罩後查詢條件與總筆數，不能只取第一頁。
- Key 輪替可能改變 key ID／hash；跨輪替期間的歸因應使用已核准的 alias、team、user 或 server-side tag 對照，不可只用目前 key hash 合併歷史。
- 報表預設只輸出必要聚合欄位；移除 virtual key、key hash、Authorization header、prompt／response、IP 與可識別 metadata。原始 SpendLogs 不得放入一般 CI artifact 或聊天內容。
- 金額、token、cache 與 model cost map 的語意由 `litellm-observability` 協助核對；SpendLogs 封存、匯入與刪除交由 `litellm-operations-runbook`，避免成本查詢流程順帶修改資料。

## 驗收

- Dry-run、核准範圍、期望筆數與實際筆數一致。
- Console、report、URL、access log 與 CI artifact 都不含 secret 或未遮罩 hash。
- 任一中途失敗不會撤銷尚未完成 cutover 的舊 key，也不會繼續後續目標。
- 建立／更新後的實際政策與核准快照一致。
- Secret sink 位於版本控制外，具有最小檔案權限與明確銷毀期限。
