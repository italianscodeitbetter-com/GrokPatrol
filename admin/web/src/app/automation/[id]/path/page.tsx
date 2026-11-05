import type { Metadata } from "next";
import { Suspense } from "react";
import { PathEditor } from "@/components/PathEditor";
import { automations } from "@/lib/mock";

// come la pagina dell'automazione: gli id di mock.ts prerenderizzati, quelli del server con l'App Shell
// e params letto dentro <Suspense>
export function generateStaticParams() {
  return automations.map((a) => ({ id: a.id }));
}

export async function generateMetadata({ params }: PageProps<"/automation/[id]/path">): Promise<Metadata> {
  const { id } = await params;
  return { title: `Change path · ${id} · GrokPatrol` };
}

async function Editor({ params }: Pick<PageProps<"/automation/[id]/path">, "params">) {
  const { id } = await params;
  return <PathEditor id={decodeURIComponent(id)} />;
}

export default function ChangePathPage({ params }: PageProps<"/automation/[id]/path">) {
  return (
    <Suspense fallback={null}>
      <Editor params={params} />
    </Suspense>
  );
}
