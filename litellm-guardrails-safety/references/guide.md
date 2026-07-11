# Guardrails 實驗與參考

最後查證日期：2026-07-11。參考 [Guardrails Quick Start](https://docs.litellm.ai/docs/proxy/guardrails/quick_start)、[Tool Permission Guardrail](https://docs.litellm.ai/docs/proxy/guardrails/tool_permission) 與 [MCP Guardrails](https://docs.litellm.ai/docs/mcp_guardrail)。

## Tool permission

```yaml
guardrails:
  - guardrail_name: course-tool-permission
    litellm_params:
      guardrail: tool_permission
      mode: post_call
      rules:
        - id: allow-course-search
          tool_name: "^course_search$"
          decision: allow
          allowed_param_patterns:
            query: "^.{1,200}$"
      default_action: deny
      on_disallowed_action: block
```

## 核心實驗

- 成功：`course_search` 加入 1–200 字元 query。
- 拒絕：未知工具、空 query、過長 query。
- PII：信用卡 block、email mask、一般文字 allow。
- 故障：guardrail provider timeout；高風險規則預期 fail-closed。
- 驗收：保存狀態碼、規則 ID、遮罩結果與不含敏感原文的 audit event。
