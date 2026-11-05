"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState, type ComponentType } from "react";
import { ArrowDownUp, Braces, Check, ChevronLeft, ChevronRight, Download, FileSpreadsheet, FileText, MessageSquare, Monitor, NotebookPen, Phone, Search, Send, X } from "lucide-react";
import { DayPicker } from "@/components/DayPicker";
import { GrokBotColorIcon, GrokBotIcon } from "@/components/GrokBotIcon";
import { Badge, CountChip, PageHeader, Panel, Stat, outcomeLabel } from "@/components/ui";
import { channelLabels, stepLabels, type AlertSent } from "@/lib/mock";
import { useConsoleData, type ConsoleAlert, type ConsoleData } from "@/lib/missions";

const channelIcons: Record<AlertSent["channel"], ComponentType<{ className?: string; strokeWidth?: number }>> = {
  SMS: MessageSquare,
  Chiamata: Phone,
  GrokBot: GrokBotIcon,
  Console: Monitor,
  Telegram: Send,
};

/** `alert` c'è solo sulle righe degli allarmi inviati: canale, destinatario e se è arrivato. */
type ActivityRow = { time: string; what: string; detail: string; missionId: string; room: string; robot: string; alert?: ConsoleAlert };

/** I dati di Reports: missioni, allarmi e turno (live o mock) più le righe di Activity. */
type Data = Omit<ConsoleData, "ready"> & { activity: ActivityRow[] };

/** Tutto quello che è successo nel turno, una riga per passo (missioni e allarmi), dal più recente. */
function activityOf({ missions, alerts }: Pick<ConsoleData, "missions" | "alerts">): ActivityRow[] {
  return [
    ...missions.flatMap((m) =>
      m.steps
        .filter((s) => s.time)
        .map((s) => ({ time: s.time!, what: stepLabels[s.step], detail: s.detail, missionId: m.id, room: m.room, robot: m.robot })),
    ),
    ...alerts.map((a) => {
      const m = missions.find((x) => x.id === a.missionId);
      return {
        time: a.time,
        what: `Alert · ${channelLabels[a.channel]}`,
        detail: a.text,
        missionId: a.missionId,
        room: m ? m.room : "—",
        robot: m ? m.robot : "—",
        alert: a,
      };
    }),
  ].sort((a, b) => b.time.localeCompare(a.time));
}

const fmtSeconds = (s: number | null) => (s == null ? "—" : `${s} s`);

/** Il filtro accanto alla ricerca: tutto, solo i passi delle missioni o solo gli allarmi inviati. */
type Kind = "all" | "steps" | "alerts";
const kinds: { value: Kind; label: string }[] = [
  { value: "all", label: "All activity" },
  { value: "steps", label: "Mission steps" },
  { value: "alerts", label: "Alerts sent" },
];

/** Ogni GrokBot prende uno dei colori dei personaggi, sempre lo stesso per la stessa missione. */
const botColors = ["text-bot-green", "text-bot-blue", "text-bot-orange", "text-bot-pink", "text-bot-teal"];
const botColor = (missionId: string) => botColors[[...missionId].reduce((h, c) => h + c.charCodeAt(0), 0) % botColors.length];

/** Righe di Activity per pagina: la tabella si allunga verso il basso, oltre si cambia pagina. */
const PAGE = 50;

const download = (body: BlobPart, type: string, name: string) => {
  const url = URL.createObjectURL(new Blob([body], { type }));
  const a = Object.assign(document.createElement("a"), { href: url, download: name });
  a.click();
  URL.revokeObjectURL(url);
};

/** Un foglio per Excel/Sheets. Live: il registro del turno dal backend (/api/log.csv); offline: CSV con «;» (il separatore
 *  di Excel in italiano) e BOM dal mock, così gli accenti restano giusti. */
function exportCsv(day: string, { missions, alerts, live, shift }: Data) {
  if (live) {
    const a = Object.assign(document.createElement("a"), { href: `/api/log.csv${shift.startTs ? `?since=${shift.startTs}` : ""}`, download: `grokpatrol-log-${day}.csv` });
    a.click();
    return;
  }
  const header = ["Day", "Mission", "Event", "Room", "Time", "Step", "Detail", "Outcome"];
  const rows: string[][] = missions.flatMap((m) =>
    m.steps.map((s) => [day, m.id, m.eventId, m.room, s.time ?? "", stepLabels[s.step], s.detail, outcomeLabel(m.outcome)]),
  );
  for (const a of alerts) {
    rows.push([day, a.missionId, "", "", a.time, `Alert ${channelLabels[a.channel]}`, `${a.to}: ${a.text}`, a.delivered ? "Delivered" : "Failed"]);
  }
  const cell = (v: string) => (/[;"\n]/.test(v) ? `"${v.replaceAll('"', '""')}"` : v);
  const csv = "\uFEFF" + [header, ...rows].map((r) => r.map(cell).join(";")).join("\r\n");
  download(csv, "text/csv;charset=utf-8", `grokpatrol-report-${day}.csv`);
}

const esc = (v: string) => v.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** Il report della giornata: un documento da stampare o salvare in PDF, con numeri, attività e allarmi. */
function exportReport(day: string, { missions, alerts, shift, activity }: Data) {
  const rows = [...activity].reverse();
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>GrokPatrol · Day report ${day}</title>
<style>
  body{font:14px/1.5 -apple-system,system-ui,sans-serif;color:#111;margin:40px;max-width:900px}
  h1{font-size:22px;margin:0}h2{font-size:16px;margin:32px 0 8px}
  .sub{color:#666;margin:4px 0 24px}
  .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
  .stat{border:1px solid #ddd;border-radius:8px;padding:10px 12px}.stat b{display:block;font-size:20px}
  table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #e5e5e5;vertical-align:top}
  th{color:#666;font-weight:500}.mono{font-family:ui-monospace,Menlo,monospace;white-space:nowrap}
  @media print{body{margin:16mm}}
</style></head><body>
<h1>GrokPatrol · Day report</h1>
<p class="sub">${esc(shift.name)} · ${esc(shift.date)} · ${shift.start}–${shift.end}</p>
<div class="stats">
  <div class="stat">Events<b>${shift.events}</b></div>
  <div class="stat">Confirmed anomalies<b>${shift.confirmed}</b></div>
  <div class="stat">False alarms blocked<b>${shift.falseAlarmsBlocked}</b></div>
  <div class="stat">Avg. time to arrival<b>${fmtSeconds(shift.avgArrivalSeconds)}</b></div>
</div>
<h2>Missions</h2>
<table><tr><th>Mission</th><th>Time</th><th>Room</th><th>Robot</th><th>What the dog found</th><th>Outcome</th></tr>
${missions
  .map(
    (m) =>
      `<tr><td class="mono">${m.id}</td><td class="mono">${m.eventTime}</td><td>${esc(m.room)}</td><td>${esc(m.robot)}</td><td>${esc(m.sighting ?? "Not on site yet")}</td><td>${esc(outcomeLabel(m.outcome))}</td></tr>`,
  )
  .join("")}
</table>
<h2>Activity</h2>
<table><tr><th>Time</th><th>Step</th><th>Detail</th><th>Mission</th><th>Room</th><th>Robot</th></tr>
${rows
  .map(
    (r) =>
      `<tr><td class="mono">${r.time}</td><td>${esc(r.what)}</td><td>${esc(r.detail)}</td><td class="mono">${r.missionId}</td><td>${esc(r.room)}</td><td>${esc(r.robot)}</td></tr>`,
  )
  .join("")}
</table>
<h2>Alerts sent</h2>
<table><tr><th>Time</th><th>Channel</th><th>To</th><th>Message</th><th>Status</th></tr>
${alerts
  .map(
    (a) =>
      `<tr><td class="mono">${a.time}</td><td>${channelLabels[a.channel]}</td><td>${esc(a.to)}</td><td>${esc(a.text)}</td><td>${a.delivered ? "Delivered" : "Failed"}</td></tr>`,
  )
  .join("")}
</table>
<script>addEventListener("load",()=>print())</script>
</body></html>`;
  // si apre in una nuova scheda pronto da stampare / salvare in PDF; se il browser blocca la scheda, si scarica il file
  const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
  const tab = window.open(url, "_blank");
  if (!tab) {
    const a = Object.assign(document.createElement("a"), { href: url, download: `grokpatrol-report-${day}.html` });
    a.click();
  }
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/** Tutti i dati del giorno così come sono, per chi li vuole leggere da un altro programma. */
function exportJson(day: string, { shift, missions, alerts, live }: Data) {
  const data = { day, live, shift, missions, alerts };
  download(JSON.stringify(data, null, 2), "application/json", `grokpatrol-report-${day}.json`);
}

/** Il rapporto di fine turno scritto dal backend (Grok, o un riassunto dei numeri senza Grok): POST /api/report, file .md. */
async function exportShiftReport(day: string) {
  try {
    const r = await fetch("/api/report", { method: "POST" });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const { markdown } = (await r.json()) as { markdown?: string };
    download(markdown ?? "", "text/markdown;charset=utf-8", `grokpatrol-shift-report-${day}.md`);
  } catch (e) {
    alert(`Could not write the shift report: ${e instanceof Error ? e.message : e}`);
  }
}

type Format = { label: string; hint: string; icon: ComponentType<{ className?: string; strokeWidth?: number }>; run: (day: string, data: Data) => void; liveOnly?: boolean };

const formats: Format[] = [
  { label: "Day report", hint: "A document of everything done that day, ready to print or save as PDF", icon: FileText, run: exportReport },
  { label: "End-of-shift report", hint: "Written by Grok from the shift log, as a .md file", icon: NotebookPen, run: (day) => void exportShiftReport(day), liveOnly: true },
  { label: "Excel / Google Sheets", hint: ".csv sheet: every activity of the day", icon: FileSpreadsheet, run: exportCsv },
  { label: "JSON", hint: "All data for the day, for other tools", icon: Braces, run: exportJson },
];

/** «Export data» → un modale chiede in che formato scaricare. */
function ExportButton({ day, disabled, data }: { day: string; disabled: boolean; data: Data }) {
  const dialog = useRef<HTMLDialogElement>(null);

  return (
    <>
      <button
        onClick={() => dialog.current?.showModal()}
        disabled={disabled}
        aria-haspopup="dialog"
        className="flex items-center gap-2 rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90 disabled:opacity-30"
      >
        <Download className="size-4" strokeWidth={2} />
        Export data
      </button>

      <dialog
        ref={dialog}
        aria-labelledby="export-title"
        onPointerDown={(e) => e.target === e.currentTarget && dialog.current?.close()}
        className="m-auto w-[440px] max-w-[calc(100%-2rem)] rounded-xl border border-line bg-panel p-0 text-ink backdrop:bg-black/60"
      >
        <div className="flex items-center justify-between border-b border-line px-4 py-3">
          <h2 id="export-title" className="text-sm font-medium">
            Export data
          </h2>
          <button
            type="button"
            onClick={() => dialog.current?.close()}
            aria-label="Close"
            className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink"
          >
            <X className="size-4" />
          </button>
        </div>
        <div className="p-2">
          <p className="px-2.5 pb-2 pt-1 text-sm text-muted">Which type of file do you want?</p>
          {formats.filter((f) => data.live || !f.liveOnly).map((f) => (
            <button
              key={f.label}
              onClick={() => {
                f.run(day, data);
                dialog.current?.close();
              }}
              className="flex w-full items-start gap-3 rounded-lg px-2.5 py-2.5 text-left hover:bg-hover"
            >
              <f.icon className="mt-0.5 size-4 shrink-0 text-muted" strokeWidth={1.75} />
              <span>
                <span className="block text-sm text-ink">{f.label}</span>
                <span className="block text-sm text-muted">{f.hint}</span>
              </span>
            </button>
          ))}
        </div>
      </dialog>
    </>
  );
}

export function ReportsView() {
  const { missions, alerts, shift, live } = useConsoleData();
  const activity = useMemo(() => activityOf({ missions, alerts }), [missions, alerts]);
  const data: Data = { missions, alerts, shift, live, activity };
  const [picked, setDay] = useState<string | null>(null);
  const day = picked ?? shift.day;
  const hasData = day === shift.day;
  const [page, setPage] = useState(0);
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<Kind>("all");
  const q = query.trim().toLowerCase();
  const filtered = activity.filter(
    (r) =>
      (kind === "all" || (kind === "alerts") === !!r.alert) &&
      (!q || [r.time, r.what, r.detail, r.missionId, r.room, r.robot, r.alert?.to ?? ""].some((v) => v.toLowerCase().includes(q))),
  );
  const pages = Math.max(1, Math.ceil(filtered.length / PAGE));
  const rows = filtered.slice(page * PAGE, (page + 1) * PAGE);

  return (
    <>
      <PageHeader
        title="Reports"
        center={<DayPicker value={day} onChange={setDay} marked={[shift.day]} />}
        actions={<ExportButton day={day} disabled={!hasData} data={data} />}
      />

      {!hasData ? (
        <Panel>
          <p className="py-10 text-center text-sm text-muted">No data for this day.</p>
        </Panel>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Stat label="Events" value={shift.events} />
            <Stat label="Confirmed anomalies" value={shift.confirmed} />
            <Stat label="False alarms blocked" value={shift.falseAlarmsBlocked} />
            <Stat label="Avg. time to arrival" value={fmtSeconds(shift.avgArrivalSeconds)} />
          </div>

          <section id="activity" className="mt-8 scroll-mt-6">
            {/* il titolo sta fuori dalla tabella, a destra il filtro e la ricerca; scorrendo, titolo e nomi delle colonne
                restano fissi in alto (sticky dentro il <main>, che è quello che scorre) */}
            <div className="sticky top-0 z-20 flex h-14 items-center justify-between gap-3 bg-app">
              <h2 className="flex items-center gap-2 text-[15px] font-medium">
                Activity
                <CountChip n={filtered.length} />
              </h2>
              {/* solo icone: a sinistra il filtro, a destra la ricerca; cliccate si aprono */}
              <div className="flex items-center gap-1">
                <FilterMenu
                  value={kind}
                  onChange={(k) => {
                    setKind(k);
                    setPage(0);
                  }}
                />
                <SearchToggle
                  value={query}
                  onChange={(v) => {
                    setQuery(v);
                    setPage(0);
                  }}
                />
              </div>
            </div>
            {/* overflow-clip (non hidden): taglia gli angoli tondi senza rompere lo sticky dell'intestazione */}
            <Panel flat className="overflow-clip" bodyClassName="p-0">
              <div className="overflow-x-auto md:overflow-visible">
                <table className="w-full text-left text-sm">
                  <thead className="text-muted">
                    <tr>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-4 py-2.5 font-normal">Time</th>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-2 py-2.5 font-normal">Step</th>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-2 py-2.5 font-normal">Mission</th>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-2 py-2.5 font-normal">Room</th>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-2 py-2.5 font-normal">Robot</th>
                      <th className="sticky top-14 z-10 bg-panel shadow-[inset_0_-1px_0_var(--color-line)] px-4 py-2.5 font-normal">Detail</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((r, i) => (
                      <ActivityTableRow key={page * PAGE + i} r={r} />
                    ))}
                  </tbody>
                </table>
                {!rows.length && <p className="px-4 py-6 text-sm text-muted">No activity matches.</p>}
              </div>
              <div className="flex items-center justify-between gap-3 border-t border-line px-4 py-2.5 text-sm text-muted">
                <span className="tabular-nums">
                  {rows.length ? page * PAGE + 1 : 0}–{page * PAGE + rows.length} of {filtered.length}
                </span>
                <span className="flex items-center gap-1">
                  <button
                    onClick={() => setPage(page - 1)}
                    disabled={page === 0}
                    aria-label="Previous page"
                    className="rounded-md p-1 hover:bg-hover hover:text-ink disabled:opacity-30 disabled:hover:bg-transparent"
                  >
                    <ChevronLeft className="size-4" />
                  </button>
                  <span className="px-1 tabular-nums">
                    Page {page + 1} of {pages}
                  </span>
                  <button
                    onClick={() => setPage(page + 1)}
                    disabled={page >= pages - 1}
                    aria-label="Next page"
                    className="rounded-md p-1 hover:bg-hover hover:text-ink disabled:opacity-30 disabled:hover:bg-transparent"
                  >
                    <ChevronRight className="size-4" />
                  </button>
                </span>
              </div>
            </Panel>
          </section>
        </>
      )}
    </>
  );
}

const iconBtn = "relative grid size-9 place-items-center rounded-lg text-ink transition-colors hover:bg-hover";

/** Il filtro come icona: cliccata apre l'elenco (tutto / passi delle missioni / allarmi). Il puntino dice che è attivo. */
function FilterMenu({ value, onChange }: { value: Kind; onChange: (k: Kind) => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
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
  return (
    <div ref={box} className="relative">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label="Filter activity"
        title="Filter"
        className={`${iconBtn} ${open ? "bg-hover" : ""}`}
      >
        <ArrowDownUp className="size-5" strokeWidth={1.75} />
        {value !== "all" && <span className="absolute right-1.5 top-1.5 size-1.5 rounded-full bg-accent" aria-hidden />}
      </button>
      {open && (
        <ul role="listbox" aria-label="Filter activity" className="absolute right-0 top-full z-30 mt-1.5 w-52 rounded-xl border border-line bg-panel p-1.5 shadow-2xl shadow-black/50">
          {kinds.map((k) => (
            <li key={k.value}>
              <button
                type="button"
                role="option"
                aria-selected={k.value === value}
                onClick={() => {
                  onChange(k.value);
                  setOpen(false);
                }}
                className="flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-left text-sm text-ink hover:bg-hover"
              >
                {k.label}
                <Check className={`size-4 shrink-0 text-accent ${k.value === value ? "" : "invisible"}`} />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** La ricerca come icona: cliccata diventa la barra. Si richiude con Esc, con la × o uscendo quando è vuota. */
function SearchToggle({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [opened, setOpened] = useState(false);
  const close = () => {
    onChange("");
    setOpened(false);
  };
  if (!opened && !value)
    return (
      <button type="button" onClick={() => setOpened(true)} aria-label="Search activity" title="Search" className={iconBtn}>
        <Search className="size-5" strokeWidth={1.75} />
      </button>
    );
  return (
    <label className="flex h-9 w-56 items-center gap-2 rounded-lg border border-line bg-app px-2.5 text-sm focus-within:border-[#3a3a3a]">
      <Search className="size-4 shrink-0 text-muted" strokeWidth={1.75} />
      <input
        autoFocus
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => e.key === "Escape" && close()}
        onBlur={() => !value && setOpened(false)}
        placeholder="Search activity"
        aria-label="Search activity"
        className="min-w-0 flex-1 bg-transparent text-ink placeholder:text-faint focus:outline-none"
      />
      <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={close} aria-label="Clear search" className="rounded p-0.5 text-muted hover:text-ink">
        <X className="size-3.5" />
      </button>
    </label>
  );
}

/** Un passo di una missione, o un allarme inviato (con icona del canale, destinatario e se è arrivato). */
function ActivityTableRow({ r }: { r: ActivityRow }) {
  const isBot = r.alert?.channel === "GrokBot";
  const Icon = r.alert && !isBot && channelIcons[r.alert.channel];
  return (
    <tr className="align-top">
      <td className="whitespace-nowrap px-4 py-2.5 font-mono tabular-nums text-muted">{r.time}</td>
      <td className="whitespace-nowrap px-2 py-2.5 text-ink">
        <span className="flex items-center gap-1.5">
          {isBot && <GrokBotColorIcon className={`size-4 ${botColor(r.missionId)}`} />}
          {Icon && <Icon className="size-3.5 text-muted" strokeWidth={1.75} />}
          {r.what}
        </span>
      </td>
      <td className="whitespace-nowrap px-2 py-2.5">
        <Link href={`/missions/${r.missionId}`} className="font-mono text-muted hover:text-ink">
          {r.missionId}
        </Link>
      </td>
      <td className="whitespace-nowrap px-2 py-2.5 text-muted">{r.room}</td>
      <td className="whitespace-nowrap px-2 py-2.5 text-muted">{r.robot}</td>
      <td className="px-4 py-2.5 text-ink/90">
        {r.alert ? (
          <>
            <span className="flex items-center gap-2 text-muted">
              To {r.alert.to}
              <Badge tone={r.alert.delivered ? "green" : "red"}>{r.alert.delivered ? "Delivered" : "Failed"}</Badge>
            </span>
            <p className="mt-1 leading-relaxed">{r.detail}</p>
          </>
        ) : (
          r.detail
        )}
      </td>
    </tr>
  );
}
