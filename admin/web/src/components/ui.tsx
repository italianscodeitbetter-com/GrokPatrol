import type { ReactNode } from "react";
import { priorityLabels, type EventStatus, type Outcome, type Priority } from "@/lib/mock";

/** `center` (facoltativo) sta in mezzo all'intestazione, fra il titolo e le azioni. */
export function PageHeader({
  title,
  subtitle,
  center,
  actions,
}: {
  title: string;
  subtitle?: string;
  center?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <header
      className={`flex flex-wrap items-end justify-between gap-4 pb-6 ${center ? "md:grid md:grid-cols-[1fr_auto_1fr]" : ""}`}
    >
      <div>
        <h1 className="text-xl font-medium tracking-tight">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-muted">{subtitle}</p>}
      </div>
      {center}
      {center ? <div className="md:justify-self-end">{actions}</div> : actions}
    </header>
  );
}

const pageSize = {
  narrow: "max-w-3xl",
  default: "max-w-6xl",
  full: "flex h-full flex-col",
} as const;

/** Ogni pagina sta centrata nel pannello del contenuto, fino a una larghezza massima («full» = la dashboard, a tutta area). */
export function Page({ children, size = "default" }: { children: ReactNode; size?: keyof typeof pageSize }) {
  return <div className={`mx-auto w-full px-4 py-6 md:px-8 md:py-8 ${pageSize[size]}`}>{children}</div>;
}

/** `count` (facoltativo) sta subito accanto al titolo; `action` va in fondo a destra.
 *  `flat` = senza sfondo, solo il bordo (le tabelle stanno così direttamente sulla pagina). */
export function Panel({
  title,
  count,
  action,
  children,
  className = "",
  bodyClassName = "p-4",
  flat = false,
}: {
  title?: string;
  count?: number;
  action?: ReactNode;
  children: ReactNode;
  className?: string;
  bodyClassName?: string;
  flat?: boolean;
}) {
  return (
    <section className={`flex min-w-0 flex-col rounded-xl border border-line ${flat ? "" : "bg-panel"} ${className}`}>
      {title && (
        <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
          <h2 className="flex items-center gap-2 text-sm font-medium text-ink">
            {title}
            {count != null && <CountChip n={count} />}
          </h2>
          {action}
        </div>
      )}
      <div className={`min-h-0 flex-1 ${bodyClassName}`}>{children}</div>
    </section>
  );
}

/** Il numerino grigio accanto a un titolo («In progress 2», «Activity 26»): solo il numero, senza riquadro. */
export function CountChip({ n }: { n: number }) {
  return <span className="font-mono text-sm font-normal tabular-nums text-muted">{n}</span>;
}

export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div className="rounded-xl border border-line bg-panel p-4">
      <div className="text-sm text-muted">{label}</div>
      <div className="mt-2 text-2xl font-medium tabular-nums tracking-tight">{value}</div>
      {hint && <div className="mt-1 text-sm text-faint">{hint}</div>}
    </div>
  );
}

type Tone = "red" | "amber" | "green" | "gray" | "blue";

const tones: Record<Tone, string> = {
  red: "bg-red-500/10 text-red-400 ring-red-500/20",
  amber: "bg-amber-500/10 text-amber-300 ring-amber-500/20",
  green: "bg-emerald-500/10 text-emerald-400 ring-emerald-500/20",
  gray: "bg-white/5 text-muted ring-white/10",
  blue: "bg-sky-500/10 text-sky-300 ring-sky-500/20",
};

export function Badge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-sm font-medium ring-1 ring-inset ${tones[tone]}`}>
      {children}
    </span>
  );
}

const statusMap: Record<EventStatus, [Tone, string]> = {
  in_valutazione: ["blue", "Assessing"],
  in_coda: ["blue", "Queued"],
  missione: ["amber", "Mission"],
  verifica: ["amber", "Verifying"],
  alert: ["red", "Alert sent"],
  falso_allarme: ["gray", "False alarm"],
  chiuso: ["green", "Closed"],
};

export const statusLabel = (status: EventStatus) => statusMap[status][1];

export function StatusBadge({ status }: { status: EventStatus }) {
  const [tone, label] = statusMap[status];
  return <Badge tone={tone}>{label}</Badge>;
}

const outcomeMap: Record<Outcome, [Tone, string]> = {
  anomalia: ["red", "Real anomaly"],
  falso_allarme: ["gray", "No anomaly"],
  in_corso: ["amber", "In progress"],
  annullata: ["gray", "Cancelled"],
  da_verificare: ["amber", "To review"],
};

export const outcomeLabel = (outcome: Outcome) => outcomeMap[outcome][1];

export function OutcomeBadge({ outcome }: { outcome: Outcome }) {
  const [tone, label] = outcomeMap[outcome];
  return <Badge tone={tone}>{label}</Badge>;
}

const priorityMap: Record<Priority, string> = {
  alta: "bg-red-400",
  media: "bg-amber-300",
  bassa: "bg-faint",
};

export function PriorityDot({ priority }: { priority: Priority }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-sm text-muted">
      <span className={`size-1.5 rounded-full ${priorityMap[priority]}`} />
      {priorityLabels[priority]}
    </span>
  );
}
