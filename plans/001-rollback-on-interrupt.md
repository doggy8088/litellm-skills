# Plan 001: 讓中斷事件也完整回復生成物

> **執行者指示**：依序完成本計畫。每一步都要執行驗證命令並確認預期結果；遇到「停止條件」時立即停止並回報，不得自行擴張範圍。完成後更新 `plans/README.md` 的本計畫狀態；若審查者明確表示由其維護索引，則不要修改狀態列。
>
> **漂移檢查**：先執行 `git diff --stat 35cd49b..HEAD -- scripts/generate_byok_forge_examples.py tests/test_generate_byok_forge_examples.py`。預期沒有輸出。若有輸出，逐段比對「目前狀態」；任何影響 `write_outputs_atomically()`、rollback 或相關測試的差異都是停止條件。

* * *

## 狀態

- 優先級：P1
- 工作量：S
- 風險：LOW
- 依賴：無
- 類別：bug
- 規劃基準：commit `35cd49b`，2026-07-18

* * *

## 為何需要處理

`write_outputs_atomically()` 會先刪除 stale provider YAML，再逐一用 `os.replace()` 更新生成物。現行 `except Exception` 可以回復一般 I/O 例外，但不會捕捉繼承 `BaseException` 的 `KeyboardInterrupt` 與 `SystemExit`。使用者若在 115 份生成物替換期間按下 Ctrl-C，工作樹可能留下部分新檔、部分舊檔及已刪除的 stale 檔。

**完成後，中斷事件必須先完成與一般寫入失敗相同的回復，再重新拋出原始中斷。**

* * *

## 目前狀態

- `scripts/generate_byok_forge_examples.py`：生成物暫存、備份、替換與回復流程。
- `tests/test_generate_byok_forge_examples.py`：以 `tempfile.TemporaryDirectory` 和 `unittest.mock` 驗證成功與一般失敗路徑。
- `examples/litellm-byok-forge/README.md:164`：對維護者承諾生成失敗不會留下部分更新；本計畫不修改這份文件。

`scripts/generate_byok_forge_examples.py:471-505` 的關鍵結構如下：

    created_directories: set[Path] = set()
    try:
        # remove stale files, then replace payloads
        ...
    except Exception as error:
        # restore existing paths and remove newly created paths
        ...
        raise

`tests/test_generate_byok_forge_examples.py:209-245` 的既有測試會讓第二次 `os.replace()` 拋出 `OSError`，接著斷言兩個既有檔案恢復原內容。新測試必須沿用此暫存目錄與 mock 風格，不可碰觸真實 `examples/`。

專案慣例：

- 測試框架是標準函式庫 `unittest`，沒有 pytest。
- 錯誤訊息使用正體中文，函式與測試名稱使用英文 snake_case。
- 測試必須離線，檔案寫入只發生於暫存目錄。

* * *

## 需要的命令

| 用途 | 命令 | 成功預期 |
|---|---|---|
| 安裝開發依賴 | `python3 -m pip install -r requirements-dev.txt` | exit 0 |
| 目標測試 | `python3 -m unittest -v tests.test_generate_byok_forge_examples` | 全部通過 |
| 完整測試 | `python3 -m unittest discover -v` | 全部通過 |
| 技能驗證 | `python3 scripts/validate_skills.py` | 顯示 7 個 skills 通過 |
| 生成物同步 | `python3 scripts/generate_byok_forge_examples.py --check` | 顯示 115 份檔案通過 |

* * *

## 範圍

### 可修改

- `scripts/generate_byok_forge_examples.py`
- `tests/test_generate_byok_forge_examples.py`
- `plans/README.md`，僅更新本計畫狀態

### 不可修改

- `examples/litellm-byok-forge/**`：本修正不得重建或改動任何生成物。
- `scripts/validate_skills.py`：與中斷回復無關。
- 不加入 signal handler、不遮蔽 Ctrl-C、不改變公開 CLI 參數。
- 不改寫整個交易機制，也不處理本計畫以外的故障注入矩陣。

* * *

## Git 工作流程

- 分支：`advisor/001-rollback-on-interrupt`
- 提交訊息格式：Conventional Commits 1.0.0。
- 建議提交標題：`fix(generator): 讓中斷事件回復生成物`
- 若操作者要求提交，先以 `commit_msg_file="$(mktemp -t codex-commit-message)"` 建立每次不同的 UTF-8 純文字檔，以編輯器寫入第一行、必要空白第二行及可選正文，再固定執行 `git commit -F "$commit_msg_file"`。不得使用 `git commit -m`。
- 未經操作者要求，不得 push 或開啟 pull request。

* * *

## 執行步驟

### 步驟 1：先加入中斷回歸測試

在 `GeneratorUnitTests` 中新增至少一個明確命名的測試，例如 `test_atomic_writer_rolls_back_after_keyboard_interrupt`。

測試必須建立以下狀態：

1. 一個既有生成檔，內容代表舊版本。
2. 一個 stale provider YAML，確認中斷後會恢復。
3. 一個原先不存在的新生成檔，確認中斷後不會殘留。
4. patch `os.replace`，讓第一次替換成功、第二次拋出 `KeyboardInterrupt`。
5. 斷言呼叫端仍收到 `KeyboardInterrupt`。
6. 斷言所有既有檔案內容完全恢復、stale 檔存在、新檔與新建空目錄不存在。

再以子測試或第二個測試涵蓋 `SystemExit`，確認它同樣先回復再重新拋出。不要模擬真實作業系統訊號。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples`。在尚未修改 production code 前，新測試預期失敗，且失敗原因必須是生成物未回復；若測試意外通過，停止並確認 live code 是否已修正。

### 步驟 2：擴大既有回復例外邊界

在 `write_outputs_atomically()` 的可變更階段，讓同一套 rollback 邏輯處理一般例外、`KeyboardInterrupt` 與 `SystemExit`。採用單一 `except BaseException as error` 邊界，保留現有行為：

- rollback 成功時使用裸 `raise` 重新拋出原始事件。
- rollback 不完整時仍聚合錯誤並以 `RuntimeError` 包裝，`from error` 保留原始原因。
- 不要吞掉或轉成成功退出。
- 不要把 staging 與 backup 建立階段移入此可變更邊界；那些步驟尚未修改目標樹。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples`，所有既有測試與新增中斷測試均顯示 `ok`。

### 步驟 3：執行完整維護閘門

依序執行完整測試、技能驗證與生成物同步檢查。任何命令失敗都必須先定位是否由本計畫造成，不得藉機修改不相關檔案。

**驗證**：

- `python3 -m unittest discover -v` → 全部通過。
- `python3 scripts/validate_skills.py` → `技能驗證通過：7 個 skills`。
- `python3 scripts/generate_byok_forge_examples.py --check` → `生成物檢查通過：115 份檔案`。

* * *

## 測試計畫

- 在 `tests/test_generate_byok_forge_examples.py` 新增：
  - `KeyboardInterrupt` 發生於部分替換後的完整回復案例。
  - `SystemExit` 發生於部分替換後的完整回復案例。
  - 每個案例都要同時斷言既有檔、stale 檔、新檔與新目錄狀態。
- 沿用 `test_atomic_writer_rolls_back_every_output_after_replace_failure` 的 mock 與暫存目錄結構。
- 不連線網路，不呼叫真實 generator CLI，不寫入工作樹。

* * *

## 完成條件

- [ ] `rg -n "except BaseException as error" scripts/generate_byok_forge_examples.py` 恰有一個目標 rollback 邊界。
- [ ] `rg -n "KeyboardInterrupt|SystemExit" tests/test_generate_byok_forge_examples.py` 找到新增回歸測試。
- [ ] 目標與完整測試全部通過。
- [ ] 技能驗證與 115 份生成物同步檢查通過。
- [ ] `git diff --name-only` 除本計畫可修改檔案及狀態列外沒有其他路徑。
- [ ] 未修改任何 `examples/litellm-byok-forge/**` 檔案。
- [ ] `plans/README.md` 狀態已更新，除非審查者明確表示由其維護。

* * *

## 停止條件

- Live code 已不是 `except Exception as error`，或 rollback 結構與摘錄不符。
- 新測試需要寫入真實 `examples/` 才能重現。
- 修正需要 signal handler、背景執行緒或平台專屬 API。
- 捕捉中斷後無法可靠重新拋出原始事件。
- 任一驗證連續兩次失敗，且合理修正仍無法排除。

* * *

## 維護備註

- 未來若增加新的目標樹修改步驟，必須放在同一 rollback 邊界內，並加入中斷測試。
- 審查時特別確認 `BaseException` 只包住已開始修改目標樹的區段，不要擴張到參數解析或遠端請求。
- 第二次真實 Ctrl-C 仍可能中斷 rollback；本計畫不加入訊號遮蔽。若要提供不可中斷回復，需要獨立設計與跨平台測試。
