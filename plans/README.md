# 實作計畫索引

由 `improve` 技能於 2026-07-18 產生，規劃基準為 commit `35cd49b`。除非依賴欄另有指示，依下表順序執行。每位執行者都必須先讀完整計畫、執行漂移檢查、遵守停止條件，完成後更新自己的狀態列。

**本批次只規劃使用者選定的前五項發現，不包含直接實作、提交、push 或 pull request。**

* * *

## 執行順序與狀態

| 計畫 | 來源發現 | 標題 | 優先級 | 工作量 | 依賴 | 狀態 |
|---|---:|---|---|---|---|---|
| [001](001-rollback-on-interrupt.md) | 1 | 讓中斷事件也完整回復生成物 | P1 | S | — | DONE |
| [002](002-test-generated-yaml-contract.md) | 2 | 以獨立測試鎖定生成 YAML 的語意契約 | P1 | S | 001 | DONE |
| [003](003-validate-catalog-schema.md) | 3 | 在渲染前拒絕不合法的 catalog | P1 | M | 002 | DONE |
| [004](004-single-source-model-counts.md) | 4 | 移除手寫文件中的動態模型統計 | P1 | M | 003 | DONE |
| [005](005-detect-nested-stale-yaml.md) | 5 | 偵測並清除巢狀 stale provider YAML | P2 | S | 004 | DONE |

狀態值：

- `TODO`
- `IN PROGRESS`
- `DONE`
- `BLOCKED: <一行原因>`
- `REJECTED: <一行理由>`

* * *

## 依賴說明

- 002 排在 001 後，因兩者都修改 generator 測試檔；先固定交易中斷行為，可避免平行修改同一測試區段。
- 003 依賴 002，因 catalog 重構前必須先有獨立的生成 YAML 語意特性測試。
- 004 依賴 003，因其記憶體數量變更測試應使用最終 catalog 契約，且同樣修改 generator 測試檔。
- 005 依賴 004，並傳遞依賴 003；只有 provider id 已保證為單一安全 path component 時，才能把所有巢狀 YAML 明確認定為 stale。
- 若必須平行執行，001–005 不適合直接在同一工作樹並行，因多份計畫會修改 `scripts/generate_byok_forge_examples.py` 或 `tests/test_generate_byok_forge_examples.py`。

* * *

## 共通驗證基線

規劃時以下命令均通過：

| 命令 | 基準結果 |
|---|---|
| `python3 scripts/validate_skills.py` | 7 個 skills 通過 |
| `python3 -m unittest discover -v` | 19 項測試通過 |
| `python3 scripts/generate_byok_forge_examples.py --check` | 115 份生成物同步 |
| `python3 scripts/check_links.py` | 74 個外部連結可連線 |

外部連結檢查屬每週網路整合閘門；一般計畫的每一步不需重跑，除非修改 URL 或連結檢查器。

* * *

## 共通 Git 規則

- 分支採 `advisor/NNN-<slug>`。
- 提交訊息遵守 Conventional Commits 1.0.0，第一行為 `<type>(<scope>): <summary>`，第二行必須空白。
- 若操作者要求提交，必須先執行 `commit_msg_file="$(mktemp -t codex-commit-message)"`，以編輯器將完整 UTF-8 訊息寫入該隨機檔案，再使用 `git commit -F "$commit_msg_file"`。
- 不得使用 `git commit -m`，不得共用固定提交訊息路徑。
- 未經操作者明確要求，不得 push 或開啟 pull request。
- 不得修改與當前計畫無關的使用者既有變更。

* * *

## 已稽核但本批次延後

以下項目不是拒絕，而是使用者此次只選定前五項：

| 原發現 | 延後項目 | 原因 |
|---:|---|---|
| 6 | 限制遠端模型回應及生成規模 | 可在 catalog 契約完成後獨立規劃安全上限 |
| 7 | 將 validator 限制在專案管理的檔案 | 應先補完整 validator 特性測試 |
| 8 | 在 CI 驗證 Python 3.10 最低版本 | 獨立的小型 CI 計畫 |
| 9 | 使用 Compose parser 驗證 Docker 範例 | 需要界定安全的範例環境變數與 CI runtime |
| 10 | 為 validator 建立完整特性測試 | 是發現 7 的前置計畫 |
| 11 | 為外部連結檢查器加入離線測試 | 低風險、低優先級，可獨立處理 |
| 12 | 區分來源基準日與文件最後查證日 | 低風險文件維護 |

方向選項也暫不規劃：

- 技能路由相容性 runner。
- 可執行的離線 capstone 堆疊。
- 多來源 catalog 差異審查流程。

* * *

## 已考慮並拒絕

- 將 `drop_params: true` 視為缺陷：README 已記錄這是承接 BYOK Forge 的刻意預設與正式環境取捨。
- 將 Docker `latest` 一律視為安全缺陷：目前範例定位為本機教學，文件已要求正式環境固定 release tag 或 digest。
- 把 111 份 provider YAML 的重複視為架構債：它們是受 generator 與 drift gate 管理的生成物。
- 直接拆分 560 行 generator：現有函式邊界足以支援選定計畫，拆檔本身沒有獨立高槓桿證據。
- 先增加 CI cache：開發依賴只有 PyYAML，測試基線極短，效益不足。
- 泛化導入 lint 或 typecheck：目前高風險問題是 runtime catalog 契約，不能用工具清單取代具體驗證。
- 要求每個 pull request 執行真實外部連結檢查：README 已記錄避免暫時性網路錯誤阻擋一般 PR 的取捨。
- 宣稱目前模型 snapshot 已失效：查無足夠資料；文件已有查核日期與動態性限制。

* * *

## 索引維護規則

- 執行者只能更新自己計畫的狀態，不得重新排序或改寫其他計畫。
- 若 finding 已由其他 commit 修正，將狀態改為 `REJECTED: 已由 <commit> 修正`，並附上驗證命令結果。
- 若漂移檢查失敗，狀態改為 `BLOCKED` 前必須先依計畫的停止條件確認不是預期依賴變更。
- 所有計畫完成後，執行 `improve reconcile` 重新檢查 DONE、BLOCKED 與剩餘延後發現。
