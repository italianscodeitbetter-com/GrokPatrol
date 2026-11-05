"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState, useSyncExternalStore } from "react";
import { Bot, FileText, LayoutDashboard, Menu, PanelLeft, Route, X, type LucideIcon } from "lucide-react";
import { GrokBotCard } from "@/components/GrokBotCard";
import { ProfileMenu } from "@/components/ProfileMenu";
import { SettingsModal } from "@/components/SettingsModal";

const mainNav: { href: string; label: string; icon: LucideIcon }[] = [
  { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
  { href: "/automation", label: "Automation", icon: Bot },
  { href: "/missions", label: "Missions", icon: Route },
  { href: "/reports", label: "Reports", icon: FileText },
];

// Stato "compresso" salvato in localStorage, letto senza mismatch di idratazione.
const KEY = "grokdog:sidebar-collapsed";
const EVT = "grokdog:sidebar";
const subscribe = (cb: () => void) => {
  window.addEventListener("storage", cb);
  window.addEventListener(EVT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(EVT, cb);
  };
};
const getCollapsed = () => localStorage.getItem(KEY) === "1";
const setCollapsed = (v: boolean) => {
  localStorage.setItem(KEY, v ? "1" : "0");
  window.dispatchEvent(new Event(EVT));
};

export function Logo({ className = "" }: { className?: string }) {
  return (
    // simbolo SpaceX (Simple Icons)
    <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden>
      <path d="M24 7.417C8.882 8.287 1.89 14.75.321 16.28L0 16.583h2.797C10.356 9.005 21.222 7.663 24 7.417zm-17.046 6.35c-.472.321-.945.68-1.398 1.02l2.457 1.796h2.778zM2.948 10.8H.189l3.25 2.381c.473-.321 1.02-.661 1.512-.945Z" />
    </svg>
  );
}

export function Sidebar() {
  const pathname = usePathname();
  const collapsed = useSyncExternalStore(subscribe, getCollapsed, () => false);
  const [mobileOpen, setMobileOpen] = useState(false);

  const isActive = (href: string) => pathname === href || pathname.startsWith(href + "/");
  const hideLabel = collapsed ? "md:sr-only" : "";
  const close = () => setMobileOpen(false);

  const item = (href: string, label: string, Icon: LucideIcon) => {
    const active = isActive(href);
    return (
      <Link
        key={href}
        href={href}
        onClick={close}
        title={collapsed ? label : undefined}
        aria-current={active ? "page" : undefined}
        className={`flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
          collapsed ? "md:justify-center md:px-0" : ""
        } ${active ? "bg-active text-ink" : "text-ink/85 hover:bg-hover hover:text-ink"}`}
      >
        <Icon className="size-[18px] shrink-0" strokeWidth={1.75} />
        <span className={hideLabel}>{label}</span>
      </Link>
    );
  };

  return (
    <>
      {/* Barra superiore solo su smartphone */}
      <div className="fixed inset-x-0 top-0 z-30 flex h-12 items-center gap-3 border-b border-line bg-side px-3 md:hidden">
        <button
          onClick={() => setMobileOpen(true)}
          aria-label="Open menu"
          className="rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink"
        >
          <Menu className="size-5" />
        </button>
        <Logo className="size-5 text-ink" />
        <span className="text-sm font-medium">GrokPatrol</span>
      </div>

      {mobileOpen && (
        <div className="fixed inset-0 z-40 bg-black/50 md:hidden" onClick={close} aria-hidden />
      )}

      <aside
        className={`fixed inset-y-0 left-0 z-50 flex w-[260px] shrink-0 flex-col border-r border-line bg-side transition-[transform,width] duration-200 md:static md:translate-x-0 md:border-r-0 ${
          mobileOpen ? "translate-x-0" : "-translate-x-full"
        } ${collapsed ? "md:w-16" : "md:w-[260px]"}`}
      >
        <div className={`flex h-14 items-center gap-2.5 px-4 ${collapsed ? "md:justify-center md:px-0" : ""}`}>
          <Logo className={`size-5 shrink-0 text-ink ${collapsed ? "md:hidden" : ""}`} />
          <span className={`flex-1 text-[15px] font-medium tracking-tight ${hideLabel}`}>GrokPatrol</span>
          <button
            onClick={() => setCollapsed(!collapsed)}
            aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            className="hidden rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink md:block"
          >
            <PanelLeft className="size-[18px]" strokeWidth={1.75} />
          </button>
          <button
            onClick={close}
            aria-label="Close menu"
            className="rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink md:hidden"
          >
            <X className="size-[18px]" />
          </button>
        </div>

        <nav className="flex flex-col gap-0.5 px-2 pt-2" aria-label="Main">
          {mainNav.map((n) => item(n.href, n.label, n.icon))}
        </nav>

        <div className="mt-auto flex flex-col gap-2 px-2 pb-3">
          <GrokBotCard className={`mb-2 ${collapsed ? "md:hidden" : ""}`} />
          <ProfileMenu collapsed={collapsed} />
        </div>
      </aside>

      {/* impostazioni: modale sopra qualsiasi pagina */}
      <SettingsModal />
    </>
  );
}
