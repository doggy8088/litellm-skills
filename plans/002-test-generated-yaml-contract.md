# Plan 002: 以獨立測試鎖定生成 YAML 的語意契約

> **執行者指示**：依序完成本計畫。每一步都要執行驗證命令並確認預期結果；遇到「停止條件」時立即停止並回報，不得自行擴張範圍。完成後更新 `plans/README.md` 的本計畫狀態；若審查者明確表示由其維護索引，則不要修改狀態列。
>
> **漂移檢查**：先執行 `git diff --stat 35cd49b..HEAD -- tests/test_generate_byok_forge_examples.py scripts/generate_byok_forge_examples.py requirements-dev.txt`。Plan 001 完成後，測試檔新增中斷回歸測試是預期差異；確認它沒有改變 renderer 契約或下述測試結構即可。其他影響 `model_entry()`、`config_text()`、`render_outputs()` 或 PyYAML 依賴的差異都是停止條件。

* * *

## 狀態

- 優先級：P1
- 工作量：S
- 風險：LOW
- 依賴：`plans/001-rollback-on-interrupt.md`
- 類別：tests
- 規劃基準：commit `35cd49b`，2026-07-18

* * *

## 為何需要處理

111 份 provider YAML 與 `all-models.yaml` 都由同一個 renderer 產生；`--check` 只確認 checked-in 檔案等於該 renderer 的輸出，`validate_skills.py` 則只確認 YAML 可解析。如果 renderer 把 API key、base URL、API version 或 alias 同時產錯，兩道閘門仍可能通過。

**本計畫建立不依賴 renderer helper 計算預期值的獨立契約測試，作為後續 catalog 驗證重構的特性基線。**

* * *

## 目前狀態

- `scripts/generate_byok_forge_examples.py:69-83`：依 provider 欄位組合 `model_name`、`model`、`api_key`、`api_base` 與 `api_version`。
- `scripts/generate_byok_forge_examples.py:128-175`：加入共通 `drop_params` 與 `master_key`。
- `scripts/generate_byok_forge_examples.py:325-366`：回傳以相對路徑為 key 的全部記憶體輸出。
- `tests/test_generate_byok_forge_examples.py`：目前測試名稱、遠端刷新、drift 與 writer，但沒有解析代表性生成 YAML。
- `requirements-dev.txt:1`：已固定 PyYAML，測試不需新增依賴。

核心 production code：

    if not provider.get("keyless"):
        lines.append(f"      api_key: os.environ/{provider['env']}")
    if provider.get("needs_base"):
        lines.append(f"      api_base: {quote(provider['base_default'])}")
    if provider.get("needs_version"):
        lines.append(f"      api_version: {quote(provider['version_default'])}")

既有測試會透過 `load_generator()` 動態載入腳本，並使用 `unittest.TestCase`。新測試必須沿用這個入口，不可用 subprocess 呼叫 generator，也不可讀取已生成 YAML 作為預期答案。

* * *

## 需要的命令

| 用途 | 命令 | 成功預期 |
|---|---|---|
| 安裝開發依賴 | `python3 -m pip install -r requirements-dev.txt` | exit 0 |
| 目標測試 | `python3 -m unittest -v tests.test_generate_byok_forge_examples` | 所有 generator 測試通過 |
| 完整測試 | `python3 -m unittest discover -v` | 全部通過 |
| 技能驗證 | `python3 scripts/validate_skills.py` | 7 個 skills 通過 |
| 生成物同步 | `python3 scripts/generate_byok_forge_examples.py --check` | 115 份檔案通過 |

* * *

## 範圍

### 可修改

- `tests/test_generate_byok_forge_examples.py`
- `plans/README.md`，僅更新本計畫狀態

### 只讀參考

- `scripts/generate_byok_forge_examples.py`
- `examples/litellm-byok-forge/catalog.json`
- `requirements-dev.txt`

### 不可修改

- Production generator、catalog 與全部生成物。
- 不安裝 LiteLLM，不啟動 Proxy，不呼叫 provider。
- 不建立完整文字 snapshot；測試應驗證結構化欄位與不變條件。
- 不使用 `model_alias()`、`model_entry()` 或 `config_text()` 計算預期值，否則會重複 production bug。

* * *

## Git 工作流程

- 分支：`advisor/002-test-generated-yaml-contract`
- 建議提交標題：`test(generator): 驗證生成 YAML 語意契約`
- 提交訊息遵守 Conventional Commits 1.0.0。
- 若操作者要求提交，使用 `commit_msg_file="$(mktemp -t codex-commit-message)"` 建立 UTF-8 暫存檔，以編輯器寫入標題、必要空白第二行及正文，再固定執行 `git commit -F "$commit_msg_file"`。不得使用 `-m`。
- 不得自行 push 或開啟 pull request。

* * *

## 執行步驟

### 步驟 1：建立 catalog 與 YAML 載入 helper

在測試模組加入 `import yaml`。加入只供測試使用的 helper，負責：

1. 從 `examples/litellm-byok-forge/catalog.json` 讀取新的 catalog 物件。
2. 呼叫 `render_outputs(catalog)` 取得記憶體輸出。
3. 以 `yaml.safe_load` 解析指定相對路徑。

每個測試應取得新的 catalog，避免測試之間共享可變狀態。helper 不得呼叫 generator 的 alias 或 entry helper。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples` → 既有測試仍全部通過。

### 步驟 2：驗證五種代表性契約

新增至少五個清楚命名的測試，分開涵蓋：

1. 一般有 key provider：使用 OpenAI 的一份現有輸出，斷言 alias、provider-prefixed model、環境變數引用存在，且沒有 `api_base` 與 `api_version`。
2. Azure：斷言 key、base URL 與 API version 三者都存在，underlying model 使用 `azure/` prefix。
3. 本機 keyless Ollama：斷言沒有 `api_key`，但具有 loopback `api_base`。
4. 直接 Ollama Cloud：斷言同時具有環境變數 API key、HTTPS base URL 與 `ollama_chat/` route。
5. `all-models.yaml`：斷言 entry 數等於 catalog 內所有 models 的總和、所有 `model_name` 唯一，且每個單一輸出對應的 alias 可在合併輸出找到。

每份解析結果也要斷言：

- `litellm_settings.drop_params` 是布林值 `True`。
- `general_settings.master_key` 是環境變數引用，不是實際憑證。
- `model_list` 是非空 list，每個 item 含一個 `litellm_params` mapping。

預期值要直接寫成測試契約，或從原始 catalog 的資料欄位取得；不可透過 production formatter 產生。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples` → 五個新測試及全部既有測試顯示 `ok`。

### 步驟 3：執行完整維護閘門

**驗證**：

- `python3 -m unittest discover -v` → 全部通過。
- `python3 scripts/validate_skills.py` → 7 個 skills 通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過。

* * *

## 測試計畫

- 新增五個 provider／合併輸出契約測試。
- 一般、Azure、本機、Cloud 與合併檔必須各自有獨立失敗定位。
- 使用 `yaml.safe_load` 驗證解析後資料，不比對整份文字。
- 測試不讀取 checked-in provider YAML 作為 oracle；唯一輸入來源是 catalog，預期語意由測試明確聲明。

* * *

## 完成條件

- [ ] `rg -n "^import yaml$" tests/test_generate_byok_forge_examples.py` 找到測試依賴。
- [ ] 至少五個新測試名稱明確包含 standard、azure、keyless、cloud、combined 或等價語意。
- [ ] 新測試沒有呼叫 `model_alias`、`model_entry` 或 `config_text` 來建立預期值。
- [ ] 目標測試、完整測試、技能驗證與生成物同步檢查全部通過。
- [ ] `git diff --name-only` 只包含測試檔與允許的計畫狀態列。
- [ ] Production generator、catalog 與生成物沒有任何 diff。
- [ ] `plans/README.md` 狀態已更新，除非審查者維護索引。

* * *

## 停止條件

- Plan 001 尚未完成，或其測試變更造成無法辨識的衝突。
- 目前 catalog 已沒有一般、Azure、keyless 本機、直接 Cloud 任一代表性類型。
- 測試必須安裝或啟動 LiteLLM 才能驗證；本計畫只處理 renderer 的結構契約。
- 唯一可行做法是比對完整生成文字 snapshot。
- 任一驗證連續兩次失敗且合理修正無法排除。

* * *

## 維護備註

- 新增 provider 旗標或更改輸出欄位時，必須先更新契約測試，再修改 renderer。
- `drop_params: true` 是現有文件記錄的刻意預設；本計畫只鎖定現況，不重新決策。
- 這些測試不能證明 LiteLLM 當前版本一定接受設定；真正的 LiteLLM config 載入屬於後續整合測試。
