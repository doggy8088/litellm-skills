# LiteLLM 與 Ollama Cloud 模型支援查核報告

> 查核日期：2026-07-12（Asia/Taipei）
>
> LiteLLM 原始碼基準：2c1d62ce2b586e047307c83d3ed79c64857287e8，上游 main 於 2026-07-11 建置。
>
> 本文件釐清「LiteLLM 支援哪些模型」與「Ollama Cloud 目前有哪些模型」不是同一份固定清單。模型供應商會動態新增、下架或改名；因此本文件同時保存可重現的靜態快照與查詢即時清單的方法。

* * *

## 1. 查核結論

**LiteLLM 沒有一份永遠完整且固定的 provider/model 清單。** 官方 provider 文件列出整合入口；部分 provider 明確宣稱支援該服務的全部模型，例如 Ollama、Fireworks AI、Together AI 與 OpenRouter。實際可呼叫的模型仍由上游服務、帳號權限、區域與模型版本決定。[LiteLLM Providers](https://docs.litellm.ai/docs/providers)

**Ollama Cloud 應視為 Ollama provider 的遠端 API，不是另一個 LiteLLM provider。** LiteLLM 官方文件建議使用 ollama_chat 呼叫 Ollama 的 /api/chat；LiteLLM 上游測試也以 [Ollama Cloud endpoint](https://ollama.com)、OLLAMA_API_KEY 及 ollama_chat/<model> 驗證 Ollama 的託管服務。[LiteLLM Ollama 文件](https://docs.litellm.ai/docs/providers/ollama)、[官方 Ollama Cloud 測試](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/tests/test_litellm/llms/ollama/test_ollama_model_info.py)

**截至本次查核，Ollama Cloud 的直接 API /api/tags 回傳 34 個可列出的模型名稱。** 這 34 個名稱是 https://ollama.com 遠端 API 的目前快照；不能把它誤當成 Ollama 本機安裝的模型清單。[Ollama Cloud 文件](https://docs.ollama.com/cloud)、[Ollama GET /api/tags 文件](https://docs.ollama.com/api/tags)、[本次查詢端點](https://ollama.com/api/tags)

**Ollama Cloud 模型庫頁面另外顯示 29 個模型家族、36 個帶有 :cloud 或尺寸標籤的雲端變體。** 模型庫的變體名稱與直接 API /api/tags 名稱不完全相同；設定 LiteLLM 時應以實際使用的端點回傳名稱為準。

* * *

## 2. LiteLLM provider 與模型清單的正確解讀方式

### 2.1 Provider 文件不是模型目錄

LiteLLM 的 [Providers 頁面](https://docs.litellm.ai/docs/providers) 是 provider 整合文件索引，包含 OpenAI、Azure、Anthropic、Gemini、Ollama、OpenRouter、vLLM 等入口。它不是每一個 provider 的即時模型 API，也不保證每個上游服務的模型名稱都會被完整複製到 LiteLLM 文件。

### 2.2 model_prices_and_context_window.json 是靜態 metadata

在本次查核的 LiteLLM commit 中，官方根目錄的 [model_prices_and_context_window.json](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/model_prices_and_context_window.json) 有 **2,963 筆 metadata 項目**。依 litellm_provider 欄位計算，原始資料出現 124 個不同值；其中包含一筆空值與一筆文件 URL 字串，因此不能直接把 124 當作 124 個有效 provider。這個檔案主要提供價格、上下文長度、模式及部分模型能力資訊；沒有出現在檔案中的模型仍可能可以透過 provider 前綴呼叫。

可在固定 commit 重現統計：

~~~sh
python3 - <<'PY'
import json
from urllib.request import urlopen

url = "https://raw.githubusercontent.com/BerriAI/litellm/2c1d62ce2b586e047307c83d3ed79c64857287e8/model_prices_and_context_window.json"
with urlopen(url) as response:
    data = json.load(response)

print("metadata entries:", len(data))
print("raw litellm_provider values:",
      len({item.get("litellm_provider") for item in data.values()}))
print("ollama entries:")
for model, item in sorted(data.items()):
    if item.get("litellm_provider") == "ollama":
        print("  ", model)
PY
~~~

### 2.3 LiteLLM 對 Ollama 採用動態列舉

LiteLLM 上游的 [OllamaModelInfo](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/litellm/llms/ollama/common_utils.py) 會向設定的 Ollama base URL 呼叫 /api/tags，從回應的 name 或 model 欄位建立模型名稱；查詢失敗時才退回靜態清單。因此，**若要顯示目前可用模型，應在啟動或定期同步時查詢目標 Ollama 端點，而不是只讀 LiteLLM 的靜態 JSON。**

~~~sh
# 本機 Ollama
curl -fsSL http://localhost:11434/api/tags

# Ollama Cloud；依 Ollama 文件，產生回應時仍須使用 API key
curl -fsSL https://ollama.com/api/tags \\
  -H "Authorization: Bearer ${OLLAMA_API_KEY}"
~~~

* * *

## 3. Ollama 與 Ollama Cloud 的 LiteLLM provider 前綴

| 使用情境 | LiteLLM model 前綴 | api_base | 驗證 | LiteLLM 送出的 Ollama API |
| --- | --- | --- | --- | --- |
| Ollama completion / generate | ollama/<model> | http://localhost:11434 或遠端 Ollama base | 本機通常不需要 | /api/generate |
| Ollama chat | ollama_chat/<model> | http://localhost:11434 或遠端 Ollama base | 本機通常不需要 | /api/chat |
| Ollama Cloud chat | ollama_chat/<model> | https://ollama.com | OLLAMA_API_KEY | `ollama.com/api/chat` |

LiteLLM 官方文件明確寫出 ollama_chat 會呼叫 Ollama 的 /api/chat，並建議使用它以取得較好的回應。[LiteLLM Ollama 文件的 ollama_chat 說明](https://docs.litellm.ai/docs/providers/ollama#using-ollama-api-chat)

LiteLLM 上游的 [OllamaChatConfig.get_complete_url](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/litellm/llms/ollama/chat/transformation.py) 會在 base URL 後加上 `/api/chat`；因此設定 LiteLLM 時建議使用 [Ollama Cloud base URL](https://ollama.com)，不要把 `ollama.com/api` 再當作 base URL，以免形成重複的 `/api` 路徑。

Ollama 官方文件則說明，直接呼叫 Ollama Cloud API 的 base URL 為 `ollama.com/api`，並要求建立 API key、設定 OLLAMA_API_KEY。[Ollama API 簡介](https://docs.ollama.com/api/introduction)、[Ollama Cloud 驗證](https://docs.ollama.com/api/authentication)

### 3.1 LiteLLM 設定範例

下列設定使用 Ollama Cloud 直接 API /api/tags 回傳的模型名稱：

~~~yaml
model_list:
  - model_name: ollama-cloud-gpt-oss-120b
    litellm_params:
      model: ollama_chat/gpt-oss:120b
      api_base: https://ollama.com
      api_key: os.environ/OLLAMA_API_KEY
~~~

~~~dotenv
OLLAMA_API_KEY=請填入-Ollama-Cloud-API-key
~~~

若要透過已登入的本機 Ollama 執行雲端變體，Ollama 官方模型頁會使用例如 gpt-oss:120b-cloud；此時 api_base 是本機 Ollama 服務，與直接呼叫 https://ollama.com 的模型名稱不要混用。[Ollama Cloud 模型文件](https://docs.ollama.com/cloud)

* * *

## 4. Ollama Cloud 直接 API 的目前模型快照

### 4.1 /api/tags 回傳的 34 個名稱

本次於 2026-07-12（Asia/Taipei）查詢 [Ollama Cloud `/api/tags`](https://ollama.com/api/tags)，回傳 34 筆。端點回應標頭的 Ollama build commit 為 63edbbb37578481383768a373789def4d0644e45，build time 為 2026-07-09T17:42:29-07:00。以下依名稱排序；這是查核當下的快照，不是永久保證。

~~~text
deepseek-v3.1:671b
deepseek-v3.2
deepseek-v4-flash
deepseek-v4-pro
devstral-2:123b
devstral-small-2:24b
gemini-3-flash-preview
gemma3:12b
gemma3:27b
gemma3:4b
gemma4:31b
glm-4.7
glm-5
glm-5.1
glm-5.2
gpt-oss:120b
gpt-oss:20b
kimi-k2.5
kimi-k2.6
kimi-k2.7-code
minimax-m2.1
minimax-m2.5
minimax-m2.7
minimax-m3
ministral-3:14b
ministral-3:3b
ministral-3:8b
mistral-large-3:675b
nemotron-3-nano:30b
nemotron-3-super
nemotron-3-ultra
qwen3-coder-next
qwen3-coder:480b
qwen3.5:397b
~~~

### 4.2 模型庫的 36 個雲端變體

Ollama 官方 [search?c=cloud](https://ollama.com/search?c=cloud) 頁面在查核時分兩頁顯示 29 個模型家族。逐一讀取各家族頁面的變體列後，得到以下 36 個雲端變體：

~~~text
glm-5.2:cloud
kimi-k2.7-code:cloud
gemma4:cloud
gemma4:31b-cloud
qwen3.5:cloud
qwen3.5:397b-cloud
glm-5.1:cloud
minimax-m2.7:cloud
nemotron-3-super:cloud
glm-5:cloud
minimax-m2.5:cloud
minimax-m3:cloud
kimi-k2.6:cloud
deepseek-v4-flash:cloud
deepseek-v4-pro:cloud
kimi-k2.5:cloud
nemotron-3-ultra:cloud
gpt-oss:20b-cloud
gpt-oss:120b-cloud
qwen3-coder:480b-cloud
glm-4.7:cloud
gemini-3-flash-preview:cloud
minimax-m2.1:cloud
deepseek-v3.2:cloud
ministral-3:3b-cloud
ministral-3:8b-cloud
ministral-3:14b-cloud
devstral-small-2:24b-cloud
nemotron-3-nano:30b-cloud
deepseek-v3.1:671b-cloud
devstral-2:123b-cloud
mistral-large-3:675b-cloud
gemma3:4b-cloud
gemma3:12b-cloud
gemma3:27b-cloud
qwen3-coder-next:cloud
~~~

差異原因：模型庫頁面呈現的是帶有 :cloud 的 CLI/API 變體；直接 Cloud API 的 /api/tags 回傳的是可供遠端 API 使用的名稱，通常省略 -cloud 後綴或提供尺寸 tag。**建立範例設定時，不能只把模型庫 URL 的文字直接套入所有端點；應先決定是本機 Ollama、Ollama Cloud 直接 API，還是 LiteLLM 透過本機 Ollama 轉送。**

* * *

## 5. 驗證「目前支援模型」的建議流程

### 5.1 先確認目標端點

| 目標 | 查詢命令 | 清單來源 |
| --- | --- | --- |
| 本機 Ollama | curl http://localhost:11434/api/tags | 該台機器已安裝或已 pull 的模型 |
| Ollama Cloud 直接 API | curl https://ollama.com/api/tags -H "Authorization: Bearer $OLLAMA_API_KEY" | Ollama Cloud 帳號可列出的模型 |
| LiteLLM 已註冊模型 | GET /v1/model/info 或讀取 Proxy config | LiteLLM Proxy 設定的 model_name 別名 |
| LiteLLM 靜態 metadata | 讀取上游 model_prices_and_context_window.json | 有價格與能力 metadata 的模型，不代表上游帳號必然可用 |

### 5.2 測試單一模型

~~~sh
OLLAMA_CLOUD_API_BASE='https://ollama.com'
curl -fsS "${OLLAMA_CLOUD_API_BASE}/api/chat" \\
  -H "Authorization: Bearer ${OLLAMA_API_KEY}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "gpt-oss:120b",
    "messages": [{"role": "user", "content": "請只回答：連線成功"}],
    "stream": false
  }'
~~~

通過 Ollama API 後，再測 LiteLLM Proxy；否則無法區分模型不存在、Ollama key 無效、LiteLLM base URL 錯誤或 Proxy key 錯誤。

### 5.3 產生範例時的同步策略

1. 將來源端點、查核日期、回應版本或 commit 寫入 catalog metadata。
2. 對 Ollama Cloud 優先使用 /api/tags 產生遠端 API 範例。
3. 將模型庫的 :cloud 變體另存為本機登入 Ollama 的範例，不與遠端 API 名稱混在同一欄位。
4. 將 LiteLLM 靜態 metadata 用於價格、上下文長度與能力補充，不作為唯一模型存在性判斷。
5. 每次更新前重新執行 /api/tags、LiteLLM upstream JSON 與連結檢查；若上游回應變更，更新 snapshot 與查核日期。

* * *

## 6. 不確定性與限制

- **Ollama Cloud 清單會變動。** 本文件的 34 個直接 API 名稱與 36 個模型庫變體只代表 2026-07-12 查核時的結果。
- **帳號權限可能改變結果。** /api/tags、模型可用性、配額、區域與付款狀態可能讓不同帳號看到不同內容；本次查核沒有使用個人 API key 呼叫產生請求。
- **LiteLLM 版本可能改變路由行為。** 本文件引用的程式碼基準是 2c1d62...；若使用不同 LiteLLM 映像 tag，應重新確認 provider 前綴、base URL 組合與 header 行為。
- **靜態價格表不等於服務保證。** 沒有 metadata 的模型可能仍能呼叫；有 metadata 的模型也可能已被上游下架或需要額外權限。
- **查無足夠資料以宣稱「所有 provider 的所有模型」已被固定列完。** 可驗證且可重現的做法，是保存上游 commit 與端點查詢結果，並在部署前重新同步。

* * *

## 7. 官方來源索引

1. [LiteLLM Providers](https://docs.litellm.ai/docs/providers)
2. [LiteLLM Ollama provider 文件](https://docs.litellm.ai/docs/providers/ollama)
3. [LiteLLM model prices/context metadata（固定 commit）](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/model_prices_and_context_window.json)
4. [LiteLLM Ollama 動態模型列舉原始碼（固定 commit）](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/litellm/llms/ollama/common_utils.py)
5. [LiteLLM Ollama chat URL/header 原始碼（固定 commit）](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/litellm/llms/ollama/chat/transformation.py)
6. [LiteLLM Ollama Cloud 測試（固定 commit）](https://github.com/BerriAI/litellm/blob/2c1d62ce2b586e047307c83d3ed79c64857287e8/tests/test_litellm/llms/ollama/test_ollama_model_info.py)
7. [Ollama Cloud 文件](https://docs.ollama.com/cloud)
8. [Ollama API 簡介](https://docs.ollama.com/api/introduction)
9. [Ollama API GET /api/tags](https://docs.ollama.com/api/tags)
10. [Ollama API 驗證](https://docs.ollama.com/api/authentication)
11. [Ollama Cloud 模型庫](https://ollama.com/search?c=cloud)
12. [Ollama Cloud 直接 API 模型端點](https://ollama.com/api/tags)
