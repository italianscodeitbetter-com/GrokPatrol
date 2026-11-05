"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { Pause, Play, Trash2 } from "lucide-react";
import { BatteryTag, RobotAvatar } from "@/components/robot";
import { Badge, Panel } from "@/components/ui";
import { deleteAutomation, setAutomationActive, useAutomations, type ConsoleAutomation } from "@/lib/automation-store";
import { deleteServerAutomation, setServerAutomationActive } from "@/lib/automations-live";

/** Le automazioni del server (allarme, ronde del sito e quelle create con «New automation»); col backend offline
 *  quelle di mock.ts più quelle salvate nel browser. Ogni riga apre /automation/<id>. */
export function AutomationTable() {
  const router = useRouter();
  const { live, list: rows, fleet } = useAutomations();
  const pause = (a: ConsoleAutomation) => (live ? void setServerAutomationActive(a.id, !a.active) : setAutomationActive(a.id, !a.active));
  const remove = (a: ConsoleAutomation) => (live ? void deleteServerAutomation(a.id) : deleteAutomation(a.id));

  return (
    <Panel flat bodyClassName="p-0">
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="text-sm text-muted">
            <tr className="border-b border-line [&>th:first-child]:rounded-tl-xl [&>th:last-child]:rounded-tr-xl [&>th]:bg-panel">
              <th className="px-4 py-2.5 font-normal">Robot</th>
              <th className="px-2 py-2.5 font-normal">Start</th>
              <th className="px-2 py-2.5 font-normal">Description</th>
              <th className="px-4 py-2.5 font-normal">Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-line">
            {/* righe centrate in verticale: robot, chip di partenza e stato a metà riga */}
            {rows.map((a) => {
              const dog = fleet.find((d) => d.id === a.dogId);
              const off = dog?.state === "spento";
              return (
                <tr key={a.id} onClick={() => router.push(`/automation/${a.id}`)} className="cursor-pointer align-middle transition-colors hover:bg-hover">
                  <td className="whitespace-nowrap px-4 py-3">
                    {/* senza robot la cella resta vuota */}
                    {dog && (
                      <span className="flex items-center gap-2 text-sm text-ink">
                        <RobotAvatar off={off} />
                        {dog.name}
                        {dog.battery != null && <BatteryTag battery={dog.battery} off={off} />}
                      </span>
                    )}
                  </td>
                  <td className="whitespace-nowrap px-2 py-3 text-sm">
                    {/* l'ora e, sotto, se si ripete (ogni giorno, lun–ven…); senza ora parte su evento */}
                    {a.startsAt ? (
                      <>
                        <div className="font-mono tabular-nums text-ink/90">{a.startsAt}</div>
                        <div className="text-muted">{a.repeats}</div>
                      </>
                    ) : (
                      <Badge tone="gray">{a.badge ?? "On event"}</Badge>
                    )}
                  </td>
                  <td className="px-2 py-3">
                    <div className="flex items-center gap-2 text-sm text-ink">
                      <Link
                        href={`/automation/${a.id}`}
                        onClick={(e) => e.stopPropagation()}
                        className="focus:outline-none focus-visible:underline"
                      >
                        {a.name}
                      </Link>
                      <span className="font-mono text-faint">{a.id}</span>
                      {a.custom && <Badge tone="amber">Custom</Badge>}
                    </div>
                    <div className="text-sm text-muted">{a.action}</div>
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2">
                      <Badge tone={a.active ? "green" : "gray"}>{a.statusLabel ?? (a.active ? "Active" : "Paused")}</Badge>
                      {a.custom && (
                        <>
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              pause(a);
                            }}
                            aria-label={a.active ? `Pause ${a.name}` : `Resume ${a.name}`}
                            title={a.active ? "Pause" : "Resume"}
                            className="rounded-md p-1 text-muted hover:bg-active hover:text-ink"
                          >
                            {a.active ? <Pause className="size-4" /> : <Play className="size-4" />}
                          </button>
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              remove(a);
                            }}
                            aria-label={`Delete ${a.name}`}
                            title="Delete"
                            className="rounded-md p-1 text-muted hover:bg-active hover:text-red-400"
                          >
                            <Trash2 className="size-4" />
                          </button>
                        </>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Panel>
  );
}
