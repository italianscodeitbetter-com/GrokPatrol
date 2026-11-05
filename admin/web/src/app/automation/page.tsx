import type { Metadata } from "next";
import Link from "next/link";
import { Plus } from "lucide-react";
import { AutomationTable } from "@/components/AutomationTable";
import { Page, PageHeader } from "@/components/ui";

export const metadata: Metadata = { title: "Automation · GrokPatrol" };

// I bot delle automazioni: quando partono, cosa fanno e quale cane usano. «New automation» → percorso A → B sulla mappa 3D + orario.
export default function AutomationPage() {
  return (
    <Page>
      <PageHeader
        title="Automation"
        actions={
          <Link
            href="/automation/new"
            className="flex items-center gap-2 rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app transition-opacity hover:opacity-90"
          >
            <Plus className="size-4" strokeWidth={2.25} />
            New automation
          </Link>
        }
      />
      <AutomationTable />
    </Page>
  );
}
