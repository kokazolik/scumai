"""Посредник между игрой и GigaChat для Yandex Cloud Functions (Python 3.12).

Зачем: движок игры на телефоне не может проверить сертификаты Сбера, а здесь
обычный Python с сертификатом Минцифры (ru_ca.pem рядом) делает это правильно.

Переменные окружения функции:
  GIGACHAT_AUTH_KEY — ключ авторизации GigaChat (необязательно: если не задан,
                      игра должна прислать свой ключ в заголовке X-Gigachat-Key);
  GIGACHAT_SCOPE    — по умолчанию GIGACHAT_API_PERS;
  APP_TOKEN         — необязательный пароль: игра шлёт его в X-App-Token;
  MAX_TOKENS_CAP    — потолок max_tokens на один запрос (по умолчанию 1500).
"""
import base64
import json
import os
import ssl
import time
import urllib.error
import urllib.request
import uuid

OAUTH_URL = os.environ.get("GC_OAUTH_URL", "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
CHAT_URL = os.environ.get("GC_CHAT_URL", "https://gigachat.devices.sberbank.ru/api/v1/chat/completions")
ALLOWED_MODELS = {"GigaChat-2-Max", "GigaChat-2-Pro", "GigaChat-2", "GigaChat-Max", "GigaChat-Pro", "GigaChat"}

_ctx = ssl.create_default_context()
_ctx.load_verify_locations(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ru_ca.pem"))
_tokens = {}  # ключ -> (токен, истекает_в_секундах)


def _resp(code, obj):
    return {"statusCode": code, "headers": {"Content-Type": "application/json; charset=utf-8"},
            "body": json.dumps(obj, ensure_ascii=False)}


class ProxyError(Exception):
    pass


def _http(url, data, headers, timeout=25):
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=_ctx, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # сеть, сертификат, таймаут — отдаём игре понятную причину
        host = url.split("/")[2]
        reason = getattr(e, "reason", e)
        raise ProxyError("%s: %s: %s" % (host, type(reason).__name__, reason))


def _clean_key(k):
    """Убрать то, что часто прилипает при копировании: пробелы, переносы, кавычки, «Basic »."""
    k = (k or "").strip().strip("`'\"").strip()
    if k.lower().startswith("basic "):
        k = k[6:]
    return "".join(k.split())


def _key_shape(k):
    try:
        dec = base64.b64decode(k + "=" * (-len(k) % 4)).decode("utf-8")
        parts = dec.split(":")
        return "длина %d, расшифровка: %s" % (len(k), "client_id:secret ✔" if len(parts) == 2 and len(parts[0]) == 36 else "не похоже на ключ")
    except Exception:
        return "длина %d, не base64" % len(k)


def _token(key, scope, force=False):
    tok = _tokens.get(key)
    if tok and not force and time.time() < tok[1] - 60:
        return tok[0], None
    code, body = _http(OAUTH_URL, ("scope=" + scope).encode(), {
        "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
        "RqUID": str(uuid.uuid4()), "Authorization": "Basic " + key})
    try:
        data = json.loads(body)
    except ValueError:
        data = {}
    if code != 200 or not data.get("access_token"):
        return None, (code, data)
    exp = float(data.get("expires_at", 0))
    exp = exp / 1000.0 if exp > 1e11 else exp
    _tokens[key] = (data["access_token"], exp or time.time() + 1700)
    return data["access_token"], None


def handler(event, context):
    try:
        return _handle(event)
    except ProxyError as e:
        print("proxy error:", e)
        return _resp(502, {"message": str(e)})
    except Exception as e:
        print("crash:", repr(e))
        return _resp(500, {"message": "%s: %s" % (type(e).__name__, e)})


def _handle(event):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if event.get("httpMethod", "POST") == "GET":
        if "check" not in (event.get("queryStringParameters") or {}):
            return _resp(200, {"ok": True, "service": "chronicles-gigachat-proxy"})
        # ?check — проверить вход в Сбер ключом из настроек функции (ключ не показывается)
        key = _clean_key(os.environ.get("GIGACHAT_AUTH_KEY", ""))
        if not key:
            return _resp(200, {"ok": False, "step": "env", "message": "GIGACHAT_AUTH_KEY не задан"})
        t0 = time.time()
        try:
            tok, err = _token(key, os.environ.get("GIGACHAT_SCOPE", "GIGACHAT_API_PERS"), force=True)
        except ProxyError as e:
            return _resp(200, {"ok": False, "step": "oauth", "message": str(e), "sec": round(time.time() - t0, 1)})
        if err:
            return _resp(200, {"ok": False, "step": "oauth", "http": err[0], "message": err[1].get("message", ""),
                               "key": _key_shape(key), "sec": round(time.time() - t0, 1)})
        return _resp(200, {"ok": True, "step": "oauth", "sec": round(time.time() - t0, 1)})
    app_token = os.environ.get("APP_TOKEN", "")
    if app_token and headers.get("x-app-token", "") != app_token:
        return _resp(403, {"message": "wrong app token"})
    key = _clean_key(headers.get("x-gigachat-key", "")) or _clean_key(os.environ.get("GIGACHAT_AUTH_KEY", ""))
    if not key:
        return _resp(401, {"message": "no GigaChat key on the server"})
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        req = json.loads(raw)
    except ValueError:
        return _resp(400, {"message": "bad json"})
    if req.get("model") not in ALLOWED_MODELS or not isinstance(req.get("messages"), list):
        return _resp(400, {"message": "bad request"})
    cap = int(os.environ.get("MAX_TOKENS_CAP", "1500"))
    body = {"model": req["model"], "messages": req["messages"],
            "temperature": float(req.get("temperature", 0.9)),
            "max_tokens": max(1, min(int(req.get("max_tokens", 600)), cap))}
    scope = os.environ.get("GIGACHAT_SCOPE", "GIGACHAT_API_PERS")
    for attempt in range(2):
        tok, err = _token(key, scope, force=attempt > 0)
        if err:
            return _resp(401 if err[0] in (400, 401, 403) else 502,
                         {"message": "oauth %s: %s" % (err[0], err[1].get("message", ""))})
        code, out = _http(CHAT_URL, json.dumps(body, ensure_ascii=False).encode(), {
            "Content-Type": "application/json", "Accept": "application/json",
            "Authorization": "Bearer " + tok}, timeout=50)
        if code == 401 and attempt == 0:
            continue
        return {"statusCode": code, "headers": {"Content-Type": "application/json; charset=utf-8"},
                "body": out.decode("utf-8", "replace")}
    return _resp(502, {"message": "no answer"})
