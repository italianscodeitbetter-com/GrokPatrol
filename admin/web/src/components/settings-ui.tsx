import type { ReactNode, SelectHTMLAttributes, InputHTMLAttributes } from "react";
import { ChevronDown } from "lucide-react";

// Mattoni della pagina Settings, sul modello del riferimento:
// titolo del gruppo sopra, card con righe (etichetta a sinistra, controllo a destra), nota sotto.

export function Group({ title, note, children }: { title: string; note?: ReactNode; children: ReactNode }) {
  return (
    <section className="mb-12">
      <h2 className="mb-3 px-6 text-[15px] font-medium">{title}</h2>
      <div className="divide-y divide-line rounded-2xl border border-line bg-white/[0.015]">{children}</div>
      {note && <p className="mt-2.5 px-6 text-[13px] leading-relaxed text-faint">{note}</p>}
    </section>
  );
}

export function Row({ label, hint, children, htmlFor }: { label: string; hint?: string; children?: ReactNode; htmlFor?: string }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-x-8 gap-y-3 px-6 py-3.5">
      <div className="min-w-0 flex-1 basis-56">
        <label htmlFor={htmlFor} className="block text-[15px]">
          {label}
        </label>
        {hint && <p className="mt-0.5 text-sm leading-relaxed text-muted">{hint}</p>}
      </div>
      {children}
    </div>
  );
}

const field =
  "h-10 w-full rounded-lg bg-panel px-3 text-[15px] text-ink placeholder:text-faint outline-none ring-1 ring-transparent transition focus:ring-[#3a3a3a]";

export function TextInput(props: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <div className="w-full sm:w-[300px]">
      <input {...props} className={field} />
    </div>
  );
}

export function Select({ children, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <div className="relative w-full sm:w-[300px]">
      <select {...props} className={`${field} appearance-none pr-9`}>
        {children}
      </select>
      <ChevronDown className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 text-muted" />
    </div>
  );
}

export function GhostButton({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      type="button"
      {...props}
      className="h-10 rounded-lg border border-line px-4 text-[15px] text-ink transition-colors hover:bg-hover disabled:text-faint disabled:hover:bg-transparent"
    >
      {children}
    </button>
  );
}

export function Key({ k }: { k: string }) {
  return <kbd className="min-w-7 rounded-md border border-line bg-panel px-1.5 py-0.5 text-center font-sans text-sm text-ink">{k}</kbd>;
}
