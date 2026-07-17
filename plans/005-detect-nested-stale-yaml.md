# Plan 005: 偵測並清除巢狀 stale provider YAML

> **執行者指示**：依序完成本計畫。每一步都要執行驗證命令並確認預期結果；遇到「停止條件」時停止並回報。完成後更新 `plans/README.md` 狀態；若審查者明確維護索引，則不要修改狀態列。
>
> **漂移檢查**：執行 `git diff --stat 35cd49b..HEAD -- scripts/generate_byok_forge_examples.py tests/test_generate_byok_forge_examples.py`。Plans 001–004 會改動這兩個檔案，是預期差異；先確認 `check_outputs()` 與 `write_outputs_atomically()` 仍各自使用固定兩層的 `glob("*/*.yaml")`。若已改為共用遞迴 helper，停止並檢查本 finding 是否已被獨立修正。

* * *

## 狀態

- 優先級：P2
- 工作量：S
- 風險：LOW
- 依賴：`plans/004-single-source-model-counts.md`
- 類別：bug
- 規劃基準：commit `35cd49b`，2026-07-18

* * *

## 為何需要處理

drift 檢查與 writer 都只列舉 `providers/*/*.yaml`。任何更深的 YAML，例如過去錯誤 provider id 造成的 `providers/old/nested/stale.yaml`，既不會被 `--check` 報告，也不會在重建時清除。Plan 003 會防止未來 catalog 再產生巢狀 provider id，但無法偵測已存在或人工加入的 stale 檔。

**完成後，產生器擁有的 providers 樹內所有額外 YAML 都必須被 drift gate 發現，正常重建則安全刪除並清理空目錄。**

* * *

## 目前狀態

- `scripts/generate_byok_forge_examples.py:369-393`：`check_outputs()` 以固定兩層 glob 建立實際 provider 集合。
- `scripts/generate_byok_forge_examples.py:431-439`：writer 使用另一份相同 glob 計算 stale 集合。
- `scripts/generate_byok_forge_examples.py:507-510`：成功後只把 stale 檔的直接 parent 傳給空目錄清理。
- `tests/test_generate_byok_forge_examples.py:161-180`：drift 測試只放置兩層 stale YAML。
- `tests/test_generate_byok_forge_examples.py:182-207`：writer 成功測試同樣只涵蓋兩層 stale YAML。

現行重複邏輯：

    actual_provider_files = {
        path.relative_to(EXAMPLES)
        for path in (EXAMPLES / "providers").glob("*/*.yaml")
    }

Plan 003 完成後，所有合法生成檔路徑仍應是 `providers/<safe-provider-id>/<model-slug>.yaml`。因此更深層 YAML 一律是額外生成物，不需猜測其來源。

* * *

## 需要的命令

| 用途 | 命令 | 成功預期 |
|---|---|---|
| 目標測試 | `python3 -m unittest -v tests.test_generate_byok_forge_examples` | 全部通過 |
| 完整測試 | `python3 -m unittest discover -v` | 全部通過 |
| 技能驗證 | `python3 scripts/validate_skills.py` | 7 個 skills 通過 |
| 生成物同步 | `python3 scripts/generate_byok_forge_examples.py --check` | 115 份檔案通過 |

* * *

## 範圍

### 可修改

- `scripts/generate_byok_forge_examples.py`
- `tests/test_generate_byok_forge_examples.py`
- `plans/README.md`，僅更新本計畫狀態

### 不可修改

- 不修改 catalog 或任何 checked-in 生成物。
- 不刪除 providers 樹內的非 YAML 檔案。
- 不追蹤或刪除解析後位於 providers root 之外的符號連結目標。
- 不改變合法生成檔的兩層 layout。
- 不把所有 `examples/` 都交給遞迴 stale 清理；範圍僅限 `examples/litellm-byok-forge/providers/**/*.yaml`。

* * *

## Git 工作流程

- 分支：`advisor/005-detect-nested-stale-yaml`
- 建議提交標題：`fix(generator): 偵測巢狀 stale YAML`
- 提交訊息遵守 Conventional Commits 1.0.0。
- 若操作者要求提交，以 `commit_msg_file="$(mktemp -t codex-commit-message)"` 建立隨機 UTF-8 暫存檔，寫入標題、必要空白第二行及正文，再固定執行 `git commit -F "$commit_msg_file"`。不得使用 `-m`。
- 不得自行 push 或建立 pull request。

* * *

## 執行步驟

### 步驟 1：先加入巢狀 stale 回歸測試

擴充或新增 drift 測試：

1. 在暫存目錄建立 `providers/old/nested/stale.yaml`。
2. 準備一組不包含它的 expected outputs。
3. patch generator 的 `EXAMPLES` 指向暫存目錄。
4. 斷言 `check_outputs()` 回傳「多餘生成檔」且包含該相對路徑。

新增 writer 成功測試：

1. 同時放置巢狀 stale YAML、既有正常輸出與一個新輸出。
2. 執行 `write_outputs_atomically()`。
3. 斷言 stale YAML 被刪除。
4. 若 `old/nested` 與 `old` 都已空，兩層目錄都被清除。
5. 新輸出正確寫入，其他既有輸出保持預期內容。

再加入一個保護案例：巢狀 stale YAML 同層若有非 YAML 檔案，writer 不得刪除該檔案，且不可移除仍非空的 parent。

**驗證**：在 production code 尚未修改前，`python3 -m unittest -v tests.test_generate_byok_forge_examples` 預期巢狀 drift／清理測試失敗。

### 步驟 2：建立共用 provider YAML 列舉 helper

在 generator 新增一個私有 helper，接收 examples root，回傳所有位於 `providers/` 下的 YAML 相對路徑集合。要求：

- 使用遞迴列舉，例如 `rglob("*.yaml")`。
- provider root 不存在時回傳空集合。
- 回傳值全部相對於 examples root，與 outputs key 格式一致。
- 不讀取檔案內容、不跟隨或解析外部目標。
- `check_outputs()` 與 `write_outputs_atomically()` 必須共用此 helper，不得保留兩份 glob 邏輯。

對 writer 而言，既有 `_safe_target()` 與 symlink 拒絕仍必須套用於每個 touched path。

**驗證**：`rg -n -F 'glob("*/*.yaml")' scripts/generate_byok_forge_examples.py` → exit 1；目標測試中的巢狀 drift 案例通過。

### 步驟 3：清理所有空的 stale ancestor

當巢狀 stale YAML 成功刪除後，建立待清理目錄集合：

- 包含 stale 檔直接 parent。
- 沿 parent chain 向上加入所有目錄，直到但不包含 `providers` root。
- 交給既有由深到淺的 `_remove_empty_directories()`。
- 若 parent 還有非 YAML 檔或其他生成檔，`rmdir()` 失敗是正常且應保留。

不要改成 `shutil.rmtree`；清理只能移除確認為空的目錄。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples` → 巢狀目錄清理與非 YAML 保留案例均通過。

### 步驟 4：執行完整維護閘門

**驗證**：

- `python3 -m unittest discover -v` → 全部通過。
- `python3 scripts/validate_skills.py` → 7 個 skills 通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過。
- `git diff -- examples/litellm-byok-forge` → 無輸出。

* * *

## 測試計畫

- `check_outputs()` 能報告三層以上的 stale YAML。
- writer 能刪除巢狀 stale YAML。
- writer 能由深到淺移除所有空 ancestor，但保留 providers root。
- 同層有非 YAML 檔案時，該檔及非空 parent 必須保留。
- 既有兩層 missing、extra、changed 與 writer rollback 測試維持通過。
- Plans 001–004 的所有 generator 測試維持通過。

* * *

## 完成條件

- [ ] 固定兩層 `glob("*/*.yaml")` 不再出現在 generator。
- [ ] drift 與 writer 共用同一個遞迴列舉 helper。
- [ ] 巢狀 stale YAML 會被 `--check` 報告。
- [ ] 正常重建會刪除巢狀 stale YAML 及所有空 ancestor。
- [ ] 非 YAML 檔案與非空目錄不會被刪除。
- [ ] 完整測試、技能驗證與 115 份生成物同步檢查通過。
- [ ] catalog 與全部生成物沒有 diff。
- [ ] `git diff --name-only` 只包含 generator、其測試及允許的狀態列。
- [ ] `plans/README.md` 狀態已更新，除非審查者維護索引。

* * *

## 停止條件

- Plan 004 或其傳遞依賴尚未完成。
- Plan 003 最終允許合法 provider id 產生巢狀路徑；此時「所有巢狀 YAML 都是 stale」的假設不成立。
- 遞迴列舉會跟隨 symlink directory 到 providers root 之外，且無法在現有 Python 3.10 基準安全避免。
- 修正需要刪除非 YAML 檔案或使用 `rmtree`。
- 完整 `--check` 開始把目前合法生成物誤報為 stale。

* * *

## 維護備註

- 若未來合法 layout 改為更深層，必須同時調整 schema、expected paths、stale 定義與測試，不能只改 glob。
- Reviewer 應確認列舉 helper 沒有讀取檔案內容，也沒有繞過 `_safe_target()`。
- 空目錄清理必須保持 best-effort；非空目錄不是錯誤。
