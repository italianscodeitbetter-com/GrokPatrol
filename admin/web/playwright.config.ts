import { defineConfig } from "@playwright/test";

// e2e: backend admin (cane simulato) su :8010, Next in dev su :3010. Non tocca un eventuale server già su :8000.
const API = 8010;
const WEB = 3010;

export default defineConfig({
  testDir: "e2e",
  timeout: 60_000,
  workers: 1,
  // Chrome di sistema: niente download dei browser di Playwright (PW_CHANNEL=chromium per quello bundled)
  use: { baseURL: `http://localhost:${WEB}`, trace: "retain-on-failure", channel: process.env.PW_CHANNEL ?? "chrome" },
  webServer: [
    {
      command: `DOG=sim PORT=${API} HTTPS_PORT=${API + 443} .venv/bin/python -m app.serve`,
      cwd: "../backend",
      url: `http://localhost:${API}/api/state`,
      reuseExistingServer: false,
      timeout: 60_000,
    },
    {
      command: `npx next dev -p ${WEB}`,
      url: `http://localhost:${WEB}/dashboard`,
      reuseExistingServer: false,
      timeout: 120_000,
      env: { BACKEND_URL: `http://localhost:${API}`, NEXT_PUBLIC_BACKEND_WS: `ws://localhost:${API}/ws/console` },
    },
  ],
});
