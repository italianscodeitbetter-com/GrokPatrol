"use client";

import Link from "next/link";
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import Image from "next/image";
import { Bell } from "lucide-react";
import { log, missions, stepLabels } from "@/lib/mock";
import { useConsoleEvents, type ConsoleEvent } from "@/lib/events";
import { useConsoleData, type ConsoleMission } from "@/lib/missions";
import { outcomeLabel, statusLabel } from "@/components/ui";

// Pezzi della barra in alto sulla dashboard: bot a sinistra, turno e ora al centro, notifiche a destra.

/** Popover che si chiude cliccando fuori o con Esc. */
function usePopover() {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);
  return { open, setOpen, ref };
}

/** Un bot nella fila: il cane live (batteria null = non nota, «offline» = scollegato) o un bot spento di mock. */
type RowBot = { id: string; name: string; battery: number | null; state: string };

/** In alto a sinistra: i bot come icone tonde, uno accanto all'altro. Clic → si apre il pannello a sinistra su quel bot. */
export function BotsRow({ bots, open, selected, onPick }: { bots: RowBot[]; open: boolean; selected: string | null; onPick: (id: string) => void }) {
  return (
    <div role="toolbar" aria-label="Bots" className="flex items-center gap-1.5 rounded-full border border-line bg-app/85 p-1 backdrop-blur">
      {bots.map((d) => {
        const off = d.state === "spento" || d.state === "offline";
        const active = open && selected === d.id;
        return (
          <button
            key={d.id}
            onClick={() => onPick(d.id)}
            aria-label={`${d.name}${off ? ", off" : ""}`}
            aria-pressed={active}
            aria-controls="bots-panel"
            title={`${d.name} · ${off ? (d.state === "offline" ? "Disconnected" : "Off") : d.battery == null ? "—" : `${d.battery}%`}`}
            className={`relative size-9 shrink-0 rounded-full ring-2 transition ${active ? "ring-accent" : "ring-transparent hover:ring-line"}`}
          >
            <span className={`block size-full overflow-hidden rounded-full bg-[radial-gradient(circle_at_40%_45%,#2a2a2a,#141414)] ${off ? "opacity-40 grayscale" : ""}`}>
              <Image src="/robot-dog.png" alt="" width={72} height={72} className="size-full scale-150 object-cover object-[40%_45%]" />
            </span>
            {/* acceso = verde (rosso sotto il 30%), spento = grigio */}
            <span
              className={`absolute -bottom-0.5 -right-0.5 size-3 rounded-full border-2 border-app ${off || d.battery == null ? "bg-faint" : d.battery <= 30 ? "bg-red-400" : d.battery < 50 ? "bg-accent" : "bg-ok"}`}
              aria-hidden
            />
          </button>
        );
      })}
    </div>
  );
}

// ora del browser, aggiornata ogni secondo; durante il prerender non c'è (niente `new Date()` lato server)
const subscribeClock = (cb: () => void) => {
  const t = setInterval(cb, 1000);
  return () => clearInterval(t);
};
const clockNow = () => Math.floor(Date.now() / 1000);

/** Secondi dall'epoch, aggiornati ogni secondo; null durante il prerender. */
export const useNow = () => useSyncExternalStore(subscribeClock, clockNow, () => null);

/** Al centro: turno, orari del turno e ora attuale. Live: il turno del backend (da quando è iniziato); offline il mock. */
export function ShiftClock() {
  const now = useNow();
  const { shift, live } = useConsoleData();
  const time = now == null ? "--:--:--" : new Date(now * 1000).toLocaleTimeString("en-GB");
  return (
    <div className="flex h-10 items-center gap-3 rounded-xl border border-line bg-app/85 px-3 text-sm backdrop-blur">
      <span className="font-mono text-base tabular-nums text-ink" aria-label="Current time">
        {time}
      </span>
      {[shift.name, shift.date, live ? `Since ${shift.start}` : `${shift.start}–${shift.end}`].map((part) => (
        <span key={part} className="contents">
          <span className="h-4 w-px bg-line" aria-hidden />
          <span className="whitespace-nowrap text-muted">{part}</span>
        </span>
      ))}
    </div>
  );
}

// le attività più recenti prima; «nuove» = quelle dopo le 11:00 finché non apri il pannello
const activity = [...log].sort((a, b) => b.time.localeCompare(a.time));
const UNREAD_FROM = "11:00:00";

/** Una riga del pannello: con il backend online sono gli eventi veri (uno per evento, nello stato attuale),
 *  offline le attività di mock. */
type ActivityRow = { key: string; title: string; time: string; detail: string; ids: string; href: string | null; ts?: number | null };

const mockRows: ActivityRow[] = activity.map((a, i) => {
  const mission = missions.find((m) => m.eventId === a.eventId);
  return {
    key: String(i),
    title: stepLabels[a.step],
    time: a.time,
    detail: a.detail,
    ids: `${a.eventId}${mission ? ` · ${mission.id}` : ""}`,
    href: mission ? `/missions/${mission.id}` : null,
  };
});

const eventRow = (e: ConsoleEvent): ActivityRow => ({
  key: e.id,
  title: statusLabel(e.status),
  time: e.time,
  detail: [`${e.sourceLabel} · ${e.anomaly}`, e.grokDecision, e.grokReason].filter(Boolean).join(". "),
  ids: `${e.id}${e.missionId ? ` · ${e.missionId}` : ""}`,
  // la pagina della missione del backend (/missions/m-xxxxx)
  href: e.missionId ? `/missions/${e.missionId}` : null,
  ts: e.ts,
});

/** Le missioni senza evento (ronde, «vai a», comandi): una riga ciascuna, nel loro stato attuale. */
const missionRow = (m: ConsoleMission): ActivityRow => ({
  key: m.id,
  title: m.outcome === "in_corso" ? statusLabel(m.status) : outcomeLabel(m.outcome),
  time: m.eventTime,
  detail: [m.triggerLabel, m.steps.findLast((s) => s.time)?.detail].filter(Boolean).join(". "),
  ids: m.id,
  href: `/missions/${m.id}`,
  ts: m.ts,
});

/** A destra: cerchio con la campanella; apre le attività del turno. */
export function NotificationsBell() {
  const { open, setOpen, ref } = usePopover();
  const [seen, setSeen] = useState(false);
  // eventi veri: «nuovi» = arrivati dopo l'ultima apertura del pannello (secondi dall'epoch)
  const [seenTs, setSeenTs] = useState(0);
  const { events, live } = useConsoleEvents();
  const { missions: liveMissions } = useConsoleData();
  const rows = live
    ? [...events.map(eventRow), ...liveMissions.filter((m) => m.eventId === "—").map(missionRow)].sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0))
    : mockRows;
  const unread = live
    ? events.filter((e) => (e.ts ?? 0) > seenTs).length
    : seen
      ? 0
      : activity.filter((a) => a.time >= UNREAD_FROM).length;
  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => {
          setOpen(!open);
          setSeen(true);
          setSeenTs(Math.max(seenTs, ...events.map((e) => e.ts ?? 0)));
        }}
        aria-label={unread ? `Activity, ${unread} new` : "Activity"}
        aria-expanded={open}
        className="relative grid size-10 place-items-center rounded-full border border-line bg-app/85 text-ink backdrop-blur transition-colors hover:border-[#3a3a3a]"
      >
        <Bell className="size-[18px]" strokeWidth={1.75} />
        {unread > 0 && (
          <span className="absolute -right-1 -top-1 grid h-5 min-w-5 place-items-center rounded-full bg-red-500 px-1 font-mono text-[13px] font-medium tabular-nums text-white">
            {unread}
          </span>
        )}
      </button>
      {open && (
        <div role="dialog" aria-label="Activity" className="absolute right-0 top-full z-30 mt-2 w-[360px] max-w-[calc(100vw-2rem)] rounded-2xl border border-line bg-panel shadow-2xl shadow-black/50">
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="text-sm font-medium">Activity</h2>
            <Link href="/reports#activity" onClick={() => setOpen(false)} className="text-sm text-muted hover:text-ink">
              View all
            </Link>
          </div>
          <ul className="max-h-[420px] divide-y divide-line overflow-y-auto">
            {rows.length === 0 && <li className="px-4 py-3 text-sm text-muted">No events yet.</li>}
            {rows.map((a) => {
              const row: ReactNode = (
                <>
                  <span className="mt-1.5 size-2 shrink-0 rounded-full bg-accent/80" aria-hidden />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center justify-between gap-2 text-sm">
                      <span className="text-ink">{a.title}</span>
                      <span className="font-mono tabular-nums text-muted">{a.time}</span>
                    </span>
                    <span className="mt-0.5 block text-sm text-muted">{a.detail}</span>
                    <span className="mt-0.5 block font-mono text-sm text-faint">{a.ids}</span>
                  </span>
                </>
              );
              return (
                <li key={a.key}>
                  {a.href ? (
                    <Link href={a.href} className="flex gap-3 px-4 py-3 transition-colors hover:bg-hover">
                      {row}
                    </Link>
                  ) : (
                    <div className="flex gap-3 px-4 py-3">{row}</div>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      )}
    </div>
  );
}
