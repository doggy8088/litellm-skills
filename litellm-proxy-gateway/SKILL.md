---
name: litellm-proxy-gateway
description: 設計、建立或審查 LiteLLM Proxy Server 作為 OpenAI-compatible LLM Gateway、集中式模型入口、virtual key 與 config.yaml 時使用。
---

# LiteLLM Proxy Gateway

## 使用時機

當任務需要集中控管多個模型 provider、讓既有 OpenAI-compatible client 透過同一個 endpoint 呼叫模型，或需要 virtual keys、budgets、logging、guardrails、Admin UI 時，使用此技能。

## 官方依據

- Getting Started：https://docs.litellm.ai/docs/
- LiteLLM AI Gateway：https://docs.litellm.ai/docs/simple_proxy
- Proxy config overview：https://docs.litellm.ai/docs/proxy/configs
- Config settings：https://docs.litellm.ai/docs/proxy/config_settings
- Life of a Request：https://docs.litellm.ai/docs/proxy/architecture
- Virtual Keys：https://docs.litellm.ai/docs/proxy/virtual_keys

## 工作流程

1. 判斷是否真的需要 Proxy：若只是單一 Python app 的本地整合，SDK 可能足夠；若是團隊共用、權限、成本、紀錄或防護需求，使用 Proxy。
2. 建立 `config.yaml`，至少包含 `model_list`；依需求加入 `router_settings`、`litellm_settings`、`general_settings`、`environment_variables`。
3. 用 `model_name` 建立對外 alias，用 `litellm_params.model` 指向實際 provider model。
4. 所有 API key、database URL、Redis 密碼與 master key 都透過環境變數注入。
5. 以 `litellm --config config.yaml` 或 Docker 啟動 proxy，確認預設 port 與 base URL。
6. 用 OpenAI SDK 測試 `base_url="http://localhost:4000"`，確認既有 client 不需改 provider-specific SDK。
7. 若要 spend tracking、virtual keys、teams 或 budgets，設定資料庫並驗證 spend 是否寫入。
8. 若要多 proxy instance 或集中 rate limit/load balancing 狀態，加入 Redis。
9. 使用 `/utils/transform_request` 檢查 LiteLLM 實際送往 provider 的 payload。
10. 交付前列出開發、測試、正式環境的 key、model alias、budget 與 logging 差異。

## Config 範例

```yaml
model_list:
  - model_name: course-gpt
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

router_settings:
  num_retries: 2
  timeout: 30

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

## OpenAI Client 測試

```python
import openai

client = openai.OpenAI(
    api_key="test-key-from-your-litellm-proxy",
    base_url="http://localhost:4000",
)

response = client.chat.completions.create(
    model="course-gpt",
    messages=[{"role": "user", "content": "Hello from LiteLLM Proxy"}],
)

print(response.choices[0].message.content)
```

## 教學練習

- 建立兩個 `model_name` alias，分別指向 OpenAI 與 Ollama。
- 用同一段 OpenAI SDK 程式碼切換 proxy model alias。
- 讓學生用 `config.yaml` 增加環境變數引用，並說明為何不可提交 secret。
- 開啟 Admin UI 後建立測試 virtual key，限制可用模型。

## 驗收檢查

- `config.yaml` 沒有真實 secret。
- 對外暴露的是穩定 model alias，而不是到處散落 provider-specific model 名稱。
- OpenAI SDK 能成功透過 proxy 呼叫模型。
- 若啟用 spend tracking，已設定資料庫並能查到 key、user 或 team spend。
- 若有多個 proxy instance，Redis 設定與連線方式清楚。

## 常見錯誤

- 把 `model_name` 與 `litellm_params.model` 混淆。
- 在正式環境用 master key 當一般 client key。
- 沒有把 proxy 層的 key 權限與 provider key 權限分開管理。
- 未測試 provider payload transform 就直接排查模型品質問題。
