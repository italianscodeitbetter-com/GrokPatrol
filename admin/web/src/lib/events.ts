"use client";

import { useMemo } from "react";
import { useLive, type Live, type ServerEvent, type ServerEventStatus } from "@/lib/backend";
import { siteToPlan, type PlanXY } from "@/lib/coords";
import { events as mockEvents, rooms, type Event, type EventStatus, type Priority } from "@/lib/mock";

// Eventi delle telecamere del backend (server/mission.py `Event.public()`) nella forma `Event` della UI.
// Con il backend online si vedono solo quelli veri (anche nessuno); il mock serve solo a vedere il design offline.

/** Un evento come lo mostra la console. x/y = null quando non si sa dove metterlo sulla pianta (niente segnaposto). */
export type ConsoleEvent = Omit<Event, "x" | "y"> & {
  x: number | null;
  y: number | null;
  /** Secondi dall'epoch (null per il mock). */
  ts: number | null;
  missionId: string | null;
};

/** Stanza (di mock.ts) che contiene il punto della pianta, "" se fuori. */
export const roomAt = (p: PlanXY) => rooms.find((r) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h)?.id ?? "";

const STATUS: Record<ServerEventStatus, EventStatus> = {
  received: "in_valutazione",
  assessing: "in_valutazione",
  dispatched: "missione",
  verifying: "verifica",
  alerted: "alert",
  dismissed: "falso_allarme",
  cleared: "chiuso",
  cancelled: "chiuso",
};

/** Quello che serve per adattare un evento: il sito (posizioni) e le camere live (nomi). */
type Ctx = Pick<Live, "site" | "cameras">;

// stessa tabella di KIND_SEVERITY in server/mission.py: vale finché Grok non ha dato la sua severità
const KIND_SEVERITY: Record<string, number> = { intrusion: 4, abandoned_object: 3, manual: 3, patrol_finding: 3, person: 4, motion: 3 };

const priorityOf = (severity: number): Priority => (severity >= 4 ? "alta" : severity === 3 ? "media" : "bassa");

const KIND_LABEL: Record<string, string> = {
  manual: "Manual trigger",
  motion: "Motion",
  person: "Person detected",
  intrusion: "Intrusion",
  abandoned_object: "Abandoned object",
  patrol_finding: "Patrol finding",
};
const label = (kind: string) => KIND_LABEL[kind] ?? kind.charAt(0).toUpperCase() + kind.slice(1).replaceAll("_", " ");

function decision(e: ServerEvent): string {
  const a = e.assessment;
  if (!a) return "Assessing…";
  const by = a.by && a.by !== "grok" ? ` (${a.by})` : "";
  return `${a.dispatch ? "Send the dog" : "Don't send the dog"}${by}`;
}

/** Dove mettere l'evento: lo spot di ispezione della camera, se no la camera stessa, se no lo spot nella nota ("spot:z1"). */
function position(e: ServerEvent, live: Ctx): PlanXY | null {
  const site = live.site;
  if (!site) return null;
  const spot = (id: string | undefined) => (id ? site.spots.find((s) => s.id === id) : undefined);
  const cam = site.cameras.find((c) => c.id === e.camera);
  const at = spot(cam?.inspect_spot) ?? cam ?? spot(e.note.startsWith("spot:") ? e.note.slice(5) : undefined);
  return at ? siteToPlan(at.x, at.y) : null;
}

export function toConsoleEvent(e: ServerEvent, live: Ctx): ConsoleEvent {
  const a = e.assessment;
  const p = position(e, live);
  const inSite = live.site?.cameras.some((c) => c.id === e.camera);
  const category = a?.category && a.category !== "none" && a.category !== "other" ? a.category : null;
  return {
    id: e.id,
    time: new Date(e.ts * 1000).toLocaleTimeString("en-GB"),
    ts: e.ts,
    source: "camera",
    // come le etichette delle camere sulla mappa (CAM-1); le camere fuori dal sito (telefoni, cane) col loro nome
    sourceLabel: inSite ? e.camera.toUpperCase() : (live.cameras.find((c) => c.id === e.camera)?.name ?? e.camera),
    roomId: p ? roomAt(p) : "",
    x: p ? Math.round(p.x) : null,
    y: p ? Math.round(p.y) : null,
    anomaly: label(category ?? e.kind),
    priority: priorityOf(Number(a?.severity ?? KIND_SEVERITY[e.kind] ?? 3)),
    status: STATUS[e.status] ?? "in_valutazione",
    grokDecision: decision(e),
    grokReason: a?.reason ?? "",
    missionId: e.mission_id,
  };
}

const MOCK: ConsoleEvent[] = mockEvents.map((e) => ({ ...e, ts: null, missionId: null }));

/** Eventi per la console, dal più recente: quelli veri col backend online, quelli di mock offline. */
export function useConsoleEvents(): { events: ConsoleEvent[]; live: boolean } {
  const { backendOnline, events, site, cameras } = useLive();
  return useMemo(() => {
    if (!backendOnline) return { events: MOCK, live: false };
    return { events: events.map((e) => toConsoleEvent(e, { site, cameras })).reverse(), live: true };
  }, [backendOnline, events, site, cameras]);
}
