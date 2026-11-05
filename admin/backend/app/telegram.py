"""Telegram bot: fixed-format alerts with the photo, buttons to act, a few commands. No AI in the messages.

Setup: create a bot with @BotFather, put TELEGRAM_BOT_TOKEN in secrets/.env, restart, send /start to the bot.
Optional TELEGRAM_PIN: then subscribing needs "/start <pin>".
"""
import asyncio
import json
import time

import httpx

from .config import DATA, env

CHATS = DATA / "telegram.json"
KIND_IT = {"person": "Persona ad allarme inserito", "motion": "Movimento ad allarme inserito",
           "intrusion": "Persona nell'area riservata", "abandoned_object": "Oggetto abbandonato",
           "patrol_finding": "Anomalia trovata in ronda", "manual": "Evento di prova"}
RISK_IT = {"none": "nessuno", "low": "basso", "medium": "medio", "high": "alto"}
HELP = ("Comandi:\n/inserisci  inserisce l'allarme\n/disinserisci  disinserisce l'allarme\n"
        "/stato  allarme e cane\n/foto  cosa vede il cane adesso\n"
        "/ronda  avvia la ronda\n/base  manda il cane alla base\n/ferma  ferma il cane\n/esci  non ricevere più allarmi")


def hm(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts))


class TelegramBot:
    def __init__(self, site, log):
        self.site, self.log = site, log
        self.token = env("TELEGRAM_BOT_TOKEN", "")
        self.pin = env("TELEGRAM_PIN", "")
        self.http = httpx.AsyncClient(timeout=45)
        self.offset = 0
        self.ok = None
        self.error = None
        self.username = None
        self.chats = {}
        if CHATS.exists():
            self.chats = json.loads(CHATS.read_text())
        for cid in (env("TELEGRAM_CHAT_ID", "") or "").split(","):
            if cid.strip():
                self.chats.setdefault(cid.strip(), {"name": "from .env"})
        self.command = None      # async (action, args) -> dict, set by main
        self.status_fn = None    # () -> dict
        self.photo_fn = None     # async () -> bytes | None

    @property
    def enabled(self):
        return bool(self.token)

    def status(self):
        return {"enabled": self.enabled, "ok": self.ok, "bot": self.username, "chats": len(self.chats), "error": self.error}

    def _save(self):
        CHATS.write_text(json.dumps(self.chats, indent=2, ensure_ascii=False))

    async def api(self, method, files=None, **data):
        url = f"https://api.telegram.org/bot{self.token}/{method}"
        for k, v in list(data.items()):
            if isinstance(v, (dict, list)):
                data[k] = json.dumps(v, ensure_ascii=False)
        r = await (self.http.post(url, data=data, files=files) if files else self.http.post(url, data=data))
        out = r.json()
        if not out.get("ok"):
            raise RuntimeError(f"telegram {method}: {out.get('description')}")
        return out["result"]

    # outgoing ---------------------------------------------------------------------------
    async def broadcast(self, text, photo=None, buttons=None):
        results = []
        for cid in list(self.chats):
            try:
                markup = {"inline_keyboard": buttons} if buttons else None
                if photo:
                    kw = {"chat_id": cid, "caption": text[:1024]}
                    if markup:
                        kw["reply_markup"] = markup
                    await self.api("sendPhoto", files={"photo": ("scena.jpg", photo, "image/jpeg")}, **kw)
                else:
                    kw = {"chat_id": cid, "text": text}
                    if markup:
                        kw["reply_markup"] = markup
                    await self.api("sendMessage", **kw)
                results.append({"chat": cid, "ok": True})
            except Exception as e:
                results.append({"chat": cid, "ok": False, "error": str(e)[:150]})
        return results

    def alert_text(self, ctx):
        evs = ctx.get("events") or []
        what = " + ".join(dict.fromkeys(KIND_IT.get(e["kind"], e["kind"]) for e in evs)) or "Controllo richiesto"
        cams = ", ".join(dict.fromkeys(e["camera"] for e in evs))
        v = ctx.get("verification") or {}
        outcome = {True: "confermato dal cane sul posto", False: "non confermato", None: "da verificare a vista"}[v.get("confirmed")]
        lines = [f"🚨 ALLARME · {what}",
                 f"Dove: {ctx['spot']}" + (f" ({cams})" if cams else ""),
                 f"Quando: {hm(ctx['ts'])}"]
        if ctx.get("arrival_s") is not None:
            lines.append(f"Cane sul posto dopo {ctx['arrival_s']:.1f} s")
        lines.append(f"Esito: {outcome} · rischio {RISK_IT.get(v.get('risk'), v.get('risk') or 'n.d.')}")
        if v.get("description"):
            lines.append(f"Il cane ha visto: {v['description']}")
        if v.get("action"):
            lines.append(f"Da fare: {v['action']}")
        return "\n".join(lines)

    async def open_link(self, kind, oid):
        """Web address that opens the mobile app on this mission/event (Telegram buttons only take http(s)).
        PUBLIC_URL if set, else the ngrok tunnel if it is up, else this Mac on the local network."""
        base = env("PUBLIC_URL")
        if not base:
            try:
                r = await self.http.get("http://127.0.0.1:4040/api/tunnels", timeout=1.5)
                base = next((t["public_url"] for t in r.json().get("tunnels", []) if t.get("public_url", "").startswith("https")), None)
            except Exception:
                base = None
        if not base:
            import socket
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sk:
                    sk.connect(("10.255.255.255", 1))   # sends nothing: picks the outgoing interface
                    base = f"http://{sk.getsockname()[0]}:{env('PORT', '8000')}"
            except OSError:
                return None
        return f"{base.rstrip('/')}/open/{kind}/{oid}"

    async def send_alert(self, ctx, image):
        eid = (ctx.get("events") or [{}])[0].get("id", "")
        buttons = [[{"text": "✅ Preso in carico", "callback_data": f"ack:{eid}"},
                    {"text": "🔁 Ricontrolla", "callback_data": f"recheck:{ctx.get('spot_id', '')}"}],
                   [{"text": "✋ Ferma il cane", "callback_data": "stop"},
                    {"text": "🏠 Cane alla base", "callback_data": "home"}]]
        mid = ctx.get("mission_id")
        link = await self.open_link("mission", mid) if mid else (await self.open_link("event", eid) if eid else None)
        res = await self.broadcast(self.alert_text(ctx), image, ([[{"text": "📱 Apri nell'app", "url": link}]] + buttons) if link else buttons)
        if link and not any(r["ok"] for r in res):
            # Telegram refuses some addresses: the alert must go out anyway, without the app button
            res = await self.broadcast(self.alert_text(ctx), image, buttons)
        ok = any(r["ok"] for r in res)
        return {"channel": "telegram", "ok": ok, "chats": len(res),
                "error": None if ok else (res[0]["error"] if res else "no chat subscribed: send /start to the bot")}

    # incoming ---------------------------------------------------------------------------
    async def run(self):
        if not self.enabled:
            return
        try:
            me = await self.api("getMe")
            self.username, self.ok = me.get("username"), True
            await self.api("setMyCommands", commands=[
                {"command": c, "description": d} for c, d in (
                    ("inserisci", "Inserisci l'allarme"), ("disinserisci", "Disinserisci l'allarme"),
                    ("stato", "Allarme e cane"), ("foto", "Cosa vede il cane adesso"),
                    ("ronda", "Avvia la ronda"), ("base", "Cane alla base"), ("ferma", "Ferma il cane"),
                    ("esci", "Non ricevere più allarmi"))])
            self.log.add("telegram.online", f"Telegram bot @{self.username} online · {len(self.chats)} chat(s) subscribed")
        except Exception as e:
            self.ok, self.error = False, str(e)[:200]
            self.log.add("telegram.error", f"Telegram bot not started: {self.error}", level="error")
            return
        while True:
            try:
                updates = await self.api("getUpdates", offset=self.offset, timeout=30,
                                         allowed_updates=["message", "callback_query"])
                for u in updates:
                    self.offset = u["update_id"] + 1
                    try:
                        if "message" in u:
                            await self.on_message(u["message"])
                        elif "callback_query" in u:
                            await self.on_button(u["callback_query"])
                    except Exception as e:
                        self.log.add("telegram.error", f"update: {e}", level="error")
                self.ok, self.error = True, None
            except Exception as e:
                self.ok, self.error = False, str(e)[:200]
                await asyncio.sleep(5)

    async def reply(self, chat, text):
        await self.api("sendMessage", chat_id=chat, text=text)

    async def on_message(self, msg):
        chat = str(msg["chat"]["id"])
        who = msg.get("from", {}).get("first_name") or msg["chat"].get("title") or chat
        text = (msg.get("text") or "").strip()
        cmd, _, arg = text.partition(" ")
        cmd = cmd.split("@")[0].lower()
        if cmd == "/start":
            if self.pin and arg.strip() != self.pin:
                await self.reply(chat, "Per ricevere gli allarmi scrivi /start seguito dal PIN.")
                return
            self.chats[chat] = {"name": who, "since": time.time()}
            self._save()
            self.log.add("telegram.subscribed", f"{who} will receive the alerts on Telegram")
            await self.reply(chat, f"Ciao {who}. Da ora ricevi qui gli allarmi della ronda.\n\n{HELP}")
            return
        if chat not in self.chats:
            await self.reply(chat, "Scrivi /start per ricevere gli allarmi.")
            return
        if cmd == "/esci":
            self.chats.pop(chat, None)
            self._save()
            self.log.add("telegram.unsubscribed", f"{who} stopped the Telegram alerts")
            await self.reply(chat, "Fatto: non ricevi più allarmi. /start per riattivarli.")
        elif cmd == "/stato":
            await self.reply(chat, self.status_text())
        elif cmd == "/foto":
            img = await self.photo_fn() if self.photo_fn else None
            if img:
                await self.api("sendPhoto", files={"photo": ("cane.jpg", img, "image/jpeg")}, chat_id=chat,
                               caption=f"Telecamera del cane · {hm(time.time())}")
            else:
                await self.reply(chat, "Nessuna immagine dalla telecamera del cane in questo momento.")
        elif cmd in ("/inserisci", "/disinserisci"):
            arm = cmd == "/inserisci"
            r = await self.command("arm" if arm else "disarm", {"by": "telegram"})
            self.log.add("telegram.command", f"{who} via Telegram: {cmd}")
            text = (f"🔒 Allarme inserito da {who}. Attivo tra {r.get('exit_delay_s', 0)} s." if arm
                    else f"🔓 Allarme disinserito da {who}.")
            await self.broadcast(text)
        elif cmd in ("/ronda", "/base", "/ferma"):
            action = {"/ronda": "patrol", "/base": "home", "/ferma": "stop"}[cmd]
            r = await self.command(action, {})
            self.log.add("telegram.command", f"{who} via Telegram: {cmd}", data={"result": r})
            await self.reply(chat, {"patrol": "Ronda avviata.", "home": "Il cane torna alla base.",
                                    "stop": "Cane fermato, missioni annullate."}[action] if r.get("ok") else f"Non riuscito: {r.get('error')}")
        else:
            await self.reply(chat, HELP)

    async def on_button(self, cq):
        chat = str(cq["message"]["chat"]["id"])
        who = cq.get("from", {}).get("first_name") or chat
        data = cq.get("data", "")
        note = ""
        if chat not in self.chats:
            await self.api("answerCallbackQuery", callback_query_id=cq["id"], text="Scrivi /start al bot")
            return
        if data.startswith("ack:"):
            self.log.add("alert.ack", f"Alert taken in charge by {who} on Telegram", event_id=data[4:] or None)
            note = f"✅ Preso in carico da {who} alle {hm(time.time())}"
            try:
                cap = (cq["message"].get("caption") or cq["message"].get("text") or "")
                await self.api("editMessageCaption", chat_id=chat, message_id=cq["message"]["message_id"],
                               caption=(cap + "\n\n" + note)[:1024])
            except Exception:
                pass
        elif data.startswith("recheck:"):
            r = await self.command("send", {"spot": data[8:]})
            self.log.add("telegram.command", f"{who} via Telegram: check {data[8:]} again", data={"result": r})
            note = "Il cane torna a controllare" if r.get("ok") else "Non riuscito"
        elif data in ("stop", "home"):
            r = await self.command(data, {})
            self.log.add("telegram.command", f"{who} via Telegram: {data}", data={"result": r})
            note = "Cane fermato" if data == "stop" else "Il cane torna alla base"
        await self.api("answerCallbackQuery", callback_query_id=cq["id"], text=note[:190] or "Ok")

    def status_text(self):
        s = self.status_fn() if self.status_fn else {}
        d = s.get("dog", {})
        m = s.get("mission")
        al = s.get("alarm", {})
        lines = [("🔒 Allarme INSERITO" if al.get("active") else f"🔒 Allarme in inserimento ({al.get('exit_delay_s')} s)")
                 if al.get("armed") else "🔓 Allarme disinserito",
                 f"Cane: {'collegato' if d.get('connected') else 'NON collegato'}"
                 f"{'' if d.get('armed', True) else ' · ARRESTO DI EMERGENZA'} · posizione {d.get('x', 0):.1f}, {d.get('y', 0):.1f} m",
                 f"Missione: {m['label']} ({m['status']})" if m else "Missione: nessuna, in attesa"]
        st = s.get("stats", {})
        lines.append(f"Turno: {st.get('events', 0)} eventi · {st.get('alerts', 0)} allarmi · "
                     f"{st.get('filtered', 0)} falsi allarmi fermati")
        if st.get("avg_arrival_s") is not None:
            lines.append(f"Tempo medio evento → arrivo: {st['avg_arrival_s']} s")
        return "\n".join(lines)
