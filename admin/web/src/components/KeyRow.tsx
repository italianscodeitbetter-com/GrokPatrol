"use client";

import { useState } from "react";
import { GhostButton } from "@/components/settings-ui";

// Riga per una chiave API. Per ora non salva né verifica nulla: lo stato resta nella pagina.
export function KeyRow({ name, hint, placeholder }: { name: string; hint: string; placeholder: string }) {
  const [value, setValue] = useState("");
  const [status, setStatus] = useState("Not connected");
  const id = `key-${name.toLowerCase().replace(/\W+/g, "-")}`;

  return (
    <div className="flex flex-wrap items-start justify-between gap-x-8 gap-y-3 px-6 py-3.5">
      <div className="min-w-0 flex-1 basis-48 pt-2">
        <label htmlFor={id} className="block text-[15px]">
          {name}
        </label>
        <p className="mt-0.5 text-sm leading-relaxed text-muted">{hint}</p>
      </div>
      <div className="flex w-full flex-col items-end gap-2 sm:w-auto">
        <div className="flex w-full items-center gap-2">
          <GhostButton onClick={() => setStatus(value ? "Key not checked yet: not wired up" : "Paste a key first")}>Check</GhostButton>
          <input
            id={id}
            type="password"
            autoComplete="off"
            spellCheck={false}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder={placeholder}
            className="h-10 min-w-0 flex-1 rounded-lg bg-panel px-3 font-mono text-sm text-ink placeholder:text-faint outline-none ring-1 ring-transparent transition focus:ring-[#3a3a3a] sm:w-[220px] sm:flex-none"
          />
          <GhostButton disabled={!value} onClick={() => setStatus("Saved for this session only")}>
            Save
          </GhostButton>
        </div>
        <p className="text-sm text-muted" role="status">
          {status}
        </p>
      </div>
    </div>
  );
}
