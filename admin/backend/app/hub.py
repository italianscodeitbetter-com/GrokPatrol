"""Live fan-out to the console websockets."""
import asyncio
import json


class Hub:
    """Fan-out of messages to the console websockets. publish() is safe from any thread."""

    def __init__(self):
        self.clients = set()
        self.loop = None
        self.queue = None

    def start(self, loop):
        self.loop = loop
        self.queue = asyncio.Queue()
        loop.create_task(self._pump())

    def publish(self, msg: dict):
        if self.loop is None:
            return
        try:
            self.loop.call_soon_threadsafe(self.queue.put_nowait, msg)
        except RuntimeError:
            pass

    async def _pump(self):
        while True:
            msg = await self.queue.get()
            try:
                await self.broadcast(msg)
            except Exception:
                pass

    async def broadcast(self, msg: dict):
        try:
            text = json.dumps(msg, ensure_ascii=False, default=str)
        except Exception:
            return
        dead = []
        for ws in list(self.clients):
            try:
                await asyncio.wait_for(ws.send_text(text), 2.0)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.clients.discard(ws)
            try:
                await ws.close()   # the page sees the close and reconnects
            except Exception:
                pass
