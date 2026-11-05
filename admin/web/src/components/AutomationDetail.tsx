"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type ReactNode } from "react";
import { ArrowLeft, Pause, Play, Route, ShieldCheck, ShieldOff, Trash2 } from "lucide-react";
import { Dropdown } from "@/components/Dropdown";
import { BatteryTag, RobotAvatar } from "@/components/robot";
import { Badge, OutcomeBadge, PageHeader, Panel, StatusBadge } from "@/components/ui";
import { deleteAutomation, letter, meters, roomAt, setAutomationActive, useAutomations, type ConsoleAutomation } from "@/lib/automation-store";
import {
  deleteServerAutomation,
  runServerAutomation,
  scheduleRoute,
  setAlarm,
  setServerAutomationActive,
  startRoute,
  type Result,
} from "@/lib/automations-live";
import { useConsoleData } from "@/lib/missions";

const button = "flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-1.5 text-sm text-ink hover:bg-hover";
const everyOptions = [
  { value: 0, label: "Not scheduled" },
  ...[15, 30, 60, 120].map((m) => ({ value: m, label: `Every ${m < 60 ? `${m} min` : `${m / 60} ${m === 60 ? "hour" : "hours"}`}` })),
];

/** La pagina di un'automazione: cosa fa, con quale robot, quando parte, il percorso e le missioni che ha fatto partire.
 *  Col backend online sono quelle del server (allarme, ronde del sito, create dall'operatore), offline quelle di mock.ts
 *  e del browser: si leggono dopo l'idratazione. */
export function AutomationDetail({ id }: { id: string }) {
  const router = useRouter();
  const { live, ready, list, fleet } = useAutomations();
  const { missions } = useConsoleData();
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const a = list.find((x) => x.id === id);

  if (!a) {
    if (!ready) return null;
    return (
      <>
        <BackLink />
        <Panel>
          <p className="py-10 text-center text-sm text-muted">Automation {id} not found.</p>
        </Panel>
      </>
    );
  }

  const dog = fleet.find((d) => d.id === a.dogId);
  const off = dog?.state === "spento";
  const start = a.startsAt;
  const launched = missions.filter((m) => m.automationId === a.id);
  const path = a.path;
  /** Esegue un comando del server e dice com'è andata sotto l'intestazione. */
  const run = async (f: () => Promise<Result>, done: string) => {
    const r = await f();
    setNote(r.ok ? { ok: true, text: done } : { ok: false, text: r.error ?? "Failed" });
  };
  const pause = (x: ConsoleAutomation) =>
    live ? void run(() => setServerAutomationActive(x.id, !x.active), x.active ? "Paused" : "Resumed") : setAutomationActive(x.id, !x.active);
  const remove = async (x: ConsoleAutomation) => {
    if (live) {
      const r = await deleteServerAutomation(x.id);
      if (!r.ok) return setNote({ ok: false, text: r.error ?? "Failed" });
    } else deleteAutomation(x.id);
    router.push("/automation");
  };

  return (
    <>
      <BackLink />
      <PageHeader
        title={a.name}
        subtitle={a.id}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone={a.active ? "green" : "gray"}>{a.statusLabel ?? (a.active ? "Active" : "Paused")}</Badge>
            {a.editablePath && (
              <Link href={`/automation/${a.id}/path`} className={button}>
                <Route className="size-4" strokeWidth={1.75} /> Change path
              </Link>
            )}
            {a.kind === "server" && (
              <button onClick={() => run(() => runServerAutomation(a.id), "Started: the dog is on its way")} className={button}>
                <Play className="size-4" /> Run now
              </button>
            )}
            {a.kind === "route" && (
              <>
                <button onClick={() => run(() => startRoute(a.id), "Started: the dog is on its way")} className={button}>
                  <Play className="size-4" /> Start now
                </button>
                <div className="w-44">
                  <Dropdown
                    label="Schedule"
                    value={a.everyMin ?? 0}
                    options={everyOptions}
                    onChange={(m) => run(() => scheduleRoute(a.id, m), m ? `Scheduled every ${m} min` : "Schedule removed")}
                  />
                </div>
              </>
            )}
            {a.kind === "alarm" && (
              <button onClick={() => run(() => setAlarm(!a.active), a.active ? "Alarm disarmed" : "Alarm armed")} className={button}>
                {a.active ? <ShieldOff className="size-4" /> : <ShieldCheck className="size-4" />}
                {a.active ? "Disarm" : "Arm alarm"}
              </button>
            )}
            {a.custom && (
              <>
                <button onClick={() => pause(a)} className={button}>
                  {a.active ? <Pause className="size-4" /> : <Play className="size-4" />}
                  {a.active ? "Pause" : "Resume"}
                </button>
                <button
                  onClick={() => void remove(a)}
                  className="flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-1.5 text-sm text-muted hover:bg-hover hover:text-red-400"
                >
                  <Trash2 className="size-4" /> Delete
                </button>
              </>
            )}
          </div>
        }
      />
      {note && (
        <p role="status" className={`-mt-2 mb-4 text-sm ${note.ok ? "text-muted" : "text-red-400"}`}>
          {note.text}
        </p>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Panel title="Details">
          <dl className="grid gap-4 text-sm">
            <Field label="Robot">
              {dog ? (
                <span className="flex items-center gap-2">
                  <RobotAvatar off={off} />
                  {dog.name}
                  {dog.battery != null && <BatteryTag battery={dog.battery} off={off} />}
                </span>
              ) : (
                <span className="text-faint">No robot</span>
              )}
            </Field>
            <Field label="Start">{start ? <span className="font-mono tabular-nums">{start}</span> : (a.badge ?? "On event")}</Field>
            <Field label="When">{a.trigger}</Field>
            <Field label="What it does">{a.action}</Field>
            <div className="grid grid-cols-2 gap-4">
              <Field label="Last run">
                <span className="font-mono tabular-nums">{a.lastRun ?? "—"}</span>
              </Field>
              <Field label="Runs today">
                <span className="font-mono tabular-nums">{a.runsToday}</span>
              </Field>
            </div>
          </dl>
        </Panel>

        {path && (
          <Panel title="Route" count={path.route.length}>
            <ol className="divide-y divide-line rounded-lg border border-line">
              {path.route.map((p, i) => (
                <li key={i} className="flex items-center gap-3 px-3 py-2 text-sm">
                  <span className="grid size-6 shrink-0 place-items-center rounded-full bg-accent font-mono font-semibold text-app">{letter(i)}</span>
                  <span className="flex-1">{roomAt(p)}</span>
                  <span className="font-mono tabular-nums text-muted">
                    {meters(p.x)} m, {meters(p.y)} m
                  </span>
                </li>
              ))}
            </ol>
            {path.loop && <p className="mt-3 text-sm text-muted">Returns to A at the end.</p>}
          </Panel>
        )}
        {!a.custom && (
          <Panel title="Missions started" count={launched.length} bodyClassName="p-0">
            {launched.length ? (
              <ul className="divide-y divide-line">
                {launched.map((m) => (
                  <li key={m.id}>
                    <Link href={`/missions/${m.id}`} className="flex items-center justify-between gap-3 px-4 py-3 text-sm transition-colors hover:bg-hover">
                      <span>
                        <span className="font-mono text-ink">{m.id}</span>
                        <span className="block text-muted">
                          <span className="font-mono tabular-nums text-faint">{m.eventTime}</span> · {m.room}
                        </span>
                      </span>
                      {m.outcome === "in_corso" ? <StatusBadge status={m.status} /> : <OutcomeBadge outcome={m.outcome} />}
                    </Link>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="px-4 py-6 text-sm text-muted">No missions from this automation today.</p>
            )}
          </Panel>
        )}
      </div>
    </>
  );
}

function BackLink() {
  return (
    <Link href="/automation" className="mb-4 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
      <ArrowLeft className="size-4" strokeWidth={1.75} /> Automation
    </Link>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt className="text-faint">{label}</dt>
      <dd className="mt-0.5 text-ink/90">{children}</dd>
    </div>
  );
}
