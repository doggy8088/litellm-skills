from __future__ import annotations

import csv
import json
import os
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse


APP_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = APP_DIR.parents[2] / ".env"
DEFAULT_KEY_LIST_PATH = APP_DIR.parent / "Key_List.csv"
DEFAULT_BASE_URL = "http://localhost:4000"


HTML_PAGE = """<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Virtual Key 使用量查詢</title>
  <style>
    :root { font-family: Inter, Arial, sans-serif; color-scheme: light dark; }
    body { margin: 0; background: #0b1020; color: #e8eefc; }
    .wrap { max-width: 760px; margin: 40px auto; padding: 20px; }
    .card { background: #121a31; border: 1px solid #26345f; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
    h1 { margin-top: 0; font-size: 24px; }
    label { display: block; margin-bottom: 8px; font-weight: 600; }
    select, button { width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid #3b4f84; background: #0f1730; color: #e8eefc; }
    button { margin-top: 12px; cursor: pointer; background: #1f4bd8; border: none; font-weight: 600; }
    button:disabled { opacity: 0.6; cursor: not-allowed; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .metric { background: #0d1430; border: 1px solid #2a3b70; border-radius: 10px; padding: 10px; }
    .k { font-size: 12px; opacity: 0.8; }
    .v { font-size: 18px; font-weight: 700; margin-top: 4px; word-break: break-all; }
    .msg { margin-top: 10px; color: #ffcf66; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Virtual Key 使用量查詢</h1>
      <label for="alias">選擇 virtual key（key_alias）</label>
      <select id="alias"></select>
      <button id="queryBtn">查詢使用量</button>
      <div class="msg" id="msg"></div>
    </div>

    <div class="card" id="resultCard" style="display:none;">
      <div class="grid">
        <div class="metric"><div class="k">key_alias</div><div class="v" id="mAlias"></div></div>
        <div class="metric"><div class="k">status</div><div class="v" id="mStatus"></div></div>
        <div class="metric"><div class="k">Total Spend</div><div class="v" id="mSpend"></div></div>
        <div class="metric"><div class="k">Total Model Spend</div><div class="v" id="mModelSpend"></div></div>
        <div class="metric"><div class="k">Today Total Spend</div><div class="v" id="mTodaySpend"></div></div>
        <div class="metric"><div class="k">Today Total Tokens</div><div class="v" id="mTodayTokens"></div></div>
        <div class="metric"><div class="k">Model Count</div><div class="v" id="mModelCount"></div></div>
        <div class="metric"><div class="k">Updated At</div><div class="v" id="mUpdatedAt"></div></div>
      </div>
    </div>
  </div>

  <script>
    const aliasSel = document.getElementById('alias');
    const queryBtn = document.getElementById('queryBtn');
    const msg = document.getElementById('msg');
    const resultCard = document.getElementById('resultCard');

    function setMsg(text) {
      msg.textContent = text || '';
    }

    function fmtNum(n) {
      if (n === null || n === undefined) return '-';
      if (typeof n === 'number') return n.toLocaleString(undefined, { maximumFractionDigits: 8 });
      return String(n);
    }

    function bindResult(data) {
      document.getElementById('mAlias').textContent = data.key_alias ?? '-';
      document.getElementById('mStatus').textContent = data.status ?? '-';
      document.getElementById('mSpend').textContent = fmtNum(data.total_spend);
      document.getElementById('mModelSpend').textContent = fmtNum(data.total_model_spend);
      document.getElementById('mTodaySpend').textContent = fmtNum(data.today_total_spend);
      document.getElementById('mTodayTokens').textContent = fmtNum(data.today_total_tokens);
      document.getElementById('mModelCount').textContent = fmtNum(data.model_count);
      document.getElementById('mUpdatedAt').textContent = data.updated_at ?? '-';
      resultCard.style.display = 'block';
    }

    async function loadAliases() {
      setMsg('載入 key_alias 清單中...');
      try {
        const res = await fetch('/api/virtual-keys', { credentials: 'omit' });
        if (!res.ok) throw new Error('載入失敗');
        const data = await res.json();
        aliasSel.innerHTML = '';
        for (const alias of data.aliases || []) {
          const opt = document.createElement('option');
          opt.value = alias;
          opt.textContent = alias;
          aliasSel.appendChild(opt);
        }
        setMsg(data.aliases?.length ? '' : '沒有可查詢的 key_alias');
      } catch {
        setMsg('讀取清單失敗，請稍後再試。');
      }
    }

    queryBtn.addEventListener('click', async () => {
      const alias = aliasSel.value;
      if (!alias) {
        setMsg('請先選擇 key_alias');
        return;
      }
      queryBtn.disabled = true;
      setMsg('查詢中...');
      try {
        const res = await fetch(`/api/usage/${encodeURIComponent(alias)}`, { credentials: 'omit' });
        const data = await res.json();
        if (!res.ok) throw new Error(data?.detail || '查詢失敗');
        bindResult(data);
        setMsg('');
      } catch {
        setMsg('查詢失敗，請稍後再試。');
      } finally {
        queryBtn.disabled = false;
      }
    });

    loadAliases();
  </script>
</body>
</html>
"""


@dataclass
class Config:
    base_url: str
    key_list_path: Path
    auth_header_value: str


def load_dotenv_file(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        os.environ.setdefault(k, v)


def resolve_auth_header_value() -> str:
    token = os.getenv("LITELLM_ADMIN_TOKEN") or os.getenv("LITELLM_MASTER_KEY")
    if not token:
        raise RuntimeError("缺少 LITELLM_ADMIN_TOKEN 或 LITELLM_MASTER_KEY 環境變數")
    return token if token.startswith("Bearer ") else f"Bearer {token}"


def load_config() -> Config:
    env_file = Path(os.getenv("LITELLM_ENV_FILE", str(DEFAULT_ENV_FILE))).expanduser()
    load_dotenv_file(env_file)

    base_url = os.getenv("LITELLM_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
    key_list_path = Path(os.getenv("KEY_LIST_PATH", str(DEFAULT_KEY_LIST_PATH))).expanduser().resolve()
    auth_header_value = resolve_auth_header_value()

    if not key_list_path.exists():
        raise RuntimeError(f"Key_List.csv 不存在: {key_list_path}")

    return Config(base_url=base_url, key_list_path=key_list_path, auth_header_value=auth_header_value)


CONFIG = load_config()
app = FastAPI(title="Virtual Key Usage API", version="1.0.0")


_ALIAS_CACHE: dict[str, Any] = {"ts": 0.0, "map": {}}
_CACHE_TTL_SEC = 120


def api_get_json(path: str, query: dict[str, Any] | None = None) -> Any:
    url = f"{CONFIG.base_url}{path}"
    if query:
        url = f"{url}?{urlencode(query)}"

    req = Request(
        url,
        headers={
            "Authorization": CONFIG.auth_header_value,
            "Content-Type": "application/json",
        },
        method="GET",
    )
    try:
        with urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else None
    except (HTTPError, URLError, TimeoutError):
        return None


def to_decimal(value: Any) -> float:
    try:
        return float(value)
    except Exception:
        return 0.0


def read_aliases_from_csv() -> list[str]:
    aliases: list[str] = []
    with CONFIG.key_list_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            alias = (row.get("key_alias") or "").strip()
            if alias:
                aliases.append(alias)
    return sorted(set(aliases))


def get_all_key_hashes() -> list[str]:
    hashes: list[str] = []
    page = 1
    while True:
        data = api_get_json("/key/list", {"page": page}) or {}
        page_hashes = data.get("keys") or []
        hashes.extend(page_hashes)

        total_pages = int(data.get("total_pages") or 1)
        if page >= total_pages:
            break
        page += 1
    return hashes


def refresh_alias_cache() -> dict[str, dict[str, Any]]:
    now = time.time()
    if now - float(_ALIAS_CACHE.get("ts", 0.0)) < _CACHE_TTL_SEC:
        return _ALIAS_CACHE["map"]

    alias_map: dict[str, dict[str, Any]] = {}
    hashes = get_all_key_hashes()
    for h in hashes:
        info_resp = api_get_json("/key/info", {"key": h})
        info = (info_resp or {}).get("info") or (info_resp or {})
        alias = (info.get("key_alias") or "").strip()
        if alias:
            alias_map[alias] = {"hash": h, "info": info}

    _ALIAS_CACHE["ts"] = now
    _ALIAS_CACHE["map"] = alias_map
    return alias_map


def resolve_logs_array(resp: Any) -> list[dict[str, Any]]:
    if isinstance(resp, list):
        return resp
    if isinstance(resp, dict):
        for key in ("spend_logs", "logs", "data", "items"):
            if isinstance(resp.get(key), list):
                return resp[key]
    return []


def get_today_totals(alias: str, key_hash: str) -> tuple[float, int]:
    today = datetime.now().strftime("%Y-%m-%d")
    candidates = [
        ("/spend/logs", {"api_key": key_hash, "start_date": today, "end_date": today}),
        ("/global/spend/logs", {"api_key": key_hash, "start_date": today, "end_date": today}),
        ("/spend/logs", {"start_date": today, "end_date": today}),
        ("/global/spend/logs", {"start_date": today, "end_date": today}),
    ]

    logs: list[dict[str, Any]] = []
    for path, query in candidates:
        arr = resolve_logs_array(api_get_json(path, query))
        if arr:
            logs = arr
            break

    total_spend = 0.0
    total_tokens = 0

    today_date = datetime.now().date()
    for log in logs:
        api_key = log.get("api_key") or log.get("user_api_key")
        metadata = log.get("metadata") if isinstance(log.get("metadata"), dict) else {}
        alias_from_meta = metadata.get("user_api_key_alias")

        ts_raw = log.get("startTime") or log.get("start_time") or log.get("created_at") or log.get("timestamp")
        is_today = True
        if ts_raw:
            try:
                is_today = datetime.fromisoformat(str(ts_raw).replace("Z", "+00:00")).date() == today_date
            except Exception:
                is_today = True

        if not is_today:
            continue
        if api_key != key_hash and alias_from_meta != alias:
            continue

        total_spend += to_decimal(log.get("spend") or log.get("cost"))

        tokens = log.get("total_tokens") or log.get("totalTokens")
        if tokens is None and isinstance(log.get("usage"), dict):
            usage = log["usage"]
            tokens = usage.get("total_tokens") or usage.get("totalTokens")

        try:
            total_tokens += int(tokens)
        except Exception:
            pass

    return total_spend, total_tokens


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return HTML_PAGE


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/virtual-keys")
def list_virtual_keys() -> dict[str, list[str]]:
    aliases = read_aliases_from_csv()
    return {"aliases": aliases}


@app.get("/api/usage/{alias}")
def get_usage(alias: str) -> dict[str, Any]:
    alias = alias.strip()
    if not alias:
        raise HTTPException(status_code=400, detail="alias 不可為空")

    try:
        alias_map = refresh_alias_cache()
        if alias not in alias_map:
            raise HTTPException(status_code=404, detail="找不到該 key_alias")

        row = alias_map[alias]
        info = row["info"]
        key_hash = row["hash"]

        model_spend = info.get("model_spend") if isinstance(info.get("model_spend"), dict) else {}
        total_model_spend = sum(to_decimal(v) for v in model_spend.values())

        today_spend, today_tokens = get_today_totals(alias=alias, key_hash=key_hash)

        return {
            "key_alias": alias,
            "status": "ok",
            "total_spend": to_decimal(info.get("spend")),
            "total_model_spend": total_model_spend,
            "model_count": len(info.get("models") or []),
            "updated_at": info.get("updated_at"),
            "today_total_spend": today_spend,
            "today_total_tokens": today_tokens,
        }
    except HTTPException:
        raise
    except Exception:
        # 避免對外曝露內部細節與金鑰相關資訊
        raise HTTPException(status_code=500, detail="查詢失敗，請稍後再試")
