"use client";

import { useEffect, useRef, useState } from "react";
import { streamUrl } from "@/lib/backend";

/** Video live di una telecamera del backend. La telecamera manda i fotogrammi veloci solo finché qualcuno guarda.
 *  Se il flusso cade si riprova da soli; finché non arriva un fotogramma non si vede niente: sotto resta il segnaposto. */
export function CameraFeed({ id, alt, className = "" }: { id: string; alt: string; className?: string }) {
  const [attempt, setAttempt] = useState(0);
  const [down, setDown] = useState(false);
  const img = useRef<HTMLImageElement>(null);

  useEffect(() => {
    if (!down) return;
    const t = setTimeout(() => {
      setDown(false);
      setAttempt((a) => a + 1);
    }, 2000);
    return () => clearTimeout(t);
  }, [down]);

  // senza questo il browser tiene aperto il flusso anche dopo aver chiuso la vista
  useEffect(() => {
    const el = img.current;
    return () => {
      if (el) el.src = "";
    };
  }, [id, attempt, down]);

  if (down) return null;
  // eslint-disable-next-line @next/next/no-img-element -- video live dal backend, non un'immagine da ottimizzare
  return <img ref={img} key={`${id}-${attempt}`} src={streamUrl(id, attempt)} alt={alt} className={className} onError={() => setDown(true)} />;
}
