"use client";

import { useEffect, useRef, useSyncExternalStore } from "react";
import { X } from "lucide-react";
import { SettingsContent } from "@/components/SettingsContent";
import { settingsGroups, settingsSections, type SettingsSection } from "@/lib/settings";

// Quale sezione è aperta (null = modale chiuso). Si apre da ovunque con openSettings() o ⌘,.
let current: SettingsSection | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());
export const openSettings = (section: SettingsSection = "general") => {
  current = section;
  emit();
};
export const closeSettings = () => {
  current = null;
  emit();
};
const subscribe = (cb: () => void) => {
  listeners.add(cb);
  return () => listeners.delete(cb);
};

/** Impostazioni in un modale: sezioni a sinistra, contenuto a destra. Esc o clic fuori per chiudere. */
export function SettingsModal() {
  const section = useSyncExternalStore(subscribe, () => current, () => null);
  const panel = useRef<HTMLDivElement>(null);

  // ⌘, (Ctrl+, su Windows/Linux) apre le impostazioni da qualsiasi pagina
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === ",") {
        e.preventDefault();
        openSettings(current ?? "general");
      } else if (e.key === "Escape" && current) closeSettings();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (section) panel.current?.focus();
  }, [section]);

  if (!section) return null;
  const info = settingsSections.find((s) => s.id === section)!;
  const Icon = info.icon;

  return (
    <div className="fixed inset-0 z-[60] grid place-items-center bg-black/60 p-4" onPointerDown={(e) => e.target === e.currentTarget && closeSettings()}>
      <div
        ref={panel}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
        className="flex h-[min(720px,calc(100vh-2rem))] w-[min(1000px,100%)] overflow-hidden rounded-2xl border border-line bg-app shadow-2xl shadow-black/60 outline-none"
      >
        <nav className="hidden w-56 shrink-0 flex-col gap-0.5 overflow-y-auto border-r border-line bg-side p-2 sm:flex" aria-label="Settings sections">
          {settingsGroups.map((g) => (
            <div key={g.label} className="flex flex-col gap-0.5 pb-4">
              <div className="px-3 pb-1.5 pt-2 text-[13px] text-muted">{g.label}</div>
              {g.items.map((s) => {
                const I = s.icon;
                const active = s.id === section;
                return (
                  <button
                    key={s.id}
                    onClick={() => openSettings(s.id)}
                    aria-current={active ? "page" : undefined}
                    className={`flex items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition-colors ${
                      active ? "bg-active text-ink" : "text-ink/85 hover:bg-hover hover:text-ink"
                    }`}
                  >
                    <I className="size-[18px] shrink-0" strokeWidth={1.75} />
                    {s.label}
                  </button>
                );
              })}
            </div>
          ))}
        </nav>

        <div className="flex min-w-0 flex-1 flex-col">
          <header className="flex h-14 shrink-0 items-center gap-3 border-b border-line px-6">
            <Icon className="size-[18px] text-ink/90" strokeWidth={1.75} />
            <h2 className="flex-1 text-[15px]">{info.label}</h2>
            {/* su schermi stretti la colonna delle sezioni sparisce: si cambia sezione da qui */}
            <select
              value={section}
              onChange={(e) => openSettings(e.target.value as SettingsSection)}
              aria-label="Section"
              className="h-9 rounded-lg bg-panel px-2 text-sm text-ink sm:hidden"
            >
              {settingsSections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            <button onClick={closeSettings} aria-label="Close settings (Esc)" title="Close (Esc)" className="rounded-lg p-1.5 text-muted hover:bg-hover hover:text-ink">
              <X className="size-5" />
            </button>
          </header>
          <div className="flex-1 overflow-y-auto px-2 py-8 md:px-4">
            <div className="mx-auto w-full max-w-[720px]">
              <SettingsContent key={section} section={section} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
