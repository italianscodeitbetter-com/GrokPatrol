"use client";

import { useState } from "react";
import { ArrowUp, Mic } from "lucide-react";

// Per ora il comando resta locale. Poi andrà a Grok, che lo traduce in una missione.
export function CommandBar() {
  const [value, setValue] = useState("");
  const [sent, setSent] = useState<string | null>(null);

  const submit = (text: string) => {
    const t = text.trim();
    if (!t) return;
    setSent(t);
    setValue("");
  };

  return (
    <div>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit(value);
        }}
        className="flex items-center gap-2 rounded-2xl border border-line bg-panel py-1.5 pl-4 pr-1.5 focus-within:border-[#3a3a3a]"
      >
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="Type a command, e.g. “patrol room 2”"
          aria-label="Command"
          className="min-w-0 flex-1 bg-transparent text-sm text-ink placeholder:text-faint focus:outline-none"
        />
        <button
          type="button"
          title="Voice command (coming soon)"
          aria-label="Voice command"
          className="grid size-8 place-items-center rounded-full text-muted hover:bg-hover hover:text-ink"
        >
          <Mic className="size-[18px]" strokeWidth={1.75} />
        </button>
        <button
          type="submit"
          aria-label="Send command"
          disabled={!value.trim()}
          className="grid size-8 place-items-center rounded-full bg-ink text-app transition-opacity disabled:opacity-30"
        >
          <ArrowUp className="size-4" strokeWidth={2.25} />
        </button>
      </form>

      {sent && (
        <p className="mt-2 text-sm text-faint" role="status">
          Sent: “{sent}”. Grok is not connected yet.
        </p>
      )}
    </div>
  );
}
