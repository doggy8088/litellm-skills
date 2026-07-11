# BYOK Forge LiteLLM provider/model 範例

這個目錄把 `byok-forge` 的 LiteLLM provider catalog 轉成可直接閱讀、複製與修改的 LiteLLM YAML 設定。

來源是 `doggy8088/byok-forge` 的 `litellm.html`，擷取 commit 為 `6b1d5012cbe0391817a79387894db2493de3b047`；可在 [BYOK Forge LiteLLM Config Forge](https://byok-forge.gh.miniasp.com/litellm.html) 查看原始介面與目前 catalog。

**這不是 LiteLLM 全部官方模型目錄。** 本目錄只固定保存該來源頁面列出的 14 個 providers、41 個 provider/model 組合。模型名稱與供應商可用性會變動，呼叫前仍須依 provider 官方文件確認。

## 目錄內容

| 路徑 | 用途 |
| --- | --- |
| `catalog.json` | provider、LiteLLM prefix、環境變數與模型清單的來源 manifest |
| `providers/<provider>/<model>.yaml` | 每個 provider/model 組合各自一份設定，共 41 份 |
| `all-models.yaml` | 將 41 個組合全部放在同一個 `model_list` 的完整設定 |
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
| Ollama | `ollama_chat` | 4 |
| vLLM | `hosted_vllm` | 2 |
| **合計** |  | **41** |

## 使用單一組合

先複製環境變數範本並填入實際 key：

```sh
cd examples/litellm-byok-forge
cp .env.example .env
chmod 600 .env
```

再選擇一份設定啟動 Proxy，例如 OpenAI `gpt-5.5`：

```sh
litellm --config providers/openai/gpt-5-5.yaml --port 4000
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

`all-models.yaml` 包含全部 41 個組合。它會讀取所有非 local provider 的環境變數，因此只適合已準備多組 provider key 的環境：

```sh
litellm --config all-models.yaml --port 4000
```

若只想測試一個 provider，使用 `providers/` 下的單一檔案，避免未設定的 provider key 影響測試結果。

## Provider-specific 設定

- Azure OpenAI：`model` 後的值是 Azure deployment name；每份 YAML 將 `api_base` 與 `api_version` 保留為設定檔值，`AZURE_API_KEY` 才從環境變數讀取。請替換 `YOUR-RESOURCE.openai.azure.com`。
- Ollama：不需要 API key，使用 `ollama_chat` prefix 與 `http://localhost:11434`。若 LiteLLM 在 Docker 內執行，通常要改成 `http://host.docker.internal:11434`。
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
python3 scripts/generate_byok_forge_examples.py
```

產生器會驗證 provider id 與 model alias 不重複，並重新產生 41 份個別 YAML、`all-models.yaml` 與 `.env.example`。不要手動把真實憑證填入產生檔後再提交。
