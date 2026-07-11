# LiteLLM 本機 Docker 新手上路手冊

> 查證日期：2026-07-12
>
> 本手冊只引用 LiteLLM 官方文件、LiteLLM 官方 GitHub 儲存庫及 Docker 官方文件。LiteLLM 與 Docker 會持續更新；模型名稱、映像標籤、設定鍵及介面都可能變動，執行前請以文件連結中的目前內容為準。

本手冊的目標是讓第一次接觸 LiteLLM 的使用者，在 macOS、Windows 或 Linux 上以 Docker 啟動一個**只供本機使用的 LiteLLM Proxy**，再用 curl 或 Python 呼叫 OpenAI 相容的 /chat/completions API。

LiteLLM 官方目前提供兩條路徑：單一容器加上本機 config.yaml，以及官方 Docker Compose 範本加上 Postgres 與 Prometheus。前者適合先確認模型呼叫；後者才包含 virtual keys、spend tracking 與 UI 所需的資料庫。官方的 Docker、Helm、Terraform 說明列出 litellm、litellm-database 與 litellm-non_root 映像，並建議生產環境固定 release tag 或 digest。[LiteLLM Docker 部署文件](https://docs.litellm.ai/docs/proxy/deploy)

**如果只想在本機快速驗證，先完成單一容器流程；需要金鑰管理、用量統計或跨容器路由時，再升級到 Compose 與 Postgres。**

* * *

## 1. 先選擇安裝路徑

| 需求 | 建議路徑 | 會得到什麼 | 不會得到什麼 |
| --- | --- | --- | --- |
| 只想測試一個 provider 模型 | 單一 docker run | Proxy、OpenAI 相容 API、健康檢查 | Postgres 資料、virtual keys、spend tracking |
| 想在本機管理 keys、users、teams 或 UI | 本節最小 Docker Compose；需要監控時再用官方完整範本 | Proxy、Postgres、named volume；完整範本再加 Prometheus | 正式環境級備份、高可用與外部 secrets 管理 |
| 多個 LiteLLM 容器共用 RPM/TPM 或高流量 | Postgres 加 Redis | 跨執行個體的路由與限流狀態 | Redis 不會取代 Postgres 的 key 與 spend 資料 |

LiteLLM 官方健康檢查文件指出，/health/readiness 會回報 Proxy 與資料庫連線狀態，而 /health 會對設定中的每個模型實際發出 API 呼叫；因此不應把 /health 當作高頻的免費 liveness probe。[LiteLLM Health Checks](https://docs.litellm.ai/docs/proxy/health)

* * *

## 2. 前置條件

### 2.1 安裝 Docker

初學者在三種作業系統都可使用 Docker Desktop。Docker 官方說明 Docker Desktop 內含 Docker Engine、Docker CLI 與 Docker Compose，並提供 macOS、Windows、Linux 的安裝方式。[Docker Desktop](https://docs.docker.com/desktop/)

- macOS：依 [Docker Desktop for Mac 安裝文件](https://docs.docker.com/desktop/setup/install/mac-install/) 安裝。官方列出目前與前兩個主要 macOS 版本及至少 4 GB RAM 的需求；Apple silicon 與 Intel 使用不同下載項目。
- Windows：依 [Docker Desktop for Windows 安裝文件](https://docs.docker.com/desktop/setup/install/windows-install/) 安裝。Linux 容器通常使用 WSL 2 後端；Windows Home 或 Education 只能執行 Linux 容器。[Windows 的 WSL 2 說明](https://docs.docker.com/desktop/features/wsl/)
- Linux：可安裝 Docker Desktop，或依 [Docker Engine 安裝總覽](https://docs.docker.com/engine/install/) 安裝原生 Engine。Ubuntu 請使用 Docker 官方 apt repository 的安裝步驟；官方也提醒 convenience script 只適合測試與開發，不應當成正式環境安裝流程。[Ubuntu 安裝 Docker Engine](https://docs.docker.com/engine/install/ubuntu/)

Linux 原生 Engine 安裝完成後，若服務尚未啟動，可依官方文件檢查並啟動 docker systemd service。Windows 與 macOS 則必須先啟動 Docker Desktop。

### 2.2 驗證 Docker 與 Compose

在終端機執行：

~~~sh
docker version
docker compose version
docker run --rm hello-world
~~~

三個命令都成功，才進入 LiteLLM 設定。hello-world 是 Docker 官方用來確認 Engine 能下載並執行映像的最小測試。[Docker Engine 安裝後驗證](https://docs.docker.com/engine/install/ubuntu/)

### 2.3 準備 provider 憑證

LiteLLM Proxy 只是統一入口，仍需要至少一個 provider 的 API key 才能完成模型呼叫。下面以 OpenAI 為例；openai/gpt-4o-mini 只是教材用的範例模型，**請依你的 provider 帳號目前可用的模型替換**。LiteLLM 的模型設定使用 model_name 作為客戶端看到的別名，再以 litellm_params.model 指定實際 provider 與模型。[LiteLLM config.yaml 概覽](https://docs.litellm.ai/docs/proxy/configs)

不要把真實 key 寫入 Git、config.yaml、問題回報或公開終端機紀錄。LiteLLM 支援 os.environ/變數名 讀取環境變數，讓設定檔不必保存 provider key。[LiteLLM 從環境變數載入設定](https://docs.litellm.ai/docs/proxy/configs)

* * *

## 3. 最小單一容器流程

這個流程不啟動 Postgres，也不保存 LiteLLM 的 virtual key 或 spend 資料；它只將設定檔以唯讀 bind mount 掛進容器。

### 3.1 建立工作目錄

macOS、Linux 或 PowerShell 均可先建立同名資料夾：

~~~sh
mkdir litellm-local
cd litellm-local
~~~

### 3.2 建立 .env

建立 .env，內容如下，並替換 provider key 與 Proxy master key：

~~~dotenv
OPENAI_API_KEY=替換成你的_provider_key
LITELLM_MASTER_KEY=sk-local-請改成隨機值
~~~

LITELLM_MASTER_KEY 是呼叫 Proxy 的管理 key，應使用新的隨機值，不要重複使用 provider key。LiteLLM 官方文件說明 master key 可放在 general_settings.master_key，也可使用 LITELLM_MASTER_KEY 環境變數；本手冊採用環境變數，避免把密鑰寫進設定檔。[LiteLLM Proxy 設定](https://docs.litellm.ai/docs/proxy/configs)

本機開發可用下列命令產生一個以 sk- 開頭的值：

~~~sh
printf 'sk-local-%s\n' "$(openssl rand -hex 24)"
~~~

把輸出貼回 .env。Windows PowerShell 可使用受信任的密碼產生器，再加上 sk-local- 前綴。

在 macOS/Linux 限制 .env 權限，並在所有平台加入版本控制排除清單：

~~~sh
chmod 600 .env
printf '.env\n' >> .gitignore
~~~

docker --env-file 只會把變數傳入容器，不會替目前主機 shell 設定變數。為了讓後面的 curl 命令能送出 Authorization，請在目前 shell 另外設定相同的 master key：

~~~sh
export LITELLM_MASTER_KEY='sk-local-你的值'
~~~

Windows PowerShell 對應為 `$env:LITELLM_MASTER_KEY='sk-local-你的值'`。不要把這個命令加入 Git 或共享的 shell history。

Docker 官方指出 Compose 的 .env 可用來提供環境變數，但敏感資料不應以普通環境變數長期保存；較高安全需求請改用 Compose secrets 或外部 secrets manager。[Compose 環境變數](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/)、[Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)

### 3.3 建立 config.yaml

~~~yaml
model_list:
  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY
~~~

model_name 是你在 API 請求中傳送的別名；litellm_params.model 使用 provider/model 格式。若 provider、模型或 API base 不同，依 [LiteLLM 支援的 provider 文件](https://docs.litellm.ai/docs/providers) 修改這兩個欄位。

### 3.4 啟動容器

LiteLLM 官方 Docker 範例使用 docker.litellm.ai/berriai/litellm、4000 埠、config /app/config.yaml 與設定檔掛載。[LiteLLM Docker Run](https://docs.litellm.ai/docs/proxy/deploy)

macOS、Linux 或使用 Bash 的 Windows 終端機：

~~~sh
docker run --name litellm-proxy \
  --env-file .env \
  --mount type=bind,src="$PWD/config.yaml",dst=/app/config.yaml,readonly \
  --publish 127.0.0.1:4000:4000 \
  docker.litellm.ai/berriai/litellm:latest \
  --config /app/config.yaml
~~~

Windows PowerShell：

~~~powershell
docker run --name litellm-proxy `
  --env-file .env `
  --mount "type=bind,src=$((Get-Location).Path)\config.yaml,dst=/app/config.yaml,readonly" `
  --publish 127.0.0.1:4000:4000 `
  docker.litellm.ai/berriai/litellm:latest `
  --config /app/config.yaml
~~~

127.0.0.1:4000:4000 只把服務發佈到本機回送介面。若改成 4000:4000，Docker 會依主機設定對外發佈，可能讓同一網路的其他裝置連線；本機教學不應預設暴露到所有介面。[Docker Port publishing](https://docs.docker.com/engine/network/port-publishing/)

若看到 bind source path does not exist，先確認目前目錄真的有 config.yaml。Docker 的 --mount 對不存在的來源路徑會直接報錯；-v 則可能自動建立目錄，反而把「檔案掛載成目錄」的錯誤隱藏起來。[Docker Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)

### 3.5 觀察啟動狀態

另開一個終端機：

~~~sh
docker ps --filter name=litellm-proxy
docker logs -f litellm-proxy
~~~

看到 Proxy 監聽 4000 埠並載入 model list 後，再執行下一節的健康檢查。若需要更詳細的 LiteLLM 日誌，可暫時在啟動命令最後加上 --detailed_debug；官方部署文件提醒正式環境不要長期使用此選項，因為會降低回應效能。[LiteLLM Docker 部署](https://docs.litellm.ai/docs/proxy/deploy)

* * *

## 4. 健康檢查與第一個請求

### 4.1 Liveness

~~~sh
curl --fail http://127.0.0.1:4000/health/liveliness
~~~

預期回應是：

~~~text
"I'm alive!"
~~~

這個端點不需要 Authorization，適合 Docker healthcheck 或「程序是否仍存活」的檢查。它不代表 provider 模型可用。[LiteLLM Health Checks：liveliness](https://docs.litellm.ai/docs/proxy/health)

### 4.2 Readiness

~~~sh
curl --fail http://127.0.0.1:4000/health/readiness
~~~

單一容器且未連接資料庫時，預期會看到 status 欄位，但 db 可能是 Not connected。連接 Postgres 後，`db` 應為 `connected`；`status` 的值可能依 LiteLLM 版本顯示 `connected` 或 `healthy`，並通常包含 LiteLLM 版本。[LiteLLM Health Checks：readiness](https://docs.litellm.ai/docs/proxy/health)

官方將 readiness 與 liveliness 標為不需 Authorization 的端點；本手冊只在 loopback 上提供它們。若要對外發布，請先在反向 Proxy、網路 ACL 或防火牆限制可連線來源。

### 4.3 實際模型健康狀態

~~~sh
curl --fail \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/health
~~~

/health 會對 config 中的每個模型實際呼叫 provider；可能產生費用、觸發 rate limit，或因 provider 暫時故障而花很久時間。只在需要確認模型端到端可用時手動執行，不要拿它當每秒探針。

### 4.4 curl smoke test

~~~sh
curl --fail --silent --show-error \
  -X POST http://127.0.0.1:4000/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [
      {"role": "user", "content": "請只回覆：LiteLLM OK"}
    ]
  }'
~~~

成功時會收到 OpenAI Chat Completions 格式的 JSON，包含 id、choices 與 usage。LiteLLM 官方入門文件以同樣的 /chat/completions 路徑與 OpenAI 相容格式示範。[LiteLLM Getting Started](https://docs.litellm.ai/)

### 4.5 Python smoke test

Python smoke test 需要主機已安裝 Python 3；只想驗證 Proxy 時可跳過，直接使用上一節的 curl。

在主機建立隔離的 Python 虛擬環境，再安裝 OpenAI SDK，避免 Linux 發行版的系統 Python 權限或 externally-managed-environment 錯誤：

~~~sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip openai
~~~

Windows PowerShell 對應命令為 `py -m venv .venv`、`.venv\Scripts\Activate.ps1` 與 `python -m pip install --upgrade pip openai`。

把與 .env 相同的 master key 放入目前 shell，再執行：

~~~sh
export LITELLM_MASTER_KEY='sk-local-你的值'
python3 - <<'PY'
import os
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["LITELLM_MASTER_KEY"],
    base_url="http://127.0.0.1:4000",
)
response = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "請只回覆：Python OK"}],
)
print(response.choices[0].message.content)
PY
~~~

Windows PowerShell 對應設定為 $env:LITELLM_MASTER_KEY='sk-local-你的值'。LiteLLM 官方入門文件以 OpenAI Python client 設定 base_url 指向本機 Proxy；本範例沿用該相容介面。[LiteLLM Getting Started：OpenAI client](https://docs.litellm.ai/)

* * *

## 5. Docker Compose：Proxy 與 PostgreSQL

如果你看到 `Authentication Error, Not connected to DB!`，代表 LiteLLM 尚未連到可用的 Postgres。若目前只啟動單一 LiteLLM 容器，這就是預期原因；若已啟動 Compose，則還要檢查 hostname、帳號、密碼與資料庫健康狀態。這些管理功能需要 Postgres；**不能只把 `DATABASE_URL` 寫進設定檔，還必須啟動 `db` service，並讓 LiteLLM 等待資料庫健康。**

本節先提供可直接執行的最小 LiteLLM + PostgreSQL Compose；Prometheus 作為後續可選擴充。官方完整範本可參考 [LiteLLM 官方 docker-compose.yml](https://github.com/BerriAI/litellm/blob/main/docker-compose.yml)。

本專案也提供可直接複製的 [PostgreSQL Compose 範例](../examples/litellm-docker-postgres/)，其中的 `compose.yaml`、`config.yaml` 與 `.env.example` 對應本節流程。

### 5.0 最小 Compose 檔案

在新的工作目錄建立 `docker-compose.yml`：

~~~yaml
services:
  litellm:
    restart: unless-stopped
    image: ${LITELLM_IMAGE:-ghcr.io/berriai/litellm-database:latest}
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    env_file:
      - .env
    environment:
      DATABASE_URL: ${DATABASE_URL:?請在 .env 設定 DATABASE_URL}
      STORE_MODEL_IN_DB: "True"
    ports:
      - "127.0.0.1:${LITELLM_PORT:-4000}:4000"
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: llmproxy
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?請在 .env 設定 POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U llmproxy"]
      interval: 5s
      timeout: 5s
      retries: 12

volumes:
  postgres_data:
~~~

兩個 service 都使用 `restart: unless-stopped`：服務異常退出時會自動重啟；若手動執行 `docker compose stop`，則必須用 `docker compose start` 恢復，避免把手動停止的服務誤當成故障。

建立 `.env`：

~~~dotenv
LITELLM_PORT=4000
LITELLM_IMAGE=ghcr.io/berriai/litellm-database:latest
LITELLM_MASTER_KEY=sk-local-請替換成隨機值
LITELLM_SALT_KEY=請替換成長且隨機的值
POSTGRES_PASSWORD=請使用只含英數字的本機密碼
DATABASE_URL=postgresql://llmproxy:請使用只含英數字的本機密碼@db:5432/litellm
OPENAI_API_KEY=替換成你的_provider_key
~~~

`POSTGRES_PASSWORD` 與 `DATABASE_URL` 的密碼部分必須完全相同。初學者先使用英數字密碼，避免 URL 中的特殊字元未編碼造成連線失敗。`.env` 必須加入 `.gitignore`，不要提交 provider key、master key 或資料庫密碼。

`LITELLM_SALT_KEY` 用於加密與解密模型憑證；新增模型後不要任意更換。[LiteLLM Docker Quick Start](https://docs.litellm.ai/docs/proxy/docker_quick_start)

### 5.0.1 含 database_url 的 config.yaml

~~~yaml
model_list:
  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
~~~

如果使用 Azure OpenAI，替換 model block，並保留 `general_settings.database_url`。為避免部分 LiteLLM image 對 Azure 設定的環境變數替換造成 deployment 被判定為 unhealthy，`api_base` 與 `api_version` 先使用設定檔固定值；API key 仍只從環境變數讀取：

~~~yaml
model_list:
  - model_name: azure-chat
    litellm_params:
      model: azure/<your-azure-deployment>
      api_base: https://<your-resource>.openai.azure.com
      api_key: os.environ/AZURE_API_KEY
      api_version: 2025-04-01-preview

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
~~~

Azure 的 `.env` 至少要提供：

~~~dotenv
AZURE_API_KEY=替換成你的_Azure_OpenAI_key
~~~

Compose 網路內的 Postgres hostname 是 `db`，不能寫 `localhost`。LiteLLM 文件指出，`database_url` 用於 virtual keys、spend tracking、users、teams 與 UI。[LiteLLM Docker Quick Start](https://docs.litellm.ai/docs/proxy/docker_quick_start)、[LiteLLM Deploy](https://docs.litellm.ai/docs/proxy/deploy)

### 5.0.2 檢查並啟動

~~~sh
test -f docker-compose.yml
test -f config.yaml
test -f .env
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 db
docker compose logs --tail=100 litellm
~~~

`depends_on.condition: service_healthy` 會讓 LiteLLM 等待 `pg_isready` 成功後才啟動。確認資料庫路徑：

第一次啟動會執行 LiteLLM 的資料庫 migration；在 migration 完成前，`litellm` 可能仍顯示 starting，請以 readiness 回應與 `docker compose ps` 為準，不要只看到第一段啟動日誌就判定失敗。

~~~sh
for attempt in $(seq 1 30); do
  if curl --silent --show-error --fail http://127.0.0.1:4000/health/liveliness >/dev/null; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    docker compose ps
    docker compose logs --tail=100 litellm
    exit 1
  fi
  sleep 2
done
curl --fail http://127.0.0.1:4000/health/readiness
~~~

**含資料庫的 readiness 預期應顯示 `db: connected`；若仍是 `Not connected`，先查看 `docker compose logs db` 與 `docker compose logs litellm`。**

### 5.0.3 驗證 UI 與 virtual key

模型 completion 成功後，開啟 `http://127.0.0.1:4000/ui`，使用 `LITELLM_MASTER_KEY` 登入。LiteLLM 官方教學將 virtual keys、RPM limit 與 UI 放在含 Postgres 的 Compose 路徑。[LiteLLM Docker Quick Start](https://docs.litellm.ai/docs/proxy/docker_quick_start)

### 5.0.4 停止與資料重設

停止服務並保留 Postgres 資料：

~~~sh
docker compose down
~~~

只有在明確要刪除本機資料時，才執行完整重設：

~~~sh
docker compose down -v
~~~

`down` 預設保留 `postgres_data`；`down -v` 會刪除 Postgres 的 users、keys、teams、spend 與 UI 資料。**不要把 `down -v` 當成一般重啟命令。**

### 5.1 可選：官方完整範本（含 Prometheus）

以下是官方完整範本的下載方式，會另外啟動 Prometheus。它與前面的最小 Compose 是兩條替代路徑，**不要把兩份 Compose、兩個 `db` service 或兩個資料庫設定混在同一個工作目錄**。

在新的工作目錄執行：

~~~sh
mkdir litellm-compose
cd litellm-compose
curl -fLO https://raw.githubusercontent.com/BerriAI/litellm/main/docker-compose.yml
curl -fLO https://raw.githubusercontent.com/BerriAI/litellm/main/prometheus.yml
~~~

Windows PowerShell 請使用 curl.exe -fLO，避免把 curl 解譯成 PowerShell 的 Invoke-WebRequest 別名。官方 main 是可變分支；正式或可重現的環境應先在 GitHub 介面檢查檔案內容，再固定到已審查的 commit，而不是無條件執行未審查的遠端檔案。

### 5.2 檢查 Compose 的 config 掛載

開啟下載的 docker-compose.yml，在 litellm service 確認類似以下設定已啟用：

~~~yaml
services:
  litellm:
    volumes:
      - ./config.yaml:/app/config.yaml
    command:
      - "--config=/app/config.yaml"
~~~

官方快速入門特別提醒，若 config.yaml 或 prometheus.yml 在 docker compose up 前不存在，Docker 可能把它們當成目錄建立，導致容器啟動失敗。[LiteLLM Compose 快速入門](https://docs.litellm.ai/docs/proxy/docker_quick_start)

### 5.3 建立 Compose .env

~~~dotenv
LITELLM_MASTER_KEY=sk-local-請改成隨機值
LITELLM_SALT_KEY=請使用長且隨機的值
OPENAI_API_KEY=替換成你的_provider_key
~~~

LITELLM_SALT_KEY 用於加密與解密模型憑證；LiteLLM 官方說明指出，新增模型後不要更換它，否則舊的加密資料可能無法解密。[LiteLLM Docker quick start](https://docs.litellm.ai/docs/proxy/docker_quick_start)

若要在主機執行本手冊第 4 節的 curl smoke test，請在目前 shell 設定與 .env 相同的 `LITELLM_MASTER_KEY`；Compose 的 env_file 不會回寫主機 shell。

官方 Compose 檔案目前以 db:5432 作為 Postgres service hostname，並以 named volume 保存 /var/lib/postgresql/data。因此容器內的資料庫 URL 必須使用 db，不能寫 localhost：

~~~yaml
model_list:
  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  database_url: "postgresql://llmproxy:dbpassword9090@db:5432/litellm"
~~~

上面的 `dbpassword9090` 是官方 Compose 教學用的本機範例值，不是安全的正式密碼。若要在共享環境使用，請在 docker-compose.yml 的 Postgres service 與 database_url 同時換成隨機值，並改用 secrets；不要把這個預設密碼帶到正式環境。

LiteLLM 文件指出，database_url 用於 virtual keys、spend tracking 與 UI；可在設定檔提供，也可由 DATABASE_URL 環境變數提供。[LiteLLM Proxy 與資料庫](https://docs.litellm.ai/docs/proxy/deploy)

### 5.4 檢查並啟動 Compose

先讓 Compose 展開設定，檢查環境變數、volume 與 command：

~~~sh
docker compose config
~~~

Docker 官方的 docker compose config 會解析並顯示合併後的設定；若 output 中直接出現完整 provider key，請停止並改用 secrets 或清除終端機紀錄。[Docker Compose config](https://docs.docker.com/reference/cli/docker/compose/config/)

啟動服務：

~~~sh
docker compose up -d
docker compose ps
docker compose logs -f litellm
~~~

docker compose up -d 會在背景啟動容器；若設定或映像改變，Compose 會停止並重新建立容器，但保留掛載的 volumes。[Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)

等待 litellm 與 db 容器健康後，重新執行本手冊第 4 節的 liveness、readiness 與 curl smoke test。管理介面通常位於 http://127.0.0.1:4000/ui；官方 Compose 教學以 master key 登入 UI，再建立 virtual key。[LiteLLM Compose 快速入門](https://docs.litellm.ai/docs/proxy/docker_quick_start)

* * *

## 6. Postgres 與 Redis 的界線

### 6.1 什麼時候需要 Postgres

LiteLLM 官方把 Postgres 用於產生與保存 virtual keys、users、teams、spend tracking 及 UI 資料。單一 litellm 映像可以呼叫 provider，但若沒有 DATABASE_URL，不應期待這些資料庫功能正常運作。需要 Postgres 時，可使用官方 litellm-database 映像；該映像包含 Proxy 使用 Postgres 所需的 Prisma 相依項。[LiteLLM Deploy with Database](https://docs.litellm.ai/docs/proxy/deploy)

### 6.2 Compose named volume 的持久化

官方 Compose 範本以 postgres_data named volume 掛載 Postgres data directory。Docker 官方說明 named volume 由 Docker 管理，容器刪除後仍保留，直到明確移除；這比依賴主機特定路徑的 bind mount 更適合跨 macOS、Windows 與 Linux 使用。[Docker Volumes](https://docs.docker.com/engine/storage/volumes/)

因此：

- docker compose down 會移除容器與網路，**預設保留 named volumes**。
- docker compose down -v 會移除 Compose 宣告的 named volumes，會刪除本機 Postgres 資料；只應在確定要重置資料時執行。
- config.yaml、.env 與 prometheus.yml 是主機檔案，不會因 down 被刪除。

Docker 官方對 docker compose down 的說明明確區分預設行為與 -v, --volumes 選項。[Docker Compose down](https://docs.docker.com/reference/cli/docker/compose/down/)

### 6.3 什麼時候需要 Redis

LiteLLM 官方部署文件把 Redis 用於多個 LiteLLM 容器之間共用 RPM/TPM 與路由狀態；設定放在 router_settings.redis_host、redis_password 與 redis_port。單一本機容器的入門流程不需要 Redis。[LiteLLM Deploy with Redis](https://docs.litellm.ai/docs/proxy/deploy)

Redis 不是 Postgres 的替代品：

- 只要 virtual keys、users、teams 或 spend tracking，仍需 Postgres。
- 需要跨執行個體共用限流或路由狀態，再加入 Redis。
- LiteLLM 文件對預期超過 1000 RPS 的部署指出需要 Redis 以避免資料庫連線耗盡；這是高流量部署界線，不是本機教學的最低需求。

* * *

## 7. 常見錯誤與排查順序

### Cannot connect to the Docker daemon

Docker Desktop 尚未啟動，或 Linux 的 Docker service 尚未啟動。先執行 docker version；若 Client 有資料而 Server 沒有資料，回到 Docker Desktop 或 Linux service 的安裝文件。

### pull access denied 或映像拉取逾時

先執行：

~~~sh
docker pull docker.litellm.ai/berriai/litellm:latest
~~~

檢查網路、公司 proxy、DNS 與 registry allowlist。LiteLLM 官方部署文件列出 ghcr.io/berriai 與 docker.litellm.ai/berriai 兩個官方來源；不要改用沒有來源可追溯的第三方映像。[LiteLLM Docker images](https://docs.litellm.ai/docs/proxy/deploy)

### config.yaml 被當成目錄

主機檔案不存在，或 Windows bind mount 路徑格式錯誤。執行 ls -l config.yaml 或 PowerShell 的 Get-Item .\\config.yaml，確認 --mount 的 src 指向檔案。Docker --mount 對不存在的來源會直接失敗，這通常比 -v 自動建立目錄更容易排錯。[Docker Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)

### 401 Unauthorized

請求的 Authorization header 沒有使用與 LITELLM_MASTER_KEY 相同的值，或 .env 沒有被傳入容器。檢查容器環境變數名稱與 shell 變數，不要把 key 貼到公開 log：

~~~sh
docker inspect litellm-proxy --format '{{range .Config.Env}}{{println .}}{{end}}' | sed 's/=.*/=<已隱藏>/'
~~~

Compose 中可用 docker compose config 檢查變數是否展開，但不要把完整 output 上傳。

### 404 model not found 或 provider authentication error

這表示 Proxy 已啟動，但 model 別名未對應到 config.yaml，或 provider key、API base、模型 ID 不正確。確認請求的 model 等於 model_list[].model_name，再對照 [LiteLLM provider 文件](https://docs.litellm.ai/docs/providers)。模型可用性與 provider 權限是外部服務條件，無法由 Docker 本身修正。

### Readiness 顯示資料庫未連線

單一容器流程預期會看到 db: Not connected；如果你選的是 Compose，確認 config 使用 db:5432 而不是 localhost，並查看：

~~~sh
docker compose ps
docker compose logs db
docker compose logs litellm
~~~

### Compose 一直重啟或 Prometheus 失敗

確認 config.yaml、.env、prometheus.yml 都是檔案，且官方 Compose 內的 config volume、--config 參數已解除註解。Prometheus 設定檔缺少時，Docker 可能建立同名目錄，造成掛載型別錯誤。[LiteLLM Compose troubleshooting](https://docs.litellm.ai/docs/proxy/docker_quick_start)

### macOS、Windows bind mount 權限或速度問題

Docker Desktop 的 Engine 在 Linux VM 中執行，Desktop 會轉換主機路徑；請把專案放在 Docker Desktop 已允許分享的位置，並避免掛載整個家目錄。Docker 官方也提醒 bind mount 預設可寫入主機；本手冊對 config.yaml 使用唯讀掛載以降低風險。[Docker Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)

* * *

## 8. 停止、清理與重設

### 單一容器

停止但保留容器：

~~~sh
docker stop litellm-proxy
~~~

再次啟動：

~~~sh
docker start litellm-proxy
~~~

刪除容器：

~~~sh
docker rm litellm-proxy
~~~

刪除容器不會刪除主機上的 config.yaml 與 .env；映像也仍留在本機。Docker 提供 docker container stop 與 docker container rm 供這些生命週期操作使用。[Docker container stop](https://docs.docker.com/reference/cli/docker/container/stop/)、[Docker container rm](https://docs.docker.com/reference/cli/docker/container/rm/)

若要移除單一容器映像：

~~~sh
docker image rm docker.litellm.ai/berriai/litellm:latest
~~~

### Compose

停止並移除容器與網路，但保留資料庫 volume：

~~~sh
docker compose down
~~~

完全重設本機 Compose 資料，包含 Postgres 與 Prometheus volumes：

~~~sh
docker compose down -v
~~~

**docker compose down -v 不可用來「試試看」；它會刪除本機持久化資料。**

不確定要刪什麼時，先盤點：

~~~sh
docker ps -a
docker image ls
docker volume ls
docker system df
~~~

避免一開始使用 docker system prune --volumes，因為它可能刪除同一 Docker Engine 上其他專案的未使用 volume。

* * *

## 9. 升級與可重現部署

### 9.1 本機快速升級

開發環境可拉取最新映像後重建容器：

~~~sh
docker pull docker.litellm.ai/berriai/litellm:latest
docker rm -f litellm-proxy
# 重新執行第 3.4 節的 docker run
~~~

這種方式方便，但 latest 是滾動標籤，不保證每次取得相同內容。LiteLLM 官方 Docker image security 文件建議使用固定的 vX.Y.Z release tag 或 digest；文件也指出 main-stable 與 main-latest 已棄用。[LiteLLM Docker Image Security](https://docs.litellm.ai/docs/proxy/docker_image_security)

### 9.2 固定版本或 digest

把命令中的映像替換為已驗證的版本，例如：

~~~sh
docker pull docker.litellm.ai/berriai/litellm:vX.Y.Z
docker run ... docker.litellm.ai/berriai/litellm:vX.Y.Z --config /app/config.yaml
~~~

實際版本請從 LiteLLM release 與映像清單選擇，不要照抄不存在的 vX.Y.Z。更嚴格的部署可先取得 digest，再使用 image@sha256:...。LiteLLM 官方也提供 cosign 簽章驗證：

~~~sh
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  ghcr.io/berriai/litellm:<release-tag>
~~~

把 <release-tag> 替換成已審查的實際版本；不要在未安裝或未驗證 cosign 時把這段當成通過證明。官方安全文件建議升級順序為驗證新映像、先在測試環境執行、更新固定參照、再部署並監看 /health。[LiteLLM Docker Image Security](https://docs.litellm.ai/docs/proxy/docker_image_security)

### 9.3 Compose 升級

在 Compose 工作目錄執行：

~~~sh
docker compose pull
docker compose up -d
docker compose ps
~~~

docker compose pull 只拉取服務映像；up -d 會依新映像重新建立必要的容器並保留 volumes。[Docker Compose pull](https://docs.docker.com/reference/cli/docker/compose/pull)、[Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)

升級前至少備份 config.yaml、.env、prometheus.yml 與 Postgres 資料，並在測試環境先跑 liveness、readiness 與實際 smoke test。**不要用 docker compose down -v 來升級，否則會先刪除資料庫。**

* * *

## 10. 跨平台注意事項

| 項目 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Docker 執行方式 | Docker Desktop，Engine 在 Linux VM | Docker Desktop，通常使用 WSL 2 Linux containers | Docker Desktop 或原生 Docker Engine |
| 啟動命令 | Bash/zsh 的 $PWD 語法 | PowerShell 使用反引號換行與 Get-Location 路徑 | Bash 的 $PWD 語法 |
| Bind mount | 確認 Docker Desktop 可存取專案目錄 | 確認 WSL 2、檔案分享與 Windows 路徑 | 注意檔案擁有者與 SELinux 標籤 |
| Port | 127.0.0.1:4000:4000 | 同樣可用 loopback 綁定 | 同樣可用 loopback 綁定；防火牆另行檢查 |
| 資料庫 volume | Docker Desktop 管理 named volume | Docker Desktop/WSL 2 管理 named volume | Docker Engine 管理 named volume |

Docker 官方指出 bind mount 是在 Docker daemon 主機上建立；Docker Desktop 會透過 Linux VM 透明處理原生主機路徑，而 named volumes 由 Docker 管理、較不依賴主機目錄結構。[Docker Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)、[Docker Volumes](https://docs.docker.com/engine/storage/volumes/)

為降低差異，教材命令固定使用：

1. 容器內設定路徑 /app/config.yaml。
2. 主機對外的 loopback 位址 127.0.0.1。
3. Compose named volume，而不是自行猜測 /var/lib/... 主機路徑。
4. docker compose 子命令，而不是已淘汰的獨立 docker-compose 命令。

* * *

## 11. 安全清單

開始前與完成後逐項確認：

- **只在本機測試時使用 127.0.0.1:4000:4000；不要把 master key 服務直接暴露到公網。**
- .env 已加入 .gitignore，並限制檔案權限；正式環境改用 Docker secrets 或專用 secrets manager。[Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- provider key 與 LITELLM_MASTER_KEY 分開，且使用不同的測試與正式值。
- config.yaml 以唯讀 bind mount 掛載；不要掛載整個家目錄或系統目錄。Docker 官方提醒 bind mount 預設可寫入主機。[Docker Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)
- 不在 shell trace、CI log、Issue 或螢幕截圖中輸出 key；避免 set -x。
- 不把 /health 設為高頻探針，因為它會實際呼叫模型並可能產生費用。
- 不使用未審查的第三方 LiteLLM 映像；需要可追溯性時固定 release tag 或 digest，並依官方文件驗證 cosign 簽章。[LiteLLM Docker Image Security](https://docs.litellm.ai/docs/proxy/docker_image_security)
- docker compose down -v 前先確認資料是否已備份；它會移除 Postgres 與 Prometheus named volumes。
- 這份手冊的 Compose 範本來自可變的官方 main 分支；部署前固定已審查 commit，並在升級前重看官方文件。

* * *

## 12. 完成判定

完成本機入門的最低驗收條件：

~~~sh
docker ps --filter name=litellm-proxy
curl --fail http://127.0.0.1:4000/health/liveliness
curl --fail http://127.0.0.1:4000/health/readiness
~~~

再以第 4.4 節的 curl 或第 4.5 節的 Python 程式取得一次模型回應。若使用 Compose，另外確認：

~~~sh
docker compose ps
docker volume ls | grep -E 'litellm|postgres'
~~~

判定結果：

- liveness 成功：Proxy 程序存活。
- readiness 成功：Proxy 可接受請求；若是無 DB 流程，db: Not connected 屬預期限制。
- Chat Completions 成功：model alias、provider key、網路及上游模型均可用。
- Compose volume 存在：Postgres 資料不會因一般 docker compose down 立即消失。

**到此只代表本機開發環境可運作，不代表已具備正式環境的高可用、備份、監控、秘密管理或供應商故障切換能力。**

* * *

## 官方來源索引

- [LiteLLM Getting Started](https://docs.litellm.ai/)
- [LiteLLM Docker quick start](https://docs.litellm.ai/docs/proxy/docker_quick_start)
- [LiteLLM Docker、Helm、Terraform 部署](https://docs.litellm.ai/docs/proxy/deploy)
- [LiteLLM config.yaml 概覽](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM Health Checks](https://docs.litellm.ai/docs/proxy/health)
- [LiteLLM Docker Image Security](https://docs.litellm.ai/docs/proxy/docker_image_security)
- [LiteLLM 官方 docker-compose.yml](https://github.com/BerriAI/litellm/blob/main/docker-compose.yml)
- [Docker Desktop](https://docs.docker.com/desktop/)
- [Docker Engine 安裝](https://docs.docker.com/engine/install/)
- [Docker compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
- [Docker compose down](https://docs.docker.com/reference/cli/docker/compose/down/)
- [Docker volumes](https://docs.docker.com/engine/storage/volumes/)
- [Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)
- [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
- [Docker Compose 環境變數](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/)
- [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
