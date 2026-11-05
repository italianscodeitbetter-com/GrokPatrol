import type { Metadata } from "next";
import { ReportsView } from "@/components/ReportsView";
import { Page } from "@/components/ui";

export const metadata: Metadata = { title: "Reports · GrokPatrol" };

export default function ReportsPage() {
  return (
    <Page>
      <ReportsView />
    </Page>
  );
}
