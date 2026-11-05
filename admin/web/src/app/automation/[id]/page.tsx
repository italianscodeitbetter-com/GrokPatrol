import type { Metadata } from "next";
import { Suspense } from "react";
import { AutomationDetail } from "@/components/AutomationDetail";
import { Page } from "@/components/ui";
import { automations } from "@/lib/mock";

// Le automazioni vere stanno sul server (AU-01…, le ronde del sito r1, r2…, «alarm») e si leggono nel browser:
// qui si prerenderizzano solo gli id di mock.ts (Cache Components vuole almeno un param), gli altri prendono
// l'App Shell e params si legge dentro <Suspense> (docs: ISR with Cache Components).
export function generateStaticParams() {
  return automations.map((a) => ({ id: a.id }));
}

// il nome non si sa sul server (gli id di mock.ts e del backend si sovrappongono): il titolo usa l'id
export async function generateMetadata({ params }: PageProps<"/automation/[id]">): Promise<Metadata> {
  const { id } = await params;
  return { title: `${id} · Automation · GrokPatrol` };
}

async function Detail({ params }: Pick<PageProps<"/automation/[id]">, "params">) {
  const { id } = await params;
  return <AutomationDetail id={decodeURIComponent(id)} />;
}

export default function AutomationPage({ params }: PageProps<"/automation/[id]">) {
  return (
    <Page>
      <Suspense fallback={null}>
        <Detail params={params} />
      </Suspense>
    </Page>
  );
}
