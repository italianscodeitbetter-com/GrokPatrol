import Image from "next/image";

/** Foto del robot, tonda e piccola (la misura arriva da className). Spento = in grigio. */
export function RobotAvatar({ off, className = "size-6" }: { off?: boolean; className?: string }) {
  return (
    <span
      className={`block shrink-0 overflow-hidden rounded-full bg-[radial-gradient(circle_at_40%_45%,#2a2a2a,#141414)] ${off ? "opacity-40 grayscale" : ""} ${className}`}
      aria-hidden
    >
      <Image src="/robot-dog.png" alt="" width={48} height={48} className="size-full scale-150 object-cover object-[40%_45%]" />
    </span>
  );
}

/** Colore della batteria: verde, arancione sotto il 50%, rossa dal 30% in giù (bordo, riempimento, testo).
 *  La usa anche l'etichetta del cane sulla mappa 3D. */
export const batteryTone = (battery: number) =>
  battery <= 30 ? "border-red-400 bg-red-400 text-red-400" : battery < 50 ? "border-accent bg-accent text-accent" : "border-ok bg-ok text-ok";

/** Batteria disegnata + percentuale, l'unica dell'app; grigia se il robot è spento. */
export function BatteryTag({ battery, off }: { battery: number; off?: boolean }) {
  const tone = off ? "border-faint bg-faint text-faint" : batteryTone(battery);
  const [border, fill, text] = tone.split(" ");
  return (
    <span className={`flex items-center gap-1.5 font-mono text-sm tabular-nums ${text}`}>
      <span className={`relative flex h-2.5 w-5 rounded-[3px] border p-px ${border}`}>
        <span className={`block h-full rounded-[1px] ${fill}`} style={{ width: `${battery}%` }} />
        <span className={`absolute -right-[3px] top-1/2 h-1 w-[2px] -translate-y-1/2 rounded-r-sm ${fill}`} />
      </span>
      {battery}%
    </span>
  );
}
