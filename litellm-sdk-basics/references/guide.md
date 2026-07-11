# SDK 實驗與參考

最後查證日期：2026-07-11。執行前仍須查核 [LiteLLM Getting Started](https://docs.litellm.ai/) 與相關 endpoint 文件。

## 最小範例

```python
import os
from litellm import completion

if not os.environ.get("OPENAI_API_KEY"):
    raise RuntimeError("請先設定 OPENAI_API_KEY")

response = completion(
    model="openai/gpt-4o-mini",
    messages=[{"role": "user", "content": "用一句話說明 LiteLLM"}],
)
print(response.choices[0].message.content)
print(response.usage)
```

模型名稱僅為教學範例，不代表永久可用或最便宜的選擇。

## 核心實驗

- 先備：Python、隔離虛擬環境；離線路徑使用 mock。
- 產出：`sdk_lab.py` 與 `test_sdk_lab.py`。
- 成功案例：回應包含文字與 usage。
- 失敗案例：authentication、rate limit、timeout、未知工具、不合法 JSON。
- 驗收：`python -m unittest -v` 全部通過，且測試不存取真實網路。
- 選跑：設定測試用 provider key 後執行一筆低成本 smoke request。

## 官方參考

- [Structured Outputs](https://docs.litellm.ai/docs/completion/json_mode)
- [Function Calling](https://docs.litellm.ai/docs/completion/function_call)
- [Reliable completions](https://docs.litellm.ai/docs/completion/reliable_completions)
