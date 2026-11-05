import type { Metadata } from "next";
import { MissionsView } from "@/components/MissionsView";
import { Page } from "@/components/ui";

export const metadata: Metadata = { title: "Missions · GrokPatrol" };

export default function MissionsPage() {
  return (
    <Page>
      <MissionsView />
    </Page>
  );
}
