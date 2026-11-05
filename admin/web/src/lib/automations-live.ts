"use client";

import { useSyncExternalStore } from "react";
import type { Live, Site } from "@/lib/backend";
import { siteToPlan, planToSite, type PlanXY } from "@/lib/coords";

// Automazioni, percorsi del sito e punti di ronda del backend (admin/backend): /api/automations, /api/command
// e `site.routes`. È la stessa mappatura dell'app mobile in modalità live (grokdog_mobile, LiveView e ConsoleStore):
// - «Alarm»: l'allarme del sito (parte quando una camera vede qualcosa ad allarme inserito); si inserisce/disinserisce.
// - i percorsi di config/site.pad3.json (r1, r2…): si avviano (`patrol`, un giro) o si programmano (`schedule`).
// - quelle create dall'operatore (AU-01…): percorso in metri + orario, salvate sul server in data/automations.json.

// ── tipi del contratto ────────────────────────────────
export type ServerRepeat = "once" | "daily" | "weekdays" | "days" | "interval";

/** Un'automazione creata dall'operatore: `Automations.public()` di admin/backend/app/automations.py. */
export type ServerAutomation = {
  id: string;
  name: string;
  /** Punti del percorso nel frame del sito, in metri. */
  points: [number, number][];
  loop: boolean;
  start: string;
  repeat: ServerRepeat;
  every_min: number | null;
  until: string | null;
  days: number[] | null;
  active: boolean;
  /** Secondi dall'epoch. */
  created: number;
  last_run: number | null;
  runs_today: number;
};

/** Un percorso di ronda del sito: `site.routes` di config/site.pad3.json. */
export type SiteRoute = { id: string; name: string; room?: string; spots: string[] };

/** La ronda programmata di un percorso del sito: `snapshot()["schedules"]` di admin/backend/app/main.py. */
export type RouteSchedule = { every_min: number; next_in_s: number };

/** Il sito con i percorsi (il tipo `Site` di backend.ts non li dichiara, ma /api/state li manda). */
export const siteRoutes = (site: Site | null): SiteRoute[] => {
  const r = (site as (Site & { routes?: unknown }) | null)?.routes;
  return Array.isArray(r) ? (r as SiteRoute[]).filter((x) => x && typeof x.id === "string" && Array.isArray(x.spots)) : [];
};

/** Id dell'automazione «allarme» (lo stesso di lib/missions.ts per le missioni partite da un evento). */
export const ALARM_ID = "alarm";

// ── metri ↔ pianta ─────────────────────────────────────
/** Un punto del server (metri) sulla pianta (cm), arrotondato al centimetro. */
export const toPlan = ([x, y]: [number, number]): PlanXY => {
  const p = siteToPlan(x, y);
  return { x: Math.round(p.x), y: Math.round(p.y) };
};
/** Un punto della pianta (cm) per il server: metri, al centimetro. */
export const toSite = (p: PlanXY): [number, number] => {
  const s = planToSite(p);
  return [Math.round(s.x * 100) / 100, Math.round(s.y * 100) / 100];
};

// ── punti di ronda per la mappa ───────────────────────
export type PatrolPoint = { id: string; label: string; x: number; y: number };

/** «p1» → «P1»; gli spot con un altro id usano il nome. */
const spotLabel = (s: { id: string; name: string }) => (/^p\d+$/i.test(s.id) ? s.id.toUpperCase() : s.name);

/** I punti della ronda da disegnare sulla mappa (cm sulla pianta), come nell'app mobile: la ronda in corso,
 *  se il cane sta facendo il giro di un percorso del sito, altrimenti il primo percorso del sito. null = niente sito (offline). */
export function patrolPointsOf(live: Pick<Live, "site" | "current">): PatrolPoint[] | null {
  const site = live.site;
  if (!site) return null;
  const spot = (id: string) => site.spots.find((s) => s.id === id);
  const cur = live.current;
  const running = cur?.kind === "patrol" && cur.stops.length > 1 && cur.stops.every((id) => spot(id)) ? cur.stops : null;
  const ids = running ?? siteRoutes(site)[0]?.spots ?? [];
  // lo stesso posto due volte di fila (o in fondo, per chiudere il giro) si disegna una volta sola
  const uniq = ids.filter((id, i) => id !== ids[i - 1] && !(i === ids.length - 1 && id === ids[0] && i > 0));
  return uniq.flatMap((id) => {
    const s = spot(id);
    if (!s) return [];
    const p = siteToPlan(s.x, s.y);
    return [{ id: s.id, label: spotLabel(s), x: Math.round(p.x), y: Math.round(p.y) }];
  });
}

/** I nomi dei punti di un percorso del sito: «P1», «P2»… */
export const routeLabels = (site: Site | null, r: SiteRoute) =>
  r.spots.map((id) => {
    const s = site?.spots.find((x) => x.id === id);
    return s ? spotLabel(s) : id.toUpperCase();
  });

/** I punti di un percorso del sito sulla pianta (cm). */
export const routePlan = (site: Site | null, r: SiteRoute): PlanXY[] =>
  r.spots.flatMap((id) => {
    const s = site?.spots.find((x) => x.id === id);
    return s ? [toPlan([s.x, s.y])] : [];
  });

// ── store: automazioni e programmazioni del server ────
// Il tick del WebSocket porta già `automations` e `schedules`, ma lo store di backend.ts non li tiene:
// qui si legge /api/state ogni POLL_MS finché qualcuno è iscritto, e subito dopo ogni comando.
export type AutomationsState = {
  automations: ServerAutomation[];
  schedules: Record<string, RouteSchedule>;
  /** "unknown" finché non risponde la prima volta. */
  status: "unknown" | "online" | "offline";
};

const POLL_MS = 2000;
const INITIAL: AutomationsState = { automations: [], schedules: {}, status: "unknown" };
let state: AutomationsState = INITIAL;
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setInterval> | undefined;
let inflight: Promise<void> | null = null;

const emit = (next: AutomationsState) => {
  state = next;
  listeners.forEach((l) => l());
};

/** Rilegge automazioni e programmazioni dal server. */
export function refreshAutomations(): Promise<void> {
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      const r = await fetch("/api/state", { cache: "no-store" });
      if (!r.ok) throw new Error(String(r.status));
      const s = (await r.json()) as { automations?: unknown; schedules?: unknown };
      const automations = Array.isArray(s.automations) ? (s.automations as ServerAutomation[]) : [];
      const schedules = s.schedules && typeof s.schedules === "object" ? (s.schedules as Record<string, RouteSchedule>) : {};
      // stessa lista di prima → stesso oggetto, così le pagine non si ridisegnano a ogni giro
      const same = state.status === "online" && JSON.stringify([automations, schedules]) === JSON.stringify([state.automations, state.schedules]);
      if (!same) emit({ automations, schedules, status: "online" });
    } catch {
      if (state.status !== "offline") emit({ ...state, status: "offline" });
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  if (!timer) {
    void refreshAutomations();
    timer = setInterval(() => void refreshAutomations(), POLL_MS);
  }
  return () => {
    listeners.delete(cb);
    if (!listeners.size) {
      clearInterval(timer);
      timer = undefined;
    }
  };
}

/** Automazioni e programmazioni del server (si aggiornano da sole finché la pagina è aperta). */
export const useServerAutomations = () => useSyncExternalStore(subscribe, () => state, () => INITIAL);

// ── comandi ───────────────────────────────────────────
export type Result = { ok: boolean; error?: string };

async function call(method: "POST" | "DELETE", url: string, body?: unknown): Promise<Result & Record<string, unknown>> {
  try {
    const r = await fetch(url, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = (await r.json().catch(() => ({}))) as Record<string, unknown> & { ok?: boolean; error?: string; detail?: unknown };
    const error = j.error ?? (typeof j.detail === "string" ? j.detail : undefined);
    return { ...j, ok: r.ok && j.ok !== false, error: error ?? (r.ok ? undefined : `HTTP ${r.status}`) };
  } catch {
    return { ok: false, error: "Backend offline" };
  } finally {
    void refreshAutomations();
  }
}

/** Il corpo di POST /api/automations. */
export type NewAutomation = {
  name: string;
  points: [number, number][];
  loop: boolean;
  start: string;
  repeat: ServerRepeat;
  days?: number[];
  every_min?: number;
  until?: string;
};

export const createAutomation = (a: NewAutomation) => call("POST", "/api/automations", a);
export const setServerAutomationActive = (id: string, active: boolean) => call("POST", `/api/automations/${encodeURIComponent(id)}`, { active });
export const deleteServerAutomation = (id: string) => call("DELETE", `/api/automations/${encodeURIComponent(id)}`);
/** Parte subito: il cane fa il percorso una volta (una missione «patrol»). */
export const runServerAutomation = (id: string) => call("POST", `/api/automations/${encodeURIComponent(id)}/run`);
export const setServerAutomationRoute = (id: string, points: [number, number][], loop: boolean) =>
  call("POST", `/api/automations/${encodeURIComponent(id)}/route`, { points, loop });

/** I comandi per i percorsi del sito e per l'allarme (non sono tra le `Action` di backend.ts). */
export const startRoute = (routeId: string) => call("POST", "/api/command", { action: "patrol", route: routeId, loops: 1 });
/** Un giro ogni `everyMin` minuti; 0 = toglie la programmazione. */
export const scheduleRoute = (routeId: string, everyMin: number) => call("POST", "/api/command", { action: "schedule", route: routeId, every_min: everyMin });
export const setAlarm = (armed: boolean) => call("POST", "/api/command", { action: armed ? "arm" : "disarm", by: "console" });
