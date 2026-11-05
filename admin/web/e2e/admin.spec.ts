import { expect, test } from "@playwright/test";

test("the /api proxy reaches the admin backend", async ({ request }) => {
  const s = await (await request.get("/api/state")).json();
  expect(s.dog.kind).toBe("sim");
  expect(s.dog.connected).toBe(true);
  expect(s.cameras.map((c: { id: string }) => c.id)).toContain("dog");
});

test("the dashboard shows the live Go1", async ({ page }) => {
  await page.goto("/dashboard");
  await expect(page.getByRole("button", { name: /Follow Unitree Go1, battery 100%/ })).toBeVisible({ timeout: 20_000 });
});

test("settings → Bots drives posture on the backend", async ({ page, request }) => {
  await page.goto("/dashboard");
  await expect(page.getByRole("button", { name: /Follow Unitree Go1/ })).toBeVisible({ timeout: 20_000 });
  await page.keyboard.press("Meta+Comma");
  await page.getByRole("button", { name: "Bots", exact: true }).first().click();
  await page.getByRole("button", { name: "Lie down" }).click();
  await expect.poll(async () => (await (await request.get("/api/state")).json()).dog.posture).toBe("down");
  await page.getByRole("button", { name: "Stand", exact: true }).click();
  await expect.poll(async () => (await (await request.get("/api/state")).json()).dog.posture, { timeout: 10_000 }).toBe("standing");
});

test("phone camera page is served through Next", async ({ request }) => {
  const r = await request.get("/camera");
  expect(r.status()).toBe(200);
  expect(await r.text()).toContain("coco-ssd");
});
