---
name: litellm-operations-runbook
description: 操作、維護、稽核或修復 LiteLLM Proxy 部署。當任務涉及 Postgres 備份與還原、Azure Blob 上傳、SpendLogs 封存、virtual key 批次作業、用量 WebApp 或機密清理時使用；成本政策、觀測設定與安全規則仍搭配對應專門技能。
---

# LiteLLM 維運手冊

## 工作流程

1. 判斷操作類型、目標環境、資料來源、影響範圍與回復目標。
2. 檢查既有自動化、設定、備份及必要工具，不假設腳本可直接套用其他環境。
3. 從環境變數或受控 secret store 取得憑證，先執行唯讀檢查、dry-run、`-WhatIf` 或 `--verify-only`。
4. 破壞性操作前記錄預期筆數、日期區間、alias、blob 名稱與 rollback；取得使用者明確確認後才執行。
5. 執行範圍最小的操作，再以資料列數、health endpoint、manifest、checksum、暫時還原容器或低成本請求驗證。
6. 彙整已變更狀態、敏感產物的保存位置、驗證證據與回復方式。

依任務讀取 [備份與還原](references/backup-restore.md)、[SpendLogs 封存](references/spendlogs-archives.md)、[Key manager runbook](references/key-manager-runbook.md) 或 [機密盤點](references/secret-inventory.md)。

## 安全底線

- 不輸出或提交 virtual key、key hash、admin token、SAS signature、密碼或 database URL。
- Key CSV、SpendLogs 匯出、備份與用量報告一律視為敏感資料。
- 刪除、覆寫、還原至正式環境或修改正式預算前必須取得明確確認。
- 破壞性指令只作用於明確 alias、日期範圍或檔案；不得使用寬鬆 glob。
- 還原演練使用暫時容器、連接埠與 volume，不覆寫正式資料。

## 驗收

- Dry-run 或唯讀檢查的範圍與結果已記錄。
- 備份、封存或批次輸出的筆數、manifest 與 checksum 可核對。
- 成功與失敗路徑皆有驗證證據，且正式資料未被測試流程覆寫。
- 敏感產物未進入版本控制，交付內容不含 secret。
- Rollback 或 restore drill 可執行，並記錄實際結果。
