"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, Check, ChevronDown, Clock } from "lucide-react";
import { Dropdown } from "@/components/Dropdown";
import { type PlanPoint } from "@/components/FloorMap3D";
import { RouteMap, RouteSteps, badLegsOf, routeOf } from "@/components/RouteEditor";
import { BatteryTag, RobotAvatar } from "@/components/robot";
import { repeatText, saveAutomation, walkText, useAutomations, useCustomAutomations, type ConsoleDog, type Repeat } from "@/lib/automation-store";
import { createAutomation, toSite } from "@/lib/automations-live";
import { automations } from "@/lib/mock";

const input =
  "h-10 w-full rounded-lg border border-line bg-app px-3 text-sm text-ink placeholder:text-faint focus:border-[#3a3a3a] focus:outline-none";

// orari con l'icona lucide dell'app (niente orologio del browser); le tendine sono <Dropdown>
function TimeField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <span className="relative block">
      <input
        type="time"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={`${input} relative pr-9 font-mono [&::-webkit-calendar-picker-indicator]:absolute [&::-webkit-calendar-picker-indicator]:right-2 [&::-webkit-calendar-picker-indicator]:size-6 [&::-webkit-calendar-picker-indicator]:cursor-pointer [&::-webkit-calendar-picker-indicator]:opacity-0`}
      />
      <Clock className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 text-muted" strokeWidth={1.75} />
    </span>
  );
}

/** Scelta del robot: foto (come nelle tabelle), nome e batteria; quelli spenti si vedono ma non si scelgono. */
function RobotPicker({ fleet, value, onChange }: { fleet: ConsoleDog[]; value: string; onChange: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const current = fleet.find((d) => d.id === value) ?? fleet[0];
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => !box.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);
  const line = (d: ConsoleDog) => (
    <>
      <RobotAvatar off={d.state === "spento"} />
      <span className="min-w-0 flex-1 truncate text-left">{d.name}</span>
      {d.state === "spento" && <span className="text-sm text-faint">Off</span>}
      {d.battery != null && <BatteryTag battery={d.battery} off={d.state === "spento"} />}
    </>
  );
  return (
    <div ref={box} className="relative">
      <button type="button" onClick={() => setOpen(!open)} aria-haspopup="listbox" aria-expanded={open} aria-label="Robot" className={`${input} flex items-center gap-2.5`}>
        {current && line(current)}
        <ChevronDown className={`size-4 shrink-0 text-muted transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && (
        <ul role="listbox" aria-label="Robot" className="absolute inset-x-0 top-full z-30 mt-1.5 max-h-72 overflow-y-auto rounded-xl border border-line bg-panel p-1.5 shadow-2xl shadow-black/50">
          {fleet.map((d) => (
            <li key={d.id}>
              <button
                type="button"
                role="option"
                aria-selected={d.id === value}
                disabled={d.state === "spento"}
                onClick={() => {
                  onChange(d.id);
                  setOpen(false);
                }}
                className="flex w-full items-center gap-2.5 rounded-lg px-3 py-2 text-sm text-ink hover:bg-hover disabled:cursor-not-allowed disabled:text-faint disabled:hover:bg-transparent"
              >
                {line(d)}
                <Check className={`size-4 shrink-0 text-accent ${d.id === value ? "" : "invisible"}`} />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const repeatOptions: { value: Repeat; label: string }[] = [
  { value: "once", label: "Once" },
  { value: "daily", label: "Every day" },
  { value: "weekdays", label: "Mon–Fri" },
  { value: "days", label: "Specific days" },
  { value: "interval", label: "Every… until" },
];

const everyOptions = [15, 30, 60, 120].map((m) => ({ value: m, label: m < 60 ? `${m} minutes` : `${m / 60} ${m === 60 ? "hour" : "hours"}` }));

/** Nuova automazione: A è dove si trova il robot scelto, poi si clicca sulla mappa 3D per i punti dopo (B, C…)
 *  e si sceglie a che ora parte. */
export function AutomationBuilder() {
  const router = useRouter();
  const saved = useCustomAutomations();
  // online: il cane live (e i bot spenti, non selezionabili); offline: la flotta di mock.ts
  const { live, fleet } = useAutomations();
  const [name, setName] = useState("");
  const [picked, setDogId] = useState<string | null>(null);
  const dog = fleet.find((d) => d.id === picked) ?? fleet.find((d) => d.state !== "spento") ?? fleet[0];
  const dogId = dog?.id ?? "";
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // i punti scelti a mano (B, C…); A lo mette il robot
  const [picks, setPicks] = useState<PlanPoint[]>([]);
  const [loop, setLoop] = useState(false);
  const [start, setStart] = useState("09:00");
  const [repeat, setRepeat] = useState<Repeat>("daily");
  const [every, setEvery] = useState(60);
  const [until, setUntil] = useState("18:00");
  const [days, setDays] = useState<number[]>([1, 3, 5]);
  const toggleDay = (d: number) => setDays((ds) => (ds.includes(d) ? ds.filter((x) => x !== d) : [...ds, d].sort()));

  // A = dove si trova il robot (per il cane live: arrotondato a 10 cm, così non cambia a ogni tick)
  const ax = dog?.spot.x ?? null;
  const ay = dog?.spot.y ?? null;
  const anchor = useMemo(() => (ax != null && ay != null ? { x: ax, y: ay } : null), [ax, ay]);
  const points = routeOf(anchor, picks);
  const badLegs = badLegsOf(points, loop);
  const missing = [!name.trim() && "a name", !picks.length && "at least one point to go to (B)"].filter(Boolean) as string[];
  const canSave = !busy && !missing.length && !badLegs.length && (repeat !== "interval" || until > start) && (repeat !== "days" || days.length > 0);

  const save = async () => {
    if (!canSave) return;
    if (live) {
      // sul server, in metri: lo stesso corpo che manda l'app mobile
      setBusy(true);
      const r = await createAutomation({
        name: name.trim(),
        points: points.map(toSite),
        loop,
        start,
        repeat,
        ...(repeat === "days" ? { days } : {}),
        ...(repeat === "interval" ? { every_min: every, until } : {}),
      });
      setBusy(false);
      if (!r.ok) return setError(r.error ?? "Could not create the automation");
      return router.push("/automation");
    }
    const n = automations.length + saved.length + 1;
    saveAutomation({
      id: `AU-${String(n).padStart(2, "0")}`,
      name: name.trim(),
      trigger: repeatText(repeat, start, every, until, days),
      action: walkText(points, loop),
      dogId,
      startsAt: start,
      active: true,
      lastRun: null,
      runsToday: 0,
      custom: true,
      route: points,
      loop,
      start,
      repeat,
      ...(repeat === "interval" ? { everyMinutes: every, until } : {}),
      ...(repeat === "days" ? { days } : {}),
    });
    router.push("/automation");
  };

  return (
    <div className="flex h-full min-h-[640px] flex-col gap-4 p-4 md:p-6 lg:flex-row">
      {/* modulo */}
      <aside className="flex w-full shrink-0 flex-col overflow-hidden rounded-xl border border-line bg-panel lg:w-[380px]">
        <div className="flex items-center gap-2 border-b border-line px-4 py-3">
          <Link href="/automation" aria-label="Back to automations" className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink">
            <ArrowLeft className="size-4" />
          </Link>
          <h1 className="text-[15px] font-medium">New automation</h1>
        </div>

        <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4">
          <label className="grid gap-1.5">
            <span className="text-sm">Name</span>
            <input value={name} onChange={(e) => setName(e.target.value)} className={input} placeholder="e.g. Morning check Room 3" autoFocus />
          </label>

          <div className="grid gap-1.5">
            <span className="text-sm">Robot</span>
            <RobotPicker fleet={fleet} value={dogId} onChange={setDogId} />
          </div>

          <RouteSteps anchor={anchor} picks={picks} setPicks={setPicks} loop={loop} setLoop={setLoop} />

          <div className="grid gap-3">
            <span className="text-sm">When it starts</span>
            <div className="grid grid-cols-2 gap-3">
              <label className="grid gap-1.5 text-sm text-muted">
                Start at
                <TimeField value={start} onChange={setStart} />
              </label>
              <div className="grid gap-1.5 text-sm text-muted">
                Repeat
                <Dropdown label="Repeat" value={repeat} options={repeatOptions} onChange={setRepeat} />
              </div>
              {repeat === "days" && (
                <div className="col-span-2 grid gap-1.5 text-sm text-muted">
                  On
                  <div className="grid grid-cols-7 gap-1" role="group" aria-label="Days of the week">
                    {WEEKDAYS.map((w, i) => {
                      const on = days.includes(i + 1);
                      return (
                        <button
                          key={w}
                          type="button"
                          onClick={() => toggleDay(i + 1)}
                          aria-pressed={on}
                          className={`h-9 rounded-lg border text-sm transition-colors ${on ? "border-accent/60 bg-accent/15 text-ink" : "border-line bg-app text-muted hover:bg-hover hover:text-ink"}`}
                        >
                          {w}
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
              {repeat === "interval" && (
                <>
                  <div className="grid gap-1.5 text-sm text-muted">
                    Every
                    <Dropdown label="Every" value={every} options={everyOptions} onChange={setEvery} />
                  </div>
                  <label className="grid gap-1.5 text-sm text-muted">
                    Until
                    <TimeField value={until} onChange={setUntil} />
                  </label>
                </>
              )}
            </div>
            <p className="text-sm text-muted">{repeatText(repeat, start, every, until, days)}</p>
            {repeat === "days" && !days.length && <p className="text-sm text-red-400">Pick at least one day.</p>}
            {repeat === "interval" && until <= start && <p className="text-sm text-red-400">«Until» must be after the start time.</p>}
          </div>
        </div>

        <div className="flex items-center justify-end gap-3 border-t border-line px-4 py-3">
          {error && (
            <p role="alert" className="min-w-0 flex-1 text-sm text-red-400">
              {error}
            </p>
          )}
          <div className="flex gap-2">
            <Link href="/automation" className="rounded-lg px-3 py-2 text-sm text-muted hover:bg-hover hover:text-ink">
              Cancel
            </Link>
            <button
              onClick={() => void save()}
              disabled={!canSave}
              className="rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90 disabled:opacity-40"
            >
              Create
            </button>
          </div>
        </div>
      </aside>

      {/* mappa: clic sul pavimento per aggiungere i punti */}
      <RouteMap anchor={anchor} picks={picks} setPicks={setPicks} loop={loop} doneHint="or create the automation" />
    </div>
  );
}
