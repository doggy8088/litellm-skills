# 成本治理實驗與參考

最後查證日期：2026-07-11。參考 [Spend Tracking](https://docs.litellm.ai/docs/proxy/cost_tracking)、[Virtual Keys](https://docs.litellm.ai/docs/proxy/virtual_keys) 與 [Request Tags](https://docs.litellm.ai/docs/proxy/request_tags)。Tags、budgets 與部分報表可能受版本或授權方案限制，使用前必須確認。

## 安全設定

若成本或 budget 依賴 tags，評估啟用：

```yaml
general_settings:
  reject_clientside_metadata_tags: true
```

啟用後，把治理 tags 改由可信任 hook 或 key/team metadata 注入。

## Key payload

```json
{
  "models": ["course-chat"],
  "max_budget": 1.0,
  "budget_duration": "24h",
  "duration": "24h",
  "metadata": {"course": "litellm-cost-governance"}
}
```

到期欄位依 LiteLLM 版本可能採 `duration` 或 `expires`；送出前查核 `/key/generate` schema，不得同時猜測兩種欄位。

## 核心實驗

- 建立 24 小時、1 美元、單一模型的測試 key。
- 驗證允許模型成功、其他模型拒絕、超額拒絕、到期或撤銷後拒絕。
- 嘗試由 client 偽造治理 tag，預期遭拒或被可信任值覆寫。
- 保存狀態碼、錯誤類型與 spend log；不得保存 key 值。
