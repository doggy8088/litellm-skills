---
name: litellm-sdk-basics
description: 使用 LiteLLM Python SDK 建立或審查 completion、streaming、structured output、tool calling、Responses API 與基礎成本追蹤整合時使用。
---

# LiteLLM SDK Basics

## 使用時機

當任務需要在 Python 應用程式中直接使用 LiteLLM，而不是先架設 Proxy Server 時，使用此技能。

適用任務：

- 建立第一個 `litellm.completion()` 或 `litellm.acompletion()` 呼叫。
- 將 OpenAI、Anthropic、Vertex AI、Bedrock、Ollama 等 provider 統一成 OpenAI Chat Completions 格式。
- 加入 streaming、exception handling、structured outputs、tool/function calling 或基礎成本 callback。
- 為學生設計 LiteLLM SDK 入門練習。

## 官方依據

- Getting Started：https://docs.litellm.ai/docs/
- LiteLLM 首頁：https://docs.litellm.ai/
- Structured Outputs：https://docs.litellm.ai/docs/completion/json_mode
- Function Calling：https://docs.litellm.ai/docs/completion/function_call
- Reliability - Retries, Fallbacks：https://docs.litellm.ai/docs/completion/reliable_completions
- Prompt Caching：https://docs.litellm.ai/docs/completion/prompt_caching

## 工作流程

1. 先判斷呼叫型態：`completion()`、`acompletion()`、`responses()`、embedding、image、audio，或是否應改用 Proxy。
2. 明確指定 provider-prefixed model，例如 `openai/gpt-4o`、`anthropic/...`、`azure/...`、`ollama/...`。
3. 用環境變數讀取 API key，不要把 key 寫進程式碼、教材或測試快照。
4. 保持 messages 為 OpenAI-compatible 結構：`role` 與 `content` 必須清楚。
5. 若使用 streaming，確認呼叫端真的逐 chunk 消費輸出，並測試空 delta 的處理。
6. 加入 OpenAI-compatible exception handling，例如 authentication、rate limit、API error。
7. 若使用 structured outputs，使用 `response_format` 與 JSON Schema，並在應用層再次驗證輸出。
8. 若使用 tool calling，建立固定的 tool registry，解析 JSON arguments，執行工具後把 tool result 加回 messages。
9. 若需要記錄成本，使用 success callback 或 `completion_cost()`，並在練習中列出 prompt tokens、completion tokens、total tokens 與估算成本。
10. 用低成本模型或 mock response 驗證流程，不要讓學生在入門練習中直接打昂貴模型。

## 最小範例

```python
import os
from litellm import completion

assert os.environ.get("OPENAI_API_KEY"), "請先在 shell 設定 OPENAI_API_KEY"

response = completion(
    model="openai/gpt-4o-mini",
    messages=[{"role": "user", "content": "用一句話說明 LiteLLM 的用途"}],
)

print(response.choices[0].message.content)
print(response.usage)
```

## 教學練習

- 練習一：同一段 messages 分別改用 OpenAI 與 Ollama provider，觀察程式碼需要改動的位置。
- 練習二：替 completion 加上 `num_retries=2`，模擬 provider 暫時失敗時的行為。
- 練習三：建立 JSON Schema，要求模型輸出 `{ "summary": string, "risk": string }`，再用 Python 驗證。
- 練習四：建立一個 `get_current_time` tool，完成一次 function calling round trip。

## 驗收檢查

- 程式碼沒有硬編碼任何真實 API key。
- model 名稱包含 provider 前綴或有清楚的 proxy model alias 說明。
- 錯誤處理涵蓋 authentication、rate limit 與 provider API error。
- structured output 有 schema 與應用層驗證。
- tool calling 不會任意執行模型輸出的未知函式名稱。
- 教學練習有成本或 token 用量觀察點。

## 常見錯誤

- 把 provider SDK 與 LiteLLM 混用，導致 response format 不一致。
- 假設每個模型都支援同一組 tools、JSON mode、reasoning 或 streaming 行為。
- 只看 `total_tokens`，沒有區分 prompt、completion、cache read 或 cache write。
- 把 fallback、retry、timeout 留到正式環境才補。

## 使用情境與提示詞範例

- **情境 1：基礎 Completion 與異常處理**
  * *提示詞*：「幫我用 LiteLLM Python SDK 寫一個基礎的 completion 腳本，使用 `openai/gpt-4o-mini`，並且要包含 rate limit 和 authentication 錯誤的 exception handling，不要將 API key 硬編碼在程式碼中。」
- **情境 2：結構化輸出 (Structured Outputs)**
  * *提示詞*：「我需要使用 LiteLLM SDK 設計一個 structured output 的範例，定義一個 Pydantic schema 來解析新聞摘要（包含 `title`、`summary` 、`tags`），並確保模型輸出符合該 schema，且在 Python 層進行再次驗證。」
- **情境 3：函式呼叫 (Function Calling)**
  * *提示詞*：「請幫我撰寫一個 LiteLLM 函式呼叫（Function Calling）的完整練習。定義一個可以查詢天氣的 `get_weather` 工具，並示範模型決定調用該工具、執行工具後將結果加回 messages，再取得最終模型回覆的完整 round-trip 流程。」
