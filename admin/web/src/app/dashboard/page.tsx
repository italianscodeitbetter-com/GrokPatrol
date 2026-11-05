import type { Metadata } from "next";
import { FloorMap3D } from "@/components/FloorMap3D";

export const metadata: Metadata = { title: "Dashboard · GrokPatrol" };

// La planimetria 3D occupa tutto il pannello; la barra in alto (bot, turno e ora, stanza, notifiche) sta dentro FloorMap3D.
export default function DashboardPage() {
  return (
    <div className="relative h-full min-h-[560px]">
      <FloorMap3D />
    </div>
  );
}
