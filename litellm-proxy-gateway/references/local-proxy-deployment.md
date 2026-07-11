# Proxy 部署參考

最後查證日期：2026-07-12。Compose、Postgres、掛載與 custom callback 欄位可能隨版本變動；部署前請重新查核 [Proxy config](https://docs.litellm.ai/docs/proxy/configs) 與 [Config settings](https://docs.litellm.ai/docs/proxy/config_settings)。

## 部署形態

- 使用已驗證的明確 LiteLLM 映像標籤；除非另有需求，Proxy 對外使用 `4000` 連接埠。
- 以 `postgres:16-alpine` 搭配具名 Docker volume 保存資料。
- 將 Proxy 設定掛載到 `/app/config.yaml`，custom hook 模組掛載到 `/app/custom_hooks`。
- 正式環境使用 `--config /app/config.yaml --port 4000`，不要啟用 `--detailed_debug`；僅可在隔離且限時的疑難排解期間啟用。
- Compose 應等待 Postgres 健康檢查通過，並設定經隱私審查且有上限的 log rotation；除非保留政策確有需要，避免產生數 GB 的除錯記錄。

## 設定模式

- Azure deployment 使用 `litellm_params.model: azure/<deployment-name>`。
- 多個項目可共用同一個 `model_name` 形成負載平衡群組；區域 alias 可使用 `chat-region-a`、`chat-region-b` 等中性名稱，實際 deployment 名稱由環境設定提供。
- Responses API 使用 `model_info.mode: responses`；影像產生使用 `mode: image_generation`。
- OpenAI-compatible 的非 OpenAI 後端應明確設定 `custom_llm_provider: openai`、`api_base`、`api_key` 與 token pricing。
- `general_settings.store_model_in_db: true` 可啟用資料庫管理的模型。
- `general_settings.store_prompts_in_spend_logs: true` 可能保存敏感 prompt／response；複製此設定前必須說明資料保存風險。
- `litellm_settings.upperbound_key_generate_params` 可設定產生 virtual key 時的預算上限預設值。
- `litellm_settings.callbacks` 可載入掛載的 hook instance，例如 `custom_hooks.proxy_policy_hook.proxy_handler_instance`。
- `router_config.optional_pre_call_checks` 可包含 Responses deployment、deployment affinity、session affinity 與 encrypted-content affinity 檢查。

## Custom hook 整合

[proxy_policy_hook.py](../../litellm-guardrails-safety/scripts/custom_hooks/proxy_policy_hook.py) 範本只會針對設定的 request-visible model alias／名稱，阻擋 `input[].type=custom_tool_call`；它不會推測 routing 後端，pricing、model alias 與 routing 必須保留在 LiteLLM 原生設定。

修改此模式時：

- 被阻擋的 request 應回傳清楚的 `HTTPException`。
- 不得硬編碼個人 allowlist；經核准的例外應置於設定中。
- 確認 hook 不會改寫 key policy 或 router 已選定的模型。
- 啟用 callback 前，先在容器內驗證模組可匯入。

## 安全注意事項

維運 repo 常殘留 CSV 內的 virtual key、腳本中的管理 token 範例、上傳工具的 SAS URL，以及瀏覽器或 API capture。不得把實際值複製到範例；公開或分享 repo 前，應清除敏感產物並輪替曾暴露的憑證。

## 驗證

- `docker compose ps` 顯示 LiteLLM 與 Postgres 健康。
- `/health`、`/health/readiness` 或實際設定的健康端點可正常回應。
- virtual key 可透過 OpenAI SDK 呼叫低成本 alias。
- Postgres 可用後，spend tracking 才開始寫入資料列。
- 以一筆允許及一筆刻意阻擋的 request 驗證 custom hook 行為。
