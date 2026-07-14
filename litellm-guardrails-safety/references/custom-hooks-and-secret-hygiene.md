# Custom hook 與機密資料處理

最後查證日期：2026-07-12。Proxy callback、guardrail mode 與 request schema 可能隨 LiteLLM 版本變動；實作前請重新查核 [Custom Callbacks](https://docs.litellm.ai/docs/observability/custom_callback) 與 [Guardrails](https://docs.litellm.ai/docs/proxy/guardrails/quick_start)。

## Hook 邊界

[proxy_policy_hook.py](../scripts/custom_hooks/proxy_policy_hook.py) 只處理一項相容性政策：針對指定模型，阻擋不支援的 `custom_tool_call` input item。

- 阻擋清單由 `LITELLM_BLOCK_CUSTOM_TOOL_CALL_MODELS` 提供；每個值都必須是 client 實際送入 `model` 的 alias／名稱，不是 routing 完成後的 provider deployment 名稱。
- Hook 不會猜測 alias 到後端的映射。同一 alias 若可能路由到能力不同的後端，應先拆成不同 aliases，再將不相容的 request-visible alias 列入阻擋清單。
- 命中時回傳 400；其餘 request 保持原樣。
- Hook 不得設定、補登或改寫 pricing、model alias 或 routing；這些設定必須留在 LiteLLM 原生機制，避免繞過 virtual key allowlist、budget 或 router policy。

## 安全規則

- 初始化必須可重複，且 request path 不得註冊或修改 pricing。
- 避免把 LiteLLM Proxy 內部型別列為必要 import，以降低版本耦合。
- 不得在 hook 內改寫 model alias 或 router 選擇結果。
- 對命中政策的 payload 採 fail-closed，錯誤訊息不得回顯 request payload。
- 測試模組匯入、正常 payload、blocked payload、未列入清單的模型與畸形 input。

## 機密盤點

LiteLLM 維運 repo 常見敏感資料包括：

- `Key_List*.csv` 與結果 CSV 中的 virtual key 或 key hash。
- Bearer token、SAS query、database URL 與 `.env`。
- 瀏覽器或 API capture、SpendLogs archive、prompt 與 response。

不得引用或複製實際值；公開 repo 前，必須清除敏感產物並輪替曾暴露的憑證。

## Prompt 與 response 保存

啟用 `store_prompts_in_spend_logs: true` 後，log 與 archive 可能包含完整內容。啟用前必須定義資料分類、保留期限、加密方式與存取權限。

## 審查問題

- 哪個精確條件會阻擋 request？
- 哪些 identity、team 或 key 可套用例外？例外存放在哪裡？
- Log 能否證明阻擋事件而不暴露 payload？
- Chat、Responses、image、audio 與 embeddings 是否都維持原始 model？
- Hook 造成正式流量異常時，如何 rollback？
