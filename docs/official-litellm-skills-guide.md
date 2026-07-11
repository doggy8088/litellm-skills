# LiteLLM 官方 `litellm-skills` 完整使用教學

> 查證日期：2026-07-11  
> 官方儲存庫基準：[`b13e7fc1bf2c3149625bcf5964fee2881fd3d027`](https://github.com/BerriAI/litellm-skills/tree/b13e7fc1bf2c3149625bcf5964fee2881fd3d027)

LiteLLM 官方 `litellm-skills` 是一組符合 Agent Skills 格式的操作指令，讓支援該標準的 agent 使用 `curl` 管理正在執行的 LiteLLM Proxy。它不是 LiteLLM Python SDK，也不是只產生 `config.yaml` 的教學內容；它會直接呼叫 Proxy 管理 API，建立、修改或刪除正式資源。[官方說明](https://docs.litellm.ai/docs/tutorials/claude_code_skills)

**這些 skills 具備改變 live proxy 狀態的能力。正式環境必須使用最小權限、變更確認、操作稽核及可回復流程。**

* * *

## 1. 適用情境

適合使用官方 skills 的情境：

- 已有一個可連線的 LiteLLM Proxy。
- 管理者希望透過 agent 建立或維護 users、teams、keys、organizations、models、MCP servers 或 agents。
- 需要按日期、使用者、團隊、組織、tag 或 job 查詢 spend、tokens 與 request activity。
- 操作者理解 agent 將執行真實 HTTP 管理請求，並能審查預定變更。

不適合直接使用的情境：

- 只想學習 LiteLLM SDK、Router 或 Proxy 設定概念。
- 沒有 Proxy admin key，只有一般模型呼叫 key。
- 無法確認 agent 會連到測試環境還是正式環境。
- 不能接受 agent 直接建立、更新或刪除資源。
- 組織尚未建立密鑰管理、稽核與變更回復制度。

* * *

## 2. 運作架構

執行一個官方 skill 時，通常會經過以下流程：

1. Agent 讀取該目錄的 `SKILL.md`。
2. 確認或詢問 `LITELLM_BASE_URL` 與 `LITELLM_API_KEY`。
3. 收集操作需要的欄位，例如 user email、team ID、model ID 或 budget。
4. 對刪除操作列出現有資源並要求確認。
5. 使用 `curl` 呼叫 LiteLLM Proxy API。
6. 顯示回應中的識別碼、變更後欄位或錯誤細節。
7. 部分 skills 會再執行查詢或測試呼叫驗證結果。

官方 skill 的 frontmatter 以 `allowed-tools` 限定 `curl`，`view-usage` 另允許 `python3` 做結果彙整。不過是否真正強制這項限制，仍取決於使用的 Agent Skills 客戶端。[官方原始碼](https://github.com/BerriAI/litellm-skills)

* * *

## 3. 前置條件

官方列出的必要條件如下：[官方 README](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/README.md)

- 已安裝 `curl`。
- 有一個正在執行且可連線的 LiteLLM Proxy。
- 具有 Proxy admin key，而不是只允許 `llm_api_routes` 的一般 virtual key。
- 安裝腳本另外需要 `git`。
- `view-usage` 的彙整範例需要 `python3`。

先確認本機工具：

```sh
curl --version
git --version
python3 --version
```

確認 Proxy URL 時應包含 scheme，例如：

```text
https://litellm.example.com
```

**正式環境不得使用未加密的 HTTP 傳送 admin key。**

* * *

## 4. 安全安裝

### 4.1 官方快速安裝方式

官方 README 提供以下命令：

```sh
curl -fsSL https://raw.githubusercontent.com/BerriAI/litellm-skills/main/install.sh | sh
```

該腳本會：

1. 把 repo clone 到 `~/.claude/skills/litellm`。
2. 若該目錄已是 Git repo，執行 `git pull --ff-only`。
3. 對 repo 第一層的每個目錄，在 `~/.claude/skills/` 建立符號連結。

可直接閱讀[官方安裝腳本](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/install.sh)。

### 4.2 建議的可審查安裝方式

**正式環境不應直接執行從可變 `main` 分支下載的 shell script。** 建議固定 commit，先審查再安裝：

```sh
git clone https://github.com/BerriAI/litellm-skills.git
cd litellm-skills
git checkout b13e7fc1bf2c3149625bcf5964fee2881fd3d027
git verify-commit b13e7fc1bf2c3149625bcf5964fee2881fd3d027 || true
sed -n '1,240p' install.sh
```

`git verify-commit` 只有在該 commit 具有可驗證簽章時才會成功；失敗不等於內容必然有問題，但表示不能以簽章確認來源。審查完成後再執行：

```sh
sh install.sh
```

安裝腳本固定寫入 Claude Code 路徑。其他 Agent Skills 客戶端可能使用不同目錄，因此不能假設腳本適用所有客戶端。

### 4.3 確認安裝結果

```sh
find "$HOME/.claude/skills" -maxdepth 1 -type l -print
git -C "$HOME/.claude/skills/litellm" rev-parse HEAD
```

重新啟動或重新載入 Agent Skills 客戶端後，確認 `/add-model`、`/add-user` 或 `/view-usage` 能被發現。

* * *

## 5. 連線與憑證設定

每個 skill 都需要以下兩項資訊：

```sh
export LITELLM_BASE_URL="https://litellm.example.com"
export LITELLM_API_KEY="<proxy-admin-key>"
```

官方 `SKILL.md` 的命令範例通常以 `$BASE` 與 `$KEY` 呼叫 API；agent 應將它們對應至上述環境變數：

```sh
BASE="$LITELLM_BASE_URL"
KEY="$LITELLM_API_KEY"
```

安全要求：

- 不把 admin key 寫入 repo、聊天內容、shell script 或投影片。
- 不使用 `set -x`，避免 shell trace 顯示 key。
- 不把完整 `curl` 命令貼入會永久保存的 ticket 或 log。
- 正式環境使用專用管理身分，不與一般應用程式共用 key。
- 在測試與正式環境使用不同 URL、key 及明確命名。
- 操作結束後清除目前 shell 的敏感環境變數：

```sh
unset LITELLM_API_KEY
```

* * *

## 6. Skills 總覽

固定基準版本共有 **22 個 skills**。

| 類別 | 新增 | 更新 | 刪除 | 查詢 |
| --- | --- | --- | --- | --- |
| Users | `add-user` | `update-user` | `delete-user` | 由操作 skill 呼叫 `/user/list` |
| Teams | `add-team` | `update-team` | `delete-team` | 由操作 skill 呼叫 `/team/list` 或 `/team/info` |
| API Keys | `add-key` | `update-key` | `delete-key` | 由操作 skill 呼叫 `/key/list` 或 `/key/info` |
| Organizations | `add-org` | 無 | `delete-org` | 由刪除 skill 呼叫 `/organization/list` |
| Models | `add-model` | `update-model` | `delete-model` | 由操作 skill 呼叫 `/model/info` |
| MCP Servers | `add-mcp` | `update-mcp` | `delete-mcp` | 由操作 skill 呼叫 `/v1/mcp/server` |
| Agents | `add-agent` | `update-agent` | `delete-agent` | 由操作 skill 呼叫 `/v1/agents` |
| Usage | 無 | 無 | 無 | `view-usage` |

**官方目前沒有 `update-org` skill。這是原始 repo 的實際狀態，不代表 LiteLLM API 一定沒有相應能力。**

* * *

## 7. Users

### 7.1 `add-user`

用途：建立使用者，設定 email、role、budget 與可用 models。[原始 skill](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/add-user/SKILL.md)

- Endpoint：`POST /user/new`
- 必填：`user_email`
- Role：`proxy_admin`、`proxy_admin_viewer`、`internal_user`、`internal_user_viewer`
- 選填：`max_budget`、`models`
- 重要回應：`user_id`、自動產生的 `key`、role、budget

使用方式：

```text
/add-user
```

Agent 會詢問 email、role、預算與模型清單。建立後必須安全保存 `user_id`；若回應包含新 key，應視為 secret 處理。

### 7.2 `update-user`

- Endpoint：`POST /user/update`
- 識別欄位：`user_id`
- 可更新：`max_budget`、`user_role`、`models`、`tpm_limit`、`rpm_limit`、`user_email`、`user_alias`
- 找不到 ID 時會先呼叫 `GET /user/list?page_size=25`

Skill 指示只送出需要改變的欄位，避免用空值覆寫其他設定。[原始 skill](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/update-user/SKILL.md)

### 7.3 `delete-user`

- Endpoint：`POST /user/delete`
- Body：`user_ids` 陣列，可一次刪除多位使用者
- 執行前：列出使用者、顯示 email 或 alias 並要求確認

**刪除前應另外盤點該使用者擁有的 keys、teams、spend 歸屬與依賴服務；官方 skill 本身只要求確認使用者身分。**

* * *

## 8. Teams

### 8.1 `add-team`

- Endpoint：`POST /team/new`
- 必填：team alias
- 選填：`max_budget`、`models`、`tpm_limit`、`rpm_limit`
- 驗證：`GET /team/info?team_id=<team_id>`

### 8.2 `update-team`

- Endpoint：`POST /team/update`
- 識別欄位：`team_id`
- 可更新：budget、models、TPM/RPM limits 等欄位
- 找不到 ID 時：`GET /team/list`

### 8.3 `delete-team`

- Endpoint：`POST /team/delete`
- Body：`team_ids` 陣列
- 執行前必須顯示 team alias 並確認

Team skills 的固定版本原始碼位於[官方 repo](https://github.com/BerriAI/litellm-skills/tree/b13e7fc1bf2c3149625bcf5964fee2881fd3d027)。刪除 team 前應確認既有 keys 是否仍需要重新指派。

* * *

## 9. API Keys

### 9.1 `add-key`

- Endpoint：`POST /key/generate`
- 選填：`key_alias`、`team_id`、`user_id`、`models`、`max_budget`、`duration`
- Duration 範例：`7d`、`30d`、`90d`
- 驗證：使用新 key 呼叫 `GET /key/info`
- 重要回應：實際 key、alias、expires、budget、models

**新 key 的完整值可能只顯示一次，必須立即存入受控 secret manager，不應保存在一般聊天紀錄。**

### 9.2 `update-key`

- Endpoint：`POST /key/update`
- 識別欄位：完整 `sk-...` key
- 可更新：budget、models、alias、TPM/RPM、duration、team 或 user ownership
- 找不到 key 時：`GET /key/list?size=25&return_full_object=true`

`return_full_object=true` 可能回傳敏感資訊；輸出結果不得直接貼到共用 log。

### 9.3 `delete-key`

- Endpoint：`POST /key/delete`
- 依 key value 刪除：`keys` 陣列
- 依 alias 刪除：`key_aliases` 陣列
- 執行前應列出 alias 並確認

Key 操作的官方細節可見 [`add-key`](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/add-key/SKILL.md)、[`update-key`](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/update-key/SKILL.md) 與 [`delete-key`](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/delete-key/SKILL.md)。

* * *

## 10. Organizations

### 10.1 `add-org`

- Endpoint：`POST /organization/new`
- 收集 organization alias、budget、budget duration 與 allowed models
- 回報 organization ID、alias 與預算設定

### 10.2 `delete-org`

- Endpoint：`DELETE /organization/delete`
- Body 包含 `organization_ids`
- 找不到 ID 時：`GET /organization/list`
- 執行前顯示 org alias 並確認

**固定基準沒有 `update-org` skill；需要更新組織時應先查核目前 LiteLLM API，而不是把其他資源的 update endpoint 套用過來。**

* * *

## 11. Models

### 11.1 `add-model`

- Endpoint：`POST /model/new`
- 必要概念：公開 `model_name` 與實際 `litellm_params.model`
- Provider 可能需要 `api_key`、`api_base`、`api_version`、project 或 location
- 建立後：呼叫 `POST /chat/completions`，以少量 tokens 驗證路由
- 重要回應：`model_id`

官方 skill 內的 provider model 名稱只是範例，可能隨時間失效。新增前應查核[目前支援的 providers](https://docs.litellm.ai/docs/providers)。

### 11.2 `update-model`

- Endpoint：`POST /model/update`
- 識別欄位：`model_info.id`
- 可更新：provider API key、base URL、API version、underlying model
- 找不到 ID 時：`GET /model/info`
- 更新後應重新執行最小 completion

**官方範例把 provider credential 放入 JSON body。操作時不得輸出請求 body，並應優先使用 LiteLLM 支援的 secret reference 或 secret manager。**

### 11.3 `delete-model`

- Endpoint：`POST /model/delete`
- Body：`id`，值為 model ID
- 若只有 model name，先由 `/model/info` 找出 ID
- 執行前顯示 model name 並確認

刪除後，限定該 model alias 的 keys 或依賴該 alias 的應用程式可能立即失敗。

* * *

## 12. MCP Servers

### 12.1 `add-mcp`

- Endpoint：`POST /v1/mcp/server`
- 收集：名稱、transport、URL、選用 auth、description 與 allowed tools
- 支援範圍依固定 skill 描述包含 SSE、HTTP 或 stdio

### 12.2 `update-mcp`

- Endpoint：`PUT /v1/mcp/server`
- 識別欄位：server ID
- 可更新：URL、auth、description 等欄位
- 找不到 ID 時：`GET /v1/mcp/server`

### 12.3 `delete-mcp`

- Endpoint：`DELETE /v1/mcp/server/<server_id>`
- 執行前列出 server name 與 URL 並確認
- 刪除後，使用該 server 的 agents 將失去工具存取

**MCP server 應視為外部程式碼與資料來源。註冊前必須審查來源、認證、資料流、工具清單與寫入能力；不要把整個 server 的工具無限制開放。** [LiteLLM MCP 文件](https://docs.litellm.ai/docs/mcp)

* * *

## 13. Agents

### 13.1 `add-agent`

- Endpoint：`POST /v1/agents`
- 收集：agent name、description、underlying model 與選用 MCP servers
- 可用 `GET /v1/agents` 列出 agents
- 可用 `GET /v1/agents/<agent_id>` 查詢單一 agent

### 13.2 `update-agent`

- Endpoint：`PATCH /v1/agents/<agent_id>`
- 可更新：model、description、MCP servers
- Agent ID 應維持不變

### 13.3 `delete-agent`

- Endpoint：`DELETE /v1/agents/<agent_id>`
- 執行前列出 agent name 並確認
- 刪除後，指向該 agent 的 keys 或 integrations 將停止運作

Agent API 的操作介面以固定版本的 [`add-agent` skill](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/add-agent/SKILL.md) 為查證基準；原始 skill 所列的 Agents 文件網址目前無法正常開啟，因此本文件不把該失效網址當成有效依據。

* * *

## 14. `view-usage`

`view-usage` 查詢每日 spend、tokens、requests 與失敗數，可依 user、team、organization、tag 或 job 分組。[原始 skill](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/view-usage/SKILL.md)

### 14.1 查詢端點

| 目的 | Endpoint |
| --- | --- |
| 全體每日 spend | `/user/daily/activity` |
| 全體 requests 與 tokens | `/global/activity` |
| Team activity | `/team/daily/activity` |
| Organization activity | `/organization/daily/activity` |
| User activity | `/user/daily/activity?user_id=...` |
| Tag 或 job activity | `/tag/daily/activity?tags=...` |
| Tags spend 排名 | `/global/spend/tags` |

範例：

```sh
BASE="$LITELLM_BASE_URL"
KEY="$LITELLM_API_KEY"

curl -s "$BASE/user/daily/activity?start_date=2026-07-01&end_date=2026-07-31&page_size=30" \
  -H "Authorization: Bearer $KEY"
```

### 14.2 Job 成本歸因

官方 skill 建議以穩定 request tag，例如 `job:nightly-eval`，查詢工作成本：

```sh
curl -s "$BASE/tag/daily/activity?tags=job:nightly-eval&start_date=2026-07-01&end_date=2026-07-31&page_size=30" \
  -H "Authorization: Bearer $KEY"
```

若要比較多個 tags，可傳逗號分隔值。若要找最昂貴工作，呼叫 `/global/spend/tags` 後依 spend 由高到低排序。

### 14.3 回應重點

固定版本的 activity 回應頂層使用 `results`，不是 `data`。每列通常包含：

- `date`
- `metrics.spend`
- `prompt_tokens`
- `completion_tokens`
- `total_tokens`
- `api_requests`
- `successful_requests`
- `failed_requests`
- model 或 provider breakdown

若 `metadata.total_pages > 1`，必須繼續分頁，否則彙總會低估用量。

**Tag 若由不受信任 client 自行提供，不應直接作為可信任的計費、授權或 budget 邊界。**

* * *

## 15. 建議操作流程

### 15.1 建立資源

1. 確認目前環境與 Proxy URL。
2. 先查詢既有資源，避免重複 alias 或名稱。
3. 收集必要欄位及 owner。
4. 顯示變更摘要，不顯示 secret。
5. 取得操作者確認。
6. 執行 add skill。
7. 查詢新資源或做最小 smoke test。
8. 保存 ID、owner、expiry 與稽核紀錄。

### 15.2 更新資源

1. 以 list/info endpoint 解析唯一 ID。
2. 讀取並保存修改前狀態，但遮罩 secret。
3. 只送出要改變的欄位。
4. 執行 update skill。
5. 再次查詢並比較前後差異。
6. 對 model、MCP 或 agent 執行最小功能測試。

### 15.3 刪除資源

1. 查詢唯一 ID、alias 與 owner。
2. 盤點依賴 keys、teams、agents、MCP tools 或應用程式。
3. 顯示刪除對象與預期影響。
4. 取得明確確認。
5. 執行 delete skill。
6. 再查詢確認資源不存在。
7. 監控錯誤率並保留回復資訊。

* * *

## 16. 完整教學情境

### 情境 A：建立團隊與限額 key

1. 執行 `/add-team`，設定 team alias、模型 allowlist 與極小 budget。
2. 保存回傳的 `team_id`。
3. 執行 `/add-key`，把 key 指派給該 team，設定 alias、models、budget 與 `7d` expiry。
4. 用新 key 呼叫 `/key/info`，確認 team、models、budget 與 expiry。
5. 執行 `/view-usage`，以 team ID 查詢測試用量。
6. 練習結束執行 `/delete-key`，再視需求執行 `/delete-team`。

### 情境 B：新增模型並驗證

1. 執行 `/add-model`。
2. 設定對外 alias 與 provider deployment。
3. 以受控方式提供 provider credential。
4. 保存 `model_id`。
5. 執行 skill 內的最小 completion。
6. 查詢用量與失敗 request。
7. 若測試失敗，先更新或刪除模型，避免留下無效 alias。

### 情境 C：建立只讀 MCP agent

1. 執行 `/add-mcp`，只註冊已審查的測試 MCP server。
2. 限制 allowed tools 為單一只讀工具。
3. 執行 `/add-agent`，指派低成本模型及該 MCP server。
4. 驗證 agent 只能看到允許的工具。
5. 執行 `/update-agent` 或 `/update-mcp` 測試權限調整。
6. 依相反順序刪除 agent，再刪除 MCP server。

* * *

## 17. 錯誤排除

| 現象 | 可能原因 | 檢查方式 |
| --- | --- | --- |
| `401` | Admin key 無效、過期或不是管理 key | 確認 `LITELLM_API_KEY` 來源與權限，不要輸出 key |
| `403` | Key 權限不足或路由受限 | 檢查角色、允許路由與 Proxy auth 設定 |
| `404` | Proxy 版本不支援 endpoint 或 URL 錯誤 | 查核 Proxy 版本、base URL 與官方 API 文件 |
| `400` | 欄位格式錯誤、ID 不存在或參照資源無效 | 顯示經遮罩的 `detail`，重新查詢 ID |
| 空結果 | 日期、filter、tag 或分頁不正確 | 確認時區、日期範圍、page size 與 total pages |
| Model 建立成功但呼叫失敗 | Provider key、base URL、deployment 或模型能力錯誤 | 執行最小 completion 並查 Proxy/provider log |
| MCP 無法列出工具 | Transport、URL、auth 或 allowed tools 錯誤 | 先直接檢查 server health，再檢查 Proxy 註冊 |
| Skill 沒有出現 | 安裝目錄或客戶端不支援 | 檢查符號連結、重新載入客戶端及其 skills 路徑 |

**官方多數 curl 範例使用 `-s`，不會自動把 HTTP 非 2xx 視為 shell 失敗。自動化流程應另外擷取狀態碼或採 `--fail-with-body`，避免把錯誤 JSON 當成成功結果。**

* * *

## 18. 升級、回復與卸載

### 18.1 官方腳本的升級行為

再次執行 `install.sh` 時，如果 `~/.claude/skills/litellm/.git` 存在，腳本會執行：

```sh
git -C "$HOME/.claude/skills/litellm" pull --ff-only
```

這會跟隨遠端預設分支，不會維持先前固定的 commit。

### 18.2 建議升級流程

```sh
cd "$HOME/.claude/skills/litellm"
git fetch origin
git log --oneline HEAD..origin/main
git diff HEAD..origin/main -- '*/SKILL.md' install.sh
```

審查 API endpoint、欄位、allowed tools 與安裝腳本後，再 checkout 已核准 commit。升級失敗時可 checkout 上一個已知良好 commit。

### 18.3 卸載

官方 repo 沒有提供卸載腳本。依目前 `install.sh` 的行為，卸載時應：

1. 先列出指向 `~/.claude/skills/litellm/*/` 的符號連結。
2. 只移除這些已確認屬於官方 repo 的符號連結。
3. 再移除 `~/.claude/skills/litellm` clone。

不要以廣泛 wildcard 刪除 `~/.claude/skills/*`，該目錄可能包含其他使用者 skills。

* * *

## 19. 已確認的限制

- 官方安裝腳本固定針對 `~/.claude/skills`，不是通用客戶端安裝器。
- 固定基準只有 `view-usage` 的專門測試檔；不能據此推定其餘 21 個 skills 都有自動整合測試。
- 多數範例直接使用 `curl -s`，沒有一致展示 HTTP status 檢查。
- 部分 `SKILL.md` 仍連到舊的 `litellm.vercel.app` 文件網址；使用時應改由目前 `docs.litellm.ai` 文件交叉查核。
- Provider model 名稱、API schema、角色、activity endpoints 及授權方案可能隨 LiteLLM 版本改變。
- 官方 skills 是操作說明，不會自動提供交易式 rollback。

**未在官方來源確認的欄位或 endpoint，不應由相似資源的命名方式推測。**

* * *

## 20. 與本專案教學 skills 的差異

| 面向 | 官方 `BerriAI/litellm-skills` | 本專案教學 skills |
| --- | --- | --- |
| 目的 | 管理 live LiteLLM Proxy | 教學、設計、審查與驗收 |
| 行為 | 直接執行 Proxy 管理 API | 指導安全實作與測試流程 |
| 權限 | 需要 Proxy admin key | 多數內容不需正式管理權限 |
| 風險 | 可建立、修改、刪除正式資源 | 主要風險是產生錯誤設定或教材 |
| 範圍 | Users、teams、keys、orgs、models、MCP、agents、usage | SDK、Proxy、routing、成本、觀測、安全、MCP |
| 適合對象 | 受控管理者與自動化 agent | 學生、教師、開發者與平台設計者 |

**需要直接操作 Proxy 時使用官方 skills；需要理解、設計或驗證 LiteLLM 解決方案時使用本專案 skills。兩者可以搭配，但不應混淆權限與責任。**

* * *

## 21. 官方來源

- [LiteLLM Skills 官方文件](https://docs.litellm.ai/docs/tutorials/claude_code_skills)
- [BerriAI/litellm-skills](https://github.com/BerriAI/litellm-skills)
- [本文件固定檢視版本](https://github.com/BerriAI/litellm-skills/tree/b13e7fc1bf2c3149625bcf5964fee2881fd3d027)
- [LiteLLM Virtual Keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [LiteLLM Model Management](https://docs.litellm.ai/docs/proxy/model_management)
- [LiteLLM MCP](https://docs.litellm.ai/docs/mcp)
- [官方 `add-agent` skill](https://github.com/BerriAI/litellm-skills/blob/b13e7fc1bf2c3149625bcf5964fee2881fd3d027/add-agent/SKILL.md)
- [Agent Skills 規格](https://agentskills.io/specification)
