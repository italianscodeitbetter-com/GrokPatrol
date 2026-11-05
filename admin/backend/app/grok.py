"""Grok (xAI Responses API): triage of camera events, what the dog sees, alerts, console, shift report."""
import base64
import json
import re
import time

import httpx

from .config import env

LANG_NAMES = {"it": "Italian", "en": "English"}


def _img(b: bytes) -> dict:
    return {"type": "input_image", "image_url": "data:image/jpeg;base64," + base64.b64encode(b).decode()}


def parse_json(text: str):
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None


class Grok:
    def __init__(self, site):
        self.site = site
        self.key = env("XAI_API_KEY", "")
        self.base = env("XAI_BASE_URL", "https://api.x.ai/v1").rstrip("/")
        self.model = env("XAI_MODEL", "grok-4.7")                      # console, reports
        self.vision = env("XAI_VISION_MODEL", "grok-4.3")             # what the dog sees
        self.fast = env("XAI_FAST_MODEL", "grok-4.20-0309-non-reasoning")  # triage, about 1 s
        self.http = httpx.AsyncClient(timeout=30)
        self.last_error = None
        self.last_ms = None
        self.calls = 0
        self.ok = None
        self.auth_failed = False

    @property
    def enabled(self):
        return bool(self.key) and not self.auth_failed

    def set_key(self, key):
        self.key, self.auth_failed, self.ok, self.last_error = key.strip(), False, None, None

    def status(self):
        return {"enabled": self.enabled, "configured": bool(self.key), "auth_failed": self.auth_failed, "ok": self.ok, "last_ms": self.last_ms, "calls": self.calls,
                "error": self.last_error, "models": {"main": self.model, "vision": self.vision, "fast": self.fast}}

    @property
    def lang(self):
        return LANG_NAMES.get(self.site.lang, self.site.lang)

    async def respond(self, input_items, model=None, tools=None, timeout=20, temperature=0.2, tool_choice=None):
        if not self.enabled:
            raise RuntimeError("Grok paused: " + (self.last_error or "XAI_API_KEY missing"))
        body = {"model": model or self.model, "input": input_items, "store": False, "temperature": temperature}
        if tools:
            body["tools"] = tools
            if tool_choice:
                body["tool_choice"] = tool_choice
        t0 = time.time()
        try:
            r = await self.http.post(self.base + "/responses", json=body, timeout=timeout,
                                     headers={"Authorization": f"Bearer {self.key}"})
            if r.status_code >= 400:
                if r.status_code in (401, 402, 403) or "API key" in r.text:
                    self.auth_failed = True  # stop hammering: re-enabled from the console (retry)
                raise RuntimeError(f"xAI {r.status_code}: {r.text[:300]}")
            data = r.json()
        except Exception as e:
            self.ok, self.last_error = False, str(e)[:300]
            raise
        self.calls += 1
        self.last_ms = int((time.time() - t0) * 1000)
        self.ok, self.last_error = True, None
        return data

    @staticmethod
    def text_of(resp) -> str:
        if isinstance(resp.get("output_text"), str) and resp["output_text"]:
            return resp["output_text"]
        parts = []
        for item in resp.get("output", []):
            if item.get("type") == "message":
                for c in item.get("content", []):
                    if c.get("type") in ("output_text", "text") and c.get("text"):
                        parts.append(c["text"])
        return "\n".join(parts)

    @staticmethod
    def calls_of(resp):
        return [i for i in resp.get("output", []) if i.get("type") == "function_call"]

    async def json_task(self, system, text, images=(), model=None, timeout=15):
        content = [{"type": "input_text", "text": text}] + [_img(b) for b in images if b]
        resp = await self.respond([{"role": "system", "content": system}, {"role": "user", "content": content}],
                                  model=model or self.vision, timeout=timeout)
        out = parse_json(self.text_of(resp))
        if out is None:
            raise RuntimeError("Grok did not return JSON: " + self.text_of(resp)[:200])
        return out

    # 1. triage of a camera event ------------------------------------------------------------
    async def assess(self, event, camera, active, model=None):
        if event.kind in ("motion", "person"):
            return await self.assess_armed(event, camera, model)
        system = (
            "You are the security triage officer of a site watched by fixed cameras and patrolled by a robot dog. "
            "A camera's on-device detector raised an event. The snapshot is the clean camera frame: the restricted zone "
            "is the red outline (red tape on the floor or a red rectangle). The detector boxes are not drawn: they are in "
            "the JSON as normalised [x, y, width, height]. The second image, when present, is a zoomed crop around the "
            "detection: use it to judge where the feet are against the tape. The 'note' says what the detector measured; "
            "trust the images when they clearly contradict it. Decide whether the robot dog should go and check.\n"
            f"Site rules: {self.site.rules}\n"
            "Decision rules, in this order:\n"
            "1. A person whose feet are inside the red zone is an INTRUSION: dispatch, severity 4 (5 if they touch or "
            "open the display case). Being a visitor does not authorise entering the zone. The only exception is "
            "authorised staff (high-visibility vest or staff lanyard): false_alarm, severity 1, no dispatch.\n"
            "2. A bag, suitcase, backpack or box inside the zone with nobody next to it is an ABANDONED_OBJECT: "
            "dispatch, severity 3.\n"
            "3. False alarms, no dispatch: reflections, posters or screens showing people, statues, mannequins, "
            "objects that belong to the exhibit, our own four-legged robot dog, a person clearly outside the tape.\n"
            "4. If you cannot tell, dispatch with verdict suspicious: sending the dog is cheap, a missed intrusion is not.\n"
            "Answer with JSON only, no prose: {\"verdict\": \"threat\"|\"suspicious\"|\"false_alarm\", "
            "\"category\": \"intrusion\"|\"abandoned_object\"|\"other\"|\"none\", \"severity\": 1-5, "
            "\"confidence\": 0-1, \"dispatch\": true|false, "
            f"\"reason\": \"max 25 words in {self.lang}\", \"check_for\": \"what the dog must look for, max 15 words in {self.lang}\"}}"
        )
        text = json.dumps({
            "camera": {"id": camera["id"], "name": camera["name"], "room": camera.get("room")},
            "detector_event": event.kind, "detector_score": event.score,
            "detections": event.detections[:12], "note": event.note,
            "local_time": time.strftime("%H:%M:%S"),
            "other_open_events": active,
        }, ensure_ascii=False)
        from .mission import closeup
        zoom = closeup(event.snapshot, [d for d in event.detections if d.get("label") in ("person", "suitcase", "backpack", "handbag")])
        return await self.json_task(system, text, [event.snapshot, zoom], model=model or self.fast,
                                    timeout=12 if model is None else 20)

    async def assess_armed(self, event, camera, model=None):
        """Alarm armed, a camera saw movement: does the robot dog need to go and check?"""
        system = (
            "You watch the cameras of a hall whose alarm is ARMED: it is closed and nobody should be inside, staff "
            "included. A camera detected movement. Decide whether the robot dog must go and check. "
            "Needs checking: a person or part of one (legs, a hand, a silhouette, someone half hidden by a pillar), "
            "a bag, box or object that looks left or moved, an open or moving door, a torch, smoke, anything you cannot "
            "explain. Does not need checking: our own grey four-legged robot dog, light and shadow changes, reflections, "
            "screens, curtains, insects, things that are part of the hall and did not change. "
            f"Site notes: {self.site.rules}\n"
            "The first image is the camera frame. The second, when present, is a zoomed crop around what moved. "
            "When in doubt, check: the dog is cheap, a missed intruder is not. Answer with JSON only: "
            "{\"dispatch\": true|false, \"what\": \"person\"|\"object\"|\"other\"|\"nothing\", \"person\": true|false, "
            "\"verdict\": \"threat\"|\"suspicious\"|\"false_alarm\", \"severity\": 1-5, \"confidence\": 0-1, "
            "\"where\": [x, y] position in the first image, 0-1 from the top left, of the person's feet or of the "
            "object on the floor, or null, "
            f"\"reason\": \"max 20 words in {self.lang}\", \"check_for\": \"what the dog must look at, max 12 words in {self.lang}\"}}"
        )
        text = json.dumps({"camera": {"id": camera["id"], "name": camera["name"], "room": camera.get("room")},
                           "detections": event.detections[:12], "note": event.note,
                           "local_time": time.strftime("%H:%M:%S")}, ensure_ascii=False)
        from .mission import closeup
        zoom = closeup(event.snapshot, [d for d in event.detections if d.get("label") in ("person", "motion", "suitcase", "backpack", "handbag")])
        return await self.json_task(system, text, [event.snapshot, zoom], model=model or self.fast,
                                    timeout=12 if model is None else 20)

    # 2. what the dog sees on arrival --------------------------------------------------------
    async def verify(self, summary, dog_img, cam_img, dog_is_fixed_cam=False):
        source = ("NOTE: no camera on the dog, the first image is a fresh frame of the fixed camera."
                  if dog_is_fixed_cam else "The first image is from the robot dog's camera, just arrived on the spot.")
        system = (
            "You are the eyes of a security robot dog that was sent to check an anomaly. "
            f"{source} The second image, if present, is the camera snapshot that raised the event. "
            f"Site rules: {self.site.rules}\n"
            "Describe what is there now and say whether there is really something wrong. The alarm is armed, so the "
            "hall should be empty. confirmed=true: a person, a bag or object left or moved, an open door, damage, smoke. "
            "confirmed=false: nothing unusual, only the hall and its furniture. null: you cannot see. "
            "Answer with JSON only: {\"confirmed\": true|false|null, "
            f"\"description\": \"max 40 words in {self.lang}, concrete: who/what, where, doing what\", "
            "\"people\": integer, \"objects\": [short strings], \"risk\": \"none\"|\"low\"|\"medium\"|\"high\", "
            f"\"action\": \"recommended action for the caretaker, max 15 words in {self.lang}\"}}"
        )
        return await self.json_task(system, json.dumps(summary, ensure_ascii=False), [dog_img, cam_img], timeout=30)

    # 3. the alert ---------------------------------------------------------------------------
    async def compose_alert(self, payload):
        system = (
            "You write security alerts for a caretaker and a security guard. Clear, calm, factual, actionable. "
            "Say what, where, when, how sure, and what to do. Never invent details not in the data. "
            f"Write in {self.lang}. Answer with JSON only: {{\"title\": \"max 8 words\", "
            "\"sms\": \"max 280 characters\", "
            "\"voice\": \"max 50 words, natural spoken sentences for a phone call, no abbreviations, no codes, "
            "starts by saying it is the automatic patrol system\"}"
        )
        resp = await self.respond([{"role": "system", "content": system},
                                   {"role": "user", "content": json.dumps(payload, ensure_ascii=False)}],
                                  model=self.fast, timeout=12)
        out = parse_json(self.text_of(resp))
        if not out:
            raise RuntimeError("no alert JSON")
        return out

    # 4. quick look at each patrol stop -------------------------------------------------------
    async def patrol_check(self, img, spot):
        system = (
            "You are a security robot dog on patrol, stopped at a checkpoint. Look at your camera image and flag "
            "only clear anomalies: an unauthorised person inside a red restricted zone, or a bag, suitcase or backpack "
            "lying on the floor with nobody near it. Furniture, display cabinets, pedestals, benches, paintings, walls, "
            "normal visitors and the red tape are never anomalies. When unsure, anomaly=false. "
            f"Site rules: {self.site.rules}\n"
            "Answer with JSON only: {\"anomaly\": true|false, \"category\": \"intrusion\"|\"abandoned_object\"|\"other\"|\"none\", "
            f"\"severity\": 1-5, \"description\": \"max 25 words in {self.lang}\"}}"
        )
        return await self.json_task(system, json.dumps({"checkpoint": spot["name"]}), [img], model=self.fast, timeout=12)

    # 5. shift report ------------------------------------------------------------------------
    async def report(self, entries, stats):
        system = (
            "You write the end-of-shift report of a robot dog security patrol, for the security manager. "
            f"Write everything in {self.lang}, headings included, in Markdown, short: a title, a 3-line summary, then "
            "a section with the events (one line each: time, camera, what it was, outcome, event-to-arrival seconds), "
            "then a section on false alarms, then open issues and recommendations. Use only the data."
        )
        resp = await self.respond([{"role": "system", "content": system},
                                   {"role": "user", "content": json.dumps({"stats": stats, "log": entries}, ensure_ascii=False)}],
                                  timeout=40)
        return self.text_of(resp)

    # 6. natural-language console ------------------------------------------------------------
    async def console(self, message, history, tools, execute, status):
        system = (
            "You are Ronda, the operator console of a robot dog security patrol. The operator types or speaks "
            "commands like 'patrol room 2', 'go and check the entrance', 'stop', 'what happened in the last hour'. "
            "Use the tools to act. Map words to ids from the site map; if a request is ambiguous ask one short "
            "question. Never invent spots or events. Every action MUST go through a tool call: never say that "
            "something was started, sent, staged or stopped unless you called the tool and it returned ok. "
            "Requests to simulate or stage a scene (intruder, abandoned bag, staff member, visitor, clear) use "
            "stage_scenario with the camera id. After acting, confirm in one or two short sentences. "
            "Reply in the operator's language.\n"
            f"Site map: {self.site.summary_for_prompt()}\nCurrent status: {json.dumps(status, ensure_ascii=False)}"
        )
        items = [{"role": "system", "content": system}]
        for h in history[-8:]:
            if h.get("role") in ("user", "assistant") and h.get("text"):
                text = h["text"]
                if h["role"] == "assistant":
                    done = [a["tool"] for a in h.get("actions") or []]
                    text += f"\n[tools actually called for this reply: {', '.join(done) if done else 'none'}]"
                items.append({"role": h["role"], "content": text})
        items.append({"role": "user", "content": message})
        actions = []
        for step in range(5):
            # the first answer must be a tool call: actions only exist if a tool ran
            resp = await self.respond(items, tools=tools, timeout=25, tool_choice="required" if step == 0 else None)
            calls = self.calls_of(resp)
            if not calls:
                return self.text_of(resp), actions
            for c in calls:
                try:
                    args = json.loads(c.get("arguments") or "{}")
                except json.JSONDecodeError:
                    args = {}
                result = await execute(c["name"], args)
                actions.append({"tool": c["name"], "args": args, "result": result})
                items.append({"type": "function_call", "call_id": c["call_id"], "name": c["name"],
                              "arguments": c.get("arguments") or "{}"})
                items.append({"type": "function_call_output", "call_id": c["call_id"],
                              "output": json.dumps(result, ensure_ascii=False, default=str)})
        return "Done.", actions
