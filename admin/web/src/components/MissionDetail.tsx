"use client";

import Link from "next/link";
import { ArrowLeft, Download } from "lucide-react";
import { DogCam } from "@/components/FloorMap3D";
import { Badge, OutcomeBadge, PageHeader, Panel, StatusBadge } from "@/components/ui";
import { stepLabels, triggerLabels } from "@/lib/mock";
import { useConsoleData, type ConsoleMission } from "@/lib/missions";

// Una pagina per missione: a sinistra lo stato e la timeline, a destra il video.
/** Il dettaglio di una missione: dal backend se è online (id m-xxxxx), dal mock offline. Si aggiorna dal vivo. */
export function MissionDetail({ id }: { id: string }) {
  const { missions, ready } = useConsoleData();
  const mission = missions.find((m) => m.id === id);
  if (!mission)
    return (
      <>
        <Link href="/missions" className="mb-4 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
          <ArrowLeft className="size-4" strokeWidth={1.75} /> Missions
        </Link>
        <PageHeader title={id} />
        <Panel>
          <p className="py-10 text-center text-sm text-muted">{ready ? "Mission not found in this shift." : "Loading…"}</p>
        </Panel>
      </>
    );

  const live = mission.outcome === "in_corso";

  return (
    <>
      <Link href="/missions" className="mb-4 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
        <ArrowLeft className="size-4" strokeWidth={1.75} /> Missions
      </Link>
      <PageHeader
        title={`${mission.id} · ${mission.room}`}
        actions={
          <div className="flex items-center gap-3">
            <OutcomeBadge outcome={mission.outcome} />
            {/* Il file arriverà dalla registrazione del cane: per ora va messo a mano in public/videos/<id>.mp4. */}
            <a
              href={`/videos/${mission.id}.mp4`}
              download={`grokpatrol-${mission.id}-${mission.eventId}.mp4`}
              className="flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-1.5 text-sm text-ink hover:bg-hover"
            >
              <Download className="size-4" strokeWidth={1.75} />
              Download video
            </a>
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-12">
        <Panel title="Mission status" action={<StatusBadge status={mission.status} />} className="lg:col-span-4">
          <dl className="mb-5 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
            <dt className="text-muted">Trigger</dt>
            <dd>{triggerLabels[mission.trigger]} · {mission.triggerLabel}</dd>
            <dt className="text-muted">Event</dt>
            <dd className="font-mono">{mission.eventId} · {mission.eventTime}</dd>
            {mission.createdBy && (
              <>
                <dt className="text-muted">Created by</dt>
                <dd>{mission.createdBy}</dd>
              </>
            )}
            <dt className="text-muted">Robot</dt>
            <dd>{mission.robot}</dd>
            <dt className="text-muted">Saw</dt>
            <dd>{mission.sighting ?? "Not on site yet"}</dd>
            <dt className="text-muted">Response time</dt>
            <dd className="font-mono">{mission.arrivalSeconds == null ? "—" : `${mission.arrivalSeconds} s`}</dd>
          </dl>
          <Timeline steps={mission.steps} />
        </Panel>

        <Panel
          title={live ? "Dog video" : "Recording"}
          action={live ? <Badge tone="red">● LIVE</Badge> : <span className="text-sm text-muted">{mission.eventTime}</span>}
          className="lg:col-span-8"
        >
          {/* la telecamera di bordo del cane (simulata nella scena 3D): dal vivo se la missione è in corso, altrimenti la registrazione */}
          <DogCam dogId={mission.dogId} tag={`${mission.id} · ${mission.eventId}`} live={live} at={mission.eventTime} />
        </Panel>
      </div>
    </>
  );
}

function Timeline({ steps }: { steps: ConsoleMission["steps"] }) {
  return (
    <ol className="relative">
      {steps.map((s, i) => {
        const done = s.time != null;
        const last = i === steps.length - 1;
        return (
          <li key={s.step} className="relative flex gap-3 pb-5 last:pb-0">
            {!last && <span className="absolute left-[5px] top-4 h-full w-px bg-line" aria-hidden />}
            <span
              className={`relative mt-1 size-[11px] shrink-0 rounded-full border ${done ? "border-accent bg-accent/80" : "border-faint bg-app"}`}
            />
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline justify-between gap-2">
                <span className={`text-sm ${done ? "text-ink" : "text-muted"}`}>{stepLabels[s.step]}</span>
                <span className={`font-mono text-sm tabular-nums ${done ? "text-ink" : "text-faint"}`}>{s.time ?? "—"}</span>
              </div>
              <p className="mt-0.5 text-sm leading-relaxed text-muted">
                <WhiteNumbers text={s.detail} />
              </p>
            </div>
          </li>
        );
      })}
    </ol>
  );
}

// Orari, secondi, frame e sigle con numero (CAM-3, MS-0088, P1, #8812) in bianco, il resto del testo resta grigio.
const NUMBER = /((?:\b[A-Z]{2,3}-|\bP|(?<![A-Za-z\d]))[#+]?\d+(?::\d+)*(?![A-Za-z])(?: s\b)?)/;

function WhiteNumbers({ text }: { text: string }) {
  return text.split(NUMBER).map((part, i) =>
    i % 2 ? (
      <span key={i} className="text-ink">
        {part}
      </span>
    ) : (
      part
    ),
  );
}
