"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, MousePointerClick, Undo2, X } from "lucide-react";
import { FloorMap3D, segmentClear, type PlanPoint } from "@/components/FloorMap3D";
import { letter, meters, roomAt } from "@/lib/automation-store";

/** Il percorso completo: A (dove si trova il robot, se c'è) e poi i punti scelti a mano (B, C…). */
export const routeOf = (anchor: PlanPoint | null, picks: PlanPoint[]) => (anchor ? [anchor, ...picks] : picks);

/** I tratti che passano dentro un muro o un oggetto, come «B → C». */
export function badLegsOf(points: PlanPoint[], loop: boolean) {
  const path = loop && points.length > 1 ? [...points, points[0]] : points;
  return path.slice(1).flatMap((p, i) => (segmentClear(path[i], p) ? [] : [`${letter(i)} → ${i + 1 === points.length ? "A" : letter(i + 1)}`]));
}

/** L'elenco dei punti con Undo / Clear, «Return to A» e l'avviso sui tratti che non passano.
 *  `anchor` = A fisso (dove si trova il robot): non si toglie, i punti a mano partono da B. */
export function RouteSteps({
  anchor,
  picks,
  setPicks,
  loop,
  setLoop,
}: {
  anchor: PlanPoint | null;
  picks: PlanPoint[];
  setPicks: (f: (ps: PlanPoint[]) => PlanPoint[]) => void;
  loop: boolean;
  setLoop: (v: boolean) => void;
}) {
  const points = routeOf(anchor, picks);
  const skip = anchor ? 1 : 0;
  const badLegs = badLegsOf(points, loop);
  return (
    <div className="grid gap-2">
      <div className="flex items-center justify-between">
        <span className="text-sm">Route</span>
        <span className="flex gap-1">
          <button
            onClick={() => setPicks((ps) => ps.slice(0, -1))}
            disabled={!picks.length}
            className="flex items-center gap-1.5 rounded-md px-2 py-1 text-sm text-muted hover:bg-hover hover:text-ink disabled:opacity-40 disabled:hover:bg-transparent"
          >
            <Undo2 className="size-3.5" /> Undo
          </button>
          <button
            onClick={() => setPicks(() => [])}
            disabled={!picks.length}
            className="rounded-md px-2 py-1 text-sm text-muted hover:bg-hover hover:text-ink disabled:opacity-40 disabled:hover:bg-transparent"
          >
            Clear
          </button>
        </span>
      </div>
      {points.length > 0 && (
        <ol className="divide-y divide-line rounded-lg border border-line">
          {points.map((p, i) => (
            <li key={i} className="flex items-center gap-3 px-3 py-2 text-sm">
              <span className="grid size-6 shrink-0 place-items-center rounded-full bg-accent font-mono font-semibold text-app">{letter(i)}</span>
              <span className="flex-1">
                {roomAt(p)}
                {anchor && i === 0 && <span className="text-muted"> · where the robot is</span>}
              </span>
              <span className="font-mono tabular-nums text-muted">
                {meters(p.x)} m, {meters(p.y)} m
              </span>
              {/* A del robot non si toglie: cambia solo cambiando robot */}
              <button
                onClick={() => setPicks((ps) => ps.filter((_, j) => j !== i - skip))}
                aria-label={`Remove point ${letter(i)}`}
                disabled={i < skip}
                className={`rounded p-0.5 text-faint hover:bg-hover hover:text-ink ${i < skip ? "invisible" : ""}`}
              >
                <X className="size-3.5" />
              </button>
            </li>
          ))}
        </ol>
      )}
      {!picks.length && (
        <p className="flex items-start gap-2 rounded-lg border border-dashed border-line px-3 py-3 text-sm text-muted">
          <MousePointerClick className="mt-0.5 size-4 shrink-0" strokeWidth={1.75} />
          {anchor
            ? "A is where the robot is now. Click the floor on the map to choose where it goes: B, then C…"
            : "Click the floor on the map: the first click is A (where it starts), the next ones B, C…"}
        </p>
      )}
      <label className="flex items-center gap-2 text-sm text-muted">
        <input type="checkbox" checked={loop} onChange={(e) => setLoop(e.target.checked)} className="size-4 accent-[#e99a3c]" />
        Return to A at the end
      </label>
      {badLegs.length > 0 && (
        <p className="flex items-start gap-2 text-sm text-red-400">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" strokeWidth={1.75} />
          {badLegs.join(", ")} {badLegs.length === 1 ? "goes" : "go"} through a wall or an object: add a point in between.
        </p>
      )}
    </div>
  );
}

/** La mappa 3D dove si cliccano i punti, con la riga d'aiuto in alto e l'avviso se si clicca un muro. */
export function RouteMap({
  anchor,
  picks,
  setPicks,
  loop,
  doneHint,
}: {
  anchor: PlanPoint | null;
  picks: PlanPoint[];
  setPicks: (f: (ps: PlanPoint[]) => PlanPoint[]) => void;
  loop: boolean;
  /** cosa fare quando il percorso è pronto, es. «or create the automation» */
  doneHint: string;
}) {
  const [miss, setMiss] = useState(false);
  useEffect(() => {
    if (!miss) return;
    const t = setTimeout(() => setMiss(false), 2500);
    return () => clearTimeout(t);
  }, [miss]);

  const onPick = useCallback(
    (p: PlanPoint | null) => {
      if (!p) return setMiss(true);
      setMiss(false);
      setPicks((ps) => [...ps, p]);
    },
    [setPicks],
  );

  // `anchor` deve arrivare già memorizzato dal chiamante, così la mappa ridisegna il percorso solo quando cambia
  const points = useMemo(() => routeOf(anchor, picks), [anchor, picks]);
  const hint =
    points.length === 0
      ? "Click the floor to set A, where the bot starts"
      : points.length === 1
        ? anchor
          ? "A is where the robot is. Click the floor to set B, where it goes"
          : "Now click where it goes: B"
        : `Click to add ${letter(points.length)}, ${doneHint}`;

  return (
    <section className="relative min-h-[420px] flex-1 overflow-hidden rounded-xl border border-line">
      <FloorMap3D pick={{ points, loop, onPick }} />
      <div className="pointer-events-none absolute left-4 top-4 z-10 flex flex-col items-start gap-2">
        <p className="rounded-lg bg-app/85 px-3 py-2 text-sm text-ink backdrop-blur">{hint}</p>
        {miss && (
          <p role="status" className="rounded-lg bg-red-500/15 px-3 py-2 text-sm text-red-300 ring-1 ring-inset ring-red-400/30 backdrop-blur">
            That spot is a wall or an object: pick a free spot on the floor.
          </p>
        )}
      </div>
    </section>
  );
}
