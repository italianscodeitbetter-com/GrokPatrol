import type { Metadata } from "next";
import { Suspense } from "react";
import { MissionDetail } from "@/components/MissionDetail";
import { Page } from "@/components/ui";
import { missions } from "@/lib/mock";

// Le missioni del mock sono prerenderizzate (con Cache Components serve almeno un parametro); quelle del backend
// (m-xxxxx) si generano alla prima richiesta. Il contenuto è live, lato client: MissionDetail.
export function generateStaticParams() {
  return missions.map((m) => ({ id: m.id }));
}

export async function generateMetadata({ params }: PageProps<"/missions/[id]">): Promise<Metadata> {
  const { id } = await params;
  return { title: `${id} · GrokPatrol` };
}

// Una pagina per missione: a sinistra lo stato e la timeline, a destra il video.
// I parametri si leggono dentro <Suspense> (Cache Components): la pagina si apre subito, l'id arriva in streaming.
export default function MissionPage({ params }: PageProps<"/missions/[id]">) {
  return (
    <Page>
      <Suspense fallback={<p className="py-10 text-center text-sm text-muted">Loading…</p>}>
        {params.then(({ id }) => (
          <MissionDetail id={id} />
        ))}
      </Suspense>
    </Page>
  );
}
