# MCP 與 Skills Gateway 實驗參考

最後查證日期：2026-07-11。參考 [MCP Overview](https://docs.litellm.ai/docs/mcp)、[MCP Permission Management](https://docs.litellm.ai/docs/mcp_control)、[Skills Gateway](https://docs.litellm.ai/docs/skills_gateway) 與 [LiteLLM Skills](https://docs.litellm.ai/docs/tutorials/claude_code_skills)。

## 供應鏈規則

- 正式環境只註冊 commit SHA 固定的 Git URL。
- 記錄已審查 SHA、內容雜湊、skill 名稱、可用工具與所需權限。
- 升級時重新檢視 diff、重跑測試並更新雜湊。
- 公開 Skill Hub 內容視為不受信任輸入；安裝前必須審查。

## 核心實驗

- 註冊一個只讀、固定版本的測試 MCP server。
- 建立兩個 toolsets，分別允許查詢與空集合。
- 驗證 agent A 可列出並呼叫單一安全工具，agent B 看不到該工具。
- 嘗試呼叫未授權及高風險工具，預期拒絕並產生 audit event。
- 註冊固定 SHA 的測試 skill；變更來源後必須重新審查，不能自動信任。
- 清理所有測試註冊、keys 與 toolsets。
