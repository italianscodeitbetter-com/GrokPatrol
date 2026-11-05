"""Checks the xAI key, image input and tool calling, and times each model. Usage: .venv/bin/python scripts/check_grok.py [image.jpg]"""
import asyncio, sys, time, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "admin" / "backend"))
from app.config import Site
from app.grok import Grok

async def main():
    g = Grok(Site())
    img = Path(sys.argv[1]).read_bytes() if len(sys.argv) > 1 else None
    for model in ["grok-4.20-0309-non-reasoning", "grok-4.3", "grok-4.7"]:
        t = time.time()
        try:
            out = await g.json_task('Answer JSON only: {"what": "max 12 words"}', "Describe the image.", [img] if img else [], model=model, timeout=40)
            print(f"{model:32s} vision {int((time.time()-t)*1000):5d} ms  {out}")
        except Exception as e:
            print(f"{model:32s} vision FAIL {e}")
    tools = [{"type": "function", "name": "start_patrol", "description": "Start a patrol", "parameters": {"type": "object", "properties": {"route_id": {"type": "string"}}, "required": ["route_id"]}}]
    async def ex(name, args): return {"ok": True, "name": name, "args": args}
    t = time.time()
    reply, actions = await g.console("patrol room 1", [], tools, ex, {"dog": "idle"})
    print(f"tools {int((time.time()-t)*1000)} ms", actions, "->", reply)
asyncio.run(main())
