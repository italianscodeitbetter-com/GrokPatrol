"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { ArrowLeft } from "lucide-react";
import { type PlanPoint } from "@/components/FloorMap3D";
import { RouteMap, RouteSteps, badLegsOf, routeOf } from "@/components/RouteEditor";
import { setAutomationRoute, useAutomations, type ConsoleDog, type SavedRoute } from "@/lib/automation-store";
import { setServerAutomationRoute, toSite } from "@/lib/automations-live";

/** «Change path»: lo stesso editor della nuova automazione, solo per il percorso. Col backend online cambia il
 *  percorso dell'automazione sul server (POST /api/automations/{id}/route, come l'app mobile); offline quelle di
 *  mock.ts e del browser, salvate nel browser. Si apre quando si sa se il backend c'è. */
export function PathEditor({ id }: { id: string }) {
  const { live, ready, list, fleet } = useAutomations();
  const a = list.find((x) => x.id === id);

  if (!ready) return null;
  if (!a || !a.editablePath)
    return (
      <div className="p-6">
        <Link href={a ? `/automation/${id}` : "/automation"} className="mb-4 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
          <ArrowLeft className="size-4" strokeWidth={1.75} /> {a ? a.name : "Automation"}
        </Link>
        <p className="py-10 text-center text-sm text-muted">
          {a ? `The path of ${a.name} is set in the site configuration: start or schedule it from its page.` : `Automation ${id} not found.`}
        </p>
      </div>
    );

  return <Editor key={`${live}:${id}`} id={id} live={live} name={a.name} dog={fleet.find((d) => d.id === a.dogId)} initial={a.path} />;
}

function Editor({ id, live, name, dog, initial }: { id: string; live: boolean; name: string; dog?: ConsoleDog; initial?: SavedRoute }) {
  const router = useRouter();
  // A = dove si trova il robot (il cane live arrotondato a 10 cm); senza robot il primo clic è A
  const ax = dog?.spot.x ?? null;
  const ay = dog?.spot.y ?? null;
  const anchor = useMemo(() => (ax != null && ay != null ? { x: ax, y: ay } : null), [ax, ay]);
  const [picks, setPicks] = useState<PlanPoint[]>(() => (initial ? initial.route.slice(anchor ? 1 : 0) : []));
  const [loop, setLoop] = useState(initial?.loop ?? false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const points = routeOf(anchor, picks);
  const badLegs = badLegsOf(points, loop);
  const canSave = !busy && points.length >= 2 && !badLegs.length;
  const back = `/automation/${id}`;

  const save = async () => {
    if (!canSave) return;
    if (live) {
      setBusy(true);
      const r = await setServerAutomationRoute(id, points.map(toSite), loop);
      setBusy(false);
      if (!r.ok) return setError(r.error ?? "Could not save the path");
    } else setAutomationRoute(id, points, loop);
    router.push(back);
  };

  return (
    <div className="flex h-full min-h-[640px] flex-col gap-4 p-4 md:p-6 lg:flex-row">
      <aside className="flex w-full shrink-0 flex-col overflow-hidden rounded-xl border border-line bg-panel lg:w-[380px]">
        <div className="flex items-center gap-2 border-b border-line px-4 py-3">
          <Link href={back} aria-label={`Back to ${name}`} className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink">
            <ArrowLeft className="size-4" />
          </Link>
          <div className="min-w-0">
            <h1 className="text-[15px] font-medium">Change path</h1>
            <p className="truncate text-sm text-muted">
              {name} · {dog?.name ?? "No robot"}
            </p>
          </div>
        </div>

        <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4">
          <RouteSteps anchor={anchor} picks={picks} setPicks={setPicks} loop={loop} setLoop={setLoop} />
        </div>

        <div className="flex items-center justify-end gap-2 border-t border-line px-4 py-3">
          {error && (
            <p role="alert" className="min-w-0 flex-1 text-sm text-red-400">
              {error}
            </p>
          )}
          <Link href={back} className="rounded-lg px-3 py-2 text-sm text-muted hover:bg-hover hover:text-ink">
            Cancel
          </Link>
          <button
            onClick={() => void save()}
            disabled={!canSave}
            className="rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90 disabled:opacity-40"
          >
            Save path
          </button>
        </div>
      </aside>

      <RouteMap anchor={anchor} picks={picks} setPicks={setPicks} loop={loop} doneHint="or save the path" />
    </div>
  );
}
