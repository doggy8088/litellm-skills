# Proxy 實驗與參考

最後查證日期：2026-07-11。執行前查核 [Proxy config](https://docs.litellm.ai/docs/proxy/configs) 與 [Config settings](https://docs.litellm.ai/docs/proxy/config_settings)。

## 最小設定

```yaml
model_list:
  - model_name: course-chat
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

## 核心實驗

- 先備：隔離 Proxy、測試 master key、低成本或 mock provider。
- 產出：`config.yaml`、client smoke script、環境差異表。
- 成功案例：alias 回傳完成結果。
- 失敗案例：錯誤 virtual key、未知 alias、缺少 provider secret。
- 驗收：記錄啟動命令、HTTP 狀態碼與回應 request ID。
- 清理：撤銷測試 key、停止 Proxy、刪除暫存資料。

模型名稱只是教學範例，使用前必須重新查證。
