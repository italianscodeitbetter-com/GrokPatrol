"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, RotateCcw, RotateCw, X } from "lucide-react";
import { CameraFeed } from "@/components/CameraFeed";
import { BatteryTag } from "@/components/robot";
import { Badge } from "@/components/ui";
import { roomName } from "@/lib/mock";

export type Move = "avanti" | "indietro" | "sinistra" | "destra" | "ruota-sx" | "ruota-dx" | "stop";

const KEYS: Record<string, Move> = {
  ArrowUp: "avanti", w: "avanti",
  ArrowDown: "indietro", s: "indietro",
  ArrowLeft: "sinistra", a: "sinistra",
  ArrowRight: "destra", d: "destra",
  q: "ruota-sx", e: "ruota-dx",
  " ": "stop",
};

const moveLabel: Record<Move, string> = {
  avanti: "Forward", indietro: "Back", sinistra: "Left", destra: "Right", "ruota-sx": "Turn left", "ruota-dx": "Turn right", stop: "Stop",
};

const NO_MOVES: ReadonlySet<Move> = new Set();

export type DogStatus = "missione" | "ronda" | "base" | "fermo" | "manuale" | "estop" | "offline";

/** Il cane come lo mostra l'interfaccia: costruito dallo stato live del backend (vedi FloorMap3D). */
export type DogInfo = {
  id: string;
  name: string;
  adapter: "simulato" | "unitree";
  /** null = non nota (cane spento o backend offline). */
  battery: number | null;
  state: DogStatus;
  task: string;
  roomId: string;
  connected: boolean;
  armed: boolean;
};

/** Il cane a tutto schermo: la sua telecamera di bordo e, se lo prendi, il controllo manuale
 *  (frecce/WASD, Q/E per ruotare, spazio = stop). Il cane si muove finché tieni premuto.
 *  Per ora guida il cane simulato sulla mappa: quando c'è l'adapter vero, gli stessi comandi vanno al cane. */
export function DogView({
  dog,
  initialControl = false,
  onClose,
  onDrive,
  onStop,
  onReset,
  streamRef,
}: {
  dog: DogInfo;
  /** Apre già col controllo manuale preso («Take control» dalla vista che segue il cane). */
  initialControl?: boolean;
  onClose: () => void;
  /** Comandi tenuti premuti; null = controllo rilasciato. */
  onDrive: (held: ReadonlySet<Move> | null) => void;
  /** Stop (pulsante rosso o spazio): ferma il cane e annulla l'obiettivo. */
  onStop: () => void;
  /** Dopo un E-stop: riarma il cane. */
  onReset: () => void;
  /** Dove disegnare la telecamera di bordo. */
  streamRef: (el: HTMLDivElement | null) => void;
}) {
  const [control, setControl] = useState(initialControl);
  const [held, setHeld] = useState<ReadonlySet<Move>>(NO_MOVES);
  const [stopped, setStopped] = useState(false);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const onDriveRef = useRef(onDrive);
  useEffect(() => {
    onDriveRef.current = onDrive;
  });

  useEffect(() => {
    closeBtn.current?.focus();
  }, []);

  // i comandi vanno al cane appena cambiano; chiudendo la vista il controllo si rilascia
  useEffect(() => {
    onDriveRef.current(control ? held : null);
  }, [control, held]);
  useEffect(() => () => onDriveRef.current(null), []);
  const onStopRef = useRef(onStop);
  useEffect(() => {
    onStopRef.current = onStop;
  });

  const press = (m: Move) => {
    if (m === "stop") {
      setHeld(NO_MOVES);
      setStopped(true);
      onStopRef.current();
      return;
    }
    setStopped(false);
    setHeld((h) => (h.has(m) ? h : new Set(h).add(m)));
  };
  const release = (m: Move) =>
    setHeld((h) => {
      if (!h.has(m)) return h;
      const n = new Set(h);
      n.delete(m);
      return n;
    });

  useEffect(() => {
    const move = (e: KeyboardEvent) => (control ? KEYS[e.key.length === 1 ? e.key.toLowerCase() : e.key] : undefined);
    const onDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") return onClose();
      const m = move(e);
      if (!m) return;
      e.preventDefault();
      if (!e.repeat) press(m);
    };
    const onUp = (e: KeyboardEvent) => {
      const m = move(e);
      if (m && m !== "stop") release(m);
    };
    // se la finestra perde il focus i tasti rilasciati non arrivano: ferma tutto
    const onBlur = () => setHeld(NO_MOVES);
    window.addEventListener("keydown", onDown);
    window.addEventListener("keyup", onUp);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("keyup", onUp);
      window.removeEventListener("blur", onBlur);
    };
  }, [control, onClose]);

  // si tiene premuto: il cane va finché il dito o il mouse restano giù
  const pad = (m: Move, Icon: typeof ArrowUp, className = "") => (
    <button
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        press(m);
      }}
      onPointerUp={() => release(m)}
      onPointerCancel={() => release(m)}
      onContextMenu={(e) => e.preventDefault()}
      aria-label={moveLabel[m]}
      title={moveLabel[m]}
      className={`grid size-14 touch-none select-none place-items-center rounded-xl border border-white/10 bg-black/50 text-ink backdrop-blur transition-colors hover:bg-white/10 ${
        held.has(m) ? "ring-2 ring-accent" : ""
      } ${className}`}
    >
      <Icon className="size-5" strokeWidth={2} />
    </button>
  );

  return createPortal(
    <div role="dialog" aria-modal="true" aria-label={`${dog.name} full screen`} className="fixed inset-0 z-50 flex flex-col bg-black text-ink">
      {/* telecamera di bordo (simulata nella scena 3D; sotto, il segnaposto finché non parte) */}
      <div className="absolute inset-0 grid place-items-center bg-[repeating-linear-gradient(135deg,#141414_0_16px,#181818_16px_32px)]">
        <span className="text-sm text-faint">{dog.name} stream · {roomName(dog.roomId)}</span>
        <div ref={streamRef} className="absolute inset-0" />
        {/* telefono montato sul cane (camera «dog» del backend): quando manda fotogrammi copre la vista simulata */}
        <CameraFeed id="dog" alt={`${dog.name} on-board camera`} className="absolute inset-0 size-full object-contain" />
      </div>

      {/* barra in alto */}
      <div className="relative flex flex-wrap items-center justify-between gap-3 bg-gradient-to-b from-black/80 to-transparent p-4 md:p-6">
        <div className="flex flex-wrap items-center gap-3">
          <Badge tone="red">● LIVE</Badge>
          <span className="text-sm text-muted">{dog.task}</span>
        </div>
        <div className="flex items-center gap-3">
          {/* nome del bot e la sua batteria, come sull'etichetta della mappa */}
          <span className="flex items-center gap-2 rounded-lg bg-black/50 px-3 py-1.5 text-sm text-ink backdrop-blur">
            {dog.name}
            {dog.battery == null ? <span className="font-mono text-sm text-faint">—</span> : <BatteryTag battery={dog.battery} off={!dog.connected} />}
          </span>
          <button
            ref={closeBtn}
            onClick={onClose}
            aria-label="Close (Esc)"
            title="Close (Esc)"
            className="grid size-9 place-items-center rounded-lg bg-black/50 text-muted backdrop-blur hover:bg-white/10 hover:text-ink"
          >
            <X className="size-5" />
          </button>
        </div>
      </div>

      {/* senza controllo: in basso al centro «Close» (chiude la visuale) e «Take control» */}
      {!control && (
        <div className="relative mt-auto flex justify-center gap-2 bg-gradient-to-t from-black/80 to-transparent p-4 pb-20 md:p-6 md:pb-24">
          {/* «Close» a sinistra, secondario (come gli altri bottoni secondari dell'app); «Take control» è il principale */}
          <button onClick={onClose} className="rounded-lg border border-line bg-panel px-4 py-2 text-sm text-ink transition-colors hover:bg-hover">
            Close
          </button>
          <button
            onClick={() => setControl(true)}
            className="rounded-lg bg-ink px-4 py-2 text-sm font-medium text-app shadow-lg shadow-black/40 transition-opacity hover:opacity-90"
          >
            Take control
          </button>
        </div>
      )}

      {/* con il controllo preso: le info in alto al centro, i comandi in basso al centro e «Release control» sotto */}
      {control && (
        <>
          <div className="pointer-events-none absolute inset-x-0 top-20 flex flex-col items-center gap-1.5 px-4 text-center md:top-24">
            <span className="flex items-center gap-2 text-sm">
              <span className="size-2 animate-pulse rounded-full bg-amber-300" />
              Manual control: mission paused
            </span>
            <span className="text-sm text-muted">
              {held.size
                ? `Moving: ${[...held].map((m) => moveLabel[m]).join(" + ")}`
                : stopped
                  ? "Stopped"
                  : "Hold arrow keys or WASD to move, Q/E to turn, Space to stop"}
            </span>
            <span className="text-sm text-faint">
              {!dog.connected
                ? "The dog is not connected: commands are not reaching it."
                : `You are driving the ${dog.adapter === "unitree" ? "real" : "simulated"} dog. When released, it stops.`}
            </span>
            {!dog.armed && (
              <button
                onClick={onReset}
                className="pointer-events-auto mt-1 rounded-lg border border-red-400/40 bg-black/50 px-3 py-2 text-sm text-red-300 backdrop-blur hover:bg-white/10"
              >
                E-stop active · Reset
              </button>
            )}
          </div>

          <div className="relative mt-auto flex flex-col items-center gap-4 bg-gradient-to-t from-black/80 to-transparent p-4 pb-20 md:p-6 md:pb-24">
            <div className="flex items-end gap-4">
              <div className="grid grid-cols-3 gap-2">
                {pad("ruota-sx", RotateCcw)}
                {pad("avanti", ArrowUp)}
                {pad("ruota-dx", RotateCw)}
                {pad("sinistra", ArrowLeft)}
                {pad("indietro", ArrowDown)}
                {pad("destra", ArrowRight)}
              </div>
            </div>
            <button
              onClick={() => {
                setControl(false);
                setHeld(NO_MOVES);
                setStopped(false);
              }}
              className="rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90"
            >
              Release control
            </button>
          </div>
        </>
      )}
    </div>,
    document.body,
  );
}
