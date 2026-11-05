"use client";

import { useMemo } from "react";
import { useLive, type Live, type LogEntry, type ServerEvent, type ServerMission, type Site } from "@/lib/backend";
import { toConsoleEvent } from "@/lib/events";
import {
  alerts as mockAlerts,
  channelLabels,
  dogName,
  missions as mockMissions,
  roomName,
  shift as mockShift,
  type AlertSent,
  type EventStatus,
  type LogStep,
  type Mission,
  type MissionStep,
  type Outcome,
  type TriggerSource,
} from "@/lib/mock";

// Missioni, allarmi inviati e turno del backend (admin/backend: `Mission.public()`, `Event.public()`, il registro di
// logbook.py e `Manager.stats()`) nella forma della UI di mock.ts. È la stessa mappatura dell'app mobile in modalità live
// (grokdog_mobile, LiveView): passi della timeline dal registro, esito dall'evento, missioni senza incidente dal registro.
// Con il backend offline si vede il mock, come in events.ts.

/** Una missione come la mostra la console: quella di mock.ts più i nomi già risolti (cane, stanza, posto). */
export type ConsoleMission = Omit<Mission, "battery"> & {
  /** Batteria del cane (%), null se non si sa. */
  battery: number | null;
  /** Nome del cane. */
  robot: string;
  /** Nome della stanza. */
  room: string;
  /** Il posto dove va (o è andato) il cane, "" se non si sa. */
  spot: string;
  /** Secondi dall'epoch dell'evento (o della creazione della missione); null per il mock. */
  ts: number | null;
};

export type ConsoleAlert = AlertSent & { ts: number | null };

/** Il turno: le stesse chiavi di `shift` di mock.ts; `avgArrivalSeconds` null se nessun arrivo ancora. */
export type ShiftView = Omit<typeof mockShift, "avgArrivalSeconds" | "logCompleteness"> & {
  avgArrivalSeconds: number | null;
  logCompleteness: number | null;
  /** Inizio del turno in secondi dall'epoch (null per il mock). */
  startTs: number | null;
};

export type ConsoleData = {
  missions: ConsoleMission[];
  alerts: ConsoleAlert[];
  shift: ShiftView;
  /** true = dati del backend; false = mock (backend offline). */
  live: boolean;
  /** false finché non si sa se il backend c'è. */
  ready: boolean;
};

export const LIVE_DOG_ID = "go1";
export const LIVE_DOG_NAME = "Unitree Go1";

// ── orari ────────────────────────────────────────────
const hms = (ts: number) => new Date(ts * 1000).toLocaleTimeString("en-GB");
const pad = (n: number) => String(n).padStart(2, "0");
const isoDay = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const round1 = (s: number) => Math.round(s * 10) / 10;

// ── registro → passi della timeline (stepOf dell'app mobile) ──
export function stepOf(kind: string): LogStep | null {
  if (kind === "event.received") return "Trigger";
  if (kind === "event.assessed" || kind === "event.second_opinion" || kind === "event.located" || kind === "event.checked_anyway") return "Valutazione";
  if (kind === "mission.verified") return "Verifica";
  if (kind === "alert.sent") return "Alert";
  if (["event.cleared", "event.dismissed", "event.cancelled", "mission.done", "mission.cancelled"].includes(kind)) return "Chiusura";
  if (kind.startsWith("mission.") || kind.startsWith("patrol.")) return "Missione";
  return null;
}

// ── sito ─────────────────────────────────────────────
/** La stanza più piccola del sito che contiene il punto (metri). */
function siteRoomAt(site: Site, x: number, y: number) {
  return [...site.rooms]
    .sort((a, b) => a.w * a.h - b.w * b.h)
    .find((r) => x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h);
}

type Place = { spot: string; roomId: string; room: string };

/** Dove va la missione: il posto in cui si trova adesso (o l'ultimo), con la sua stanza. */
function placeOf(m: ServerMission, rows: LogEntry[], ev: ServerEvent | undefined, live: Pick<Live, "site">): Place {
  const site = live.site;
  if (!site) return { spot: "", roomId: "", room: "—" };
  const roomById = (id?: string) => site.rooms.find((r) => r.id === id);
  const stop = m.stops[Math.min(m.idx, m.stops.length - 1)] ?? m.stops[0];
  let spot: { name: string; room?: string; x: number; y: number } | undefined = site.spots.find((s) => s.id === stop);
  if (!spot) {
    // posto provvisorio davanti all'evento (pt-ev-…): lo dice la riga event.located del registro
    const located = rows.find((r) => r.kind === "event.located" && (r.data as { spot?: { id?: string } } | null)?.spot?.id === stop);
    const s = (located?.data as { spot?: { name: string; x: number; y: number } } | null)?.spot;
    if (s) spot = s;
  }
  const cam = ev ? site.cameras.find((c) => c.id === ev.camera) : undefined;
  const room = roomById(spot?.room) ?? (spot ? siteRoomAt(site, spot.x, spot.y) : undefined) ?? roomById(cam?.room) ?? (cam ? siteRoomAt(site, cam.x, cam.y) : undefined);
  return { spot: spot?.name ?? stop ?? "", roomId: room?.id ?? "", room: room?.name ?? "—" };
}

const spotName = (site: Site | null, id: string) => site?.spots.find((s) => s.id === id)?.name ?? id;

// ── missioni dal registro (quelle finite prima che la console si aprisse) ──
function fromLog(id: string, rows: LogEntry[]): ServerMission {
  const queued = rows.find((r) => r.kind === "mission.queued");
  const data = (queued?.data ?? {}) as { kind?: string; stops?: string[] };
  const end = [...rows].reverse().find((r) => r.kind === "mission.done" || r.kind === "mission.cancelled");
  const started = rows.find((r) => r.kind === "mission.started");
  const label = queued?.message.replace(/ queued \(priority \d+\)$/, "") ?? end?.message.replace(/ (done|cancelled)(:.*)?$/, "") ?? id;
  const priority = Number(queued?.message.match(/priority (\d+)/)?.[1] ?? 0);
  const note = end?.message.match(/ (?:done|cancelled): (.*)$/)?.[1] ?? "";
  return {
    id,
    kind: data.kind ?? "goto",
    stops: Array.isArray(data.stops) ? data.stops : [],
    priority,
    label,
    loops: 1,
    loop_count: 0,
    idx: 0,
    event_ids: [...new Set(rows.filter((r) => r.mission_id === id && r.event_id).map((r) => r.event_id!))],
    status: end?.kind === "mission.cancelled" ? "cancelled" : "done",
    phase: "idle",
    path: [],
    speculative: false,
    route_id: null,
    created: queued?.ts ?? rows[0]?.ts ?? 0,
    started: started?.ts ?? null,
    ended: end?.ts ?? null,
    note,
  };
}

// ── una missione del server → ConsoleMission ─────────
const EV_STATUS: Record<ServerEvent["status"], EventStatus> = {
  received: "in_valutazione",
  assessing: "in_valutazione",
  dispatched: "missione",
  verifying: "verifica",
  alerted: "alert",
  dismissed: "falso_allarme",
  cleared: "chiuso",
  cancelled: "chiuso",
};
const EV_CLOSED = new Set<ServerEvent["status"]>(["alerted", "dismissed", "cleared", "cancelled"]);
const M_CLOSED = new Set<ServerMission["status"]>(["done", "cancelled"]);

const CHANNEL: Record<string, AlertSent["channel"]> = { console: "Console", telegram: "Telegram", sms: "SMS", call: "Chiamata" };
const channelOf = (c: unknown): AlertSent["channel"] => CHANNEL[String(c)] ?? "Console";
const channelTo: Record<AlertSent["channel"], string> = {
  Console: "Console · control room",
  Telegram: "Telegram · subscribed chats",
  SMS: "Supervisor on shift",
  Chiamata: "Supervisor on shift",
  GrokBot: "Grok chat · Control room",
};

/** Il controllo del cane sul posto (mission.verified) e se è partito un alert: anche le missioni senza evento
 *  (un «manda il cane» dalla console) possono trovare qualcosa. */
type Check = { confirmed: boolean | null | undefined; alerted: boolean };

function outcomeOf(m: ServerMission, ev: ServerEvent | undefined, check: Check): Outcome {
  if (ev && EV_CLOSED.has(ev.status)) {
    if (ev.status === "cancelled") return "annullata";
    if (ev.status === "alerted") {
      const c = ev.verification?.confirmed;
      return c === true ? "anomalia" : c === false ? "falso_allarme" : "da_verificare";
    }
    return "falso_allarme";
  }
  if (m.status === "cancelled") return "annullata";
  if (m.status !== "done") return "in_corso";
  // con un evento ancora aperto resta in corso
  if (ev) return "in_corso";
  if (check.confirmed === true) return "anomalia";
  if (check.alerted) return check.confirmed === false ? "falso_allarme" : "da_verificare";
  // finita senza trovare niente (ronda, vai a…)
  return "falso_allarme";
}

function statusOf(m: ServerMission, ev: ServerEvent | undefined, arrived: boolean, check: Check): EventStatus {
  if (ev && EV_CLOSED.has(ev.status)) return EV_STATUS[ev.status];
  switch (m.status) {
    case "queued":
    case "paused":
      return "in_coda";
    case "verifying":
      return "verifica";
    case "active":
      return arrived && ev ? "verifica" : "missione";
    default:
      return ev ? EV_STATUS[ev.status] : check.alerted ? "alert" : "chiuso";
  }
}

function toConsoleMission(m: ServerMission, live: Live, allRows: LogEntry[], eventsById: Map<string, ServerEvent>): ConsoleMission {
  const evs = m.event_ids.map((id) => eventsById.get(id)).filter((e): e is ServerEvent => !!e);
  const ev = evs[0];
  const evIds = new Set(m.event_ids);
  const rows = allRows.filter((r) => r.mission_id === m.id || (r.event_id != null && evIds.has(r.event_id) && (!r.mission_id || r.mission_id === m.id)));
  const ce = ev ? toConsoleEvent(ev, live) : null;
  const place = placeOf(m, allRows, ev, live);
  const first = (kind: string) => rows.find((r) => r.kind === kind);
  const last = (pred: (r: LogEntry) => boolean) => [...rows].reverse().find(pred);

  // trigger
  const trigger: TriggerSource = ev ? (ev.kind === "patrol_finding" ? "ronda" : "camera") : m.kind === "patrol" ? "ronda" : "comando";
  const stopNames = m.stops.map((s) => spotName(live.site, s));
  const triggerLabel = ce
    ? `${ce.sourceLabel} · ${ce.anomaly.toLowerCase()}`
    : m.kind === "patrol" && stopNames.length
      ? `${m.label} · ${stopNames.join(" → ")}`
      : m.label;
  const automationId = ev ? "alarm" : m.route_id ?? (m.kind === "patrol" ? "patrol" : null);

  // tempi
  const t0 = ev?.ts ?? m.created;
  const arrivedRow = first("mission.arrived") ?? first("patrol.checkpoint");
  const arrivedTs = ev?.timings.arrived != null ? ev.ts + ev.timings.arrived : arrivedRow?.ts ?? null;
  const startedTs = m.started ?? first("mission.started")?.ts ?? (ev?.timings.dispatched != null ? ev.ts + ev.timings.dispatched : null);
  const fromRow = Number((first("mission.arrived")?.data as { event_to_arrival_s?: number } | null)?.event_to_arrival_s);
  const arrivalSeconds =
    ev?.timings.arrived != null
      ? round1(ev.timings.arrived)
      : Number.isFinite(fromRow)
        ? round1(fromRow)
        : arrivedTs != null && startedTs != null
          ? round1(arrivedTs - startedTs)
          : null;

  // cosa ha visto il cane
  const verifiedRow = last((r) => r.kind === "mission.verified");
  const sighting =
    ev?.verification?.description ??
    verifiedRow?.message.replace(/^[^:]*: /, "") ??
    (M_CLOSED.has(m.status) && !ev ? m.note || (arrivedTs != null ? "No anomalies" : null) : null);

  const check: Check = {
    confirmed: ev?.verification?.confirmed ?? (verifiedRow?.data as { confirmed?: boolean | null } | null)?.confirmed,
    alerted: rows.some((r) => r.kind === "alert.sent"),
  };
  const outcome = outcomeOf(m, ev, check);
  const closed = outcome !== "in_corso";

  // timeline: sei passi, come nel mock
  const steps: MissionStep[] = [];
  const at = (ts: number | null | undefined) => (ts == null ? null : hms(ts));
  // Trigger
  if (ev && ce) {
    const rec = first("event.received");
    steps.push({ step: "Trigger", time: at(ev.ts), detail: rec?.message ?? `${ce.sourceLabel}, ${ce.anomaly.toLowerCase()}` });
  } else {
    const how = m.kind === "patrol" ? `Patrol, ${m.stops.length} point${m.stops.length === 1 ? "" : "s"}` : m.route_id ? `Automation ${m.label}` : `Command from console: ${m.label}`;
    steps.push({ step: "Trigger", time: at(m.created), detail: how });
  }
  // Valutazione
  if (ev) {
    const a = ev.assessment;
    const ts = ev.timings.assessed != null ? ev.ts + ev.timings.assessed : first("event.assessed")?.ts;
    steps.push({
      step: "Valutazione",
      time: a ? at(ts) : null,
      detail: a ? [ce?.grokDecision, a.reason].filter(Boolean).join(": ") : "Assessing…",
    });
  } else {
    steps.push({ step: "Valutazione", time: at(m.created), detail: m.kind === "patrol" || m.route_id ? "Automatic start, no assessment" : m.kind === "home" ? "Return to base, no assessment" : "Operator command, no assessment" });
  }
  // Missione
  {
    const queued = first("mission.queued");
    let detail: string;
    let time: string | null;
    if (arrivedTs != null && startedTs != null) {
      detail = `Departed ${hms(startedTs)}, arrived ${hms(arrivedTs)}${arrivalSeconds != null ? `, ${arrivalSeconds} s` : ""}`;
      time = hms(arrivedTs);
    } else if (startedTs != null && m.status !== "queued") {
      detail = `Departed ${hms(startedTs)} for ${place.spot || m.label}`;
      time = hms(startedTs);
    } else if (m.status === "queued" || m.status === "paused") {
      const busy = live.current && live.current.id !== m.id ? `: dog busy on ${live.current.id}` : "";
      detail = `${m.status === "paused" ? "Paused" : "Queued"} (priority ${m.priority})${busy}`;
      time = at(queued?.ts ?? m.created);
    } else {
      detail = m.status === "cancelled" ? "Did not depart" : "Pending";
      time = null;
    }
    if (m.kind === "patrol") {
      const cps = rows.filter((r) => r.kind === "patrol.checkpoint").length;
      if (cps) detail += ` · ${cps} checkpoint${cps === 1 ? "" : "s"}`;
      if (m.loop_count) detail += ` · ${m.loop_count} round${m.loop_count === 1 ? "" : "s"}`;
    }
    steps.push({ step: "Missione", time, detail });
  }
  // Verifica
  if (verifiedRow) {
    const c = (verifiedRow.data as { confirmed?: boolean | null } | null)?.confirmed;
    const desc = verifiedRow.message.replace(/^[^:]*: /, "").replace(/\.+$/, "");
    steps.push({ step: "Verifica", time: hms(verifiedRow.ts), detail: `${desc}${c === true ? ". Confirmed" : c === false ? ". Not confirmed" : ""}` });
  } else if (m.kind === "patrol" && rows.some((r) => r.kind.startsWith("patrol."))) {
    const look = last((r) => r.kind === "patrol.look" || r.kind === "patrol.round" || r.kind === "patrol.known");
    steps.push({ step: "Verifica", time: look ? hms(look.ts) : null, detail: look?.message ?? "Pending" });
  } else steps.push({ step: "Verifica", time: null, detail: closed ? "No check" : "Pending" });
  // Alert
  const sent = rows.filter((r) => r.kind === "alert.sent");
  if (sent.length) {
    const res = sent.flatMap((r) => ((r.data as { results?: { channel?: string; ok?: boolean }[] } | null)?.results ?? []));
    const chans = [...new Set(res.map((x) => `${channelLabel(channelOf(x.channel))}${x.ok === false ? " (failed)" : ""}`))];
    steps.push({ step: "Alert", time: hms(sent[sent.length - 1].ts), detail: `${chans.join(", ") || "Console"}: sent` });
  } else steps.push({ step: "Alert", time: null, detail: closed ? "No alert" : "Not sent yet" });
  // Chiusura
  const endRow = last((r) => stepOf(r.kind) === "Chiusura");
  steps.push({ step: "Chiusura", time: closed ? at(endRow?.ts ?? m.ended) : null, detail: closed ? (endRow?.message ?? (m.note || "Closed")) : "In progress" });

  const battery = live.dog?.battery;
  return {
    id: m.id,
    eventId: ev?.id ?? m.event_ids[0] ?? "—",
    dogId: LIVE_DOG_ID,
    robot: LIVE_DOG_NAME,
    battery: battery == null ? null : Math.round(battery),
    sighting,
    automationId,
    // il backend non dice chi l'ha creata (console, Telegram, Grok o il ritorno automatico alla base): non lo inventiamo
    createdBy: undefined,
    trigger,
    triggerLabel,
    roomId: place.roomId,
    room: place.room,
    spot: place.spot,
    status: statusOf(m, ev, arrivedTs != null, check),
    eventTime: hms(t0),
    ts: t0,
    arrivalSeconds,
    outcome,
    steps,
  };
}

const channelLabel = (c: AlertSent["channel"]) => channelLabels[c];

// ── tutto insieme ────────────────────────────────────
/** Missioni (dalla più recente), allarmi inviati e turno dallo stato live. */
export function buildConsole(live: Live): Omit<ConsoleData, "live" | "ready"> {
  const eventsById = new Map(live.events.map((e) => [e.id, e]));
  const known = new Map<string, ServerMission>();
  // dal registro le più vecchie, poi la storia della console, poi coda e corrente (le più aggiornate)
  const byMission = new Map<string, LogEntry[]>();
  for (const r of live.log) if (r.mission_id) byMission.set(r.mission_id, [...(byMission.get(r.mission_id) ?? []), r]);
  for (const [id, rows] of byMission) if (rows.some((r) => r.kind === "mission.queued")) known.set(id, fromLog(id, live.log.filter((r) => r.mission_id === id || (r.event_id && rows.some((x) => x.event_id === r.event_id)))));
  for (const m of [...live.history].reverse()) known.set(m.id, { ...known.get(m.id), ...m });
  for (const m of [...live.queue, ...(live.current ? [live.current] : [])]) known.set(m.id, m);
  // il registro dice come è finita una missione che la console ha visto sparire
  for (const [id, m] of known) {
    if (!M_CLOSED.has(m.status) || live.current?.id === id || live.queue.some((q) => q.id === id)) continue;
    const end = [...(byMission.get(id) ?? [])].reverse().find((r) => r.kind === "mission.done" || r.kind === "mission.cancelled");
    if (end) known.set(id, { ...m, status: end.kind === "mission.cancelled" ? "cancelled" : "done", ended: m.ended ?? end.ts });
    // eventi agganciati dopo (mission.merged)
    const extra = (byMission.get(id) ?? []).map((r) => r.event_id).filter((e): e is string => !!e && !m.event_ids.includes(e));
    if (extra.length) known.set(id, { ...known.get(id)!, event_ids: [...m.event_ids, ...new Set(extra)] });
  }
  const missions = [...known.values()].map((m) => toConsoleMission(m, live, live.log, eventsById)).sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));

  // allarmi: le righe alert.sent del registro, una per canale
  const alerts: ConsoleAlert[] = [];
  const seen = new Set<string>();
  for (const r of live.log) {
    if (r.kind !== "alert.sent") continue;
    const d = (r.data ?? {}) as { alert?: { title?: string; sms?: string }; results?: { channel?: string; ok?: boolean; error?: string | null }[] };
    const ev = r.event_id ? eventsById.get(r.event_id) : undefined;
    if (r.event_id) seen.add(r.event_id);
    const text = d.alert?.sms ?? r.message;
    for (const x of d.results?.length ? d.results : [{ channel: "console", ok: true }]) {
      const ch = channelOf(x.channel);
      alerts.push({ time: hms(r.ts), ts: r.ts, missionId: r.mission_id ?? ev?.mission_id ?? "—", channel: ch, to: channelTo[ch], text, delivered: x.ok !== false });
    }
  }
  // eventi con l'alert ma senza la riga del registro (registro troncato)
  for (const e of live.events) {
    if (!e.alert || seen.has(e.id)) continue;
    const ts = e.ts + (e.timings.alerted ?? 0);
    const res = Array.isArray(e.alert_results) ? (e.alert_results as { channel?: string; ok?: boolean }[]) : [{ channel: "console", ok: true }];
    for (const x of res) {
      const ch = channelOf(x.channel);
      alerts.push({ time: hms(ts), ts, missionId: e.mission_id ?? "—", channel: ch, to: channelTo[ch], text: e.alert.sms ?? e.alert.title ?? "", delivered: x.ok !== false });
    }
  }
  alerts.sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));

  return { missions, alerts, shift: shiftOf(live) };
}

/** Nome, giorno e numeri del turno, da `shift` (inizio) e `stats` del backend. */
export function shiftOf(live: Pick<Live, "shift" | "stats" | "events">): ShiftView {
  const startTs = live.shift ?? Date.now() / 1000;
  const d = new Date(startTs * 1000);
  const h = d.getHours();
  const name = h >= 5 && h < 12 ? "Morning shift" : h >= 12 && h < 18 ? "Afternoon shift" : h >= 18 && h < 22 ? "Evening shift" : "Night shift";
  const date = d.toLocaleDateString("en-GB", { day: "numeric", month: "long" });
  const s = live.stats;
  const forwarded = live.events.filter((e) => e.status === "alerted" && e.verification?.confirmed === false).length;
  const closed = live.events.filter((e) => EV_CLOSED.has(e.status)).length;
  return {
    day: isoDay(d),
    label: `${name} · ${date}`,
    name,
    date,
    start: `${pad(d.getHours())}:${pad(d.getMinutes())}`,
    end: "now",
    events: s?.events ?? 0,
    confirmed: s?.confirmed ?? 0,
    falseAlarmsBlocked: (s?.filtered ?? 0) + (s?.cleared ?? 0),
    falseAlarmsForwarded: forwarded,
    avgArrivalSeconds: s?.avg_arrival_s ?? null,
    // eventi chiusi (con un esito nel registro) su tutti quelli del turno
    logCompleteness: live.events.length ? Math.round((closed / live.events.length) * 100) : null,
    startTs: live.shift,
  };
}

// ── mock (backend offline) ───────────────────────────
const MOCK: Omit<ConsoleData, "ready"> = {
  missions: mockMissions.map((m) => ({ ...m, robot: dogName(m.dogId), room: roomName(m.roomId), spot: "", ts: null })),
  alerts: mockAlerts.map((a) => ({ ...a, ts: null })),
  shift: { ...mockShift, startTs: null },
  live: false,
};

/** Missioni, allarmi e turno per la console: quelli veri col backend online, quelli di mock offline. */
export function useConsoleData(): ConsoleData {
  const live = useLive();
  const { backendOnline, ready, log, events, current, queue, history, stats, shift, site, cameras, dog } = live;
  const battery = dog?.battery;
  return useMemo(() => {
    if (!backendOnline) return { ...MOCK, ready };
    return { ...buildConsole({ ...live, log, events, current, queue, history, stats, shift, site, cameras }), live: true, ready };
    // il tick arriva 4 volte al secondo: si ricalcola solo quando cambia qualcosa che conta (non la posa del cane)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backendOnline, ready, log, events, current, queue, history, stats, shift, site, cameras, battery]);
}

