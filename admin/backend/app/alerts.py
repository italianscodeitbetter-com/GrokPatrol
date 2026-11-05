"""Alert channels: console (always), Telegram photo, Twilio SMS, Twilio voice call. Test numbers only."""
import time
from xml.sax.saxutils import escape

import httpx

from .config import env


class Alerts:
    def __init__(self):
        self.http = httpx.AsyncClient(timeout=15)
        self.bot = None  # TelegramBot, set by main
        self.last_call = 0.0
        self.call_gap = float(env("ALERT_CALL_MIN_GAP_S", 60))

    @property
    def twilio(self):
        return all(env(k) for k in ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM", "ALERT_TO"))

    @property
    def telegram(self):
        return bool(self.bot and self.bot.enabled)

    def channels(self):
        out = ["console"]
        if self.telegram:
            out.append("telegram")
        if self.twilio:
            if env("ALERT_SMS", "1") != "0":
                out.append("sms")
            if env("ALERT_CALL", "1") != "0":
                out.append("call")
        return out

    async def send(self, alert: dict, image: bytes | None, severity: int = 3, ctx: dict | None = None):
        results = [{"channel": "console", "ok": True}]
        ch = self.channels()
        if "telegram" in ch and ctx:
            try:
                results.append(await self.bot.send_alert(ctx, image))
            except Exception as e:
                results.append({"channel": "telegram", "ok": False, "error": str(e)[:200]})
        if "sms" in ch:
            results.append(await self._twilio_sms(alert))
        if "call" in ch and severity >= int(env("ALERT_CALL_MIN_SEVERITY", 3)):
            if time.time() - self.last_call >= self.call_gap:
                self.last_call = time.time()
                results.append(await self._twilio_call(alert))
            else:
                results.append({"channel": "call", "ok": False, "skipped": "rate limit"})
        return results

    def _auth(self):
        return (env("TWILIO_ACCOUNT_SID"), env("TWILIO_AUTH_TOKEN"))

    async def _twilio_sms(self, alert):
        sid = env("TWILIO_ACCOUNT_SID")
        try:
            r = await self.http.post(f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json", auth=self._auth(),
                                     data={"To": env("ALERT_TO"), "From": env("TWILIO_FROM"),
                                           "Body": f"{alert.get('title', '')}: {alert.get('sms', '')}"[:600]})
            return {"channel": "sms", "ok": r.status_code < 300, "status": r.status_code,
                    "error": None if r.status_code < 300 else r.text[:200]}
        except Exception as e:
            return {"channel": "sms", "ok": False, "error": str(e)[:200]}

    async def _twilio_call(self, alert):
        sid = env("TWILIO_ACCOUNT_SID")
        voice = env("TWILIO_VOICE", "Polly.Bianca")
        lang = env("TWILIO_LANG", "it-IT")
        say = escape(alert.get("voice") or alert.get("sms", ""))
        twiml = (f'<Response><Say language="{lang}" voice="{voice}">{say}</Say><Pause length="1"/>'
                 f'<Say language="{lang}" voice="{voice}">{say}</Say></Response>')
        try:
            r = await self.http.post(f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Calls.json", auth=self._auth(),
                                     data={"To": env("ALERT_TO"), "From": env("TWILIO_FROM"), "Twiml": twiml})
            return {"channel": "call", "ok": r.status_code < 300, "status": r.status_code,
                    "error": None if r.status_code < 300 else r.text[:200]}
        except Exception as e:
            return {"channel": "call", "ok": False, "error": str(e)[:200]}
