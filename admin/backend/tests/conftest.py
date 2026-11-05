import os
import tempfile

# before the app is imported: never the real logbook, real Grok calls or the real dog
os.environ["DOG"] = "sim"
os.environ.setdefault("RONDA_PIN", "")
os.environ["RONDA_DATA"] = tempfile.mkdtemp()
os.environ["XAI_API_KEY"] = ""
os.environ["TELEGRAM_BOT_TOKEN"] = ""

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c
