// Ronda console: live state over a websocket, commands over HTTP.
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const hms = (ts) => new Date(ts * 1000).toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
const S = { site: null, dog: null, current: null, queue: [], stats: {}, grok: {}, alerts: [], cameras: [], sim: {},
  schedules: {}, events: new Map(), selected: null, filter: "", connected: false, lastAlertEvent: null };

async function api(path, body) {
  const r = await fetch(path, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
  return r.json();
}
const cmd = (action, extra = {}) => api("/api/command", { action, ...extra }).then((r) => {
  if (r && r.ok === false) toast(r.error || "Not done");
  return r;
}).catch((e) => toast("Server not reachable: " + e));

// in-page confirmation: browser confirm() returns false in embedded views and some apps
function ask(text, yes = "Confirm") {
  return new Promise((resolve) => {
    const d = $("#askDlg"); $("#askText").textContent = text; $("#askYes").textContent = yes;
    const done = (v) => { d.close(); $("#askYes").onclick = $("#askNo").onclick = null; resolve(v); };
    $("#askYes").onclick = () => done(true); $("#askNo").onclick = () => done(false);
    d.oncancel = () => done(false);
    try { d.showModal(); } catch { resolve(true); }
  });
}
let toastT = null;
function toast(text) {
  let t = document.querySelector(".toast"); if (!t) { t = document.createElement("div"); t.className = "toast"; document.body.appendChild(t); }
  t.textContent = text; t.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => (t.hidden = true), 3500);
}

// ---------------------------------------------------------------- websocket
S.lastMsg = 0; S.lastLogId = 0; S.mode = "connecting";
function handleMsg(m) {
    if (m.type === "tick") applyTick(m);
    else if (m.type === "log") addLog(m.entry, true);
    else if (m.type === "event") upsertEvent(m.event);
    else if (m.type === "missions") { S.current = m.current; S.queue = m.queue; renderPatrol(); }
    else if (m.type === "alert") showAlert(m);
    else if (m.type === "site") { S.site = m.site; buildStatic(); }
    else if (m.type === "reset") location.reload();
    else if (m.type === "alarm") { S.alarm = m; renderAlarm(); }
}
function connect() {
  let ws;
  try { ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws/console"); }
  catch { setTimeout(connect, 3000); return; }
  S.ws = ws;
  ws.onopen = () => { S.connected = true; renderChips(); };
  ws.onclose = () => { S.connected = false; renderChips(); setTimeout(connect, 2000); };
  ws.onerror = () => {};
  ws.onmessage = (e) => {
    S.lastMsg = Date.now();
    try { handleMsg(JSON.parse(e.data)); } catch (err) { console.error("update failed", err); }
  };
}
// if no live message arrives (websocket blocked by the browser, a proxy or a certificate), ask every second
async function pollLoop() {
  const live = Date.now() - S.lastMsg < 1500;
  const mode = live ? "live" : "polling";
  if (mode !== S.mode) { S.mode = mode; renderChips(); }
  if (!live) {
    try {
      const r = await fetch(`/api/poll?log_after=${S.lastLogId}&ev_after=${S.lastPoll || 0}`).then((x) => x.json());
      S.lastPoll = r.now;
      handleMsg({ type: "tick", ...r.tick });
      for (const e of r.log) handleMsg({ type: "log", entry: e });
      for (const ev of r.events) handleMsg({ type: "event", event: ev });
      S.pollOk = true;
    } catch { S.pollOk = false; }
  }
  setTimeout(pollLoop, 1000);
}

function applyTick(m) {
  if (m.shift && S.shift && m.shift !== S.shift) { location.reload(); return; }
  if (m.shift) S.shift = m.shift;
  const simWas = S.sim.connected;
  Object.assign(S, { dogcam: m.dogcam, alarm: m.alarm, dog: m.dog, current: m.current, queue: m.queue, stats: m.stats, grok: m.grok, alerts: m.alerts, telegram: m.telegram,
    cameras: m.cameras, sim: m.sim, schedules: m.schedules });
  renderChips(); renderKpis(); renderMapDynamic(); renderPatrol(); renderHud(); renderAlarm(); renderDogcam();
  if (simWas !== S.sim.connected) { renderStage(); renderViewTabs(); }
}

// ---------------------------------------------------------------- the Go1's head camera
function renderDogcam() {
  const b = $("#btnDogcam"); const dc = S.dogcam;
  b.hidden = !dc;
  if (!dc) return;
  b.textContent = dc.state === "streaming" ? `Dog camera · ${dc.fps || ""} fps · Stop` : dc.state === "starting" ? "Starting the dog camera…" : dc.state === "error" ? "Dog camera error · Retry" : "Start dog camera";
  b.title = dc.error || "";
}
$("#btnDogcam").onclick = async () => {
  const dc = S.dogcam || {};
  if (dc.state === "streaming") { if (await ask("Stop the dog camera stream? Unitree's obstacle cameras come back only after a reboot of the dog.", "Stop")) await api("/api/dogcam/stop", {}); return; }
  if (!(await ask("Start the head camera stream on the Go1? It stops Unitree's camera program on the head Jetson: until the dog reboots, the front camera no longer feeds its obstacle detection.", "Start camera"))) return;
  $("#btnDogcam").textContent = "Starting the dog camera…";
  const r = await api("/api/dogcam/start", {});
  if (r.state === "error") toast(r.error);
};

// ---------------------------------------------------------------- alarm
function renderAlarm() {
  const a = S.alarm || {}; const b = $("#btnAlarm");
  b.classList.toggle("armed", !!a.active); b.classList.toggle("arming", !!a.armed && !a.active);
  b.textContent = a.active ? "ARMED · Disarm" : a.armed ? `Arming in ${a.exit_delay_s} s · Cancel` : "Arm alarm";
}
$("#btnAlarm").onclick = () => cmd(S.alarm?.armed ? "disarm" : "arm");

// ---------------------------------------------------------------- header + kpis
function chip(label, state) { return `<span class="chip"><span class="dot ${state || ""}"></span>${label}</span>`; }
function renderChips() {
  const d = S.dog || {};
  const g = S.grok || {};
  const fixed = S.cameras.filter((c) => c.id !== "dog" && c.id !== "sim-view");
  const online = fixed.filter((c) => c.online).length;
  const dogcam = S.cameras.find((c) => c.id === "dog");
  const grokState = !g.configured ? "bad" : g.enabled ? (g.ok === false ? "warn" : "ok") : "bad";
  const grokLabel = !g.configured ? "Grok: no key" : !g.enabled ? "Grok paused" : `Grok ${g.last_ms ? g.last_ms + " ms" : "ready"}`;
  $("#chips").innerHTML = [
    chip(S.mode === "live" ? "Server · live" : S.pollOk ? "Server · polling" : "Server offline", S.mode === "live" ? "ok" : S.pollOk ? "warn" : "bad"),
    chip(d.kind === "go1" && !d.connected && d.link === "standby" ? "Dog GO1 · on, press L1 + START"
      : `Dog ${(d.kind || "").toUpperCase()}${d.connected ? "" : " · not connected"}${d.battery != null && d.connected ? " · " + d.battery + "%" : ""}${d.odom === "integrate" ? " · dead reckoning" : ""}`,
      d.connected ? (d.armed ? "ok" : "bad") : d.link === "standby" ? "warn" : "bad"),
    chip(grokLabel, grokState),
    chip(`Cameras ${online}/${fixed.length}${dogcam && dogcam.online ? " + dog" : ""}`, online ? "ok" : "warn"),
    chip(S.sim.connected ? "3D sim" : "3D sim off", S.sim.connected ? "ok" : ""),
    chip("Alerts: " + (S.alerts || []).join(", ") + (S.telegram?.enabled ? ` (${S.telegram.chats} chat)` : ""), (S.alerts || []).length > 1 ? (S.telegram?.ok === false ? "bad" : "ok") : "warn"),
  ].join("");
  $("#grokState").textContent = g.enabled ? `${g.models?.main} · ${g.calls} calls` : (g.error ? "offline: " + g.error.slice(0, 80) : "offline");
  const es = $("#btnEstop");
  es.classList.toggle("engaged", d.armed === false);
  es.textContent = d.armed === false ? "Release" : "E-stop";
}

function renderKpis() {
  const s = S.stats || {};
  const k = (v, l) => `<div class="kpi"><b>${v ?? "-"}</b><span>${l}</span></div>`;
  $("#kpis").innerHTML = k(s.events, "Events") + k(s.dispatched, "Dog dispatched") +
    k(s.avg_arrival_s != null ? s.avg_arrival_s + " s" : "-", "Avg event to arrival") +
    k(s.confirmed, "Confirmed on site") + k(s.filtered + (s.cleared || 0), "False alarms stopped") + k(s.alerts, "Alerts sent");
}

// ---------------------------------------------------------------- live view
const VIEWS = [["follow", "Follow"], ["map", "Top"], ["dog", "Dog cam"]];
function renderViewTabs() {
  const cams = (S.site?.cameras || []).map((c) => [c.id, c.id.replace("cam-", "Cam ")]);
  $("#viewTabs").innerHTML = [...VIEWS, ...cams].map(([id, l]) =>
    `<button data-v="${id}" class="${(S.sim.view || "follow") === id ? "on" : ""}">${l}</button>`).join("");
}
$("#viewTabs").addEventListener("click", async (e) => {
  const v = e.target.dataset.v; if (!v) return;
  S.sim.view = v; renderViewTabs();
  if (S.sim.connected) await cmd("view", { mode: v });
});
function dogLive() { return !S.sim.connected && (S.cameras || []).some((c) => c.id === "dog" && c.online); }
function renderStage() {
  const showing = S.sim.connected || dogLive();
  $("#stageEmpty").hidden = showing;
  $("#view3d").style.visibility = showing ? "visible" : "hidden";
  if (S.dog?.kind === "go1") $("#stageMsg").innerHTML = "<strong>Real dog.</strong> Press <b>Start dog camera</b> (Cameras panel) to see the head camera of the Go1 here.";
  document.querySelectorAll("#stagingPanel .btn").forEach((b) => { if (b.dataset.stage) b.disabled = !S.sim.connected; });
}
// the big view is an MJPEG stream: while it is open the backend asks the simulator (or the dog) for fast frames
let viewSrc = null;
function loopView() {
  const img = $("#view3d");
  const src = S.sim.connected ? "/api/cameras/sim-view/stream" : dogLive() ? "/api/cameras/dog/stream" : null;
  if (src !== viewSrc) {
    viewSrc = src;
    img.onerror = () => { viewSrc = null; };   // dropped: the next check opens it again
    img.src = src ? src + "?t=" + Date.now() : "";
  }
  if (!src) renderStage();
  setTimeout(loopView, 1000);
}
function renderHud() {
  const d = S.dog || {}; const m = S.current;
  const v = d.cmd ? Math.abs(d.cmd[0]).toFixed(2) : "0.00";
  const al = S.alarm || {};
  $("#hud").innerHTML = (al.active ? chip("ALARM ARMED", "bad") : al.armed ? chip(`Arming ${al.exit_delay_s} s`, "warn") : chip("Alarm off", "")) + chip(m ? esc(m.label) + (m.status === "verifying" ? " · Grok is looking" : "") : "Idle", m ? "ok" : "") +
    chip(`${v} m/s`, "") + (d.armed === false ? chip("E-STOP", "bad") : "") + (d.manual ? chip("Manual", "warn") : "");
}

// ---------------------------------------------------------------- incident flow
// the panel follows the newest incident; a click pins one for 30 s
function upsertEvent(ev) {
  const isNew = !S.events.has(ev.id);
  S.events.set(ev.id, ev);
  const pinned = S.pinnedUntil && Date.now() < S.pinnedUntil;
  if (isNew && !pinned) S.selected = ev.id;
  renderFlow(); renderMapDynamic();
}
$("#flowWho").addEventListener("click", (e) => { if (e.target.id === "followLatest") { e.preventDefault(); S.pinnedUntil = 0; S.selected = [...S.events.values()].sort((a, b) => b.ts - a.ts)[0]?.id; renderFlow(); } });
const STEP_TXT = {
  person: "Person seen, alarm armed", motion: "Movement, alarm armed",
  intrusion: "Person in the restricted zone", abandoned_object: "Object left in the zone", manual: "Manual event",
  patrol_finding: "Found on patrol",
};
function renderFlow() {
  const evs = [...S.events.values()].sort((a, b) => b.ts - a.ts);
  const ev = S.events.get(S.selected) || evs[0];
  if (!ev) {
    $("#flow").innerHTML = `<div class="empty">No events yet. Stage a scene or point a camera at the restricted zone.</div>`;
    $("#flowWho").textContent = ""; return;
  }
  const t = ev.timings || {}; const a = ev.assessment; const v = ev.verification; const al = ev.alert;
  const cam = (S.site?.cameras || []).find((c) => c.id === ev.camera);
  const newest = evs[0];
  const behind = newest && newest.id !== ev.id;
  $("#flowWho").innerHTML = `${ev.id} · ${hms(ev.ts)}` + (behind ? ` · <a href="#" id="followLatest">show latest</a>` : "");
  const st = (key, cls) => (t[key] != null ? "done" : cls || "");
  const time = (key) => (t[key] != null ? `+${t[key].toFixed(1)} s` : "");
  const dismissed = ev.status === "dismissed"; const cleared = ev.status === "cleared"; const cancelled = ev.status === "cancelled";
  const steps = [
    { c: "done", b: `${STEP_TXT[ev.kind] || ev.kind}`, p: `${esc(cam ? cam.name : ev.camera)} · detector ${Math.round((ev.score || 0) * 100)}%${ev.duplicates ? ` · seen ${ev.duplicates + 1}×` : ""}`, tm: "0.0 s" },
    { c: a ? (a.dispatch ? "done" : "bad") : "now", b: a ? `Grok: ${a.verdict?.replace("_", " ")} · severity ${a.severity}` : "Grok is looking at the snapshot",
      p: a ? esc(a.reason) + (a.by === "rules" ? " (fallback rules)" : "") : "", tm: time("assessed") },
    { c: dismissed ? "skip" : st("dispatched", a ? "now" : ""), b: dismissed ? "Dog not sent (or recalled)" : "Dog dispatched",
      p: dismissed ? "Filtered before anyone was bothered" : (a?.check_for ? "Look for: " + esc(a.check_for) : "Moving while Grok assesses"), tm: time("dispatched") },
    { c: dismissed ? "skip" : st("arrived", t.dispatched != null ? "now" : ""), b: "Dog on the spot",
      p: t.arrived != null ? `${(t.arrived).toFixed(1)} s from the event` : "", tm: time("arrived") },
    { c: dismissed ? "skip" : st("verified", t.arrived != null ? "now" : ""), b: v ? `Seen on site: ${v.confirmed === true ? "confirmed" : v.confirmed === false ? "nothing wrong" : "unclear"} · risk ${v.risk}` : "Grok describes what the dog frames",
      p: v ? esc(v.description) : "", tm: time("verified") },
    { c: dismissed || cleared || cancelled ? "skip" : st("alerted", t.verified != null ? "now" : ""),
      b: al ? `Alert: ${esc(al.title)}` : cleared ? "No alert: false alarm" : dismissed ? "No alert" : cancelled ? "Check not completed: mission cancelled" : "Alert",
      p: al ? esc(al.sms) + "<br>" + (ev.alert_results || []).map((r) => `${r.channel} ${r.ok ? "✓" : "✗"}`).join(" · ") : "", tm: time("alerted") },
  ];
  const img = ev.images || {};
  const shots = [img.camera && `<figure><img src="${img.camera}" alt=""><figcaption>Camera snapshot</figcaption></figure>`,
    (img.dog || img.check) && `<figure><img src="${img.dog || img.check}" alt=""><figcaption>${img.dog ? "Dog camera on arrival" : "Fresh frame on arrival"}</figcaption></figure>`]
    .filter(Boolean).join("");
  $("#flow").innerHTML = `<ol class="steps">${steps.map((s) => `<li class="step ${s.c}"><span class="ic"></span><div><b>${s.b}</b>${s.p ? `<p>${s.p}</p>` : ""}</div><time>${s.tm}</time></li>`).join("")}</ol>
    ${shots ? `<div class="shots">${shots}</div>` : ""}
    <div class="evlist">${evs.slice(0, 30).map((e) => `<div class="ev ${e.id === ev.id ? "sel" : ""}" data-id="${e.id}"><time>${hms(e.ts)}</time><span>${esc((S.site?.cameras || []).find((c) => c.id === e.camera)?.name || e.camera)} · ${esc(STEP_TXT[e.kind] || e.kind)}</span><span class="tag ${e.status}">${e.status}</span></div>`).join("")}</div>`;
}
$("#flow").addEventListener("click", (e) => {
  if (e.target.closest("#followLatest")) { S.pinnedUntil = 0; S.selected = [...S.events.values()].sort((a, b) => b.ts - a.ts)[0]?.id; renderFlow(); return; }
  const r = e.target.closest(".ev"); if (!r) return;
  S.selected = r.dataset.id; S.pinnedUntil = Date.now() + 30000; renderFlow();
});

function showAlert(m) {
  $("#alertTitle").textContent = m.alert?.title || "Alert";
  $("#alertBody").textContent = m.alert?.sms || "";
  $("#alertMeta").textContent = `${m.spot} · ${new Date().toLocaleTimeString()} · ${(m.results || []).map((r) => r.channel + (r.ok ? " sent" : " failed")).join(", ")}`;
  $("#alertImg").src = m.image || ""; $("#alertImg").hidden = !m.image;
  $("#alertBanner").hidden = false;
  try { const c = new AudioContext(); const o = c.createOscillator(); o.frequency.value = 880; o.connect(c.destination); o.start(); setTimeout(() => { o.frequency.value = 660; }, 180); setTimeout(() => o.stop(), 420); } catch {}
}
$("#alertClose").onclick = () => { $("#alertBanner").hidden = true; };

// ---------------------------------------------------------------- map
let MB = null;
function buildStatic() {
  const s = S.site; if (!s) return;
  const pad = 0.75;
  if (s.plan) {
    const [bx0, by0, bx1, by1] = s.plan.bounds;
    MB = { x0: bx0 - pad, x1: bx1 + pad, y0: by0 - pad, y1: by1 + pad };
  } else {
    const xs = s.rooms.flatMap((r) => [r.x, r.x + r.w]); const ys = s.rooms.flatMap((r) => [r.y, r.y + r.h]);
    MB = { x0: Math.min(...xs) - pad, x1: Math.max(...xs) + pad, y0: Math.min(...ys) - pad, y1: Math.max(...ys) + pad };
  }
  const svg = $("#map");
  svg.setAttribute("viewBox", `${MB.x0} ${-MB.y1} ${MB.x1 - MB.x0} ${MB.y1 - MB.y0}`);
  const spot = (id) => s.spots.find((p) => p.id === id);
  let h = "";
  if (s.plan) {
    // the real room: walls and pillars cut at the dog's height, from the CAD model
    h += `<rect x="${s.plan.bounds[0]}" y="${-s.plan.bounds[3]}" width="${s.plan.bounds[2] - s.plan.bounds[0]}" height="${s.plan.bounds[3] - s.plan.bounds[1]}" fill="#15171c"/>`;
    for (const poly of s.plan.solids) h += `<polygon points="${poly.map(([x, y]) => `${x},${-y}`).join(" ")}" fill="#4a4e57" stroke="#5d626b" stroke-width="0.02"/>`;
    for (const e of s.exhibits || []) {
      const c = Math.cos(e.yaw || 0), sn = Math.sin(e.yaw || 0), hw = e.w / 2, hd = e.d / 2;
      const pts = [[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]].map(([a, b]) => `${e.x + c * a - sn * b},${-(e.y + sn * a + c * b)}`).join(" ");
      h += `<polygon points="${pts}" fill="#3a2e24" stroke="#6b5440" stroke-width="0.03"/>`;
    }
    h += `<text x="${s.plan.bounds[0] + 0.2}" y="${-s.plan.bounds[3] - 0.2}" style="font-size:.4px;fill:#8b9099">${esc(s.name || "")} · ${esc(s.plan.source || "")}</text>`;
  } else {
    for (const r of s.rooms) h += `<rect x="${r.x}" y="${-(r.y + r.h)}" width="${r.w}" height="${r.h}" fill="#15171c" stroke="#30333b" stroke-width="0.06"/>
      <text x="${r.x + r.w / 2}" y="${-(r.y + r.h) - 0.18}" text-anchor="middle" style="font-size:.34px;fill:#8b9099">${esc(r.name)}</text>`;
  }
  for (const d of s.doors || []) h += `<circle cx="${d.x}" cy="${-d.y}" r="0.28" fill="#0d0e11"/>`;
  for (const c of s.cameras) {
    if (c.zone_world) { const [a, b, e, f] = c.zone_world; h += `<rect x="${a}" y="${-f}" width="${e - a}" height="${f - b}" fill="rgba(255,59,48,.07)" stroke="#ff3b30" stroke-width="0.04" stroke-dasharray="0.15 0.1"/>`; }
    const look = c.look || [spot(c.inspect_spot)?.x, spot(c.inspect_spot)?.y];
    if (look[0] != null) {
      const ang = Math.atan2(look[1] - c.y, look[0] - c.x); const L = Math.hypot(look[1] - c.y, look[0] - c.x) * 0.9; const f = 0.32;
      h += `<path d="M${c.x} ${-c.y} L${c.x + L * Math.cos(ang - f)} ${-(c.y + L * Math.sin(ang - f))} L${c.x + L * Math.cos(ang + f)} ${-(c.y + L * Math.sin(ang + f))} Z" fill="rgba(79,140,255,.045)" stroke="rgba(79,140,255,.16)" stroke-width="0.02"/>`;
    }
    h += `<rect x="${c.x - 0.16}" y="${-c.y - 0.16}" width="0.32" height="0.32" rx="0.06" fill="#4f8cff"/><text x="${c.x + 0.25}" y="${-c.y + 0.12}" style="font-size:.3px;fill:#a9c4ff">${esc(c.id)}</text>`;
  }
  for (const p of s.spots) h += `<g class="spot" data-id="${p.id}" style="cursor:pointer"><circle cx="${p.x}" cy="${-p.y}" r="0.16" fill="#1c1f26" stroke="#8b9099" stroke-width="0.04"/><text x="${p.x}" y="${-p.y + 0.5}" text-anchor="middle" style="font-size:.28px;fill:#8b9099">${esc(p.id)}</text><title>${esc(p.name)}: click to send the dog</title></g>`;
  svg.innerHTML = `<g>${h}</g><g id="dyn"></g>`;
  // selectors
  $("#routeSel").innerHTML = s.routes.map((r) => `<option value="${r.id}">${esc(r.name)}</option>`).join("");
  $("#stageCam").innerHTML = s.cameras.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join("");
  renderViewTabs(); renderMapDynamic();
}
$("#map").addEventListener("click", async (e) => {
  const g = e.target.closest(".spot"); if (!g) return;
  const p = S.site.spots.find((x) => x.id === g.dataset.id);
  if (await ask(`Send the dog to check ${p.name}?`, "Send the dog")) await cmd("send", { spot: p.id });
});
function renderMapDynamic() {
  const dyn = document.getElementById("dyn"); if (!dyn || !S.site || !S.dog) return;
  const s = S.site; const d = S.dog; let h = "";
  const spot = (id) => s.spots.find((p) => p.id === id);
  const patrol = [S.current, ...S.queue].find((m) => m && m.kind === "patrol");
  if (patrol) {
    const pts = patrol.stops.map(spot).filter(Boolean);
    if (pts.length > 1) h += `<polygon points="${pts.map((p) => `${p.x},${-p.y}`).join(" ")}" fill="none" stroke="#4f8cff" stroke-opacity=".35" stroke-width="0.05" stroke-dasharray="0.2 0.14"/>`;
  }
  const open = [...S.events.values()].filter((e) => ["received", "assessing", "dispatched", "verifying"].includes(e.status));
  for (const e of open) {
    const c = s.cameras.find((x) => x.id === e.camera); const p = c && spot(c.inspect_spot); if (!p) continue;
    h += `<circle cx="${p.x}" cy="${-p.y}" r="0.3" fill="none" stroke="#ff3b30" stroke-width="0.06"><animate attributeName="r" values="0.25;0.8;0.25" dur="1.4s" repeatCount="indefinite"/><animate attributeName="opacity" values="1;0.2;1" dur="1.4s" repeatCount="indefinite"/></circle>`;
  }
  for (const a of S.sim.actors || []) {
    const col = a.id === "staff" ? "#ffd60a" : a.kind === "bag" ? "#b0703a" : a.id === "intruder" ? "#ff9f43" : "#c9ccd1";
    h += a.kind === "bag" ? `<rect x="${a.x - 0.15}" y="${-a.y - 0.15}" width="0.3" height="0.3" fill="${col}"/>` : `<circle cx="${a.x}" cy="${-a.y}" r="0.2" fill="${col}"/>`;
  }
  if (S.current && S.current.path && S.current.path.length) {
    h += `<polyline points="${[[d.x, d.y], ...S.current.path].map((p) => `${p[0]},${-p[1]}`).join(" ")}" fill="none" stroke="#3ccf8e" stroke-width="0.05" stroke-dasharray="0.12 0.1"/>`;
  }
  const deg = -(d.yaw * 180) / Math.PI;
  h += `<g transform="translate(${d.x} ${-d.y}) rotate(${deg})"><path d="M0.38 0 L-0.25 0.22 L-0.16 0 L-0.25 -0.22 Z" fill="${d.armed === false ? "#ff3b30" : "#3ccf8e"}" stroke="#0b0c0e" stroke-width="0.03"/></g>`;
  dyn.innerHTML = h;
  $("#mapInfo").textContent = `dog at ${d.x.toFixed(2)}, ${d.y.toFixed(2)} m`;
}

// ---------------------------------------------------------------- cameras
function renderCams() {
  const list = S.cameras.filter((c) => c.id !== "sim-view");
  const grid = $("#camGrid");
  for (const c of list) {
    let el = grid.querySelector(`[data-cam="${c.id}"]`);
    if (!el) {
      el = document.createElement("div"); el.className = "cam"; el.dataset.cam = c.id;
      el.innerHTML = `<img alt=""><div class="lbl"><span class="n"></span><span class="s"></span></div>`;
      grid.appendChild(el);
    }
    el.classList.toggle("off", !c.online);
    const open = [...S.events.values()].some((e) => e.camera === c.id && ["received", "assessing", "dispatched", "verifying"].includes(e.status));
    el.classList.toggle("hit", open);
    el.querySelector(".n").textContent = c.name;
    el.querySelector(".s").textContent = (c.online ? (c.info?.detector === "simulated" ? "sim" : (c.info?.fps ? c.info.fps + " fps" : "live")) : "offline") + (c.calib_m != null ? (typeof c.calib_m === "number" ? ` · calibrated ±${Math.round(c.calib_m * 100)} cm` : " · calibrated") : "");
    if (c.online && c.preview_ts) el.querySelector("img").src = `/api/cameras/${c.id}/preview.jpg?t=${Math.floor(c.preview_ts)}`;
  }
}

// ---------------------------------------------------------------- calibration
const CAL = { cam: null, pairs: [], pImg: null, pMap: null, solved: null, mode: "pair", test: null, aspect: 4 / 3, snapped: false };
const applyH = (H, a, b) => { const x = H[0][0] * a + H[0][1] * b + H[0][2], y = H[1][0] * a + H[1][1] * b + H[1][2], w = H[2][0] * a + H[2][1] * b + H[2][2]; return Math.abs(w) < 1e-9 ? null : [x / w, y / w, w]; };
function calSign() { const p = CAL.pairs[0]; if (!CAL.solved?.Hinv || !p) return 1; const q = applyH(CAL.solved.Hinv, p.x, p.y); return q ? Math.sign(q[2]) : 1; }
function floorToImg(x, y, sign) {
  const H = CAL.solved?.Hinv; if (!H) return null;
  const q = applyH(H, x, y); if (!q || Math.sign(q[2]) !== sign) return null;
  return q[0] < -1 || q[0] > 2 || q[1] < -1 || q[1] > 2 ? null : [q[0], q[1]];
}
function calHint() {
  const n = CAL.pairs.length;
  let t;
  if (CAL.mode === "test") t = CAL.solved?.ok ? "Test: tap anywhere on the floor in the image, the point appears on the map." : "Add at least 4 pairs first.";
  else if (CAL.pImg && !CAL.pMap) t = `Pair ${n + 1}: now tap the same point on the map (corners of walls and pillars snap), or press Use dog position.`;
  else if (CAL.pMap && !CAL.pImg) t = `Pair ${n + 1}: now tap that point on the floor in the image.`;
  else t = n < 4 ? `Pair ${n + 1} of at least 4: tap a point on the floor in the image. Corners of pillars and walls at floor level work best. Spread them: near, left, right, middle distance. Avoid points far away near the horizon, where one pixel is many centimeters.`
    : n < 6 ? `${n} pairs. Add ${6 - n} more to measure the accuracy, or save.` : `${n} pairs. Save, or check with Test.`;
  $("#calHint").textContent = t;
}
function calDraw() {
  const box = $("#calImgBox"), cv = $("#calCanvas"), dpr = devicePixelRatio || 1;
  const W = box.clientWidth, H = box.clientHeight; cv.width = W * dpr; cv.height = H * dpr;
  const c = cv.getContext("2d"); c.scale(dpr, dpr); c.lineWidth = 1.5; c.font = "12px sans-serif";
  const sign = calSign();
  if ($("#calOverlay").checked && CAL.solved?.ok && S.site) {
    const poly = (pts, color, close = true) => {
      c.strokeStyle = color; c.beginPath(); let on = false;
      const list = close ? [...pts, pts[0]] : pts;
      for (const [x, y] of list) { const q = floorToImg(x, y, sign); if (!q) { on = false; continue; } const px = q[0] * W, py = q[1] * H; on ? c.lineTo(px, py) : c.moveTo(px, py); on = true; }
      c.stroke();
    };
    for (const p of S.site.plan?.solids || []) poly(p, "rgba(90,200,255,.85)");
    for (const cam of S.site.cameras) if (cam.zone_world) { const [a, b, e, f] = cam.zone_world; poly([[a, b], [e, b], [e, f], [a, f]], "rgba(255,80,70,.9)"); }
    // a 1 m grid on the floor
    const bd = S.site.plan?.bounds;
    if (bd) for (let x = Math.ceil(bd[0]); x <= bd[2]; x++) poly(Array.from({ length: 41 }, (_, i) => [x, bd[1] + (bd[3] - bd[1]) * i / 40]), "rgba(255,255,255,.08)", false);
    if (bd) for (let y = Math.ceil(bd[1]); y <= bd[3]; y++) poly(Array.from({ length: 41 }, (_, i) => [bd[0] + (bd[2] - bd[0]) * i / 40, y]), "rgba(255,255,255,.08)", false);
    for (const sp of S.site.spots) { const q = floorToImg(sp.x, sp.y, sign); if (q) { c.fillStyle = "#a9c4ff"; c.beginPath(); c.arc(q[0] * W, q[1] * H, 3, 0, 7); c.fill(); c.fillText(sp.id, q[0] * W + 5, q[1] * H - 4); } }
  }
  CAL.pairs.forEach((p, i) => {
    const e = CAL.solved?.errors_m?.[i];
    c.strokeStyle = c.fillStyle = e == null ? "#ffd60a" : e < 0.2 ? "#3ccf8e" : e < 0.5 ? "#f2b33d" : "#ff5a52";
    c.beginPath(); c.arc(p.u * W, p.v * H, 7, 0, 7); c.stroke(); c.fillText(String(i + 1), p.u * W + 9, p.v * H - 7);
  });
  if (CAL.pImg) { c.strokeStyle = "#fff"; c.beginPath(); c.arc(CAL.pImg[0] * W, CAL.pImg[1] * H, 9, 0, 7); c.stroke(); }
  if (CAL.test) { c.strokeStyle = "#ff4fd8"; c.lineWidth = 2; const x = CAL.test[0] * W, y = CAL.test[1] * H; c.beginPath(); c.moveTo(x - 9, y); c.lineTo(x + 9, y); c.moveTo(x, y - 9); c.lineTo(x, y + 9); c.stroke(); }
  // map layer
  let m = "";
  CAL.pairs.forEach((p, i) => { m += `<circle cx="${p.x}" cy="${-p.y}" r="0.22" fill="none" stroke="#ffd60a" stroke-width="0.06"/><text x="${p.x + 0.3}" y="${-p.y - 0.2}" style="font-size:.4px;fill:#ffd60a">${i + 1}</text>`; });
  if (CAL.pMap) m += `<circle cx="${CAL.pMap[0]}" cy="${-CAL.pMap[1]}" r="0.3" fill="none" stroke="#fff" stroke-width="0.06"/>`;
  if (CAL.test && CAL.solved?.H) { const q = applyH(CAL.solved.H, CAL.test[0], CAL.test[1]); if (q) m += `<path d="M${q[0] - 0.35} ${-q[1]}h0.7M${q[0]} ${-q[1] - 0.35}v0.7" stroke="#ff4fd8" stroke-width="0.09"/><text x="${q[0] + 0.4}" y="${-q[1] - 0.3}" style="font-size:.4px;fill:#ff4fd8">${q[0].toFixed(2)}, ${q[1].toFixed(2)} m</text>`; }
  if (S.dog) m += `<g transform="translate(${S.dog.x} ${-S.dog.y}) rotate(${-(S.dog.yaw * 180) / Math.PI})"><path d="M0.38 0 L-0.25 0.22 L-0.16 0 L-0.25 -0.22 Z" fill="#3ccf8e"/></g>`;
  const cam = S.site?.cameras.find((x) => x.id === CAL.cam);
  if (cam) m += `<rect x="${cam.x - 0.2}" y="${-cam.y - 0.2}" width="0.4" height="0.4" fill="#4f8cff"/>`;
  document.getElementById("calDyn").innerHTML = m;
  const t = CAL.pairs.map((p, i) => { const e = CAL.solved?.errors_m?.[i]; return `<span data-i="${i}" class="${e == null ? "" : e < 0.2 ? "ok" : e >= 0.5 ? "bad" : ""}" title="Click to remove">${i + 1} · ${p.x.toFixed(2)}, ${p.y.toFixed(2)} m${e != null ? ` · ${(e * 100).toFixed(0)} cm` : ""}</span>`; });
  $("#calTable").innerHTML = t.join("") || `<span class="muted">No pairs yet</span>`;
  const sv = CAL.solved;
  $("#calStatus").textContent = !sv ? "" : !sv.ok ? sv.error : `${sv.n} pairs${sv.rms_m != null && sv.n > 4 ? ` · average error ${(sv.rms_m * 100).toFixed(0)} cm` : ""}${sv.warnings?.length ? " · " + sv.warnings.join("; ") : ""}`;
  calHint();
}
async function calSolve() {
  CAL.solved = CAL.pairs.length >= 4 ? await api("/api/calib/solve", { points: CAL.pairs }) : null;
  calDraw();
}
function calPair() {
  if (!CAL.pImg || !CAL.pMap) { calDraw(); return; }
  CAL.pairs.push({ u: +CAL.pImg[0].toFixed(4), v: +CAL.pImg[1].toFixed(4), x: +CAL.pMap[0].toFixed(3), y: +CAL.pMap[1].toFixed(3) });
  CAL.pImg = CAL.pMap = null; calSolve();
}
async function calLoad(cid) {
  CAL.cam = cid; CAL.pImg = CAL.pMap = CAL.test = null;
  const all = await api("/api/calib"); CAL.pairs = (all[cid]?.points || []).slice();
  calFrame(); calSolve();
}
function calFrame() {
  const img = $("#calImg");
  img.onload = () => { CAL.aspect = img.naturalWidth / img.naturalHeight; calDraw(); };
  img.src = `/api/cameras/${CAL.cam}/frame.jpg?t=${Date.now()}`;
}
$("#btnCalib").onclick = () => {
  const fixed = (S.site?.cameras || []);
  $("#calCam").innerHTML = fixed.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join("");
  const svg = $("#calMap"); svg.setAttribute("viewBox", $("#map").getAttribute("viewBox"));
  svg.innerHTML = `<g>${$("#map").firstElementChild.innerHTML}</g><g id="calDyn"></g>`;
  $("#calDlg").showModal(); calLoad($("#calCam").value);
};
$("#calCam").onchange = (e) => calLoad(e.target.value);
$("#calRefresh").onclick = calFrame;
$("#calClose").onclick = () => $("#calDlg").close();
$("#calOverlay").onchange = calDraw;
$("#calMode").addEventListener("click", (e) => { const m = e.target.dataset.m; if (!m) return; CAL.mode = m; CAL.test = null; document.querySelectorAll("#calMode button").forEach((b) => b.classList.toggle("on", b.dataset.m === m)); calDraw(); });
$("#calImgBox").addEventListener("click", (e) => {
  const r = $("#calImgBox").getBoundingClientRect(); const uv = [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height];
  if (CAL.mode === "test") { CAL.test = uv; calDraw(); return; }
  CAL.pImg = uv; calPair();
});
$("#calMap").addEventListener("click", (e) => {
  if (e.target.closest(".spot")) e.stopPropagation();
  if (CAL.mode === "test") return;
  const svg = $("#calMap"); const pt = svg.createSVGPoint(); pt.x = e.clientX; pt.y = e.clientY;
  const p = pt.matrixTransform(svg.getScreenCTM().inverse()); let xy = [p.x, -p.y];
  // snap to the nearest corner of a wall or pillar from the CAD plan
  let best = null;
  for (const poly of S.site.plan?.solids || []) for (const [x, y] of poly) { const d = Math.hypot(x - xy[0], y - xy[1]); if (d < 0.35 && (!best || d < best[0])) best = [d, x, y]; }
  if (best && !e.altKey) xy = [best[1], best[2]];
  CAL.pMap = xy; calPair();
});
$("#calDog").onclick = () => { if (S.dog) { CAL.pMap = [S.dog.x, S.dog.y]; calPair(); } };
$("#calUndo").onclick = () => { if (CAL.pImg || CAL.pMap) { CAL.pImg = CAL.pMap = null; calDraw(); } else { CAL.pairs.pop(); calSolve(); } };
$("#calClear").onclick = () => { CAL.pairs = []; CAL.pImg = CAL.pMap = null; calSolve(); };
$("#calTable").addEventListener("click", (e) => { const i = e.target.dataset.i; if (i != null) { CAL.pairs.splice(+i, 1); calSolve(); } });
$("#calSave").onclick = async () => {
  const r = await api(`/api/calib/${CAL.cam}`, { points: CAL.pairs, aspect: CAL.aspect });
  $("#calStatus").textContent = r.ok ? `Saved · ${r.n} pairs${r.rms_m != null && r.n > 4 ? ` · average error ${(r.rms_m * 100).toFixed(0)} cm` : ""}` : (r.error || "Not saved");
};
$("#calDelete").onclick = async () => { await fetch(`/api/calib/${CAL.cam}`, { method: "DELETE" }); CAL.pairs = []; calSolve(); $("#calStatus").textContent = "Calibration removed"; };
addEventListener("resize", () => { if ($("#calDlg").open) calDraw(); });

// ---------------------------------------------------------------- phones: public address and QR codes
$("#btnPhones").onclick = async () => {
  const r = await api("/api/public");
  const lan = location.hostname === "localhost" ? "" : `${location.origin}/camera`;
  $("#phonesBody").innerHTML = r.url ? `
    <p class="muted small">Through the tunnel: works from any network, also when this Mac is on the dog's wifi.</p>
    <div class="phones-qr"><img src="/api/qr.png?data=${encodeURIComponent(r.camera + "?pin=" + r.pin)}" alt="QR code for the camera page">
      <div><b>Camera page</b><br><code>${esc(r.camera)}</code><br><span class="muted small">Scan it, choose the camera, Start camera.</span></div></div>
    <div class="phones-qr"><img src="/api/qr.png?data=${encodeURIComponent(r.url + "/?pin=" + r.pin)}" alt="QR code for the console">
      <div><b>Console on a phone</b><br><code>${esc(r.url)}</code><br><span class="muted small">PIN ${esc(r.pin)}. The QR codes include it.</span></div></div>
    <div class="phones-qr"><img src="/api/qr.png?data=${encodeURIComponent(r.url + "/controller?pin=" + r.pin)}" alt="QR code for the controller">
      <div><b>Controller</b><br><code>${esc(r.url)}/controller</code><br><span class="muted small">A joystick to drive the dog from a phone.</span></div></div>`
    : `<p>No public address yet. In a terminal, in the project folder, run <code>./public.sh</code>, then open this again.</p>
       <p class="muted small">On the same wifi as this Mac, phones can also use ${lan ? `<code>${esc(lan)}</code>` : "the https address printed by ./run.sh"}.</p>`;
  $("#phonesDlg").showModal();
};
$("#btnController").onclick = () => {
  const w = window.open("/controller", "ronda-controller", "width=420,height=780");
  if (!w) location.href = "/controller";
};
$("#phonesClose").onclick = () => $("#phonesDlg").close();

// ---------------------------------------------------------------- patrol + manual
function renderPatrol() {
  const m = S.current;
  $("#missionNow").textContent = m ? `${m.label} · ${m.status}${m.kind === "patrol" ? ` · stop ${m.idx + 1}/${m.stops.length}` : ""}` : "idle";
  const sched = Object.entries(S.schedules || {}).map(([r, v]) => `<div class="qi"><span>Scheduled: ${esc(S.site?.routes.find((x) => x.id === r)?.name || r)} every ${v.every_min} min</span><span class="muted">next in ${Math.max(0, v.next_in_s)} s</span></div>`);
  const q = (S.queue || []).map((x) => `<div class="qi"><span>${esc(x.label)}</span><span class="muted">${x.status} · p${x.priority}</span></div>`);
  $("#queue").innerHTML = [...sched, ...q].join("");
}
$("#btnPatrol").onclick = () => cmd("patrol", { route: $("#routeSel").value, loops: 0 });
$("#btnStopPatrol").onclick = () => cmd("stop_patrol");
$("#btnSchedule").onclick = () => cmd("schedule", { route: $("#routeSel").value, every_min: +$("#everyMin").value });
$("#btnHome").onclick = () => cmd("home");
$("#btnStop").onclick = () => cmd("stop");
$("#btnResetAll").onclick = async () => {
  const where = S.dog?.kind === "sim" ? "The dog goes back to its base." : "The real dog stops where it is.";
  if (!(await ask(`Reset everything?\n\nThe alarm is disarmed. Missions, patrol schedules, staged people and bags, incidents, counters and the chat are cleared. ${where}\nThe full log stays in the database.`, "Reset"))) return;
  await cmd("reset_all");
};
$("#btnEstop").onclick = async () => (S.dog?.armed === false ? ((await ask("Release the emergency stop? The dog can move again.", "Release")) && cmd("reset")) : cmd("estop"));
$("#btnReset").onclick = () => cmd("reset");
$("#btnZero").onclick = async () => (await ask("Set the dog's current position as its home spot?", "Set home")) && cmd("zero");
$("#btnLie").onclick = () => cmd("lie");
$("#btnStand").onclick = () => cmd("stand");
$("#btnTeach").onclick = async () => {
  const r = await cmd("teach", { id: $("#spotId").value, name: $("#spotName").value });
  if (r.ok) { $("#spotId").value = ""; $("#spotName").value = ""; }
};
let driveTimer = null;
function drive(v) {
  clearInterval(driveTimer);
  if (!v) return;
  const send = () => (S.ws?.readyState === 1 && S.mode === "live")
    ? S.ws.send(JSON.stringify({ type: "drive", vx: v[0], vy: v[1], wz: v[2] }))
    : api("/api/command", { action: "drive", vx: v[0], vy: v[1], wz: v[2] });
  send(); driveTimer = setInterval(send, 100);
}
document.querySelectorAll(".pad .key").forEach((b) => {
  const v = b.dataset.d.split(",").map(Number);
  b.addEventListener("pointerdown", (e) => { e.preventDefault(); b.setPointerCapture(e.pointerId); drive(v); });
  ["pointerup", "pointercancel", "lostpointercapture"].forEach((ev) => b.addEventListener(ev, () => drive(null)));
});
const KEYS = { w: [0.4, 0, 0], s: [-0.25, 0, 0], a: [0, 0, 0.8], d: [0, 0, -0.8], q: [0.3, 0, 0.6], e: [0.3, 0, -0.6] };
const held = new Set();
addEventListener("keydown", (e) => {
  if (/INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName) || !KEYS[e.key]) return;
  held.add(e.key); drive(KEYS[e.key]);
});
addEventListener("keyup", (e) => { held.delete(e.key); if (!held.size) drive(null); });

// ---------------------------------------------------------------- staging
document.querySelectorAll("[data-stage]").forEach((b) => b.addEventListener("click", () => cmd("stage", { scenario: b.dataset.stage, camera: $("#stageCam").value })));
$("#btnTestEvent").onclick = () => cmd("test_event", { camera: $("#stageCam").value, kind: "manual" });

// ---------------------------------------------------------------- chat
function addMsg(role, text, actions) {
  const el = document.createElement("div"); el.className = "msg " + role;
  el.innerHTML = esc(text) + (actions?.length ? `<div class="acts">${actions.map((a) => `<span>${esc(a.tool)}</span>`).join("")}</div>` : "");
  $("#msgs").appendChild(el); $("#msgs").scrollTop = 1e9; return el;
}
async function say(text, via = "text") {
  if (!text.trim()) return;
  addMsg("user", text);
  const pending = addMsg("assistant", "…");
  try {
    const r = await api("/api/chat", { message: text, via });
    pending.remove(); addMsg("assistant", r.reply || "(no reply)", r.actions);
    if ($("#speak").checked && "speechSynthesis" in window) {
      const u = new SpeechSynthesisUtterance(r.reply); u.lang = /[àèéìòù]|\b(il|la|che|sono|cane)\b/i.test(r.reply) ? "it-IT" : "en-US";
      speechSynthesis.cancel(); speechSynthesis.speak(u);
    }
  } catch (e) { pending.textContent = "Error: " + e; }
}
$("#chatForm").onsubmit = (e) => { e.preventDefault(); const v = $("#chatIn").value; $("#chatIn").value = ""; say(v); };
document.querySelectorAll("[data-say]").forEach((b) => b.addEventListener("click", () => say(b.dataset.say)));
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
let rec = null;
$("#btnMic").onclick = () => {
  if (!SR) { toast("Voice input is not available in this browser: use Chrome or Safari."); return; }
  if (rec) { rec.stop(); return; }
  rec = new SR(); rec.lang = navigator.language?.startsWith("it") ? "it-IT" : "en-US"; rec.interimResults = true;
  let finalText = "";
  rec.onresult = (e) => { finalText = [...e.results].map((r) => r[0].transcript).join(" "); $("#chatIn").value = finalText; };
  rec.onend = () => { $("#btnMic").classList.remove("on"); rec = null; if (finalText) { $("#chatIn").value = ""; say(finalText, "voice"); } };
  $("#btnMic").classList.add("on"); rec.start();
};

// ---------------------------------------------------------------- log
const LOG_MAX = 400;
function addLog(e, live) {
  if (e.id && e.id <= S.lastLogId) return;
  if (e.id) S.lastLogId = e.id;
  const f = S.filter;
  const el = document.createElement("div");
  el.className = `li ${e.level}`; el.dataset.kind = e.kind;
  el.innerHTML = `<time>${hms(e.ts)}</time><span class="k">${esc(e.kind)}</span><span>${esc(e.message)}</span>`;
  if (f && !e.kind.startsWith(f) && !(f === "alert" && e.level === "alert")) el.hidden = true;
  const box = $("#log"); box.prepend(el);
  while (box.children.length > LOG_MAX) box.lastChild.remove();
}
$("#logFilter").addEventListener("click", (e) => {
  const f = e.target.dataset.f; if (f === undefined) return;
  S.filter = f;
  document.querySelectorAll("#logFilter button").forEach((b) => b.classList.toggle("on", b.dataset.f === f));
  document.querySelectorAll("#log .li").forEach((el) => { el.hidden = !!f && !el.dataset.kind.startsWith(f) && !(f === "alert" && el.classList.contains("alert")); });
});

function md(src) {
  const lines = esc(src).split("\n"); let out = ""; let list = false; let table = [];
  const inline = (s) => s.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`(.+?)`/g, "<code>$1</code>");
  const flushTable = () => { if (!table.length) return; const rows = table.filter((r) => !/^\|\s*:?-/.test(r)).map((r) => r.split("|").slice(1, -1).map((c) => inline(c.trim())));
    out += `<table>${rows.map((r, i) => `<tr>${r.map((c) => (i ? `<td>${c}</td>` : `<th>${c}</th>`)).join("")}</tr>`).join("")}</table>`; table = []; };
  for (const l of lines) {
    if (l.trim().startsWith("|")) { table.push(l.trim()); continue; } else flushTable();
    if (/^\s*[-*] /.test(l)) { if (!list) { out += "<ul>"; list = true; } out += `<li>${inline(l.replace(/^\s*[-*] /, ""))}</li>`; continue; }
    if (list) { out += "</ul>"; list = false; }
    const m = l.match(/^(#{1,3}) (.*)/);
    if (m) out += `<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`; else if (l.trim()) out += `<p>${inline(l)}</p>`;
  }
  flushTable(); if (list) out += "</ul>"; return out;
}
$("#btnReport").onclick = async () => {
  $("#reportBody").innerHTML = `<p class="muted">Grok is writing the report…</p>`; $("#reportDlg").showModal();
  const r = await api("/api/report", {});
  $("#reportBody").innerHTML = md(r.markdown || "");
};
$("#btnShift").onclick = async () => {
  if (!(await ask("Start a new shift? Counters and the incident list are reset; the full log stays in the database.", "New shift"))) return;
  await cmd("new_shift"); location.reload();
};
$("#reportClose").onclick = () => $("#reportDlg").close();

// ---------------------------------------------------------------- boot
(async function boot() {
  const st = await api("/api/state");
  S.site = st.site; applyTick({ ...st });
  buildStatic();
  st.events.forEach((e) => S.events.set(e.id, e));
  S.selected = st.events.length ? st.events[st.events.length - 1].id : null;
  st.log.forEach((e) => addLog(e));
  (st.chat || []).forEach((c) => addMsg(c.role, c.text, c.actions));
  renderFlow(); renderStage(); renderCams();
  connect(); loopView(); setTimeout(pollLoop, 1500);
  setInterval(renderCams, 1000);
})();
