# Plan 003: 在渲染前拒絕不合法的 catalog

> **執行者指示**：依序完成本計畫。先讀完整檔案，再執行每個驗證命令。遇到「停止條件」時停止並回報，不得為了讓測試通過而放寬契約。完成後更新 `plans/README.md` 狀態；若審查者明確維護索引，則不要修改狀態列。
>
> **漂移檢查**：執行 `git diff --stat 35cd49b..HEAD -- scripts/generate_byok_forge_examples.py tests/test_generate_byok_forge_examples.py examples/litellm-byok-forge/catalog.json`。Plans 001–002 完成後，generator 的中斷邊界與新增契約測試是預期差異。若 live catalog 欄位、`render_outputs()` 或 `main()` 的控制流程與「目前狀態」不符，停止並回報。

* * *

## 狀態

- 優先級：P1
- 工作量：M
- 風險：MED
- 依賴：`plans/002-test-generated-yaml-contract.md`
- 類別：tech-debt
- 規劃基準：commit `35cd49b`，2026-07-18

* * *

## 為何需要處理

目前 `render_outputs()` 只驗證 `providers`、provider 與 `models` 的容器型別，再直接把 provider id 放入路徑、把環境變數名稱放入 YAML，並用 Python truthiness 解讀 `keyless`、`needs_base` 與 `needs_version`。人工編輯 catalog 時，字串型 `false`、含路徑分隔符的 id、含換行的文字或缺少條件必要欄位，都可能在後段產生錯置檔案、無效設定或不清楚的 `KeyError`。

**完成後，catalog 必須在任何路徑計算、文字渲染或遠端刷新之前通過單一、具欄位脈絡的結構契約。**

* * *

## 目前狀態

- `examples/litellm-byok-forge/catalog.json:1-8`：root 具有 `source` 與 `providers`。
- `catalog.json:131-143`：Azure 同時使用 `needs_base`、`needs_version`、`base_default` 與 `version_default`。
- `catalog.json:146-158`：本機 Ollama 是 `keyless: true`，env 為空字串，仍需要 HTTP base。
- `catalog.json:161-172`：直接 Ollama Cloud 有 provider source metadata。
- `catalog.json:211-260`：本機登入型 Cloud 同時是 keyless、有 base、有 source。
- `scripts/generate_byok_forge_examples.py:325-347`：現行結構檢查僅涵蓋容器型別與重複 id／alias。
- `scripts/generate_byok_forge_examples.py:528-533`：`main()` 在讀取 catalog 後，可能先刷新遠端資料，之後才進入 `render_outputs()`。

現行判斷：

    if not provider.get("keyless"):
        lines.append(f"      api_key: os.environ/{provider['env']}")
    if provider.get("needs_base"):
        lines.append(f"      api_base: {quote(provider['base_default'])}")

測試慣例：

- 使用 JSON 讀取真實 catalog，再修改 deep copy 或新讀取的物件製造單一錯誤。
- 使用 `self.subTest` 表格化同類失敗案例。
- 對無效資料斷言 `ValueError`，訊息使用正體中文並指出欄位。

* * *

## 需要的命令

| 用途 | 命令 | 成功預期 |
|---|---|---|
| 安裝依賴 | `python3 -m pip install -r requirements-dev.txt` | exit 0 |
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

### 只讀

- `examples/litellm-byok-forge/catalog.json`

### 不可修改

- 不改 catalog 內容來迎合驗證器。
- 不改任何 checked-in 生成物；現有 catalog 的輸出必須 byte-for-byte 不變。
- 不把完整 catalog 驗證複製到 `scripts/validate_skills.py`；generator 的 `--check` 是此契約的權威入口。
- 不新增第三方 schema 套件。
- 不限制合法模型名稱到比既有 `MODEL_NAME_PATTERN` 更窄。

* * *

## Git 工作流程

- 分支：`advisor/003-validate-catalog-schema`
- 建議提交標題：`fix(generator): 驗證 catalog 結構契約`
- 提交訊息遵守 Conventional Commits 1.0.0。
- 若操作者要求提交，以 `commit_msg_file="$(mktemp -t codex-commit-message)"` 建立隨機 UTF-8 暫存檔，寫入標題、空白第二行及測試正文，再執行 `git commit -F "$commit_msg_file"`。不得使用 `-m`。
- 不得自行 push 或建立 pull request。

* * *

## 目標契約

實作單一 `validate_catalog(catalog: object) -> None`，錯誤時拋出 `ValueError`。契約至少包含：

| 區域 | 規則 |
|---|---|
| Root | 必須是 mapping；只允許並要求 `source`、`providers` |
| Root source | 必須是 mapping；`repository`、`commit`、`file`、`page`、`extracted_at` 都是無控制字元的非空字串；commit 是 40 位十六進位，page 是具有 host 的 HTTP 或 HTTPS URL |
| Providers | 必須是非空 list；每項是 mapping |
| Provider id | 符合 `[a-z0-9]+(?:_[a-z0-9]+)*`，不可含 slash、反斜線、dot segment 或空白；全域唯一 |
| Name | 無 CR、LF 或 NUL 的非空字串 |
| Prefix | 符合 `[a-z][a-z0-9_]*` |
| Flags | `keyless`、`needs_base`、`needs_version` 若存在，型別必須恰為 bool；缺少時視為 false |
| Environment | `env` 必須是字串；非 keyless 時符合 `[A-Z][A-Z0-9_]*`，keyless 時必須是空字串 |
| Base | `needs_base: true` 時，`base_default` 必須是具有 host 的 HTTP 或 HTTPS URL；false 時可省略 |
| Version | `needs_version: true` 時，`version_default` 必須是無控制字元的非空字串；false 時可省略 |
| Models | 非空 list；每個值通過既有 `validate_model_name()`；同 provider 內不得產生重複 alias |
| Provider source | 若存在，必須是 mapping，並要求無控制字元的 `type`、HTTP 或 HTTPS `url`、HTTP 或 HTTPS `docs`、ISO date 形式的 `retrieved_at` |
| Unknown fields | Root、root source、provider 與 provider source 的未知欄位要拒絕，防止拼字錯誤靜默失效 |

Provider error 必須包含 provider index，能取得合法 id 時也要包含 id；例如指出 `providers[3].needs_base`，而不是只顯示 `KeyError`。

* * *

## 執行步驟

### 步驟 1：先加入 catalog 契約測試

在 generator 測試模組新增 helper，每次從真實 catalog 重新讀取資料。新增測試：

1. 現有 catalog 通過 `validate_catalog()` 且 `render_outputs()` 仍產生 115 個 output entries。
2. provider id 含路徑分隔符時拒絕。
3. env 含控制字元或小寫格式時拒絕。
4. 三個旗標使用字串或整數時拒絕。
5. `needs_base: true` 缺少或使用無效 base 時拒絕。
6. `needs_version: true` 缺少 version 時拒絕。
7. 非 keyless provider 缺少合法 env，以及 keyless provider 使用非空 env 時拒絕。
8. root source 或 provider source 缺欄位、URL 無 host、日期格式錯誤時拒絕。
9. provider、模型或 alias 重複時拒絕。
10. 未知欄位時拒絕，錯誤訊息包含欄位路徑。

使用 `copy.deepcopy` 或重新讀 JSON，避免測試互相污染。不要在測試中放入可用憑證。

**驗證**：在 production function 尚未實作前，`python3 -m unittest -v tests.test_generate_byok_forge_examples` 預期因缺少 `validate_catalog` 或錯誤資料未被拒絕而失敗。

### 步驟 2：實作集中式驗證 helper

在 generator 靠近現有 pattern 常數與 `validate_model_name()` 的位置新增：

- provider id、prefix、環境變數與日期 pattern。
- 無控制字元字串檢查 helper。
- HTTP／HTTPS URL 檢查 helper，使用標準函式庫，不新增依賴。
- `validate_catalog()`，先驗證型別再索引欄位，避免 `KeyError` 或 `AttributeError`。

保留 `validate_model_name()` 作為模型名稱的單一權威。不要在多個 renderer 函式重複 schema 判斷。

**驗證**：`python3 -m unittest -v tests.test_generate_byok_forge_examples` → 新增 invalid fixture 測試全部通過。

### 步驟 3：在所有正式入口套用契約

- `render_outputs()` 的第一個動作必須是 `validate_catalog(catalog)`，再建立 entries。
- `main()` 讀取 JSON 後、判斷 `--refresh-ollama-cloud` 前先驗證一次，確保 malformed catalog 不會觸發網路。
- 遠端刷新後仍由 `render_outputs()` 再驗證一次，確認 mutation 也符合契約。
- 保持直接測試 `refresh_ollama_cloud_catalog()` 所使用的最小 catalog fixture 可用；該低階函式本身不必要求完整 root schema。

**驗證**：

- `python3 -m unittest -v tests.test_generate_byok_forge_examples` → 全部通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過，且 `git diff -- examples/litellm-byok-forge` 無輸出。

### 步驟 4：執行完整維護閘門

**驗證**：

- `python3 -m unittest discover -v` → 全部通過。
- `python3 scripts/validate_skills.py` → 7 個 skills 通過。
- `python3 scripts/generate_byok_forge_examples.py --check` → 115 份檔案通過。

* * *

## 測試計畫

- 至少一個現有 catalog 成功案例。
- 每個條件必要欄位一個失敗案例。
- flags 採錯誤 truthy 值的回歸案例。
- 路徑、環境變數與文字控制字元案例。
- root 與 provider source metadata 案例。
- 重複 provider id、重複模型／alias 案例。
- 錯誤訊息至少斷言欄位路徑，避免重新退化成裸 `KeyError`。
- Plan 002 的五種生成 YAML 語意測試必須全數維持通過。

* * *

## 完成條件

- [ ] `validate_catalog()` 是所有 rendering 的單一入口。
- [ ] `main()` 在遠端請求前驗證 checked-in catalog。
- [ ] 現有 catalog 不需修改即可通過。
- [ ] `python3 scripts/generate_byok_forge_examples.py --check` 通過且生成物無 diff。
- [ ] Invalid schema 測試涵蓋表格中的全部規則。
- [ ] 所有錯誤都是具 provider／欄位脈絡的 `ValueError`。
- [ ] 完整測試與技能驗證通過。
- [ ] `git diff --name-only` 只包含 generator、其測試及允許的狀態列。
- [ ] `plans/README.md` 狀態已更新，除非審查者維護索引。

* * *

## 停止條件

- Plans 001 或 002 尚未完成，或新增測試不在 live 分支。
- 現有 catalog 的合法值不符合本計畫規則；停止並列出值與規則衝突，不得直接放寬整類限制。
- 需要修改 catalog 或 checked-in 生成物才能讓驗證通過。
- 需要新增第三方 schema 套件。
- 驗證器開始依賴網路、LiteLLM runtime 或 provider 憑證。
- 任一驗證連續兩次失敗且合理修正無法排除。

* * *

## 維護備註

- 新增 catalog 欄位時，先更新 allowed fields、條件規則與 invalid／valid 測試，再更新 renderer。
- 審查時確認所有字串都在進入檔案路徑、YAML、Markdown 或環境變數範本前完成驗證。
- `_safe_target()` 仍是最終 filesystem 邊界，不可因 provider id 已驗證而移除。
- 本計畫不處理遠端回應大小上限；該安全強化已列為後續發現。
