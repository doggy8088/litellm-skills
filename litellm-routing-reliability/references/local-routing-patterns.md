# 路由模式參考

最後查證日期：2026-07-12。多區路由、endpoint mode 與 affinity 欄位可能隨 LiteLLM 版本變動；調整前請重新查核 [Routing](https://docs.litellm.ai/docs/routing) 與 [Proxy reliability](https://docs.litellm.ai/docs/proxy/reliability)。

## Alias 模式

- 多個項目使用相同 `model_name`，代表同一個負載平衡模型群組。
- 區域 alias 可使用 `chat-region-a`、`chat-region-b` 等中性名稱；實際 deployment 名稱由環境設定提供。
- 部署範例中的名稱應視為本地 alias，不可推定為公開模型名稱或官方供應區域。

## Endpoint mode

- Chat alias 使用 `/chat/completions` 測試。
- `model_info.mode: responses` 使用 `/v1/responses` 測試。
- `model_info.mode: image_generation` 需使用相容的影像產生測試，並設定 `output_cost_per_image` 等成本欄位。
- Transcription alias 應以 multipart request 呼叫 `/v1/audio/transcriptions`，不可用 chat completions 測試。

## Router 控制

- `enable_loadbalancing_on_batch_endpoints: true` 會把負載平衡擴及 batch 類端點。
- `router_config.optional_pre_call_checks` 可包含：
  - `responses_api_deployment_check`
  - `deployment_affinity`
  - `session_affinity`
  - `encrypted_content_affinity`

這些檢查可能在一般路由前固定或篩選 request。

## 路由矩陣範本

調整或審查路由時，建立簡潔矩陣：

| Alias | Provider | Region | Mode | Primary／Fallback | Cost class | Test endpoint |
| --- | --- | --- | --- | --- | --- | --- |
| `chat-default` | Azure | `region-a` | chat | primary | low | `/chat/completions` |

## 失敗情境測試

- 停用或錯設一個 deployment；若群組仍有其他 deployment，alias 應可繼續服務。
- 對只支援 chat 的 alias 發送 Responses API request，確認錯誤訊息清楚。
- 模擬逾時，確認 client 不會無限等待。
- 對高成本或稀缺的 fallback alias 設定預算限制。
- 從 log 確認實際處理 request 的 deployment。
