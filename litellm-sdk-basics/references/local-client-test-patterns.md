# Proxy client 測試模式

最後查證日期：2026-07-12。本參考用於測試本機 LiteLLM Proxy 或混合 endpoint mode；執行前請重新查核 [LiteLLM 官方文件](https://docs.litellm.ai/docs/) 所列的目前 endpoint schema。

## Proxy base URL

本機測試只使用測試專用的 placeholder：

```python
base_url = "http://localhost:4000"
api_key = "test-only-virtual-key"
```

不得重用維運 CSV、log、螢幕截圖或既有報告中的 key。

## 選擇 endpoint

- Chat model：`POST /chat/completions`，或 OpenAI SDK 的 `client.chat.completions.create`。
- Responses mode：以 `input` 呼叫 `POST /v1/responses`。
- 影像產生 alias：依目前 LiteLLM 版本使用 `POST /v1/responses` 或支援的影像端點，並檢查輸出 item type。
- Transcription alias：以 multipart form-data 和小型音訊檔呼叫 `POST /v1/audio/transcriptions`。
- Embeddings：使用專用 API，不可假設 chat 欄位存在。

## 權限測試

將模型加入 virtual key 後：

1. 使用該 virtual key，不使用 admin key。
2. 發送極短的 prompt，例如 `Say OK`。
3. 使用低數值的 `max_completion_tokens` 或該端點等效上限。
4. 記錄 status、model alias、endpoint 與 error body 類別。
5. 不得在 log 或最終輸出中顯示 virtual key。

## Tool 與 Responses 注意事項

Proxy custom hook 可能會依 request-visible model alias／名稱阻擋 `input[].type=custom_tool_call`。Responses API replay 失敗時，應檢查 request 是否包含此 item type、送出的 alias 是否在阻擋清單，以及其後端是否支援它；不要假設 pre-call hook 已知道 routing 後的 deployment。
