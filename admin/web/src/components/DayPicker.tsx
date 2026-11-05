"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Calendar, ChevronLeft, ChevronRight } from "lucide-react";

const WEEK = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const parse = (s: string) => new Date(`${s}T12:00:00`);
const addDays = (s: string, n: number) => {
  const d = parse(s);
  d.setDate(d.getDate() + n);
  return iso(d);
};
const fmt = (s: string) => parse(s).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });

// oggi secondo il browser; durante il prerender non c'è (con Cache Components niente `new Date()` lato server)
const noop = () => () => {};
const todayIso = () => iso(new Date());

/** Si può andare solo indietro: dopo oggi non ci sono dati, quindi freccia e giorni futuri sono disattivati.
 *  Giorno precedente/successivo con le frecce (bottoni separati); clic sulla data → calendario del mese. */
export function DayPicker({ value, onChange, marked = [] }: { value: string; onChange: (day: string) => void; marked?: string[] }) {
  const [open, setOpen] = useState(false);
  const [month, setMonth] = useState(() => parse(value));
  const box = useRef<HTMLDivElement>(null);
  const today = useSyncExternalStore(noop, todayIso, () => null);
  const isFuture = (d: string) => today != null && d > today;
  const atToday = today == null || value >= today;

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

  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const lead = (first.getDay() + 6) % 7; // lunedì per primo
  const days = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const cells = [...Array(lead).fill(null), ...Array.from({ length: days }, (_, i) => iso(new Date(month.getFullYear(), month.getMonth(), i + 1)))];
  const nextMonthFirst = iso(new Date(month.getFullYear(), month.getMonth() + 1, 1));
  const shiftMonth = (n: number) => setMonth(new Date(month.getFullYear(), month.getMonth() + n, 1));

  return (
    <div ref={box} className="relative">
      <div className="flex items-center gap-1.5">
        <button
          onClick={() => onChange(addDays(value, -1))}
          aria-label="Previous day"
          className="rounded-lg border border-line bg-panel p-2 text-muted hover:bg-hover hover:text-ink"
        >
          <ChevronLeft className="size-4" />
        </button>
        <button
          onClick={() => {
            setMonth(parse(value));
            setOpen(!open);
          }}
          aria-haspopup="dialog"
          aria-expanded={open}
          className="flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-1.5 text-sm text-ink hover:bg-hover"
        >
          <Calendar className="size-4 text-muted" strokeWidth={1.75} />
          {fmt(value)}
        </button>
        <button
          onClick={() => !atToday && onChange(addDays(value, 1))}
          disabled={atToday}
          aria-label="Next day"
          title={atToday ? "No days after today" : undefined}
          className="rounded-lg border border-line bg-panel p-2 text-muted hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-35 disabled:hover:bg-panel disabled:hover:text-muted"
        >
          <ChevronRight className="size-4" />
        </button>
      </div>

      {open && (
        <div role="dialog" aria-label="Pick a day" className="absolute left-1/2 top-full z-20 mt-2 w-72 -translate-x-1/2 rounded-xl border border-line bg-panel p-3 shadow-2xl shadow-black/50">
          <div className="mb-2 flex items-center justify-between">
            <button onClick={() => shiftMonth(-1)} aria-label="Previous month" className="rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink">
              <ChevronLeft className="size-4" />
            </button>
            <span className="text-sm capitalize">{month.toLocaleDateString("en-GB", { month: "long", year: "numeric" })}</span>
            <button
              onClick={() => shiftMonth(1)}
              disabled={isFuture(nextMonthFirst)}
              aria-label="Next month"
              className="rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-35 disabled:hover:bg-transparent"
            >
              <ChevronRight className="size-4" />
            </button>
          </div>
          <div className="grid grid-cols-7 gap-0.5 text-center text-sm">
            {WEEK.map((w) => (
              <span key={w} className="py-1 text-faint">{w}</span>
            ))}
            {cells.map((d, i) =>
              d ? (
                <button
                  key={d}
                  onClick={() => {
                    onChange(d);
                    setOpen(false);
                  }}
                  disabled={isFuture(d)}
                  aria-pressed={d === value}
                  className={`relative grid h-9 place-items-center rounded-lg tabular-nums transition-colors disabled:cursor-not-allowed disabled:text-faint/50 disabled:hover:bg-transparent ${
                    d === value ? "bg-ink text-app" : d === today ? "text-accent hover:bg-hover" : "text-ink/90 hover:bg-hover"
                  }`}
                >
                  {Number(d.slice(8))}
                  {marked.includes(d) && d !== value && <span className="absolute bottom-1 size-1 rounded-full bg-accent" aria-hidden />}
                </button>
              ) : (
                <span key={`x${i}`} />
              ),
            )}
          </div>
        </div>
      )}
    </div>
  );
}
