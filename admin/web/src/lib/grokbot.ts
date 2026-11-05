"use client";

import { useSyncExternalStore } from "react";

// Stato del collegamento a GrokBot, condiviso fra la card nella sidebar e le impostazioni.
// Per ora è finto: «Connect» aspetta un attimo e risulta collegato.
export type GrokBotStatus = "off" | "connecting" | "on";

let status: GrokBotStatus = "off";
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());
let timer: ReturnType<typeof setTimeout> | undefined;

export function setGrokBot(next: GrokBotStatus) {
  clearTimeout(timer);
  status = next;
  if (next === "connecting") timer = setTimeout(() => setGrokBot("on"), 1200);
  emit();
}

export const toggleGrokBot = () => setGrokBot(status === "off" ? "connecting" : "off");

export function useGrokBot() {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => status,
    () => "off" as GrokBotStatus,
  );
}
