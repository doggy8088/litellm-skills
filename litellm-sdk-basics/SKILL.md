---
name: litellm-sdk-basics
description: 使用 LiteLLM Python SDK 建立或審查 completion、streaming、structured output、tool calling、Responses API 與基礎成本追蹤。當任務是在 Python 程式內直接呼叫 LiteLLM 而非管理 Proxy 時使用；Proxy、virtual key、集中式預算或 gateway 維運改用對應專門技能。
---

# LiteLLM SDK Basics

## 工作流程

1. 判斷 endpoint 類型與模型能力，並確認是否真的應使用 SDK 而非 Proxy。
2. 查核目前 LiteLLM 官方文件與 provider 支援狀態；不要依記憶猜測模型名稱或參數。
3. 使用環境變數讀取憑證，指定 provider-prefixed model。
4. 實作成功路徑及 authentication、rate limit、timeout、provider error 路徑。
5. Structured output 在應用層再次驗證；tool calling 只執行已註冊工具並驗證 arguments。
6. Streaming 必須處理空 delta、中途失敗及取消。
7. 執行離線測試；只有使用者明確允許時才呼叫付費 provider。

需要程式範例、測試案例或版本注意事項時，讀取 [實驗與參考](references/guide.md)；測試 proxy-compatible client 或混合 endpoint mode 時，讀取 [本機 client 測試模式](references/local-client-test-patterns.md)。

## 安全底線

- 不硬編碼或輸出真實 API key。
- 不任意執行模型產生的函式名稱或未驗證參數。
- 不假設所有模型都支援相同的 tools、JSON mode、reasoning 或 streaming 行為。
- 成本資料是估算值；需要價格時重新查核官方 model cost map。

## 驗收

- 最小成功案例可執行或由 mock 驗證。
- 三類主要錯誤有明確處理與測試。
- Structured output 有 schema 與應用層驗證。
- Tool calling 對未知工具及不合法 arguments 採拒絕策略。
- 回報執行命令、預期結果及實際證據。
