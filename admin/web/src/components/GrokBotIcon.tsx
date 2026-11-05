import type { SVGProps } from "react";

/** Il logo di Grok Bot (la sfera con i due occhi) disegnato come le icone lucide: stesso box 24×24, colore = currentColor. */
export function GrokBotIcon({ strokeWidth = 2, ...props }: SVGProps<SVGSVGElement> & { strokeWidth?: number }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" aria-hidden {...props}>
      <circle cx="12" cy="12" r="9" />
      <path d="M8.9 10.2l1.4 3.6M13.6 8.6l1 2.4" strokeWidth={strokeWidth * 1.35} />
    </svg>
  );
}

/** GrokBot a colori: la sfera piena (colore = currentColor, es. `text-bot-pink`) con gli occhi bianchi. */
export function GrokBotColorIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...props}>
      <circle cx="12" cy="12" r="11" fill="currentColor" />
      <path d="M8.9 10.2l1.4 3.6M13.6 8.6l1 2.4" stroke="#fff" strokeWidth={2.4} strokeLinecap="round" />
    </svg>
  );
}

/** GrokBot pieno, per i menu: sfera piena col colore del testo (come le altre icone), occhi «bucati» col colore dello sfondo. */
export function GrokBotFilledIcon({ strokeWidth = 2, ...props }: SVGProps<SVGSVGElement> & { strokeWidth?: number }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...props}>
      <circle cx="12" cy="12" r="10" fill="currentColor" />
      <path d="M8.9 10.2l1.4 3.6M13.6 8.6l1 2.4" stroke="var(--color-app)" strokeWidth={strokeWidth * 1.35} strokeLinecap="round" />
    </svg>
  );
}
