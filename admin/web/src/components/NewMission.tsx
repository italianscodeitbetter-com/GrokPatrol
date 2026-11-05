"use client";

import { useEffect, useRef, useState } from "react";
import { Plus, X } from "lucide-react";
import { rooms } from "@/lib/mock";

const input =
  "w-full rounded-lg border border-line bg-app px-3 py-2 text-sm text-ink placeholder:text-faint focus:border-[#3a3a3a] focus:outline-none";

// Per ora la missione resta locale. Poi andrà a Grok, che la traduce in comandi per il cane.
export function NewMission() {
  const dialog = useRef<HTMLDialogElement>(null);
  const [sent, setSent] = useState<string | null>(null);

  useEffect(() => {
    if (!sent) return;
    const t = setTimeout(() => setSent(null), 4000);
    return () => clearTimeout(t);
  }, [sent]);

  return (
    <>
      <div className="flex items-center gap-3">
        {sent && (
          <span className="text-sm text-faint" role="status">
            “{sent}” created locally. Grok is not connected yet.
          </span>
        )}
        <button
          onClick={() => dialog.current?.showModal()}
          className="flex items-center gap-2 rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90"
        >
          <Plus className="size-4" strokeWidth={2.25} />
          New mission
        </button>
      </div>

      <dialog
        ref={dialog}
        className="m-auto w-[440px] max-w-[calc(100%-2rem)] rounded-xl border border-line bg-panel p-0 text-ink backdrop:bg-black/60"
      >
        <form
          method="dialog"
          onSubmit={(e) => {
            const data = new FormData(e.currentTarget);
            setSent(String(data.get("what") || "Mission"));
            e.currentTarget.reset();
          }}
        >
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="text-sm font-medium">New mission</h2>
            <button
              type="button"
              onClick={() => dialog.current?.close()}
              aria-label="Close"
              className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink"
            >
              <X className="size-4" />
            </button>
          </div>
          <div className="grid gap-4 p-4">
            <label className="grid gap-1.5">
              <span className="text-sm">What should the dog do</span>
              <input name="what" required autoFocus className={input} placeholder="e.g. “check the east exit”" />
            </label>
            <label className="grid gap-1.5">
              <span className="text-sm">Room</span>
              <select name="room" className={input} defaultValue={rooms[0].id}>
                {rooms.map((r) => (
                  <option key={r.id} value={r.id}>
                    {r.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="flex justify-end gap-2 border-t border-line px-4 py-3">
            <button
              type="button"
              onClick={() => dialog.current?.close()}
              className="rounded-lg px-3 py-2 text-sm text-muted hover:bg-hover hover:text-ink"
            >
              Cancel
            </button>
            <button type="submit" className="rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app hover:opacity-90">
              Create mission
            </button>
          </div>
        </form>
      </dialog>
    </>
  );
}
