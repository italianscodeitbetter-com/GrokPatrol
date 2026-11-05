"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type ReactNode } from "react";
import { Bot, CircleCheck, ClockFading, UserRound } from "lucide-react";
import { DayPicker } from "@/components/DayPicker";
import { NewMission } from "@/components/NewMission";
import { BatteryTag } from "@/components/robot";
import { CountChip, OutcomeBadge, PageHeader, Panel, StatusBadge } from "@/components/ui";
import { triggerLabels } from "@/lib/mock";
import { useConsoleData, type ConsoleMission as Mission } from "@/lib/missions";

const fmtArrival = (s: number | null) => (s == null ? "—" : `${s} s`);

/** Il giorno si sceglie in alto, come in Reports. In corso sopra (la corrente e la coda del backend), completate sotto
 *  (la storia del turno), entrambe in tabella: ogni riga apre /missions/<id>. I dati ci sono solo per il giorno del turno. */
export function MissionsView() {
  const { missions, shift } = useConsoleData();
  // Quando una missione finisce passa dalla tabella «In progress» a «Completed».
  const inProgress = missions.filter((m) => m.outcome === "in_corso");
  const completed = missions.filter((m) => m.outcome !== "in_corso");
  const [picked, setDay] = useState<string | null>(null);
  const day = picked ?? shift.day;
  const hasData = day === shift.day;

  return (
    <>
      <PageHeader title="Missions" center={<DayPicker value={day} onChange={setDay} marked={[shift.day]} />} actions={<NewMission />} />

      {!hasData ? (
        <Panel>
          <p className="py-10 text-center text-sm text-muted">No missions for this day.</p>
        </Panel>
      ) : (
        <div className="flex flex-col gap-8">
          <Section title="In progress" count={inProgress.length} icon={<ClockFading className="size-4 text-amber-300" strokeWidth={2} />}>
            <Panel flat bodyClassName="p-0">
              {inProgress.length ? <MissionTable missions={inProgress} /> : <p className="px-4 py-6 text-sm text-muted">No missions in progress.</p>}
            </Panel>
          </Section>
          <Section title="Completed" count={completed.length} icon={<CircleCheck className="size-4 text-ok" strokeWidth={2} />}>
            <Panel flat bodyClassName="p-0">
              {completed.length ? <MissionTable missions={completed} /> : <p className="px-4 py-6 text-sm text-muted">No completed missions yet.</p>}
            </Panel>
          </Section>
        </div>
      )}
    </>
  );
}

function Section({ title, count, icon, children }: { title: string; count: number; icon: ReactNode; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-3 flex items-center gap-2 text-[15px] font-medium">
        {icon}
        {title}
        <CountChip n={count} />
      </h2>
      {children}
    </section>
  );
}

/** Un solo stato: finché è in corso il passo (Queued, Verifying…), poi l'esito (Real anomaly / No anomaly). */
function MissionState({ m }: { m: Mission }) {
  return m.outcome === "in_corso" ? <StatusBadge status={m.status} /> : <OutcomeBadge outcome={m.outcome} />;
}

/** «Automation» (partita da un'automazione) o «New mission» (creata a mano da una persona: chi l'ha creata sta nella pagina della missione). */
function OriginTag({ m }: { m: Mission }) {
  return m.automationId ? (
    <span className="inline-flex w-fit items-center gap-1.5 rounded-full bg-sky-400/10 px-2 py-0.5 text-sm font-medium text-sky-300 ring-1 ring-inset ring-sky-400/25">
      <Bot className="size-3.5" strokeWidth={2} /> Automation
    </span>
  ) : (
    <span className="inline-flex w-fit items-center gap-1.5 rounded-full bg-violet-400/10 px-2 py-0.5 text-sm font-medium text-violet-300 ring-1 ring-inset ring-violet-400/25">
      <UserRound className="size-3.5" strokeWidth={2} /> New mission
    </span>
  );
}

function MissionTable({ missions }: { missions: Mission[] }) {
  const router = useRouter();
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead className="text-sm text-muted">
          <tr className="border-b border-line [&>th:first-child]:rounded-tl-xl [&>th:last-child]:rounded-tr-xl [&>th]:bg-panel">
            <th className="px-4 py-2.5 font-normal">ID</th>
            <th className="px-2 py-2.5 font-normal">Robot</th>
            <th className="px-2 py-2.5 font-normal">Type</th>
            <th className="px-2 py-2.5 font-normal">Trigger</th>
            <th className="px-2 py-2.5 font-normal">Response</th>
            <th className="px-4 py-2.5 font-normal">Status</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line">
          {/* righe centrate in verticale: chip, risposta e stato a metà riga */}
          {missions.map((m) => (
            <tr key={m.id} onClick={() => router.push(`/missions/${m.id}`)} className="cursor-pointer align-middle transition-colors hover:bg-hover">
              <td className="whitespace-nowrap px-4 py-3">
                <Link
                  href={`/missions/${m.id}`}
                  onClick={(e) => e.stopPropagation()}
                  className="font-mono text-sm text-ink focus:outline-none focus-visible:underline"
                >
                  {m.id}
                </Link>
                <div className="text-sm text-muted">
                  <span className="font-mono tabular-nums text-faint">{m.eventTime}</span> · {m.room}
                </div>
              </td>
              <td className="whitespace-nowrap px-2 py-3">
                <div className="text-sm text-ink/90">{m.robot}</div>
                {/* la batteria del cane quando è partita la missione */}
                <div className="mt-0.5">
                  {m.battery == null ? <span className="font-mono text-sm text-faint">—</span> : <BatteryTag battery={m.battery} />}
                </div>
              </td>
              <td className="px-2 py-3">
                <OriginTag m={m} />
              </td>
              <td className="px-2 py-3">
                <div className="text-sm text-ink/90">{triggerLabels[m.trigger]}</div>
                <div className="text-sm text-muted">{m.triggerLabel}</div>
              </td>
              <td className="whitespace-nowrap px-2 py-3 font-mono text-sm tabular-nums">{fmtArrival(m.arrivalSeconds)}</td>
              <td className="px-4 py-3">
                <MissionState m={m} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
