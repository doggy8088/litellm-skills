# Plan 004: 移除手寫文件中的動態模型統計

> **執行者指示**：依序完成本計畫。每一步都要執行驗證命令並確認預期結果；遇到「停止條件」時停止並回報，不得自行建立第二套統計來源。完成後更新 `plans/README.md` 狀態；若審查者明確維護索引，則不要修改狀態列。
>
> **漂移檢查**：執行 `git diff --stat 35cd49b..HEAD -- README.md examples/litellm-byok-forge/README.md scripts/validate_skills.py tests/test_generate_byok_forge_examples.py scripts/generate_byok_forge_examples.py`。Plans 001–003 完成後，generator 與其測試的差異是預期狀態；確認 `model_catalog_text()`、`ollama_cloud_catalog_text()` 仍以 catalog 動態計數。若兩份手寫 README 的統計段落或 `validate_catalog_counts()` 已被其他變更處理，停止並重新評估。

* * *

## 狀態

- 優先級：P1
- 工作量：M
- 風險：LOW
- 依賴：`plans/003-validate-catalog-schema.md`
- 類別：docs
- 規劃基準：commit `35cd49b`，2026-07-18

* * *

## 為何需要處理

`--refresh-ollama-cloud` 會依遠端回應動態改變 catalog 與生成物數量，但 root README 和 BYOK Forge README 手寫了 34、36、41、70、111 及逐 provider 數量。validator 只核對其中三個片段；上游模型數改變後，即使維護者修正被檢查的片段，其他敘述仍可能互相矛盾。

本計畫採取明確策略：**手寫 README 只解釋用途並連結生成目錄；所有會隨 catalog 改變的即時數量只存在於受 `--check` 保護的生成文件。**

* * *

## 目前狀態

- `README.md:64`：同一行手寫 provider、總模型、直接 Cloud 與本機 Cloud 數量。
- `examples/litellm-byok-forge/README.md:7-19`：摘要與目錄表手寫多個總數。
- `examples/litellm-byok-forge/README.md:23-43`：完整 provider 統計表由人工維護。
- `examples/litellm-byok-forge/README.md:85,121,164`：使用與刷新段落再次重複數量。
- `scripts/validate_skills.py:124-146`：`validate_catalog_counts()` 只搜尋三種文字片段。
- `scripts/generate_byok_forge_examples.py:205-257`：`model-catalog.md` 已由 catalog 動態輸出 provider 總數、entry 總數及每 provider 數量。
- `scripts/generate_byok_forge_examples.py:260-322`：`ollama-cloud-models.md` 已由 catalog 動態輸出兩種 Cloud 存取方式與合計。

生成文件是本計畫的單一數量來源：

    f"本文件是 {len(catalog['providers'])} 個 providers、{len(entries)} 組"
    ...
    total = sum(len(provider["models"]) for provider in providers)

`docs/litellm-model-support-research.md` 是有明確查核日期的歷史研究快照，其中的數字具有時間語意，必須保留且不在本計畫範圍。

* * *

## 需要的命令

| 用途 | 命令 | 成功預期 |
|---|---|---|
| 目標測試 | `python3 -m unittest -v tests.test_generate_byok_forge_examples` | 全部通過 |
| 完整測試 | `python3 -m unittest discover -v` | 全部通過 |
| 技能與文件驗證 | `python3 scripts/validate_skills.py` | 7 個 skills 通過 |
| 生成物同步 | `python3 scripts/generate_byok_forge_examples.py --check` | 115 份檔案通過 |
| 搜尋手寫數量 | `rg -n "\b(34|36|41|70|111)\b" README.md examples/litellm-byok-forge/README.md` | exit 1，沒有匹配 |

* * *

## 範圍

### 可修改

- `README.md`
- `examples/litellm-byok-forge/README.md`
- `scripts/validate_skills.py`
- `tests/test_generate_byok_forge_examples.py`
- `plans/README.md`，僅更新本計畫狀態

### 只讀

- `scripts/generate_byok_forge_examples.py`
- `examples/litellm-byok-forge/model-catalog.md`
- `examples/litellm-byok-forge/ollama-cloud-models.md`

### 不可修改

- `docs/litellm-model-support-research.md`：這是有日期的研究快照。
- `examples/litellm-byok-forge/catalog.json` 與所有生成物。
- 不加入 Markdown include、模板引擎或 README marker writer。
- 不把手寫統計搬到另一個手寫檔案。
- 不移除使用、安全、來源或同步限制說明。

* * *

## Git 工作流程

- 分支：`advisor/004-single-source-model-counts`
- 建議提交標題：`docs(examples): 移除手動維護的模型統計`
- 提交訊息遵守 Conventional Commits 1.0.0。
- 若操作者要求提交，以 `commit_msg_file="$(mktemp -t codex-commit-message)"` 建立隨機 UTF-8 暫存檔，寫入標題、必要空白第二行及正文，再固定執行 `git commit -F "$commit_msg_file"`。不得使用 `-m`。
- 不得自行 push 或開啟 pull request。

* * *

## 執行步驟

### 步驟 1：先鎖定生成文件的動態計數

在 `tests/test_generate_byok_forge_examples.py` 新增一個測試：

1. 讀取新的完整 catalog。
2. 計算原始 provider/model 與兩種 Ollama Cloud 模型總數。
3. 在記憶體中替直接 Cloud provider 加入一個符合 Plan 003 schema 的唯一測試模型。
4. 呼叫 `render_outputs()`。
5. 斷言 `model-catalog.md` 顯示新的全域 entry 數。
6. 斷言 `ollama-cloud-models.md` 顯示新的 Cloud 合計。
7. 斷言 outputs 總數增加一，代表新模型也產生個別 YAML。

預期值由測試直接計算，不得呼叫 production count helper。不要寫入 catalog 或生成物。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples` → 新測試及 Plans 001–003 的測試全部通過。

### 步驟 2：將 root README 改為穩定敘述

修改 `README.md` 的 provider/model 範例段落：

- 說明目錄提供由 catalog 產生的個別設定、合併設定及可讀目錄。
- 將目前數量導向 `examples/litellm-byok-forge/model-catalog.md` 與 `ollama-cloud-models.md`。
- 保留模型來源差異、查核方法與同步限制連結。
- 不保留任何會隨 catalog 更新的數字。

**驗證**：`rg -n "\b(34|36|41|70|111)\b" README.md` → exit 1。

### 步驟 3：移除 BYOK Forge README 的重複統計

在 `examples/litellm-byok-forge/README.md`：

- 摘要改為連結兩份生成目錄，不手寫數量。
- 目錄內容表移除「共 N 份」等數字，只描述每個檔案角色。
- 移除整個人工 Provider 統計表，改成短段落指向 `model-catalog.md`；該生成文件已有每 provider 數量。
- 「使用完整設定」、「完整 Cloud 模型」與「重新產生」段落改用「catalog 中的全部組合」、「目前完整清單」、「每個 provider/model 一份 YAML」等穩定描述。
- 保留 2026-07-12 來源日期文字可以，但不要在手寫 README 重述該日的數量；日期與數量的完整歷史證據由研究報告保存。

**驗證**：`rg -n "\b(34|36|41|70|111)\b" examples/litellm-byok-forge/README.md` → exit 1。

### 步驟 4：移除片段式 count validator

從 `scripts/validate_skills.py` 移除 `validate_catalog_counts()` 及 `main()` 對它的呼叫。不要以新的文字搜尋替代它；動態數量已由 generator renderer 與 `--check` 負責。

保留 `validate_data_files()`，catalog 仍必須是合法 JSON；Plan 003 的完整結構契約則由 generator `--check` 負責。

**驗證**：

- `rg -n "validate_catalog_counts" scripts/validate_skills.py` → exit 1。
- `python3 scripts/validate_skills.py` → 7 個 skills 通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過。

### 步驟 5：執行完整維護閘門

**驗證**：

- `python3 -m unittest discover -v` → 全部通過。
- `python3 scripts/validate_skills.py` → 7 個 skills 通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過。
- `git diff -- examples/litellm-byok-forge/model-catalog.md examples/litellm-byok-forge/ollama-cloud-models.md examples/litellm-byok-forge/catalog.json` → 無輸出。

* * *

## 測試計畫

- 新增一個純記憶體 catalog 數量變更案例。
- 同時驗證全域模型目錄、Cloud 目錄與 outputs 數量。
- 不修改真實 catalog，不從生成文件反推預期值。
- 使用 `rg` 鎖定兩份手寫 README 不再含目前的動態總數。
- 完整維護閘門確認移除 `validate_catalog_counts()` 後沒有失去 JSON、Markdown 或生成物 drift 驗證。

* * *

## 完成條件

- [ ] 兩份手寫 README 不含 34、36、41、70、111 等目前 catalog 統計。
- [ ] Provider 統計表只存在於生成的 `model-catalog.md`。
- [ ] `validate_catalog_counts()` 與其呼叫已移除。
- [ ] 記憶體模型增量測試證明兩份生成目錄會動態更新數量。
- [ ] 研究報告及生成物沒有 diff。
- [ ] 完整測試、技能驗證及生成物同步檢查通過。
- [ ] `git diff --name-only` 只包含本計畫可修改檔案與狀態列。
- [ ] `plans/README.md` 狀態已更新，除非審查者維護索引。

* * *

## 停止條件

- Plan 003 尚未完成，或 live catalog 契約與新增測試無法相容。
- 生成的 `model-catalog.md` 或 `ollama-cloud-models.md` 已不再包含動態數量。
- 維護者要求 root README 必須即時顯示精確數量；這需要重新選擇受控 marker 或全文件生成策略，不可在本計畫內 improvisation。
- 必須修改有日期的研究報告才能讓驗證通過。
- 生成物同步檢查要求重寫大量 provider YAML。

* * *

## 維護備註

- 未來模型增減只更新 catalog 與生成物；手寫 README 不應重新加入即時總數。
- 有日期的研究報告可保留歷史統計，但必須明確標示查核日期與限制。
- Reviewer 應確認移除 count validator 沒有移除 JSON 語法、相對連結或 generator drift 閘門。
