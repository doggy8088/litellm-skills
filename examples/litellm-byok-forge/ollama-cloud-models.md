# Ollama Cloud 模型清單

本文件列出 2 種 Ollama Cloud 存取方式、70 個模型名稱；直接 API 名稱與本機登入後的 `:cloud` 變體不能互換。


## Ollama Cloud

- 查核日期：`2026-07-12`
- API base：`https://ollama.com`
- LiteLLM prefix：`ollama_chat`
- API key 環境變數：`OLLAMA_API_KEY`
- 來源：[Ollama Cloud 官方來源](https://ollama.com/api/tags)
- 官方說明：[Ollama Cloud 官方文件](https://docs.ollama.com/cloud)

| 模型 | LiteLLM model route | model alias |
| --- | --- | --- |
| `deepseek-v3.1:671b` | `ollama_chat/deepseek-v3.1:671b` | `ollama_cloud__deepseek-v3-1-671b` |
| `deepseek-v3.2` | `ollama_chat/deepseek-v3.2` | `ollama_cloud__deepseek-v3-2` |
| `deepseek-v4-flash` | `ollama_chat/deepseek-v4-flash` | `ollama_cloud__deepseek-v4-flash` |
| `deepseek-v4-pro` | `ollama_chat/deepseek-v4-pro` | `ollama_cloud__deepseek-v4-pro` |
| `devstral-2:123b` | `ollama_chat/devstral-2:123b` | `ollama_cloud__devstral-2-123b` |
| `devstral-small-2:24b` | `ollama_chat/devstral-small-2:24b` | `ollama_cloud__devstral-small-2-24b` |
| `gemini-3-flash-preview` | `ollama_chat/gemini-3-flash-preview` | `ollama_cloud__gemini-3-flash-preview` |
| `gemma3:12b` | `ollama_chat/gemma3:12b` | `ollama_cloud__gemma3-12b` |
| `gemma3:27b` | `ollama_chat/gemma3:27b` | `ollama_cloud__gemma3-27b` |
| `gemma3:4b` | `ollama_chat/gemma3:4b` | `ollama_cloud__gemma3-4b` |
| `gemma4:31b` | `ollama_chat/gemma4:31b` | `ollama_cloud__gemma4-31b` |
| `glm-4.7` | `ollama_chat/glm-4.7` | `ollama_cloud__glm-4-7` |
| `glm-5` | `ollama_chat/glm-5` | `ollama_cloud__glm-5` |
| `glm-5.1` | `ollama_chat/glm-5.1` | `ollama_cloud__glm-5-1` |
| `glm-5.2` | `ollama_chat/glm-5.2` | `ollama_cloud__glm-5-2` |
| `gpt-oss:120b` | `ollama_chat/gpt-oss:120b` | `ollama_cloud__gpt-oss-120b` |
| `gpt-oss:20b` | `ollama_chat/gpt-oss:20b` | `ollama_cloud__gpt-oss-20b` |
| `kimi-k2.5` | `ollama_chat/kimi-k2.5` | `ollama_cloud__kimi-k2-5` |
| `kimi-k2.6` | `ollama_chat/kimi-k2.6` | `ollama_cloud__kimi-k2-6` |
| `kimi-k2.7-code` | `ollama_chat/kimi-k2.7-code` | `ollama_cloud__kimi-k2-7-code` |
| `minimax-m2.1` | `ollama_chat/minimax-m2.1` | `ollama_cloud__minimax-m2-1` |
| `minimax-m2.5` | `ollama_chat/minimax-m2.5` | `ollama_cloud__minimax-m2-5` |
| `minimax-m2.7` | `ollama_chat/minimax-m2.7` | `ollama_cloud__minimax-m2-7` |
| `minimax-m3` | `ollama_chat/minimax-m3` | `ollama_cloud__minimax-m3` |
| `ministral-3:14b` | `ollama_chat/ministral-3:14b` | `ollama_cloud__ministral-3-14b` |
| `ministral-3:3b` | `ollama_chat/ministral-3:3b` | `ollama_cloud__ministral-3-3b` |
| `ministral-3:8b` | `ollama_chat/ministral-3:8b` | `ollama_cloud__ministral-3-8b` |
| `mistral-large-3:675b` | `ollama_chat/mistral-large-3:675b` | `ollama_cloud__mistral-large-3-675b` |
| `nemotron-3-nano:30b` | `ollama_chat/nemotron-3-nano:30b` | `ollama_cloud__nemotron-3-nano-30b` |
| `nemotron-3-super` | `ollama_chat/nemotron-3-super` | `ollama_cloud__nemotron-3-super` |
| `nemotron-3-ultra` | `ollama_chat/nemotron-3-ultra` | `ollama_cloud__nemotron-3-ultra` |
| `qwen3-coder-next` | `ollama_chat/qwen3-coder-next` | `ollama_cloud__qwen3-coder-next` |
| `qwen3-coder:480b` | `ollama_chat/qwen3-coder:480b` | `ollama_cloud__qwen3-coder-480b` |
| `qwen3.5:397b` | `ollama_chat/qwen3.5:397b` | `ollama_cloud__qwen3-5-397b` |


## Ollama Cloud (local signed-in)

- 查核日期：`2026-07-12`
- API base：`http://localhost:11434`
- LiteLLM prefix：`ollama_chat`
- 驗證：本機 Ollama 需先執行 `ollama signin`
- 來源：[Ollama Cloud 官方來源](https://ollama.com/search?c=cloud)
- 官方說明：[Ollama Cloud 官方文件](https://docs.ollama.com/cloud)

| 模型 | LiteLLM model route | model alias |
| --- | --- | --- |
| `glm-5.2:cloud` | `ollama_chat/glm-5.2:cloud` | `ollama_cloud_local__glm-5-2-cloud` |
| `kimi-k2.7-code:cloud` | `ollama_chat/kimi-k2.7-code:cloud` | `ollama_cloud_local__kimi-k2-7-code-cloud` |
| `gemma4:cloud` | `ollama_chat/gemma4:cloud` | `ollama_cloud_local__gemma4-cloud` |
| `gemma4:31b-cloud` | `ollama_chat/gemma4:31b-cloud` | `ollama_cloud_local__gemma4-31b-cloud` |
| `qwen3.5:cloud` | `ollama_chat/qwen3.5:cloud` | `ollama_cloud_local__qwen3-5-cloud` |
| `qwen3.5:397b-cloud` | `ollama_chat/qwen3.5:397b-cloud` | `ollama_cloud_local__qwen3-5-397b-cloud` |
| `glm-5.1:cloud` | `ollama_chat/glm-5.1:cloud` | `ollama_cloud_local__glm-5-1-cloud` |
| `minimax-m2.7:cloud` | `ollama_chat/minimax-m2.7:cloud` | `ollama_cloud_local__minimax-m2-7-cloud` |
| `nemotron-3-super:cloud` | `ollama_chat/nemotron-3-super:cloud` | `ollama_cloud_local__nemotron-3-super-cloud` |
| `glm-5:cloud` | `ollama_chat/glm-5:cloud` | `ollama_cloud_local__glm-5-cloud` |
| `minimax-m2.5:cloud` | `ollama_chat/minimax-m2.5:cloud` | `ollama_cloud_local__minimax-m2-5-cloud` |
| `minimax-m3:cloud` | `ollama_chat/minimax-m3:cloud` | `ollama_cloud_local__minimax-m3-cloud` |
| `kimi-k2.6:cloud` | `ollama_chat/kimi-k2.6:cloud` | `ollama_cloud_local__kimi-k2-6-cloud` |
| `deepseek-v4-flash:cloud` | `ollama_chat/deepseek-v4-flash:cloud` | `ollama_cloud_local__deepseek-v4-flash-cloud` |
| `deepseek-v4-pro:cloud` | `ollama_chat/deepseek-v4-pro:cloud` | `ollama_cloud_local__deepseek-v4-pro-cloud` |
| `kimi-k2.5:cloud` | `ollama_chat/kimi-k2.5:cloud` | `ollama_cloud_local__kimi-k2-5-cloud` |
| `nemotron-3-ultra:cloud` | `ollama_chat/nemotron-3-ultra:cloud` | `ollama_cloud_local__nemotron-3-ultra-cloud` |
| `gpt-oss:20b-cloud` | `ollama_chat/gpt-oss:20b-cloud` | `ollama_cloud_local__gpt-oss-20b-cloud` |
| `gpt-oss:120b-cloud` | `ollama_chat/gpt-oss:120b-cloud` | `ollama_cloud_local__gpt-oss-120b-cloud` |
| `qwen3-coder:480b-cloud` | `ollama_chat/qwen3-coder:480b-cloud` | `ollama_cloud_local__qwen3-coder-480b-cloud` |
| `glm-4.7:cloud` | `ollama_chat/glm-4.7:cloud` | `ollama_cloud_local__glm-4-7-cloud` |
| `gemini-3-flash-preview:cloud` | `ollama_chat/gemini-3-flash-preview:cloud` | `ollama_cloud_local__gemini-3-flash-preview-cloud` |
| `minimax-m2.1:cloud` | `ollama_chat/minimax-m2.1:cloud` | `ollama_cloud_local__minimax-m2-1-cloud` |
| `deepseek-v3.2:cloud` | `ollama_chat/deepseek-v3.2:cloud` | `ollama_cloud_local__deepseek-v3-2-cloud` |
| `ministral-3:3b-cloud` | `ollama_chat/ministral-3:3b-cloud` | `ollama_cloud_local__ministral-3-3b-cloud` |
| `ministral-3:8b-cloud` | `ollama_chat/ministral-3:8b-cloud` | `ollama_cloud_local__ministral-3-8b-cloud` |
| `ministral-3:14b-cloud` | `ollama_chat/ministral-3:14b-cloud` | `ollama_cloud_local__ministral-3-14b-cloud` |
| `devstral-small-2:24b-cloud` | `ollama_chat/devstral-small-2:24b-cloud` | `ollama_cloud_local__devstral-small-2-24b-cloud` |
| `nemotron-3-nano:30b-cloud` | `ollama_chat/nemotron-3-nano:30b-cloud` | `ollama_cloud_local__nemotron-3-nano-30b-cloud` |
| `deepseek-v3.1:671b-cloud` | `ollama_chat/deepseek-v3.1:671b-cloud` | `ollama_cloud_local__deepseek-v3-1-671b-cloud` |
| `devstral-2:123b-cloud` | `ollama_chat/devstral-2:123b-cloud` | `ollama_cloud_local__devstral-2-123b-cloud` |
| `mistral-large-3:675b-cloud` | `ollama_chat/mistral-large-3:675b-cloud` | `ollama_cloud_local__mistral-large-3-675b-cloud` |
| `gemma3:4b-cloud` | `ollama_chat/gemma3:4b-cloud` | `ollama_cloud_local__gemma3-4b-cloud` |
| `gemma3:12b-cloud` | `ollama_chat/gemma3:12b-cloud` | `ollama_cloud_local__gemma3-12b-cloud` |
| `gemma3:27b-cloud` | `ollama_chat/gemma3:27b-cloud` | `ollama_cloud_local__gemma3-27b-cloud` |
| `qwen3-coder-next:cloud` | `ollama_chat/qwen3-coder-next:cloud` | `ollama_cloud_local__qwen3-coder-next-cloud` |


> Ollama Cloud 模型會隨官方 API 與模型庫變更；重新產生前請再次查核模型可用性、帳戶方案與區域限制。這份檔案不是 Ollama 公開 model library 的永久快照。
