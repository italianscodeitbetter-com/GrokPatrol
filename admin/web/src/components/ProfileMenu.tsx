"use client";

import { useEffect, useRef, useState } from "react";
import { Bell, Bot, Camera, Keyboard, LogOut, Settings } from "lucide-react";
import { GrokBotFilledIcon } from "@/components/GrokBotIcon";
import { openSettings as openModal } from "@/components/SettingsModal";
import { Avatar } from "@/components/Avatar";
import { profile } from "@/lib/profile";
import type { SettingsSection } from "@/lib/settings";

/** In fondo alla sidebar: avatar e nome aprono il menu; ogni voce apre le impostazioni nel modale. ⌘, ovunque. */
export function ProfileMenu({ collapsed }: { collapsed: boolean }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => !box.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  const openSettings = (s: SettingsSection) => {
    setOpen(false);
    openModal(s);
  };

  const item = "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm text-ink transition-colors hover:bg-hover";
  const icon = "size-[18px] text-muted";
  const sep = <div className="mx-3 my-1.5 h-px bg-line" />;

  return (
    <div ref={box} className="relative">
      {open && (
        <div role="menu" className="absolute bottom-full left-0 z-50 mb-2 w-64 rounded-2xl border border-line bg-panel p-1.5 shadow-2xl shadow-black/50">
          <button role="menuitem" onClick={() => openSettings("general")} className={item}>
            <Settings className={icon} strokeWidth={1.75} />
            <span className="flex-1 text-left">Settings</span>
            <kbd className="font-sans text-sm text-muted">⌘,</kbd>
          </button>
          {sep}
          <button role="menuitem" onClick={() => openSettings("alerts")} className={item}>
            <Bell className={icon} strokeWidth={1.75} /> Alerts
          </button>
          <button role="menuitem" onClick={() => openSettings("bots")} className={item}>
            <Bot className={icon} strokeWidth={1.75} /> Bots
          </button>
          <button role="menuitem" onClick={() => openSettings("grokbot")} className={item}>
            <GrokBotFilledIcon className={icon} strokeWidth={1.75} /> GrokBot
          </button>
          <button role="menuitem" onClick={() => openSettings("cameras")} className={item}>
            <Camera className={icon} strokeWidth={1.75} /> Cameras
          </button>
          <button role="menuitem" onClick={() => openSettings("shortcuts")} className={item}>
            <Keyboard className={icon} strokeWidth={1.75} /> Shortcuts
          </button>
          {sep}
          <button role="menuitem" disabled title="Coming soon" className={`${item} disabled:opacity-50 disabled:hover:bg-transparent`}>
            <LogOut className={icon} strokeWidth={1.75} /> Log out
          </button>
        </div>
      )}

      <div className={`flex items-center gap-1 ${collapsed ? "md:justify-center" : ""}`}>
        <button
          onClick={() => setOpen(!open)}
          aria-haspopup="menu"
          aria-expanded={open}
          title={collapsed ? profile.name : undefined}
          className={`flex min-w-0 flex-1 items-center gap-3 rounded-xl p-1.5 text-left transition-colors hover:bg-hover ${open ? "bg-hover" : ""} ${
            collapsed ? "md:flex-none" : ""
          }`}
        >
          <Avatar className="size-9 shrink-0" />
          <span className={`min-w-0 flex-1 truncate text-sm ${collapsed ? "md:sr-only" : ""}`}>{profile.name}</span>
        </button>
      </div>
    </div>
  );
}
