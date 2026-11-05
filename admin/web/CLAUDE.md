# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Project state

GrokDog is a fresh `create-next-app` scaffold: `src/app/page.tsx` is still the template home page and `layout.tsx` still has the default metadata. There is no test framework, no backend and no data layer yet. Git is local only: work goes on the `design` branch, with no remote and no push.

## Commands

```bash
npm run dev     # dev server on http://localhost:3000 (Turbopack)
npm run build   # production build; also the main type/route check
npm run start   # serve the production build
npm run lint    # ESLint 9 flat config (next core-web-vitals + typescript)
npx tsc --noEmit  # type-check without building
npm run commenti  # Commenta server on 127.0.0.1:4747 (run next to `npm run dev`)
```

No test runner is configured. If you add tests, add the script to `package.json` and update this file.

## Comments (Commenta)

In `npm run dev` the root layout loads `http://127.0.0.1:4747/commenta.js` (the comment tool from Pocket Editor, installed
in `~/.commenta`). With `npm run commenti` running, the user's comments go to `comments/app.json` + `comments/shots/`.
«sistema i commenti» → follow the `commenti` skill. Never delete comments or shots.

## Stack and the non-obvious parts

- **Next.js 16.4.5 + React 19.3, App Router under `src/app/`.** As AGENTS.md says, this Next version postdates most training data. Read the guides in `node_modules/next/dist/docs/` (`01-app/` for App Router) before using any Next API.
- **`next.config.ts` turns on `cacheComponents` and `partialPrefetching`.** With Cache Components, dynamic data access and caching (`"use cache"`, `<Suspense>` boundaries around dynamic content) work differently from older Next caching. Check the docs before fetching data or reading request APIs in components.
- **Tailwind CSS v4 runs through the `@tailwindcss/turbopack` loader** (a Turbopack rule for `*.css` in `next.config.ts`), not PostCSS. There is no `postcss.config` or `tailwind.config`. The app is dark-only. Its colors are `@theme inline` tokens in `src/app/globals.css`, taken from the Grok Bot interface: `app`/`side`/`panel`/`hover`/`active`/`line` for surfaces, `ink`/`muted`/`faint` for text, `accent` (orange), `user` (blue avatar), `ok` (connected/battery). Use these tokens (`bg-panel`, `text-muted`, …), not raw hex. The one exception is `FloorMap3D.tsx`, where Three.js needs literal colors and they must be kept in sync by hand.
- **Typed route helpers:** layouts and pages use the global `LayoutProps<"/">` / `PageProps<...>` types, which Next generates into `.next/types` when it runs `dev` or `build`.
- Import alias: `@/*` → `src/*`.
- Icons: `lucide-react`.
