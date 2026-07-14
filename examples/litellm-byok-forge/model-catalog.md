# LiteLLM provider/model 模型目錄

本文件是 16 個 providers、111 組 provider/model 設定的可讀版快照。模型清單會變動，請依各 provider 官方文件 與來源端點重新查核。

## 來源

- BYOK Forge：[doggy8088/byok-forge 的 `litellm.html`](https://byok-forge.gh.miniasp.com/litellm.html)，commit `6b1d5012cbe0391817a79387894db2493de3b047`。
- Ollama Cloud：官方模型 API [來源端點](https://ollama.com/api/tags)，擷取日期 `2026-07-12`。
- Ollama Cloud (local signed-in)：官方模型 API [來源端點](https://ollama.com/search?c=cloud)，擷取日期 `2026-07-12`。

## Mistral

- LiteLLM prefix：`mistral`
- 模型數：4

| 模型 | model alias | API base |
| --- | --- | --- |
| `mistral-medium-latest` | `mistral__mistral-medium-latest` | `provider 預設端點` |
| `mistral-large-latest` | `mistral__mistral-large-latest` | `provider 預設端點` |
| `devstral-2512` | `mistral__devstral-2512` | `provider 預設端點` |
| `magistral-medium-latest` | `mistral__magistral-medium-latest` | `provider 預設端點` |

## DeepSeek

- LiteLLM prefix：`deepseek`
- 模型數：2

| 模型 | model alias | API base |
| --- | --- | --- |
| `deepseek-chat` | `deepseek__deepseek-chat` | `provider 預設端點` |
| `deepseek-reasoner` | `deepseek__deepseek-reasoner` | `provider 預設端點` |

## Anthropic

- LiteLLM prefix：`anthropic`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `claude-opus-4-8` | `anthropic__claude-opus-4-8` | `provider 預設端點` |
| `claude-sonnet-4-6` | `anthropic__claude-sonnet-4-6` | `provider 預設端點` |
| `claude-haiku-4-5` | `anthropic__claude-haiku-4-5` | `provider 預設端點` |

## Google Gemini

- LiteLLM prefix：`gemini`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `gemini-3-pro` | `gemini__gemini-3-pro` | `provider 預設端點` |
| `gemini-2.5-pro` | `gemini__gemini-2-5-pro` | `provider 預設端點` |
| `gemini-2.5-flash` | `gemini__gemini-2-5-flash` | `provider 預設端點` |

## Cerebras

- LiteLLM prefix：`cerebras`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `qwen-3-coder-480b` | `cerebras__qwen-3-coder-480b` | `provider 預設端點` |
| `llama-3.3-70b` | `cerebras__llama-3-3-70b` | `provider 預設端點` |
| `gpt-oss-120b` | `cerebras__gpt-oss-120b` | `provider 預設端點` |

## Together AI

- LiteLLM prefix：`together_ai`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `deepseek-ai/DeepSeek-V3.1` | `together__deepseek-ai-deepseek-v3-1` | `provider 預設端點` |
| `Qwen/Qwen3-Coder-480B-A35B-Instruct` | `together__qwen-qwen3-coder-480b-a35b-instruct` | `provider 預設端點` |
| `moonshotai/Kimi-K2-Instruct` | `together__moonshotai-kimi-k2-instruct` | `provider 預設端點` |

## Fireworks

- LiteLLM prefix：`fireworks_ai`
- 模型數：2

| 模型 | model alias | API base |
| --- | --- | --- |
| `accounts/fireworks/models/deepseek-v3p1` | `fireworks__accounts-fireworks-models-deepseek-v3p1` | `provider 預設端點` |
| `accounts/fireworks/models/qwen3-coder-480b-a35b-instruct` | `fireworks__accounts-fireworks-models-qwen3-coder-480b-a35b-instruct` | `provider 預設端點` |

## Groq

- LiteLLM prefix：`groq`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `openai/gpt-oss-120b` | `groq__openai-gpt-oss-120b` | `provider 預設端點` |
| `llama-3.3-70b-versatile` | `groq__llama-3-3-70b-versatile` | `provider 預設端點` |
| `moonshotai/kimi-k2-instruct` | `groq__moonshotai-kimi-k2-instruct` | `provider 預設端點` |

## OpenAI

- LiteLLM prefix：`openai`
- 模型數：4

| 模型 | model alias | API base |
| --- | --- | --- |
| `gpt-5.5` | `openai__gpt-5-5` | `provider 預設端點` |
| `gpt-5.4` | `openai__gpt-5-4` | `provider 預設端點` |
| `o3` | `openai__o3` | `provider 預設端點` |
| `o4-mini` | `openai__o4-mini` | `provider 預設端點` |

## OpenRouter

- LiteLLM prefix：`openrouter`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `anthropic/claude-opus-4.8` | `openrouter__anthropic-claude-opus-4-8` | `provider 預設端點` |
| `x-ai/grok-4.3` | `openrouter__x-ai-grok-4-3` | `provider 預設端點` |
| `deepseek/deepseek-chat` | `openrouter__deepseek-deepseek-chat` | `provider 預設端點` |

## xAI Grok

- LiteLLM prefix：`xai`
- 模型數：2

| 模型 | model alias | API base |
| --- | --- | --- |
| `grok-4.3` | `xai__grok-4-3` | `provider 預設端點` |
| `grok-code-fast` | `xai__grok-code-fast` | `provider 預設端點` |

## Azure OpenAI

- LiteLLM prefix：`azure`
- 模型數：3

| 模型 | model alias | API base |
| --- | --- | --- |
| `gpt-5.5` | `azure__gpt-5-5` | `https://your-resource.openai.azure.com` |
| `gpt-5.4` | `azure__gpt-5-4` | `https://your-resource.openai.azure.com` |
| `gpt-4.1` | `azure__gpt-4-1` | `https://your-resource.openai.azure.com` |

## Ollama (local)

- LiteLLM prefix：`ollama_chat`
- 模型數：4

| 模型 | model alias | API base |
| --- | --- | --- |
| `qwen3-coder:30b` | `ollama__qwen3-coder-30b` | `http://localhost:11434` |
| `llama3.3:70b` | `ollama__llama3-3-70b` | `http://localhost:11434` |
| `deepseek-r1:8b` | `ollama__deepseek-r1-8b` | `http://localhost:11434` |
| `devstral` | `ollama__devstral` | `http://localhost:11434` |

## Ollama Cloud

- LiteLLM prefix：`ollama_chat`
- 模型數：34

| 模型 | model alias | API base |
| --- | --- | --- |
| `deepseek-v3.1:671b` | `ollama_cloud__deepseek-v3-1-671b` | `https://ollama.com` |
| `deepseek-v3.2` | `ollama_cloud__deepseek-v3-2` | `https://ollama.com` |
| `deepseek-v4-flash` | `ollama_cloud__deepseek-v4-flash` | `https://ollama.com` |
| `deepseek-v4-pro` | `ollama_cloud__deepseek-v4-pro` | `https://ollama.com` |
| `devstral-2:123b` | `ollama_cloud__devstral-2-123b` | `https://ollama.com` |
| `devstral-small-2:24b` | `ollama_cloud__devstral-small-2-24b` | `https://ollama.com` |
| `gemini-3-flash-preview` | `ollama_cloud__gemini-3-flash-preview` | `https://ollama.com` |
| `gemma3:12b` | `ollama_cloud__gemma3-12b` | `https://ollama.com` |
| `gemma3:27b` | `ollama_cloud__gemma3-27b` | `https://ollama.com` |
| `gemma3:4b` | `ollama_cloud__gemma3-4b` | `https://ollama.com` |
| `gemma4:31b` | `ollama_cloud__gemma4-31b` | `https://ollama.com` |
| `glm-4.7` | `ollama_cloud__glm-4-7` | `https://ollama.com` |
| `glm-5` | `ollama_cloud__glm-5` | `https://ollama.com` |
| `glm-5.1` | `ollama_cloud__glm-5-1` | `https://ollama.com` |
| `glm-5.2` | `ollama_cloud__glm-5-2` | `https://ollama.com` |
| `gpt-oss:120b` | `ollama_cloud__gpt-oss-120b` | `https://ollama.com` |
| `gpt-oss:20b` | `ollama_cloud__gpt-oss-20b` | `https://ollama.com` |
| `kimi-k2.5` | `ollama_cloud__kimi-k2-5` | `https://ollama.com` |
| `kimi-k2.6` | `ollama_cloud__kimi-k2-6` | `https://ollama.com` |
| `kimi-k2.7-code` | `ollama_cloud__kimi-k2-7-code` | `https://ollama.com` |
| `minimax-m2.1` | `ollama_cloud__minimax-m2-1` | `https://ollama.com` |
| `minimax-m2.5` | `ollama_cloud__minimax-m2-5` | `https://ollama.com` |
| `minimax-m2.7` | `ollama_cloud__minimax-m2-7` | `https://ollama.com` |
| `minimax-m3` | `ollama_cloud__minimax-m3` | `https://ollama.com` |
| `ministral-3:14b` | `ollama_cloud__ministral-3-14b` | `https://ollama.com` |
| `ministral-3:3b` | `ollama_cloud__ministral-3-3b` | `https://ollama.com` |
| `ministral-3:8b` | `ollama_cloud__ministral-3-8b` | `https://ollama.com` |
| `mistral-large-3:675b` | `ollama_cloud__mistral-large-3-675b` | `https://ollama.com` |
| `nemotron-3-nano:30b` | `ollama_cloud__nemotron-3-nano-30b` | `https://ollama.com` |
| `nemotron-3-super` | `ollama_cloud__nemotron-3-super` | `https://ollama.com` |
| `nemotron-3-ultra` | `ollama_cloud__nemotron-3-ultra` | `https://ollama.com` |
| `qwen3-coder-next` | `ollama_cloud__qwen3-coder-next` | `https://ollama.com` |
| `qwen3-coder:480b` | `ollama_cloud__qwen3-coder-480b` | `https://ollama.com` |
| `qwen3.5:397b` | `ollama_cloud__qwen3-5-397b` | `https://ollama.com` |

## Ollama Cloud (local signed-in)

- LiteLLM prefix：`ollama_chat`
- 模型數：36

| 模型 | model alias | API base |
| --- | --- | --- |
| `glm-5.2:cloud` | `ollama_cloud_local__glm-5-2-cloud` | `http://localhost:11434` |
| `kimi-k2.7-code:cloud` | `ollama_cloud_local__kimi-k2-7-code-cloud` | `http://localhost:11434` |
| `gemma4:cloud` | `ollama_cloud_local__gemma4-cloud` | `http://localhost:11434` |
| `gemma4:31b-cloud` | `ollama_cloud_local__gemma4-31b-cloud` | `http://localhost:11434` |
| `qwen3.5:cloud` | `ollama_cloud_local__qwen3-5-cloud` | `http://localhost:11434` |
| `qwen3.5:397b-cloud` | `ollama_cloud_local__qwen3-5-397b-cloud` | `http://localhost:11434` |
| `glm-5.1:cloud` | `ollama_cloud_local__glm-5-1-cloud` | `http://localhost:11434` |
| `minimax-m2.7:cloud` | `ollama_cloud_local__minimax-m2-7-cloud` | `http://localhost:11434` |
| `nemotron-3-super:cloud` | `ollama_cloud_local__nemotron-3-super-cloud` | `http://localhost:11434` |
| `glm-5:cloud` | `ollama_cloud_local__glm-5-cloud` | `http://localhost:11434` |
| `minimax-m2.5:cloud` | `ollama_cloud_local__minimax-m2-5-cloud` | `http://localhost:11434` |
| `minimax-m3:cloud` | `ollama_cloud_local__minimax-m3-cloud` | `http://localhost:11434` |
| `kimi-k2.6:cloud` | `ollama_cloud_local__kimi-k2-6-cloud` | `http://localhost:11434` |
| `deepseek-v4-flash:cloud` | `ollama_cloud_local__deepseek-v4-flash-cloud` | `http://localhost:11434` |
| `deepseek-v4-pro:cloud` | `ollama_cloud_local__deepseek-v4-pro-cloud` | `http://localhost:11434` |
| `kimi-k2.5:cloud` | `ollama_cloud_local__kimi-k2-5-cloud` | `http://localhost:11434` |
| `nemotron-3-ultra:cloud` | `ollama_cloud_local__nemotron-3-ultra-cloud` | `http://localhost:11434` |
| `gpt-oss:20b-cloud` | `ollama_cloud_local__gpt-oss-20b-cloud` | `http://localhost:11434` |
| `gpt-oss:120b-cloud` | `ollama_cloud_local__gpt-oss-120b-cloud` | `http://localhost:11434` |
| `qwen3-coder:480b-cloud` | `ollama_cloud_local__qwen3-coder-480b-cloud` | `http://localhost:11434` |
| `glm-4.7:cloud` | `ollama_cloud_local__glm-4-7-cloud` | `http://localhost:11434` |
| `gemini-3-flash-preview:cloud` | `ollama_cloud_local__gemini-3-flash-preview-cloud` | `http://localhost:11434` |
| `minimax-m2.1:cloud` | `ollama_cloud_local__minimax-m2-1-cloud` | `http://localhost:11434` |
| `deepseek-v3.2:cloud` | `ollama_cloud_local__deepseek-v3-2-cloud` | `http://localhost:11434` |
| `ministral-3:3b-cloud` | `ollama_cloud_local__ministral-3-3b-cloud` | `http://localhost:11434` |
| `ministral-3:8b-cloud` | `ollama_cloud_local__ministral-3-8b-cloud` | `http://localhost:11434` |
| `ministral-3:14b-cloud` | `ollama_cloud_local__ministral-3-14b-cloud` | `http://localhost:11434` |
| `devstral-small-2:24b-cloud` | `ollama_cloud_local__devstral-small-2-24b-cloud` | `http://localhost:11434` |
| `nemotron-3-nano:30b-cloud` | `ollama_cloud_local__nemotron-3-nano-30b-cloud` | `http://localhost:11434` |
| `deepseek-v3.1:671b-cloud` | `ollama_cloud_local__deepseek-v3-1-671b-cloud` | `http://localhost:11434` |
| `devstral-2:123b-cloud` | `ollama_cloud_local__devstral-2-123b-cloud` | `http://localhost:11434` |
| `mistral-large-3:675b-cloud` | `ollama_cloud_local__mistral-large-3-675b-cloud` | `http://localhost:11434` |
| `gemma3:4b-cloud` | `ollama_cloud_local__gemma3-4b-cloud` | `http://localhost:11434` |
| `gemma3:12b-cloud` | `ollama_cloud_local__gemma3-12b-cloud` | `http://localhost:11434` |
| `gemma3:27b-cloud` | `ollama_cloud_local__gemma3-27b-cloud` | `http://localhost:11434` |
| `qwen3-coder-next:cloud` | `ollama_cloud_local__qwen3-coder-next-cloud` | `http://localhost:11434` |

## vLLM (hosted)

- LiteLLM prefix：`hosted_vllm`
- 模型數：2

| 模型 | model alias | API base |
| --- | --- | --- |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | `vllm__qwen-qwen3-coder-30b-a3b-instruct` | `http://localhost:8000/v1` |
| `openai/gpt-oss-120b` | `vllm__openai-gpt-oss-120b` | `http://localhost:8000/v1` |
