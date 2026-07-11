# LiteLLM + PostgreSQL Compose 範例

此範例用於需要 users、teams、virtual keys、spend tracking 或 UI 的本機測試。它包含 LiteLLM、PostgreSQL、healthcheck、服務自動恢復與 named volume。

```sh
cp .env.example .env
docker compose config
docker compose up -d
docker compose ps
for attempt in $(seq 1 30); do
  curl --silent --show-error --fail http://127.0.0.1:4000/health/liveliness >/dev/null && break
  if [ "$attempt" -eq 30 ]; then
    docker compose ps
    docker compose logs --tail=100 litellm
    exit 1
  fi
  sleep 2
done
curl --fail http://127.0.0.1:4000/health/readiness
```

請先替換 `.env` 中的所有 placeholder。`POSTGRES_PASSWORD` 必須與 `DATABASE_URL` 中的密碼相同；實際環境請改用 secrets。停止但保留資料：

```sh
docker compose down
```

重設資料庫才使用：

```sh
docker compose down -v
```
