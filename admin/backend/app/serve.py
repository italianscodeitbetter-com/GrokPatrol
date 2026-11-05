"""Serves the app on HTTP :8000 (this laptop) and HTTPS :8443 (phones: the browser camera needs HTTPS)."""
import asyncio
import os

import uvicorn

from .config import ROOT
from .main import app


async def main():
    port = int(os.environ.get("PORT", 8000))
    sport = int(os.environ.get("HTTPS_PORT", 8443))
    configs = [uvicorn.Config(app, host="0.0.0.0", port=port, log_level="warning", ws_max_size=16 * 1024 * 1024)]
    cert, key = ROOT / "certs" / "cert.pem", ROOT / "certs" / "key.pem"
    if cert.exists() and key.exists():
        configs.append(uvicorn.Config(app, host="0.0.0.0", port=sport, log_level="warning", lifespan="off",
                                      ssl_certfile=str(cert), ssl_keyfile=str(key), ws_max_size=16 * 1024 * 1024))
    await asyncio.gather(*(uvicorn.Server(c).serve() for c in configs))


if __name__ == "__main__":
    asyncio.run(main())
