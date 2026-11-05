import type { ComponentType } from "react";
import { Bell, Bot, Camera, Keyboard, Settings } from "lucide-react";
import { GrokBotFilledIcon } from "@/components/GrokBotIcon";

export type SettingsIcon = ComponentType<{ className?: string; strokeWidth?: number }>;

export type SettingsSection = "general" | "alerts" | "bots" | "grokbot" | "cameras" | "shortcuts";

// Stesso raggruppamento del riferimento: «App» in alto, «Account» sotto. Le impostazioni si aprono in un modale.
export const settingsGroups: { label: string; items: { id: SettingsSection; label: string; icon: SettingsIcon }[] }[] = [
  {
    label: "App",
    items: [
      { id: "alerts", label: "Alerts", icon: Bell },
      { id: "bots", label: "Bots", icon: Bot },
      { id: "grokbot", label: "GrokBot", icon: GrokBotFilledIcon },
      { id: "cameras", label: "Cameras", icon: Camera },
      { id: "shortcuts", label: "Shortcuts", icon: Keyboard },
    ],
  },
  { label: "Account", items: [{ id: "general", label: "Settings", icon: Settings }] },
];

export const settingsSections = settingsGroups.flatMap((g) => g.items);
