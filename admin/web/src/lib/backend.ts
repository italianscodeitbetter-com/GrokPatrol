"use client";

import { useSyncExternalStore } from "react";

// Collegamento al backend FastAPI (admin/backend): stato live del cane e delle telecamere.
// HTTP passa dai rewrites di next.config.ts (/api/* → BACKEND_URL); il WebSocket va diretto
// a NEXT_PUBLIC_BACKEND_WS. Qui arrivano anche missioni (in corso, in coda e finite), statistiche del turno,
// registro e allarme: le pagine li adattano alla UI in lib/missions.ts.

// ── tipi del contratto ────────────────────────────────
export type Posture = "standing" | "down" | "rising";

export type LiveDog = {
  kind: "sim" | "mujoco" | "go1";
  connected: boolean;
  /** false dopo un E-stop, finché non arriva `reset`. */
  armed: boolean;
  /** Posa nel frame del sito: metri e radianti. */
  x: number;
  y: number;
  yaw: number;
  target: [number, number, number | null] | null;
  moving: boolean;
  manual: boolean;
  posture: Posture;
  battery: number | null;
  odom: string;
  cmd: [number, number, number];
};

export type LiveCamera = {
  id: string;
  name: string;
  online: boolean;
  info: { fps?: number; people?: number; [k: string]: unknown };
  preview_ts: number;
  zone?: string | null;
  calib_m?: number | string | null;
  /** Chi sta guardando il video adesso, e a quanti fotogrammi al secondo arriva. */
  viewers?: number;
  stream_fps?: number;
};

export type SiteSpot = { id: string; name: string; room?: string; x: number; y: number; yaw?: number };
export type SiteCamera = {
  id: string;
  name: string;
  room?: string;
  x: number;
  y: number;
  z?: number;
  look?: [number, number, number];
  fovy?: number;
  /** Spot dove il cane va a controllare gli eventi di questa camera. */
  inspect_spot?: string;
};
export type SiteRoom = { id: string; name: string; x: number; y: number; w: number; h: number };
export type Site = { name: string; home: string; spots: SiteSpot[]; cameras: SiteCamera[]; rooms: SiteRoom[] };

export type Limits = { vmax: number; wmax: number };
/** Una riga del registro: logbook.py `Logbook.add`. */
export type LogEntry = {
  id: number | string;
  ts: number;
  kind: string;
  message: string;
  level: string;
  event_id?: string | null;
  mission_id?: string | null;
  data?: Record<string, unknown> | null;
};

export type ServerMissionStatus = "queued" | "active" | "paused" | "verifying" | "done" | "cancelled";

/** Una missione del cane: `Mission.public()` di admin/backend/app/mission.py. */
export type ServerMission = {
  id: string;
  /** patrol | inspect | goto | home */
  kind: string;
  /** Id degli spot da visitare, nell'ordine. */
  stops: string[];
  /** 0 ronda, 1 comandi dell'operatore, 2-5 eventi per gravità. */
  priority: number;
  label: string;
  loops: number;
  loop_count: number;
  idx: number;
  event_ids: string[];
  status: ServerMissionStatus;
  phase: string;
  path: [number, number][];
  speculative: boolean;
  route_id: string | null;
  /** Secondi dall'epoch. */
  created: number;
  started: number | null;
  ended: number | null;
  note: string;
};

/** Contatori del turno: `Manager.stats()`. */
export type ShiftStats = {
  events: number;
  dispatched: number;
  patrol_findings: number;
  filtered: number;
  confirmed: number;
  cleared: number;
  alerts: number;
  avg_arrival_s: number | null;
  best_arrival_s: number | null;
  open: number;
};

/** L'allarme: `Manager.alarm_state()`. */
export type Alarm = { armed: boolean; active: boolean; exit_delay_s: number; since: number | null; by: string | null; suppressed: number };

export type ServerEventStatus = "received" | "assessing" | "dispatched" | "verifying" | "cleared" | "dismissed" | "alerted" | "cancelled";

/** Valutazione di Grok (o delle regole, se Grok non c'è): server/grok.py `assess`. */
export type Assessment = {
  by?: string;
  verdict?: "threat" | "suspicious" | "false_alarm" | string;
  category?: string;
  severity?: number;
  confidence?: number;
  dispatch?: boolean;
  reason?: string;
  check_for?: string;
};

/** Cosa ha visto il cane sul posto: server/grok.py `verify`. */
export type Verification = {
  by?: string;
  confirmed?: boolean | null;
  description?: string;
  people?: number | null;
  objects?: string[];
  risk?: string;
  action?: string;
  source?: string;
};

/** Un evento delle telecamere: `Event.public()` di server/mission.py. */
export type ServerEvent = {
  id: string;
  /** Secondi dall'epoch. */
  ts: number;
  camera: string;
  kind: string;
  score: number;
  detections: unknown[];
  note: string;
  status: ServerEventStatus;
  assessment: Assessment | null;
  verification: Verification | null;
  alert: { title?: string; sms?: string; voice?: string; by?: string } | null;
  alert_results: unknown;
  mission_id: string | null;
  images: Record<string, string>;
  timings: Record<string, number>;
  duplicates: number;
};

export type Live = {
  dog: LiveDog | null;
  cameras: LiveCamera[];
  site: Site | null;
  limits: Limits;
  /** Registro del turno, dal più vecchio al più recente (al massimo LOG_MAX righe). */
  log: LogEntry[];
  /** Eventi delle telecamere, dal più vecchio al più recente ([] se il backend non li manda). */
  events: ServerEvent[];
  /** La missione che il cane sta facendo adesso. */
  current: ServerMission | null;
  /** Missioni in attesa (anche quelle messe in pausa da una più urgente). */
  queue: ServerMission[];
  /** Missioni uscite da corrente/coda mentre la console era aperta, dalla più recente. Quelle più vecchie
   *  si ricostruiscono dal registro (lib/missions.ts). */
  history: ServerMission[];
  stats: ShiftStats | null;
  alarm: Alarm | null;
  /** Inizio del turno (secondi dall'epoch): cambia con Reset e New shift. */
  shift: number | null;
  /** WebSocket aperto o ultimo /api/state riuscito. */
  backendOnline: boolean;
  /** true dopo la prima risposta (o il primo errore) di /api/state: prima non si sa ancora se il backend c'è. */
  ready: boolean;
};

const DEFAULT_LIMITS: Limits = { vmax: 0.5, wmax: 1.0 };

// ── store condiviso (un solo WebSocket per tutta l'app) ──
const OFFLINE: Live = {
  dog: null,
  cameras: [],
  site: null,
  limits: DEFAULT_LIMITS,
  log: [],
  events: [],
  current: null,
  queue: [],
  history: [],
  stats: null,
  alarm: null,
  shift: null,
  backendOnline: false,
  ready: false,
};
const LOG_MAX = 2000;
let live: Live = OFFLINE;
const listeners = new Set<() => void>();
const set = (patch: Partial<Live>) => {
  live = { ...live, ...patch };
  listeners.forEach((l) => l());
};

let ws: WebSocket | null = null;
let wsOpen = false;
let started = false;
let retry: ReturnType<typeof setTimeout> | undefined;
let poll: ReturnType<typeof setInterval> | undefined;

function wsUrl() {
  const env = process.env.NEXT_PUBLIC_BACKEND_WS;
  if (env) return env;
  // stesso host della pagina (localhost in sviluppo), porta del backend
  const proto = location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${location.hostname || "localhost"}:8000/ws/console`;
}

/** Unisce righe del registro per id (le stesse righe arrivano da /api/state, /api/log.json e dal WebSocket). */
function mergeLog(a: LogEntry[], b: LogEntry[]): LogEntry[] {
  if (!b.length) return a;
  const byId = new Map(a.map((e) => [String(e.id), e]));
  for (const e of b) byId.set(String(e.id), e);
  return [...byId.values()].sort((x, y) => x.ts - y.ts || Number(x.id) - Number(y.id)).slice(-LOG_MAX);
}

type Tick = { current?: ServerMission | null; queue?: ServerMission[]; stats?: ShiftStats; alarm?: Alarm; shift?: number };

/** Missioni corrente e in coda; quelle che spariscono da entrambe sono finite e vanno nella storia. */
function missionsPatch(current: ServerMission | null, queue: ServerMission[]): Partial<Live> {
  const now = new Set([current?.id, ...queue.map((m) => m.id)]);
  const gone = [live.current, ...live.queue].filter((m): m is ServerMission => !!m && !now.has(m.id));
  if (!gone.length) return { current, queue };
  const done = new Set(gone.map((m) => m.id));
  const ended = gone.map((m) => {
    // il messaggio con lo stato finale non arriva: lo dice il registro (mission.done / mission.cancelled)
    const last = [...live.log].reverse().find((e) => e.mission_id === m.id && (e.kind === "mission.done" || e.kind === "mission.cancelled"));
    return { ...m, status: last?.kind === "mission.cancelled" ? "cancelled" : "done", ended: m.ended ?? last?.ts ?? Date.now() / 1000 } as ServerMission;
  });
  return { current, queue, history: [...ended, ...live.history.filter((m) => !done.has(m.id))] };
}

/** Nuovo turno (Reset o New shift): via la storia del turno precedente, si riparte da /api/state. */
function newShift(shift: number) {
  set({ shift, log: [], events: [], history: [] });
  void fetchState();
}

function applyTick(t: Tick) {
  if (typeof t.shift === "number" && live.shift != null && t.shift !== live.shift) return newShift(t.shift);
  set({
    ...("current" in t || t.queue ? missionsPatch(t.current ?? null, Array.isArray(t.queue) ? t.queue : []) : {}),
    ...(t.stats ? { stats: t.stats } : {}),
    ...(t.alarm ? { alarm: t.alarm } : {}),
    ...(typeof t.shift === "number" ? { shift: t.shift } : {}),
  });
}

/** Tutto il registro del turno (lo stato ne porta solo le ultime 300 righe): una volta per turno. */
let logShift: number | null = null;
async function fetchShiftLog(shift: number) {
  if (logShift === shift) return;
  logShift = shift;
  try {
    const r = await fetch(`/api/log.json?since=${shift}`, { cache: "no-store" });
    if (!r.ok) throw new Error(String(r.status));
    const rows = (await r.json()) as LogEntry[];
    if (Array.isArray(rows) && live.shift === shift) set({ log: mergeLog(live.log, rows) });
  } catch {
    logShift = null;
  }
}

async function fetchState() {
  try {
    const r = await fetch("/api/state", { cache: "no-store" });
    if (!r.ok) throw new Error(String(r.status));
    const s = (await r.json()) as Partial<Live> & Tick & { log?: LogEntry[]; events?: ServerEvent[] };
    if (typeof s.shift === "number" && live.shift != null && s.shift !== live.shift) set({ log: [], events: [], history: [], current: null, queue: [] });
    set({
      dog: s.dog ?? null,
      cameras: s.cameras ?? [],
      site: s.site ?? live.site,
      limits: s.limits ?? live.limits,
      log: Array.isArray(s.log) ? mergeLog(live.log, s.log) : live.log,
      // il backend lean di admin/backend non ha eventi: lista vuota
      events: Array.isArray(s.events) ? [...s.events].sort((a, b) => a.ts - b.ts) : [],
      ...missionsPatch(s.current ?? null, Array.isArray(s.queue) ? s.queue : []),
      stats: s.stats ?? live.stats,
      alarm: s.alarm ?? live.alarm,
      shift: typeof s.shift === "number" ? s.shift : live.shift,
      backendOnline: true,
      ready: true,
    });
    if (typeof s.shift === "number") void fetchShiftLog(s.shift);
  } catch {
    if (!wsOpen) set({ backendOnline: false, ready: true, dog: live.dog && { ...live.dog, connected: false, moving: false } });
  }
}

function startPolling() {
  if (poll) return;
  poll = setInterval(fetchState, 1000);
}
function stopPolling() {
  clearInterval(poll);
  poll = undefined;
}

function connect() {
  clearTimeout(retry);
  let sock: WebSocket;
  try {
    sock = new WebSocket(wsUrl());
  } catch {
    retry = setTimeout(connect, 2000);
    return;
  }
  ws = sock;
  sock.onopen = () => {
    wsOpen = true;
    stopPolling();
    set({ backendOnline: true });
    // il tick non porta il sito né il log: li prendiamo una volta
    fetchState();
  };
  sock.onmessage = (e) => {
    let m: { type?: string; [k: string]: unknown };
    try {
      m = JSON.parse(String(e.data));
    } catch {
      return;
    }
    if (m.type === "tick") {
      set({
        dog: (m.dog as LiveDog) ?? null,
        cameras: (m.cameras as LiveCamera[]) ?? live.cameras,
        limits: (m.limits as Limits) ?? live.limits,
        backendOnline: true,
      });
      applyTick(m as Tick);
    } else if (m.type === "missions") applyTick({ current: (m.current as ServerMission | null) ?? null, queue: (m.queue as ServerMission[]) ?? [] });
    else if (m.type === "alarm") {
      const { type: _type, ...alarm } = m;
      void _type;
      set({ alarm: alarm as Alarm });
    } else if (m.type === "log" && m.entry) set({ log: mergeLog(live.log, [m.entry as LogEntry]) });
    else if (m.type === "event" && m.event) {
      // nuovo evento o cambio di stato: sostituisce quello con lo stesso id
      const ev = m.event as ServerEvent;
      const rest = live.events.filter((e) => e.id !== ev.id);
      set({ events: [...rest, ev].sort((a, b) => a.ts - b.ts).slice(-100) });
    } else if (m.type === "reset") {
      set({ events: [], history: [], log: [] });
      void fetchState();
    }
  };
  sock.onclose = () => {
    if (ws === sock) ws = null;
    wsOpen = false;
    startPolling();
    retry = setTimeout(connect, 2000);
  };
  sock.onerror = () => sock.close();
}

function start() {
  if (started || typeof window === "undefined") return;
  started = true;
  startPolling();
  fetchState();
  connect();
}

/** Stato live del backend, condiviso: dog, cameras, site, limits, log, events, missioni (current, queue, history),
 *  stats, alarm, shift, backendOnline, ready. */
export function useLive(): Live {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      start();
      return () => listeners.delete(cb);
    },
    () => live,
    () => OFFLINE,
  );
}

// ── comandi ───────────────────────────────────────────
export type Action = "drive" | "goto" | "home" | "stop" | "estop" | "reset" | "stand" | "lie" | "zero" | "teach";

export async function command(action: Action, args: Record<string, unknown> = {}): Promise<{ ok: boolean; error?: string }> {
  try {
    const r = await fetch("/api/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, ...args }),
    });
    const body = (await r.json().catch(() => ({}))) as { ok?: boolean; error?: string };
    return { ok: r.ok && body.ok !== false, error: body.error ?? (r.ok ? undefined : `HTTP ${r.status}`) };
  } catch {
    return { ok: false, error: "Backend offline" };
  }
}

/** Velocità manuale (valida 0,6 s sul backend: va ripetuta finché si tiene premuto). */
export function sendDrive(vx: number, vy: number, wz: number) {
  if (ws && wsOpen) ws.send(JSON.stringify({ type: "drive", vx, vy, wz }));
  else void command("drive", { vx, vy, wz });
}

export const streamUrl = (id: string, attempt = 0) => `/api/cameras/${encodeURIComponent(id)}/stream?a=${attempt}`;
export const qrUrl = (data: string) => `/api/qr.png?data=${encodeURIComponent(data)}`;
