"use client";

import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown } from "lucide-react";

export type DropdownOption<T> = { value: T; label: string };

/** Tendina dell'app (al posto della <select> del browser): la scelta corrente, clic → lista sotto con la spunta.
 *  Si chiude cliccando fuori o con Esc. */
export function Dropdown<T extends string | number>({
  value,
  options,
  onChange,
  label,
}: {
  value: T;
  options: DropdownOption<T>[];
  onChange: (value: T) => void;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const current = options.find((o) => o.value === value) ?? options[0];

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
        aria-label={label}
        className={`flex h-10 w-full items-center gap-2 rounded-lg border bg-app px-3 text-sm text-ink focus:outline-none ${open ? "border-[#3a3a3a]" : "border-line"}`}
      >
        <span className="min-w-0 flex-1 truncate text-left">{current.label}</span>
        <ChevronDown className={`size-4 shrink-0 text-muted transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && (
        <ul role="listbox" aria-label={label} className="absolute inset-x-0 top-full z-30 mt-1.5 max-h-72 min-w-max overflow-y-auto rounded-xl border border-line bg-panel p-1.5 shadow-2xl shadow-black/50">
          {options.map((o) => (
            <li key={o.value}>
              <button
                type="button"
                role="option"
                aria-selected={o.value === value}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                }}
                className="flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-left text-sm text-ink hover:bg-hover"
              >
                {o.label}
                <Check className={`size-4 shrink-0 text-accent ${o.value === value ? "" : "invisible"}`} />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
