"use client";

import { useMemo, useSyncExternalStore } from "react";
import { useLive } from "@/lib/backend";
import { siteToPlan } from "@/lib/coords";
import { useConsoleData } from "@/lib/missions";
import {
  ALARM_ID,
  routeLabels,
  routePlan,
  siteRoutes,
  toPlan,
  useServerAutomations,
  type ServerAutomation,
} from "@/lib/automations-live";
import { automations as mockAutomations, dogSpot, fleet as mockFleet, offlineDogs, rooms, type Automation, type Dog } from "@/lib/mock";

type Point = { x: number; y: number };

/** A, B, C… per i punti del percorso. */
export const letter = (i: number) => String.fromCharCode(65 + i);
/** La stanza che contiene il punto; se cade fuori dai rettangoli delle stanze (bordi, porte), la più vicina. */
export const roomAt = (p: Point) => {
  const gap = (r: (typeof rooms)[number]) => Math.hypot(Math.max(r.x - p.x, 0, p.x - r.x - r.w), Math.max(r.y - p.y, 0, p.y - r.y - r.h));
  return rooms.reduce((best, r) => (gap(r) < gap(best) ? r : best)).name;
};
/** «Walks A → B → A (Room 2 → Room 3) and reports what it sees»: cosa fa un'automazione col suo percorso. */
export const walkText = (route: Point[], loop: boolean) =>
  `Walks ${route.map((_, i) => letter(i)).join(" → ")}${loop ? " → A" : ""} (${[...new Set(route.map(roomAt))].join(" → ")}) and reports what it sees`;
/** cm sulla pianta → metri, una cifra decimale. */
export const meters = (cm: number) => (cm / 100).toFixed(1);

// Le automazioni create dall'operatore: per ora salvate nel browser (localStorage), finché non c'è un backend.
export type Repeat = "once" | "daily" | "weekdays" | "days" | "interval";
export type CustomAutomation = Automation & {
  custom: true;
  /** Punti del percorso (cm sulla pianta), nell'ordine: A, B, C… */
  route: Point[];
  loop: boolean;
  start: string; // HH:MM
  repeat: Repeat;
  /** Per «days»: i giorni della settimana, 1 = lunedì … 7 = domenica. */
  days?: number[];
  everyMinutes?: number;
  until?: string; // HH:MM, per «interval»
};

const WEEKDAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
/** Quanto si ripete, senza l'ora di partenza (sta accanto): «Every day», «Mon–Fri», «Every day, every 30 min until 18:00»… */
export function repeatLabel(a: Pick<CustomAutomation, "repeat" | "days" | "everyMinutes" | "until">) {
  switch (a.repeat) {
    case "once":
      return "Once";
    case "daily":
      return "Every day";
    case "weekdays":
      return "Mon–Fri";
    case "days":
      return (a.days ?? []).map((d) => WEEKDAY_NAMES[d - 1]).join(", ") || "No days";
    case "interval":
      return `Every day, every ${a.everyMinutes ?? 60} min until ${a.until ?? "—"}`;
  }
}

const KEY = "grokdog:automations";
const EVT = "grokdog:automations";
const EMPTY: CustomAutomation[] = [];
let cacheRaw: string | null = null;
let cache: CustomAutomation[] = EMPTY;

const read = () => {
  const raw = localStorage.getItem(KEY);
  if (raw !== cacheRaw) {
    cacheRaw = raw;
    try {
      cache = raw ? (JSON.parse(raw) as CustomAutomation[]) : EMPTY;
    } catch {
      cache = EMPTY;
    }
  }
  return cache;
};

const subscribe = (cb: () => void) => {
  window.addEventListener("storage", cb);
  window.addEventListener(EVT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(EVT, cb);
  };
};

export const useCustomAutomations = () => useSyncExternalStore(subscribe, read, () => EMPTY);

export function saveAutomation(a: CustomAutomation) {
  localStorage.setItem(KEY, JSON.stringify([...read(), a]));
  window.dispatchEvent(new Event(EVT));
}

export function setAutomationActive(id: string, active: boolean) {
  localStorage.setItem(KEY, JSON.stringify(read().map((a) => (a.id === id ? { ...a, active } : a))));
  window.dispatchEvent(new Event(EVT));
}

export function deleteAutomation(id: string) {
  localStorage.setItem(KEY, JSON.stringify(read().filter((a) => a.id !== id)));
  window.dispatchEvent(new Event(EVT));
}

// Il percorso cambiato con «Change path»: per quelle create a mano si aggiorna l'automazione stessa,
// per quelle di sistema si salva a parte (sempre nel browser), per id.
export type SavedRoute = { route: Point[]; loop: boolean };
const ROUTES_KEY = "grokdog:automation-routes";
const NO_ROUTES: Record<string, SavedRoute> = {};
let routesRaw: string | null = null;
let routesCache = NO_ROUTES;

const readRoutes = () => {
  const raw = localStorage.getItem(ROUTES_KEY);
  if (raw !== routesRaw) {
    routesRaw = raw;
    try {
      routesCache = raw ? (JSON.parse(raw) as Record<string, SavedRoute>) : NO_ROUTES;
    } catch {
      routesCache = NO_ROUTES;
    }
  }
  return routesCache;
};

export const useSavedRoutes = () => useSyncExternalStore(subscribe, readRoutes, () => NO_ROUTES);

export function setAutomationRoute(id: string, route: Point[], loop: boolean) {
  if (read().some((a) => a.id === id)) {
    // per quelle create a mano anche «What it does» racconta il percorso: si riscrive
    localStorage.setItem(KEY, JSON.stringify(read().map((a) => (a.id === id ? { ...a, route, loop, action: walkText(route, loop) } : a))));
  } else {
    localStorage.setItem(ROUTES_KEY, JSON.stringify({ ...readRoutes(), [id]: { route, loop } }));
  }
  window.dispatchEvent(new Event(EVT));
}

// ── la vista unica per le pagine: server se il backend risponde, mock + browser se no ──
/** Un robot negli elenchi: il cane live (battery null = non si sa ancora) o uno di mock.ts. */
export type ConsoleDog = Omit<Dog, "battery" | "route"> & { battery: number | null; spot: Point };

/** Che automazione è: di mock.ts, creata nel browser (offline), o del server (allarme, percorso del sito, creata dall'operatore). */
export type AutomationKind = "mock" | "local" | "alarm" | "route" | "server";

export type ConsoleAutomation = Automation & {
  kind: AutomationKind;
  /** Creata dall'operatore (nel browser offline, sul server online): si mette in pausa, si cancella, si cambia il percorso. */
  custom: boolean;
  /** Senza ora di partenza: cosa dice il badge della colonna Start («On event», «Manual», «Every 30 min»). */
  badge?: string;
  /** Il percorso (cm sulla pianta, A, B, C…) e se torna ad A. */
  path?: SavedRoute;
  /** Si può cambiare il percorso da qui (le ronde del sito stanno nella configurazione del server). */
  editablePath: boolean;
  /** Il testo del badge di stato, se non è «Active»/«Paused» (allarme: «Armed»/«Disarmed»). */
  statusLabel?: string;
  /** Per le ronde del sito: ogni quanti minuti è programmata (null = no). */
  everyMin?: number | null;
};

export type AutomationsView = {
  /** true = automazioni del server; false = mock.ts e quelle salvate nel browser (backend offline). */
  live: boolean;
  /** false finché non si sa se il backend c'è (le pagine non mostrano ancora niente). */
  ready: boolean;
  list: ConsoleAutomation[];
  /** I robot: online il cane live e poi i bot spenti di mock.ts, offline la flotta di mock.ts. */
  fleet: ConsoleDog[];
};

export const LIVE_DOG = { id: "go1", name: "Unitree Go1" };

const hms = (ts: number) => new Date(ts * 1000).toLocaleTimeString("en-GB");
const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
/** «Every day at 09:00», «Every 30 min, 09:00–18:00»…: lo stesso testo del modulo di creazione. */
export const repeatText = (repeat: Repeat, start: string, every: number, until: string, days: number[]) =>
  repeat === "once"
    ? `Once, at ${start}`
    : repeat === "daily"
      ? `Every day at ${start}`
      : repeat === "weekdays"
        ? `Mon–Fri at ${start}`
        : repeat === "days"
          ? `${days.length ? days.map((d) => WEEK[d - 1]).join(", ") : "No days"} at ${start}`
          : `Every ${every} min, ${start}–${until}`;

const consoleDog = (d: Dog): ConsoleDog => ({ id: d.id, name: d.name, adapter: d.adapter, battery: d.battery, state: d.state, task: d.task, roomId: d.roomId, spot: dogSpot(d) });

/** Automazioni e robot per le pagine di /automation. */
export function useAutomations(): AutomationsView {
  const server = useServerAutomations();
  const local = useCustomAutomations();
  const savedRoutes = useSavedRoutes();
  const live = useLive();
  const { missions } = useConsoleData();
  const { site, alarm, current } = live;
  const d = live.dog;
  // la posizione del cane a 10 cm: così A non cambia (e la mappa non ridisegna) a ogni tick
  const at = d ? siteToPlan(d.x, d.y) : null;
  const ax = at ? Math.round(at.x / 10) * 10 : null;
  const ay = at ? Math.round(at.y / 10) * 10 : null;
  const battery = d?.battery == null ? null : Math.round(d.battery);
  const busy = d?.target ? (current?.kind === "patrol" ? "ronda" : "missione") : "base";

  return useMemo((): AutomationsView => {
    if (server.status !== "online") {
      // backend offline (o non ancora sentito): il design con i dati di mock.ts e quelle salvate nel browser
      const fleet = mockFleet.map(consoleDog);
      const list: ConsoleAutomation[] = [
        ...mockAutomations.map(
          (a): ConsoleAutomation => ({
            ...a,
            kind: "mock",
            custom: false,
            badge: "On event",
            editablePath: true,
            path: savedRoutes[a.id] ?? (a.route ? { route: a.route, loop: a.loop ?? false } : undefined),
          }),
        ),
        ...local.map(
          (a): ConsoleAutomation => ({
            ...a,
            kind: "local",
            custom: true,
            startsAt: a.start,
            repeats: repeatLabel(a),
            editablePath: true,
            path: { route: a.route, loop: a.loop },
          }),
        ),
      ];
      return { live: false, ready: server.status === "offline", list, fleet };
    }

    const spot = ax != null && ay != null ? { x: ax, y: ay } : (() => {
      const home = site?.spots.find((s) => s.id === (site.home ?? "home"));
      return home ? toPlan([home.x, home.y]) : { x: 870, y: 1680 };
    })();
    const dog: ConsoleDog = {
      id: LIVE_DOG.id,
      name: LIVE_DOG.name,
      adapter: d?.kind === "go1" ? "unitree" : "simulato",
      battery,
      state: busy,
      task: "",
      roomId: "",
      spot,
    };
    // ultima esecuzione e quante oggi: dalle missioni del turno partite da quell'automazione
    const runs = (id: string) => {
      const ms = missions.filter((m) => m.automationId === id);
      return { lastRun: ms[0]?.eventTime ?? null, runsToday: ms.length };
    };
    const alarmRow: ConsoleAutomation = {
      id: ALARM_ID,
      name: "Alarm",
      trigger: "A camera sees movement while the alarm is armed",
      action: "Grok assesses the frame and, if needed, sends the dog to check",
      startsAt: null,
      badge: "On event",
      dogId: dog.id,
      active: !!alarm?.armed,
      statusLabel: alarm?.armed ? "Armed" : "Disarmed",
      kind: "alarm",
      custom: false,
      editablePath: false,
      ...runs(ALARM_ID),
    };
    const routes = siteRoutes(site).map((r): ConsoleAutomation => {
      const every = server.schedules[r.id]?.every_min ?? null;
      const labels = routeLabels(site, r);
      const names = labels.length > 2 ? `${labels.slice(0, -1).join(", ")} and ${labels[labels.length - 1]}` : labels.join(" and ");
      return {
        id: r.id,
        name: r.name,
        trigger: every ? `Every ${every} min` : "Not scheduled",
        action: `The dog visits ${names} and reports what it sees`,
        startsAt: null,
        badge: every ? `Every ${every} min` : "Manual",
        dogId: dog.id,
        active: !!every,
        statusLabel: every ? "Scheduled" : "Not scheduled",
        kind: "route",
        custom: false,
        editablePath: false,
        everyMin: every,
        path: { route: routePlan(site, r), loop: true },
        ...runs(r.id),
      };
    });
    const mine = server.automations.map((a: ServerAutomation): ConsoleAutomation => {
      const route = a.points.map(toPlan);
      const days = a.days ?? [];
      const every = a.every_min ?? 60;
      const until = a.until ?? "—";
      return {
        id: a.id,
        name: a.name,
        trigger: repeatText(a.repeat, a.start, every, until, days),
        action: walkText(route, a.loop),
        startsAt: a.start,
        repeats: repeatLabel({ repeat: a.repeat, days, everyMinutes: every, until }),
        dogId: dog.id,
        active: a.active,
        lastRun: a.last_run ? hms(a.last_run) : null,
        runsToday: a.runs_today,
        kind: "server",
        custom: true,
        editablePath: true,
        path: { route, loop: a.loop },
      };
    });
    return { live: true, ready: true, list: [alarmRow, ...routes, ...mine], fleet: [dog, ...offlineDogs.map(consoleDog)] };
  }, [server, local, savedRoutes, site, alarm, missions, ax, ay, battery, busy, d?.kind]);
}
