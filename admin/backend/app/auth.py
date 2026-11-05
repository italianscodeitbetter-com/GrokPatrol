"""Access from outside the laptop (the public tunnel): a PIN, remembered by the browser in a cookie.

Requests that come straight to the laptop (localhost, the simulator, the console on the Mac) need nothing.
Requests through the tunnel carry X-Forwarded-For and a public host name: they need the PIN once.
"""
import hashlib
import hmac
import time
from urllib.parse import quote

from fastapi.responses import HTMLResponse, RedirectResponse

from .config import env

PIN = env("RONDA_PIN", "")
COOKIE = "ronda_auth"
_token = hashlib.sha256(("ronda:" + PIN).encode()).hexdigest() if PIN else ""
_fails = {}   # ip -> [timestamps]

LOCAL_HOSTS = ("localhost", "127.0.0.1", "[::1]")


def is_remote(headers, host):
    h = (host or "").split(":")[0]
    return bool(headers.get("x-forwarded-for")) or (h not in LOCAL_HOSTS and not h.startswith(("192.168.", "10.", "172.", "100.")))


def authorized(headers, cookies, query):
    if not PIN:
        return True
    if hmac.compare_digest(cookies.get(COOKIE, ""), _token):
        return True
    return hmac.compare_digest(query.get("pin", ""), PIN)


def blocked(ip):
    now = time.time()
    _fails[ip] = [t for t in _fails.get(ip, []) if now - t < 600]
    return len(_fails[ip]) >= 10


def failed(ip):
    _fails.setdefault(ip, []).append(time.time())


def set_cookie(resp, secure):
    resp.set_cookie(COOKIE, _token, max_age=30 * 86400, httponly=True, samesite="lax", secure=secure)
    return resp


def login_page(next_url="/", error=""):
    return HTMLResponse(f"""<!doctype html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Ronda · accesso</title>
<style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0c0e;color:#e8e9eb;
font:16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:16px}}form{{width:min(340px,100%);display:grid;gap:12px}}
h1{{font-size:22px;margin:0}}p{{margin:0;color:#8b9099}}input,button{{font:inherit;padding:12px;border-radius:10px;border:1px solid #2e3138;
background:#181a1f;color:inherit}}button{{background:#4f8cff;border-color:#4f8cff;color:#fff;font-weight:600}}.e{{color:#ff8a80}}</style></head>
<body><form method="post" action="/login"><h1>Ronda</h1><p>Inserisci il PIN mostrato nella console sul Mac.</p>
<input name="pin" inputmode="numeric" autocomplete="one-time-code" placeholder="PIN" autofocus>
<input type="hidden" name="next" value="{quote(next_url, safe='/?=&')}">
<button type="submit">Entra</button><p class="e">{error}</p></form></body></html>""")


def redirect_after_login(next_url, secure):
    target = next_url if next_url.startswith("/") else "/"
    return set_cookie(RedirectResponse(target, status_code=303), secure)
