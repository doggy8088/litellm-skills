# LiteLLM provider/model 範例

這個目錄把 `byok-forge` 的 LiteLLM provider catalog，以及 Ollama Cloud 官方 API 的模型清單，轉成可直接閱讀、複製與修改的 LiteLLM YAML 設定。

BYOK Forge 來源是 `doggy8088/byok-forge` 的 `litellm.html`，擷取 commit 為 `6b1d5012cbe0391817a79387894db2493de3b047`；可在 [BYOK Forge LiteLLM Config Forge](https://byok-forge.gh.miniasp.com/litellm.html) 查看原始介面與其 catalog。

Ollama Cloud 分成兩種必須分開處理的使用方式：直接呼叫 `https://ollama.com` 的 API 在 `2026-07-12` 回傳 **34 個模型名稱**；本機 Ollama 執行 `ollama signin` 後可使用官方 model library 的 **36 個 `:cloud` 變體**。完整清單請見 [Ollama Cloud 模型清單](ollama-cloud-models.md)，所有 provider/model 組合請見 [完整模型目錄](model-catalog.md)。

**這不是 LiteLLM 全部官方 providers/model 的永久目錄。** LiteLLM 官方文件指出 Ollama provider 可使用 Ollama 模型；Ollama Cloud 的 `/api/tags` 與公開 model library 也會變動。因此本目錄的「完整」是指查核日期當下的 34 個直接 API 名稱與 36 個本機登入變體，加上 BYOK Forge 的 41 個組合；重新同步前仍須依 provider 官方文件確認模型、帳戶方案與區域限制。

## 目錄內容

| 路徑 | 用途 |
| --- | --- |
| `catalog.json` | provider、LiteLLM prefix、環境變數與模型清單的來源 manifest |
| `providers/<provider>/<model>.yaml` | 每個 provider/model 組合各自一份設定，共 111 份 |
| `all-models.yaml` | 將 111 個組合全部放在同一個 `model_list` 的完整設定 |
| `model-catalog.md` | 所有 providers 與 provider/model alias 的可讀版清單 |
| `ollama-cloud-models.md` | Ollama Cloud 直接 API 與本機登入變體的完整模型清單，共 70 個 |
| `.env.example` | 所有需要的 API key 與 master key placeholder |
| `README.md` | 使用、命名與 provider-specific 注意事項 |

## Provider 統計

| Provider | LiteLLM prefix | 模型數 |
| --- | --- | ---: |
| Mistral | `mistral` | 4 |
| DeepSeek | `deepseek` | 2 |
| Anthropic | `anthropic` | 3 |
| Google Gemini | `gemini` | 3 |
| Cerebras | `cerebras` | 3 |
| Together AI | `together_ai` | 3 |
| Fireworks | `fireworks_ai` | 2 |
| Groq | `groq` | 3 |
| OpenAI | `openai` | 4 |
| OpenRouter | `openrouter` | 3 |
| xAI Grok | `xai` | 2 |
| Azure OpenAI | `azure` | 3 |
| Ollama (local) | `ollama_chat` | 4 |
| Ollama Cloud | `ollama_chat` | 34 |
| Ollama Cloud (local signed-in) | `ollama_chat` | 36 |
| vLLM | `hosted_vllm` | 2 |
| **合計** |  | **111** |

LiteLLM 官方 Ollama provider 文件：[Ollama provider](https://docs.litellm.ai/docs/providers/ollama)。Ollama Cloud API 與登入、API key、模型查詢方式：[Ollama Cloud 官方文件](https://docs.ollama.com/cloud)。完整查核與限制請見 [LiteLLM 與 Ollama Cloud 模型支援查核報告](../../docs/litellm-model-support-research.md)。

## 使用單一組合

先複製環境變數範本並填入實際 key：

```sh
cd examples/litellm-byok-forge
cp .env.example .env
chmod 600 .env
```

再選擇一份設定啟動 Proxy，例如 OpenAI `gpt-5.5`：

```sh
litellm --config providers/openai/gpt-5-5.yaml --host 127.0.0.1 --port 4000
```

該設定的對外 model alias 是：

```text
openai__gpt-5-5
```

請求時使用 alias，而不是直接使用 `litellm_params.model`：

```sh
curl --fail http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "openai__gpt-5-5",
    "messages": [{"role": "user", "content": "Reply with exactly: LiteLLM OK"}]
  }'
```

每個 alias 都使用 `<provider-id>__<model-slug>` 格式，避免完整設定中不同 provider 的同名模型互相覆蓋。例如 `deepseek-chat` 與 OpenRouter 的 `deepseek/deepseek-chat` 會分別成為 `deepseek__deepseek-chat` 與 `openrouter__deepseek-deepseek-chat`。

## 使用完整設定

`all-models.yaml` 包含全部 111 個組合，其中包含 34 個 Ollama Cloud 直接 API 模型與 36 個本機登入變體。它會讀取所有非 local provider 的環境變數，因此只適合已準備多組 provider key，並已登入本機 Ollama 的環境：

```sh
litellm --config all-models.yaml --host 127.0.0.1 --port 4000
```

若只想測試一個 provider，使用 `providers/` 下的單一檔案，避免未設定的 provider key 影響測試結果。

## 使用 Ollama Cloud

Ollama Cloud 與本機 Ollama 是不同端點。先在 [Ollama Cloud 官方文件](https://docs.ollama.com/cloud) 建立 API key，再填入 `.env`：

```sh
export OLLAMA_API_KEY='replace-with-your-ollama-cloud-key'
litellm --config providers/ollama_cloud/gpt-oss-120b.yaml --host 127.0.0.1 --port 4000
```

這份設定使用：

- `model: ollama_chat/gpt-oss:120b`
- `api_base: https://ollama.com`
- `api_key: os.environ/OLLAMA_API_KEY`
- 對外 alias：`ollama_cloud__gpt-oss-120b`

呼叫 Proxy 時使用 alias：

```sh
curl --fail http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ollama_cloud__gpt-oss-120b",
    "messages": [{"role": "user", "content": "Reply with exactly: Ollama Cloud OK"}]
  }'
```

完整 70 個 Ollama Cloud 模型與對應 alias 請見 [ollama-cloud-models.md](ollama-cloud-models.md)。

## 使用本機 Ollama 轉送 Cloud model

這個路徑使用本機 Ollama daemon 轉送雲端模型，與直接把 API key 交給 `https://ollama.com` 不同。先登入本機 Ollama：

```sh
ollama signin
litellm --config providers/ollama_cloud_local/gpt-oss-120b-cloud.yaml --host 127.0.0.1 --port 4000
```

這份設定使用 `ollama_chat/gpt-oss:120b-cloud`、`http://localhost:11434`，不在 YAML 放置 API key；對外 alias 是 `ollama_cloud_local__gpt-oss-120b-cloud`。若 LiteLLM 在 Docker 容器內執行，請將 `api_base` 改為可從容器連到 Ollama 的位址，例如 `http://host.docker.internal:11434`。

## Provider-specific 設定

- Azure OpenAI：`model` 後的值是 Azure deployment name；每份 YAML 將 `api_base` 與 `api_version` 保留為設定檔值，`AZURE_API_KEY` 才從環境變數讀取。請替換 `YOUR-RESOURCE.openai.azure.com`。
- Ollama：不需要 API key，使用 `ollama_chat` prefix 與 `http://localhost:11434`。若 LiteLLM 在 Docker 內執行，通常要改成 `http://host.docker.internal:11434`。
- Ollama Cloud：使用 `ollama_chat` prefix、`https://ollama.com` 與 `OLLAMA_API_KEY`；不要把 Ollama Cloud key 當成本機 Ollama 的 keyless 設定。
- Ollama Cloud（local signed-in）：使用 `ollama_chat` prefix、`http://localhost:11434` 與 `:cloud` 模型名稱；先執行 `ollama signin`，不要把這些設定誤當成直接 Cloud API key 路徑。
- vLLM：使用 `hosted_vllm` prefix，預設 base URL 為 `http://localhost:8000/v1`；Docker 內執行時依部署位置調整 host。
- 其他 providers：使用對應的 `*_API_KEY` 環境變數，不要把實際 key 寫入 YAML 或 Git。

所有設定都帶有：

```yaml
litellm_settings:
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

`drop_params: true` 延續 BYOK Forge 的預設，讓 Proxy 在 provider 不支援某些參數時丟棄該參數；正式環境是否啟用，應依應用程式對參數嚴格性的需求確認。

## 重新產生

`catalog.json` 是已審查的輸入來源。若更新 manifest 或重新同步來源，執行：

```sh
cd "$(git rev-parse --show-toplevel)"
python3 scripts/generate_byok_forge_examples.py --refresh-ollama-cloud
```

`--refresh-ollama-cloud` 會從 Ollama Cloud 官方 `/api/tags` 重新取得直接 API 模型名稱、更新 `catalog.json` 的查核日期，再產生 111 份個別 YAML、`all-models.yaml`、`model-catalog.md`、`ollama-cloud-models.md` 與 `.env.example`。本機登入後的 36 個 `:cloud` 變體是依官方 model library 查核後保存的 snapshot；若 model library 改變，請同步更新 `catalog.json` 的 `ollama_cloud_local` 區段與來源日期。不使用旗標時，產生器只依現有 `catalog.json` 重建檔案。產生器會先暫存並驗證全部內容，再以可回復流程更新所有生成物與目錄；任一步驟失敗時，不會留下部分更新的檔案。產生器也會驗證 provider id 與 model alias 不重複。不要手動把真實憑證填入產生檔後再提交。

提交前使用唯讀模式確認 catalog 與全部生成物同步：

```sh
python3 scripts/generate_byok_forge_examples.py --check
```
