"use client";

import { useState, useSyncExternalStore } from "react";
import Image from "next/image";
import { CircleCheck, Loader2, X } from "lucide-react";
import { toggleGrokBot, useGrokBot } from "@/lib/grokbot";

// La × nasconde la card solo fino al prossimo ricaricamento: finché GrokBot non è collegato
// (e il collegamento per ora non sopravvive al reload) la card torna a ogni apertura della pagina.
let hidden = false;
const listeners = new Set<() => void>();
const subscribe = (cb: () => void) => {
  listeners.add(cb);
  return () => listeners.delete(cb);
};
const getHidden = () => hidden;
const hide = () => {
  hidden = true;
  listeners.forEach((l) => l());
};
// La vecchia versione salvava la chiusura in localStorage: la togliamo, così la card ricompare.
if (typeof window !== "undefined") localStorage.removeItem("grokdog:grokbot-card-hidden");

// Per ora la connessione è finta (stato condiviso con Settings → GrokBot): quando c'è l'adapter vero, «Connect» apre il collegamento.
// «Connect» → un attimo di caricamento → modale di conferma; collegato, la card sparisce dalla sidebar.
export function GrokBotCard({ className = "" }: { className?: string }) {
  const status = useGrokBot();
  const isHidden = useSyncExternalStore(subscribe, getHidden, () => false);
  // la conferma si apre solo se il collegamento è partito da questa card
  const [asked, setAsked] = useState(false);
  const confirm = asked && status === "on";

  return (
    <>
      {!isHidden && status !== "on" && (
        <div className={`rounded-xl border border-line bg-app/40 p-3 ${className}`}>
          {/* la × sta sopra l'immagine, non sulla foto; l'immagine senza riquadro dietro */}
          <div className="-mr-1 -mt-1 mb-1 flex justify-end">
            <button onClick={hide} aria-label="Close" title="Close" className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink">
              <X className="size-4" />
            </button>
          </div>
          <Image src="/grokbot.png" alt="GrokBot" width={800} height={523} sizes="220px" priority className="h-auto w-full rounded-lg" />
          <div className="mt-3 text-sm font-medium">GrokBot</div>
          <p className="mt-1.5 text-sm leading-snug text-muted">Connect the dogs to GrokBot to control them directly from Grok.</p>
          <button
            onClick={() => {
              setAsked(true);
              toggleGrokBot();
            }}
            disabled={status === "connecting"}
            className="mt-3 flex w-full items-center justify-center gap-2 rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90 disabled:opacity-60"
          >
            {status === "connecting" && <Loader2 className="size-4 animate-spin" aria-hidden />}
            {status === "connecting" ? "Connecting…" : "Connect"}
          </button>
        </div>
      )}

      {confirm && (
        <dialog
          ref={(el) => {
            if (el && !el.open) el.showModal();
          }}
          onClose={() => setAsked(false)}
          aria-labelledby="grokbot-connected"
          className="m-auto w-[400px] max-w-[calc(100%-2rem)] rounded-2xl border border-line bg-panel p-0 text-ink backdrop:bg-black/60"
        >
          <div className="p-5">
            <Image src="/grokbot.png" alt="" width={800} height={523} sizes="400px" className="h-auto w-full rounded-lg" />
            <h2 id="grokbot-connected" className="mt-4 flex items-center gap-2 text-[15px] font-medium">
              <CircleCheck className="size-5 text-ok" strokeWidth={2} />
              GrokBot connected
            </h2>
            <p className="mt-1.5 text-sm leading-relaxed text-muted">
              You can now drive the dogs and start missions directly from a Grok chat. You can disconnect it from Settings → GrokBot.
            </p>
            <form method="dialog" className="mt-5 flex justify-end">
              <button className="rounded-lg bg-ink px-4 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90">Done</button>
            </form>
          </div>
        </dialog>
      )}
    </>
  );
}
