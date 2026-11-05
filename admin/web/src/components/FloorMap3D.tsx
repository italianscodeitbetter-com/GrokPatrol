"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { CSS2DObject, CSS2DRenderer } from "three/addons/renderers/CSS2DRenderer.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Crosshair,
  Footprints,
  Maximize2,
  MapPin,
  RotateCcw,
  RotateCw,
  Search,
  Video,
  X,
} from "lucide-react";
import { CameraFeed } from "@/components/CameraFeed";
import { DogView, type DogInfo, type DogStatus, type Move } from "@/components/DogView";
import { BotsRow, NotificationsBell, ShiftClock, useNow } from "@/components/MapBar";
import { BatteryTag, batteryTone } from "@/components/robot";
import { Badge } from "@/components/ui";
import { PLAN_FLOOR, PLAN_H, PLAN_OBJECTS, PLAN_W, PLAN_WALLS, type PlanObject } from "@/lib/floorplan";
import { command, sendDrive, useLive, type Limits, type Live } from "@/lib/backend";
import { HOME_HEADING, HOME_PLAN, siteToPlan, yawToHeading, type PlanXY } from "@/lib/coords";
import { dogName, offlineDogs, patrolPoints, roomName, rooms } from "@/lib/mock";
import { roomAt, useConsoleEvents } from "@/lib/events";
import { patrolPointsOf, type PatrolPoint } from "@/lib/automations-live";

const ACTIVE = new Set(["in_valutazione", "in_coda", "missione", "verifica"]);
const WALL_H = 2.4; // m: un po' più bassi del vero (3 m), così dall'alto si vede dentro le sale

// cane robot (m): busto, zampe a due segmenti con il ginocchio all'indietro
const BODY_Y = 0.4; // altezza del busto da terra
const HIP_Y = -0.04; // anche, rispetto al busto
const THIGH = 0.21;
const SHIN = 0.21;
const FOOT_R = 0.028;
const GAIT_T = 0.42; // s per ciclo di trotto
const LIFT = 0.07; // quanto alza la zampa in volo
const FOLLOW_DIST = 4.5; // m: distanza della camera quando segue un cane

const DOG_R = 24; // cm: ingombro del cane contro i muri
const CHAIR = 0.45; // m: fascia delle sedie intorno al piano del tavolo (dentro il rettangolo del tavolo)

/** IK a due segmenti nel piano della zampa: angoli (da verticale, + in avanti) di coscia e ginocchio. */
function legIK(dx: number, dy: number): [number, number] {
  const d = Math.min(Math.hypot(dx, dy), THIGH + SHIN - 1e-3);
  const a = Math.atan2(dx, -dy);
  const b = Math.acos((THIGH * THIGH + d * d - SHIN * SHIN) / (2 * THIGH * d));
  const g = Math.acos((THIGH * THIGH + SHIN * SHIN - d * d) / (2 * THIGH * SHIN));
  return [a - b, Math.PI - g];
}

const wrapAngle = (a: number) => Math.atan2(Math.sin(a), Math.cos(a));

// ── geometria ─────────────────────────────────────────
type Loop = { x: number; y: number }[];

/** "M x yL x y…Z" (cm) → anelli chiusi. */
function parseLoops(d: string): Loop[] {
  return d
    .split("Z")
    .filter((s) => s.trim())
    .map((s) =>
      s
        .replace("M", "")
        .split("L")
        .map((p) => {
          const [x, y] = p.trim().split(/\s+/).map(Number);
          return { x, y };
        }),
    );
}

const area = (l: Loop) => Math.abs(l.reduce((s, p, i) => s + p.x * l[(i + 1) % l.length].y - l[(i + 1) % l.length].x * p.y, 0)) / 2;

function inside(p: { x: number; y: number }, l: Loop) {
  let c = false;
  for (let i = 0, j = l.length - 1; i < l.length; j = i++) {
    const a = l[i],
      b = l[j];
    if (a.y > p.y !== b.y > p.y && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) c = !c;
  }
  return c;
}

/** Pianta (cm, y in giù) → mondo (m, centrato; x a destra, z verso chi guarda). */
const wx = (x: number) => x / 100 - PLAN_W / 200;
const wz = (y: number) => y / 100 - PLAN_H / 200;

/** Anelli con fill-rule evenodd → THREE.Shape con i buchi al posto giusto. */
function toShapes(loops: Loop[]) {
  const sorted = [...loops].sort((a, b) => area(b) - area(a));
  const parent = sorted.map((l, i) => {
    for (let j = i - 1; j >= 0; j--) if (inside(l[0], sorted[j])) return j;
    return -1;
  });
  const depth = (i: number): number => (parent[i] < 0 ? 0 : 1 + depth(parent[i]));
  const shapes = new Map<number, THREE.Shape>();
  // la forma 2D usa (x, -z): ruotata di -90° su X, l'estrusione va verso l'alto
  const pts = (l: Loop) => l.map((p) => new THREE.Vector2(wx(p.x), -wz(p.y)));
  sorted.forEach((l, i) => {
    if (depth(i) % 2 === 0) shapes.set(i, new THREE.Shape(pts(l)));
    else shapes.get(parent[i])?.holes.push(new THREE.Path(pts(l)));
  });
  return [...shapes.values()];
}

// muri (cm, coordinate della pianta) per gli urti quando il cane è guidato a mano
const WALL_LOOPS = parseLoops(PLAN_WALLS).map((l) => ({
  l,
  x0: Math.min(...l.map((p) => p.x)),
  x1: Math.max(...l.map((p) => p.x)),
  y0: Math.min(...l.map((p) => p.y)),
  y1: Math.max(...l.map((p) => p.y)),
}));

/** Nel muro (regola evenodd) o fuori dalla pianta. */
function solid(x: number, y: number) {
  if (x < 0 || y < 0 || x > PLAN_W || y > PLAN_H) return true;
  let n = 0;
  for (const w of WALL_LOOPS) if (x >= w.x0 && x <= w.x1 && y >= w.y0 && y <= w.y1 && inside({ x, y }, w.l)) n++;
  return n % 2 === 1;
}

/** Il cane, con il suo ingombro, tocca un muro o un oggetto (tavoli, auto, scala)? */
function blocked(x: number, y: number) {
  for (const o of PLAN_OBJECTS)
    if (x > o.x - DOG_R && x < o.x + o.w + DOG_R && y > o.y - DOG_R && y < o.y + o.h + DOG_R) return true;
  if (solid(x, y)) return true;
  for (let i = 0; i < 8; i++) {
    const a = (i * Math.PI) / 4;
    if (solid(x + DOG_R * Math.cos(a), y + DOG_R * Math.sin(a))) return true;
  }
  return false;
}

export type PlanPoint = { x: number; y: number };

/** Il cane può stare in questo punto (cm sulla pianta)? */
export const isFree = (p: PlanPoint) => !blocked(p.x, p.y);

/** Il tratto in linea retta da a a b passa senza toccare muri o oggetti? */
export function segmentClear(a: PlanPoint, b: PlanPoint) {
  const n = Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / 10);
  for (let i = 0; i <= n; i++) if (blocked(a.x + ((b.x - a.x) * i) / n, a.y + ((b.y - a.y) * i) / n)) return false;
  return true;
}

function label(html: string, className: string) {
  const el = document.createElement("div");
  el.className = className;
  el.innerHTML = html;
  return new CSS2DObject(el);
}

// ── arredi ────────────────────────────────────────────
type Keep = <T extends { dispose: () => void }>(x: T) => T;

/** Costruisce un oggetto della pianta. Nel suo gruppo il davanti (muso / verso di salita) è +x, il centro è l'origine. */
function buildObject(o: PlanObject, keep: Keep, mats: Record<"body" | "steel" | "black" | "glass", THREE.Material>) {
  const g = new THREE.Group();
  const along = o.facing === "n" || o.facing === "s";
  const L = (along ? o.h : o.w) / 100; // lunghezza nel verso del muso
  const W = (along ? o.w : o.h) / 100;
  const box = (w: number, h: number, d: number, mat: THREE.Material, x: number, y: number, z: number) => {
    const m = new THREE.Mesh(keep(new THREE.BoxGeometry(w, h, d)), mat);
    m.position.set(x, y, z);
    g.add(m);
    return m;
  };
  const rbox = (w: number, h: number, d: number, r: number, mat: THREE.Material, x: number, y: number, z: number) => {
    const m = new THREE.Mesh(keep(new RoundedBoxGeometry(w, h, d, 3, r)), mat);
    m.position.set(x, y, z);
    g.add(m);
    return m;
  };
  const wheel = (r: number, width: number, x: number, z: number) => {
    const tyre = new THREE.Mesh(keep(new THREE.CylinderGeometry(r, r, width, 28).rotateX(Math.PI / 2)), mats.black);
    tyre.position.set(x, r, z);
    const rim = new THREE.Mesh(keep(new THREE.CylinderGeometry(r * 0.6, r * 0.6, width + 0.01, 20).rotateX(Math.PI / 2)), mats.steel);
    rim.position.copy(tyre.position);
    g.add(tyre, rim);
  };

  if (o.kind === "tavolo") {
    // il rettangolo è tavolo + sedie: piano a 75 cm rientrato di CHAIR per lato, sedie tutto intorno
    const lx = o.w / 100 - 2 * CHAIR,
      lz = o.h / 100 - 2 * CHAIR;
    box(lx, 0.05, lz, mats.body, 0, 0.75, 0);
    for (const sx of [-1, 1])
      for (const sz of [-1, 1]) box(0.05, 0.73, 0.05, mats.black, sx * (lx / 2 - 0.1), 0.365, sz * (lz / 2 - 0.1));
    // sedia con lo schienale verso l'esterno: (x, z) = centro della seduta, (nx, nz) = verso l'esterno
    const chair = (x: number, z: number, nx: number, nz: number) => {
      const c = new THREE.Group();
      const seat = 0.42;
      const add = (w: number, h: number, d: number, mat: THREE.Material, px: number, py: number, pz: number) => {
        const m = new THREE.Mesh(keep(new THREE.BoxGeometry(w, h, d)), mat);
        m.position.set(px, py, pz);
        c.add(m);
      };
      add(seat, 0.04, seat, mats.body, 0, 0.45, 0);
      for (const a of [-1, 1]) for (const b of [-1, 1]) add(0.03, 0.43, 0.03, mats.black, a * 0.18, 0.215, b * 0.18);
      add(0.03, 0.42, seat, mats.body, seat / 2 - 0.015, 0.68, 0); // schienale (lato +x del gruppo)
      c.position.set(x, 0, z);
      c.rotation.y = Math.atan2(-nz, nx);
      g.add(c);
    };
    const off = 0.24; // dal bordo del piano al centro della seduta
    const row = (len: number) => Math.max(1, Math.floor(len / 0.6));
    for (const s of [-1, 1]) {
      const nx = row(lx);
      for (let i = 0; i < nx; i++) chair(-lx / 2 + (lx * (i + 0.5)) / nx, s * (lz / 2 + off), 0, s);
      if (lz >= 0.9) {
        const nz = row(lz) > 1 ? 2 : 1;
        for (let i = 0; i < nz; i++) chair(s * (lx / 2 + off), -lz / 2 + (lz * (i + 0.5)) / nz, s, 0);
      }
    }
  } else if (o.kind === "f1") {
    // monoposto: ruote scoperte, alettoni. Tutta grigia, come gli altri arredi: i colori distraggono dalla mappa
    const white = mats.body,
      blue = mats.body,
      red = mats.body;
    const w = Math.min(W, 2);
    const half = w / 2 - 0.22;
    box(L * 0.8, 0.05, w * 0.55, mats.black, -0.02 * L, 0.06, 0); // fondo
    rbox(L * 0.42, 0.42, 0.62, 0.1, white, -0.08 * L, 0.36, 0); // scocca
    rbox(L * 0.3, 0.22, 0.3, 0.08, white, 0.27 * L, 0.27, 0); // muso
    box(L * 0.68, 0.02, 0.14, blue, 0.04 * L, 0.585, 0); // riga blu sopra
    for (const sz of [-1, 1]) rbox(L * 0.26, 0.36, 0.34, 0.1, red, -0.08 * L, 0.3, sz * 0.46); // pance
    const airbox = new THREE.Mesh(keep(new THREE.CylinderGeometry(0.13, 0.16, 0.3, 20)), white);
    airbox.position.set(-0.17 * L, 0.72, 0);
    g.add(airbox);
    box(0.06, 0.14, 0.5, blue, 0.02 * L, 0.68, 0); // halo
    wheel(0.33, 0.36, 0.3 * L, half);
    wheel(0.33, 0.36, 0.3 * L, -half);
    wheel(0.34, 0.44, -0.33 * L, half);
    wheel(0.34, 0.44, -0.33 * L, -half);
    box(0.36, 0.04, w * 0.95, mats.black, 0.45 * L, 0.08, 0); // alettone anteriore
    for (const sz of [-1, 1]) box(0.3, 0.12, 0.02, white, 0.45 * L, 0.14, sz * w * 0.47);
    box(0.3, 0.05, 0.95, red, -0.45 * L, 0.95, 0); // alettone posteriore
    for (const sz of [-1, 1]) box(0.32, 0.36, 0.02, red, -0.45 * L, 0.8, sz * 0.475);
  } else if (o.kind === "auto") {
    // coupé sportiva con alettone; grigia come gli altri arredi
    const l = L * 0.92,
      w = Math.min(W, 1.85);
    const front = mats.body;
    const back = mats.body;
    rbox(l * 0.5, 0.62, w, 0.16, front, l * 0.25, 0.52, 0);
    rbox(l * 0.5, 0.62, w, 0.16, back, -l * 0.25, 0.52, 0);
    rbox(l * 0.45, 0.48, w * 0.84, 0.16, mats.glass, -l * 0.06, 1.0, 0); // abitacolo
    box(l * 0.28, 0.03, w * 0.7, back, -l * 0.08, 1.25, 0); // tetto
    for (const sx of [-1, 1]) for (const sz of [-1, 1]) wheel(0.33, 0.26, sx * l * 0.32, sz * (w / 2 - 0.1));
    box(0.32, 0.03, w * 0.98, mats.black, -l * 0.46, 1.3, 0); // alettone
    for (const sz of [-1, 1]) box(0.06, 0.45, 0.04, mats.black, -l * 0.44, 1.07, sz * 0.5);
    for (const sz of [-1, 1]) box(0.02, 0.08, 0.32, mats.steel, l * 0.5, 0.6, sz * (w / 2 - 0.25)); // fari
  } else if (o.kind === "scala") {
    // scala in ferro a giorno: gradini sospesi su due cosciali, ringhiera dal lato aperto
    const steps = 14;
    const H = WALL_H; // sale fino al solaio del piano di sopra
    const run = L / steps;
    for (let i = 0; i < steps; i++) box(run * 1.05, 0.04, W, mats.steel, -L / 2 + run * (i + 0.5), ((i + 1) * H) / steps, 0);
    const slope = Math.atan2(H, L);
    const len = Math.hypot(L, H);
    for (const sz of [-1, 1]) {
      const m = box(len, 0.22, 0.05, mats.steel, 0, H / 2, sz * (W / 2 + 0.025));
      m.rotation.z = slope;
    }
    // corrimano e montanti sul lato verso la sala
    const rail = box(len, 0.05, 0.05, mats.steel, 0, H / 2 + 0.95, -(W / 2 + 0.05));
    rail.rotation.z = slope;
    for (let i = 0; i <= 6; i++) {
      const x = -L / 2 + (L * i) / 6;
      const y = (H * i) / 6;
      box(0.03, 0.95, 0.03, mats.steel, x, y + 0.475, -(W / 2 + 0.05));
    }
    box(0.12, H + 0.6, 0.12, mats.steel, -L / 2 + 0.06, (H + 0.6) / 2, -(W / 2 + 0.1)); // trave di sostegno
  }

  g.traverse((m) => (m.castShadow = m.receiveShadow = true));
  g.position.set(wx(o.x + o.w / 2), 0, wz(o.y + o.h / 2));
  g.rotation.y = { e: 0, s: -Math.PI / 2, w: Math.PI, n: Math.PI / 2 }[o.facing ?? "e"];
  return g;
}

type View = { kind: "dog" | "camera"; id: string; control?: boolean };
/** Comandi della camera della mappa (pulsanti tondi in basso a destra), tenuti premuti. */
type Nav = "left" | "right" | "up" | "down" | "rot-l" | "rot-r";
const NAV_PAN = 6; // m/s di spostamento
const NAV_ROT = 1.2; // rad/s di rotazione
/** Il cane guidato a mano e i comandi tenuti premuti. */
type Drive = { dogId: string; held: ReadonlySet<Move> };
/** Quello che la scena legge a ogni fotogramma: il cane live (posa già sulla pianta, cm e heading). */
type SceneDog = {
  id: string;
  name: string;
  battery: number | null;
  connected: boolean;
  pose: (PlanXY & { heading: number }) | null;
  /** I punti che restano della missione in corso (cm), per la linea verde del percorso. */
  path: PlanXY[];
};
/** Una telecamera del sito, sulla pianta (cm), con il punto verso cui guarda. */
type SceneCam = { id: string; label: string; x: number; y: number; aim: PlanXY; online: boolean };
/** Dove disegnare la telecamera di bordo di un cane. cover = a tutto schermo (la mappa è coperta, non serve disegnarla). */
type Pov = { dogId: string; el: HTMLElement; cover: boolean };
/** Dove disegnare la ripresa di una telecamera fissa. */
type CamPov = { camId: string; el: HTMLElement };
/** Un evento attivo da segnare sulla pianta (cm). */
type ScenePin = { id: string; x: number; y: number; anomaly: string; high: boolean };

// ── scena ─────────────────────────────────────────────
function useScene(
  host: React.RefObject<HTMLDivElement | null>,
  onCamera: (id: string) => void,
  onDog: (id: string) => void,
  following: string | null,
  resetRef: React.RefObject<(() => void) | null>,
  liveRef: React.RefObject<SceneDog>,
  camsRef: React.RefObject<((cams: SceneCam[]) => void) | null>,
  povRef: React.RefObject<Pov | null>,
  camPovRef: React.RefObject<CamPov | null>,
  focusRef: React.RefObject<((roomId: string | null) => void) | null>,
  pickRef: React.RefObject<((p: PlanPoint | null) => void) | null>,
  routeRef: React.RefObject<((pts: PlanPoint[], loop: boolean) => void) | null>,
  navRef: React.RefObject<((held: Nav | null) => void) | null>,
) {
  const onCameraRef = useRef(onCamera);
  const onDogRef = useRef(onDog);
  const followRef = useRef(following);
  const zoomRef = useRef<number | null>(null);
  // eventi attivi (veri col backend online, di mock offline): la scena ridisegna i segnaposto quando cambiano
  const pinsRef = useRef<((pins: ScenePin[]) => void) | null>(null);
  // punti della ronda: dal sito del backend (la ronda in corso o il primo percorso), di mock.ts finché non c'è il sito
  const patrolRef = useRef<((pts: PatrolPoint[]) => void) | null>(null);
  const { site, current } = useLive();
  const patrolKey = JSON.stringify(patrolPointsOf({ site, current }) ?? patrolPoints);
  const { events } = useConsoleEvents();
  const pinsKey = JSON.stringify(
    events
      .filter((e) => ACTIVE.has(e.status) && e.x != null && e.y != null)
      .map((e): ScenePin => ({ id: e.id, x: e.x!, y: e.y!, anomaly: e.anomaly, high: e.priority === "alta" })),
  );
  useEffect(() => {
    onCameraRef.current = onCamera;
    onDogRef.current = onDog;
  });
  useEffect(() => {
    followRef.current = following;
    // quando si inizia a seguire un cane, la camera gli si avvicina
    zoomRef.current = following ? FOLLOW_DIST : null;
  }, [following]);

  useEffect(() => {
    const el = host.current;
    if (!el) return;
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    // creando un'automazione si clicca solo il pavimento: etichette di cani e telecamere non si selezionano,
    // e non si vedono i cani che si muovono, la loro ronda e gli eventi (solo la mappa)
    const picking = !!pickRef.current;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color("#121212");
    scene.fog = new THREE.Fog("#121212", 45, 90);

    const camera = new THREE.PerspectiveCamera(35, 1, 0.1, 200);
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    el.appendChild(renderer.domElement);

    const labels = new CSS2DRenderer();
    labels.domElement.style.position = "absolute";
    labels.domElement.style.inset = "0";
    labels.domElement.style.pointerEvents = "none";
    // CSS2DRenderer dà uno z-index a ogni etichetta: così restano chiuse qui e non passano sopra le card
    labels.domElement.style.zIndex = "0";
    el.appendChild(labels.domElement);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.maxPolarAngle = 1.2;
    controls.minDistance = 2;
    controls.maxDistance = 70;
    // se l'utente zooma mentre la camera si avvicina, vince lui
    controls.addEventListener("start", () => (zoomRef.current = null));

    // luci
    scene.add(new THREE.HemisphereLight("#ffffff", "#202020", 1.6));
    const sun = new THREE.DirectionalLight("#ffffff", 1.4);
    sun.position.set(-10, 25, 12);
    sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048);
    Object.assign(sun.shadow.camera, { left: -14, right: 14, top: 14, bottom: -14, near: 1, far: 60 });
    sun.shadow.bias = -0.0005;
    scene.add(sun);

    const disposables: { dispose: () => void }[] = [];
    const keep = <T extends { dispose: () => void }>(x: T) => (disposables.push(x), x);

    // pavimento e muri dal file STEP
    const floorGeo = keep(new THREE.ShapeGeometry(toShapes(parseLoops(PLAN_FLOOR))));
    floorGeo.rotateX(-Math.PI / 2);
    const floor = new THREE.Mesh(floorGeo, keep(new THREE.MeshStandardMaterial({ color: "#262626", roughness: 1 })));
    floor.receiveShadow = true;
    scene.add(floor);

    const wallGeo = keep(new THREE.ExtrudeGeometry(toShapes(parseLoops(PLAN_WALLS)), { depth: WALL_H, bevelEnabled: false }));
    wallGeo.rotateX(-Math.PI / 2);
    const walls = new THREE.Mesh(wallGeo, keep(new THREE.MeshStandardMaterial({ color: "#5c5c5c", roughness: 0.85 })));
    walls.castShadow = walls.receiveShadow = true;
    scene.add(walls);
    scene.add(new THREE.LineSegments(keep(new THREE.EdgesGeometry(wallGeo, 30)), keep(new THREE.LineBasicMaterial({ color: "#7a7a7a" }))));

    // arredi: tavoli con sedie, auto e scala (dalla pianta annotata). Solo grigi, niente colori: l'attenzione va a cani ed eventi
    const objMats = {
      body: keep(new THREE.MeshStandardMaterial({ color: "#5a5a5a", roughness: 0.75 })),
      steel: keep(new THREE.MeshStandardMaterial({ color: "#6e6e6e", roughness: 0.55, metalness: 0.4 })),
      black: keep(new THREE.MeshStandardMaterial({ color: "#333333", roughness: 0.8 })),
      glass: keep(new THREE.MeshStandardMaterial({ color: "#2a2a2a", roughness: 0.2, metalness: 0.5 })),
    };
    for (const o of PLAN_OBJECTS) scene.add(buildObject(o, keep, objMats));

    // sale
    for (const r of rooms) {
      const l = label(r.name, "text-sm text-faint whitespace-nowrap select-none");
      l.position.set(wx(r.x + r.w / 2), 0.05, wz(r.y + 80));
      l.center.set(0.5, 0.5);
      scene.add(l);
    }

    // ronda: i punti e il giro dal sito del backend (patrolPointsOf), di mock.ts offline; si ridisegnano quando cambiano
    const accent = new THREE.Color("#e99a3c"); // = --color-accent
    const patrolGroup = new THREE.Group();
    scene.add(patrolGroup);
    const routeMat = keep(new THREE.LineDashedMaterial({ color: accent, dashSize: 0.25, gapSize: 0.25, transparent: true, opacity: 0.6 }));
    const ringGeo = keep(new THREE.RingGeometry(0.16, 0.22, 32).rotateX(-Math.PI / 2));
    const ringMat = keep(new THREE.MeshBasicMaterial({ color: accent, transparent: true, opacity: 0.8 }));
    patrolRef.current = (pts) => {
      patrolGroup.children.forEach((c) => {
        if (c instanceof THREE.Line) c.geometry.dispose();
        if (c instanceof CSS2DObject) c.element.remove();
      });
      patrolGroup.clear();
      if (picking || !pts.length) return;
      if (pts.length > 1) {
        const route = [...pts, pts[0]].map((p) => new THREE.Vector3(wx(p.x), 0.03, wz(p.y)));
        const routeLine = new THREE.Line(new THREE.BufferGeometry().setFromPoints(route), routeMat);
        routeLine.computeLineDistances();
        patrolGroup.add(routeLine);
      }
      for (const p of pts) {
        const m = new THREE.Mesh(ringGeo, ringMat);
        m.position.set(wx(p.x), 0.03, wz(p.y));
        patrolGroup.add(m);
        const l = label(p.label, "text-sm text-muted select-none");
        l.position.set(wx(p.x) + 0.35, 0.05, wz(p.y));
        l.center.set(0, 0.5);
        patrolGroup.add(l);
      }
    };

    // camere: telecamera «bullet» appesa al soffitto, puntata verso il centro della sua stanza, col cono di ripresa.
    // Cliccabili: l'etichetta apre la vista della camera.
    const camShell = keep(new THREE.MeshStandardMaterial({ color: "#e6e6e6", roughness: 0.35, metalness: 0.2 }));
    const camDark = keep(new THREE.MeshStandardMaterial({ color: "#2a2a2a", roughness: 0.5, metalness: 0.5 }));
    const camLens = keep(new THREE.MeshStandardMaterial({ color: "#0a0c10", roughness: 0.05, metalness: 0.9 }));
    const camLed = keep(new THREE.MeshStandardMaterial({ color: "#f87171", emissive: "#f87171", emissiveIntensity: 1.2 }));
    const coneMat = keep(
      new THREE.MeshBasicMaterial({ color: "#9ecbff", transparent: true, opacity: 0.07, side: THREE.DoubleSide, depthWrite: false }),
    );
    const stemGeo = keep(new THREE.CylinderGeometry(0.025, 0.025, 0.22, 12));
    const baseGeo = keep(new THREE.CylinderGeometry(0.07, 0.07, 0.03, 20));
    const jointGeo = keep(new THREE.SphereGeometry(0.04, 16, 12));
    const bodyGeo = keep(new THREE.CylinderGeometry(0.065, 0.065, 0.3, 20).rotateZ(Math.PI / 2));
    const hoodGeo = keep(new THREE.BoxGeometry(0.38, 0.015, 0.17));
    const lensGeo = keep(new THREE.CylinderGeometry(0.05, 0.05, 0.02, 20).rotateZ(Math.PI / 2));
    const ledGeo = keep(new THREE.SphereGeometry(0.008, 8, 6));
    const fovGeo = keep(new THREE.ConeGeometry(1.5, 4, 32, 1, true).rotateZ(Math.PI / 2).translate(2, 0, 0));
    const ledOff = keep(new THREE.MeshStandardMaterial({ color: "#4a4a4a", roughness: 0.6 }));
    // dove sta l'obiettivo e dove guarda: serve per la ripresa simulata (sotto l'anteprima live della camera)
    const camPoses = new Map<string, { rig: THREE.Group; eye: THREE.Vector3; look: THREE.Vector3 }>();
    // le camere arrivano dal backend (site.cameras, posizioni in metri già convertite): si ridisegnano quando cambiano
    const camGroup = new THREE.Group();
    scene.add(camGroup);
    camsRef.current = (list) => {
      camGroup.traverse((o) => o instanceof CSS2DObject && o.element.remove());
      camGroup.clear();
      camPoses.clear();
      for (const c of list) {
        const rig = new THREE.Group();
        rig.position.set(wx(c.x), WALL_H, wz(c.y));
        rig.rotation.y = -Math.atan2(c.aim.y - c.y, c.aim.x - c.x); // +x locale verso dove guarda la camera
        const base = new THREE.Mesh(baseGeo, camDark);
        base.position.y = -0.015;
        const stem = new THREE.Mesh(stemGeo, camDark);
        stem.position.y = -0.13;
        const joint = new THREE.Mesh(jointGeo, camDark);
        joint.position.y = -0.24;
        const head = new THREE.Group(); // inclinata verso il basso
        head.position.y = -0.27;
        head.rotation.z = -0.5;
        const body = new THREE.Mesh(bodyGeo, camShell);
        body.position.x = 0.1;
        const hood = new THREE.Mesh(hoodGeo, camShell);
        hood.position.set(0.13, 0.075, 0);
        const lens = new THREE.Mesh(lensGeo, camLens);
        lens.position.x = 0.255;
        const led = new THREE.Mesh(ledGeo, c.online ? camLed : ledOff);
        led.position.set(0.262, -0.045, 0.035);
        const fov = new THREE.Mesh(fovGeo, coneMat);
        fov.position.x = 0.265;
        fov.visible = c.online;
        head.add(body, hood, lens, led, fov);
        rig.add(base, stem, joint, head);
        rig.traverse((m) => m !== fov && (m.castShadow = true));
        camGroup.add(rig);
        rig.updateMatrixWorld(true);
        camPoses.set(c.id, { rig, eye: head.localToWorld(new THREE.Vector3(0.28, 0, 0)), look: head.localToWorld(new THREE.Vector3(5, 0, 0)) });
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = `${picking ? "pointer-events-none" : "pointer-events-auto hover:bg-hover"} flex select-none items-center gap-1.5 rounded-lg border border-line bg-app/90 px-2 py-1 text-sm ${
          c.online ? "text-ink" : "text-faint"
        }`;
        btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5"/><rect x="2" y="6" width="14" height="12" rx="2"/></svg>${c.label}`;
        btn.setAttribute("aria-label", `Open ${c.label}${c.online ? "" : " (offline)"}`);
        btn.addEventListener("click", () => onCameraRef.current(c.id));
        btn.addEventListener("pointerdown", (e) => e.stopPropagation());
        const l = new CSS2DObject(btn);
        l.position.set(wx(c.x), WALL_H + 0.1, wz(c.y));
        l.center.set(0.5, 1);
        camGroup.add(l);
      }
    };

    // eventi attivi = waypoint: segnaposto che fluttua sopra il punto, raggio verso terra, bersaglio a terra che pulsa
    // e un'etichetta con cosa è successo. Rosso alta priorità, ambra il resto.
    const pings: THREE.Mesh[] = [];
    const pins: THREE.Group[] = [];
    const pinHeadGeo = keep(new THREE.SphereGeometry(0.2, 28, 20));
    const pinTipGeo = keep(new THREE.ConeGeometry(0.17, 0.42, 28).rotateX(Math.PI).translate(0, -0.25, 0));
    const pinDotGeo = keep(new THREE.SphereGeometry(0.085, 20, 14));
    const beamGeo = keep(new THREE.CylinderGeometry(0.012, 0.012, 1, 8).translate(0, 0.5, 0));
    const targetGeo = keep(new THREE.RingGeometry(0.22, 0.3, 40).rotateX(-Math.PI / 2));
    const discGeo = keep(new THREE.CircleGeometry(0.12, 32).rotateX(-Math.PI / 2));
    const pingGeo = keep(new THREE.RingGeometry(0.3, 0.38, 48).rotateX(-Math.PI / 2));
    const whiteMat = keep(new THREE.MeshBasicMaterial({ color: "#ffffff" }));
    const pinGroup = new THREE.Group();
    scene.add(pinGroup);
    let pinMats: THREE.Material[] = [];
    const pinMat = <T extends THREE.Material>(m: T) => (pinMats.push(m), m);
    pinsRef.current = (list) => {
      pinGroup.traverse((o) => o instanceof CSS2DObject && o.element.remove());
      pinGroup.clear();
      pinMats.forEach((m) => m.dispose());
      pinMats = [];
      pins.length = 0;
      pings.length = 0;
      for (const e of picking ? [] : list) addPin(e);
    };
    const addPin = (e: ScenePin) => {
      const color = e.high ? "#f87171" : "#fcd34d";
      const solidMat = pinMat(new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.7, roughness: 0.35 }));
      const flatMat = pinMat(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.85 }));
      const x = wx(e.x),
        z = wz(e.y);
      const pin = new THREE.Group();
      pin.position.set(x, 1.35, z);
      const dot = new THREE.Mesh(pinDotGeo, whiteMat);
      const head = new THREE.Mesh(pinHeadGeo, solidMat);
      pin.add(head, new THREE.Mesh(pinTipGeo, solidMat));
      // il pallino bianco «buca» la testa: lo mettiamo davanti, verso la camera, nel tick
      pin.add(dot);
      pin.traverse((m) => (m.castShadow = true));
      pin.userData.dot = dot;
      pinGroup.add(pin);
      pins.push(pin);
      const beam = new THREE.Mesh(beamGeo, pinMat(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.45 })));
      beam.position.set(x, 0, z);
      beam.scale.y = 0.95;
      pinGroup.add(beam);
      const target = new THREE.Mesh(targetGeo, flatMat);
      target.position.set(x, 0.03, z);
      const disc = new THREE.Mesh(discGeo, flatMat);
      disc.position.set(x, 0.031, z);
      pinGroup.add(target, disc);
      for (const delay of [0, 0.5]) {
        const ping = new THREE.Mesh(pingGeo, pinMat(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.6 })));
        ping.position.set(x, 0.03, z);
        ping.userData.delay = delay;
        pinGroup.add(ping);
        pings.push(ping);
      }
      const tag = document.createElement("div");
      tag.className = "flex items-center gap-1.5 whitespace-nowrap rounded-md border bg-app/90 px-1.5 py-0.5 text-sm text-ink select-none";
      tag.style.borderColor = color;
      const idEl = document.createElement("span");
      idEl.className = "font-mono";
      idEl.style.color = color;
      idEl.textContent = e.id;
      const what = document.createElement("span");
      what.textContent = e.anomaly;
      tag.append(idEl, what);
      const l = new CSS2DObject(tag);
      l.position.set(0, 0.32, 0);
      l.center.set(0.5, 1);
      pin.add(l);
    };

    // cani: robot a quattro zampe; ogni zampa ha anca, coscia, ginocchio, stinco e piede
    const shellMat = keep(new THREE.MeshStandardMaterial({ color: "#e8e8e8", roughness: 0.45, metalness: 0.1 }));
    const darkMat = keep(new THREE.MeshStandardMaterial({ color: "#2b2b2b", roughness: 0.6, metalness: 0.3 }));
    const glassMat = keep(new THREE.MeshStandardMaterial({ color: "#0d0d0d", roughness: 0.15, metalness: 0.6 }));
    const accentMat = keep(new THREE.MeshStandardMaterial({ color: accent, emissive: accent, emissiveIntensity: 0.9 }));
    const torsoGeo = keep(new RoundedBoxGeometry(0.6, 0.15, 0.26, 3, 0.045));
    const bellyGeo = keep(new RoundedBoxGeometry(0.46, 0.05, 0.2, 2, 0.02));
    const stripeGeo = keep(new THREE.BoxGeometry(0.36, 0.012, 0.262));
    const headGeo = keep(new RoundedBoxGeometry(0.15, 0.11, 0.2, 3, 0.035));
    const visorGeo = keep(new RoundedBoxGeometry(0.03, 0.07, 0.17, 2, 0.012));
    const eyeGeo = keep(new THREE.BoxGeometry(0.012, 0.014, 0.12));
    const lidarGeo = keep(new THREE.CylinderGeometry(0.04, 0.045, 0.045, 24));
    const lidarRingGeo = keep(new THREE.CylinderGeometry(0.041, 0.041, 0.01, 24));
    const lidarDotGeo = keep(new THREE.BoxGeometry(0.012, 0.012, 0.012));
    const motorGeo = keep(new THREE.CylinderGeometry(0.048, 0.048, 0.07, 20).rotateX(Math.PI / 2));
    const thighGeo = keep(new THREE.CapsuleGeometry(0.034, THIGH - 0.04, 4, 12));
    const kneeGeo = keep(new THREE.SphereGeometry(0.03, 16, 12));
    const shinGeo = keep(new THREE.CapsuleGeometry(0.02, SHIN - 0.03, 4, 10));
    const footGeo = keep(new THREE.SphereGeometry(FOOT_R, 16, 12));
    const haloGeo = keep(new THREE.CircleGeometry(0.6, 40).rotateX(-Math.PI / 2));
    const haloMat = keep(new THREE.MeshBasicMaterial({ color: accent, transparent: true, opacity: 0.18 }));

    // trotto: le zampe in diagonale si muovono insieme (ant. sx + post. dx, poi le altre due)
    const LEGS = [
      { x: 0.22, z: 0.16, phase: 0 },
      { x: -0.22, z: -0.16, phase: 0 },
      { x: 0.22, z: -0.16, phase: 0.5 },
      { x: -0.22, z: 0.16, phase: 0.5 },
    ];

    // un solo cane: quello del backend (Unitree Go1, vero o simulato). Scegliendo i punti non si vede
    const dogObjs = (picking ? [] : [liveRef.current]).map((d) => {
      const body = new THREE.Group();
      body.position.y = BODY_Y;
      const torso = new THREE.Mesh(torsoGeo, shellMat);
      const belly = new THREE.Mesh(bellyGeo, darkMat);
      belly.position.y = -0.085;
      const stripe = new THREE.Mesh(stripeGeo, accentMat);
      stripe.position.y = 0.025;
      const head = new THREE.Mesh(headGeo, shellMat);
      head.position.set(0.32, 0.035, 0);
      const visor = new THREE.Mesh(visorGeo, glassMat);
      visor.position.set(0.395, 0.035, 0);
      const eye = new THREE.Mesh(eyeGeo, accentMat);
      eye.position.set(0.411, 0.045, 0);
      const lidar = new THREE.Group();
      lidar.position.set(0.3, 0.11, 0);
      const ring = new THREE.Mesh(lidarRingGeo, accentMat);
      ring.position.y = 0.005;
      const dot = new THREE.Mesh(lidarDotGeo, accentMat);
      dot.position.set(0.042, 0.005, 0);
      lidar.add(new THREE.Mesh(lidarGeo, darkMat), ring, dot);
      body.add(torso, belly, stripe, head, visor, eye, lidar);

      const legs = LEGS.map((spec) => {
        const hip = new THREE.Group();
        hip.position.set(spec.x, HIP_Y, spec.z);
        hip.add(new THREE.Mesh(motorGeo, darkMat));
        const thigh = new THREE.Group();
        const thighMesh = new THREE.Mesh(thighGeo, shellMat);
        thighMesh.position.y = -THIGH / 2;
        const knee = new THREE.Group();
        knee.position.y = -THIGH;
        const shin = new THREE.Mesh(shinGeo, darkMat);
        shin.position.y = -SHIN / 2;
        const foot = new THREE.Mesh(footGeo, darkMat);
        foot.position.y = -SHIN;
        knee.add(new THREE.Mesh(kneeGeo, darkMat), shin, foot);
        thigh.add(thighMesh, knee);
        hip.add(thigh);
        body.add(hip);
        return { ...spec, thigh, knee };
      });

      body.traverse((o) => (o.castShadow = true));
      const halo = new THREE.Mesh(haloGeo, haloMat);
      halo.position.y = 0.02;

      // etichetta cliccabile: segue il cane con la camera. Nome, batteria e collegamento arrivano dal backend
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `${picking ? "pointer-events-none" : "pointer-events-auto hover:bg-hover"} flex select-none items-center gap-2 rounded-md border border-line bg-app/80 px-1.5 py-0.5 text-sm text-ink whitespace-nowrap`;
      const nameEl = document.createElement("span");
      // batteria: la stessa di BatteryTag (l'icona si svuota col livello, stessi colori)
      const batt = document.createElement("span");
      batt.className = "flex items-center gap-1";
      btn.append(nameEl, batt);
      btn.addEventListener("click", () => onDogRef.current(liveRef.current.id));
      btn.addEventListener("pointerdown", (e) => e.stopPropagation());
      let shown = "";
      const setLabel = (s: SceneDog) => {
        const key = `${s.name}|${s.battery}|${s.connected}`;
        if (key === shown) return;
        shown = key;
        nameEl.textContent = s.name;
        if (!s.connected || s.battery == null) {
          batt.innerHTML = `<span class="text-faint">${s.connected ? "—" : "Offline"}</span>`;
          btn.setAttribute("aria-label", `Follow ${s.name}, ${s.connected ? "battery unknown" : "disconnected"}`);
          return;
        }
        const b = s.battery;
        const [border, fill, text] = batteryTone(b).split(" ");
        batt.innerHTML = `<span class="relative flex h-2.5 w-5 rounded-[3px] border p-px ${border}"><span class="block h-full rounded-[1px] ${fill}" style="width:${b}%"></span><span class="absolute -right-[3px] top-1/2 h-1 w-[2px] -translate-y-1/2 rounded-r-sm ${fill}"></span></span><span class="font-mono tabular-nums ${text}">${b}%</span>`;
        btn.setAttribute("aria-label", `Follow ${s.name}, battery ${b}%`);
      };
      setLabel(d);
      const l = new CSS2DObject(btn);
      l.position.y = 1.0;
      l.center.set(0.5, 1);

      const root = new THREE.Group();
      root.add(body, halo, l);
      scene.add(root);
      const start = d.pose ?? { ...HOME_PLAN, heading: HOME_HEADING };
      return {
        d,
        root,
        body,
        halo,
        legs,
        lidar,
        setLabel,
        heading: start.heading,
        phase: 0,
        pos: { x: start.x, y: start.y }, // cm sulla pianta
      };
    });

    // contorno della stanza scelta nel menu in alto
    const outlineMat = keep(new THREE.LineDashedMaterial({ color: accent, dashSize: 0.3, gapSize: 0.15 }));
    const outlines = new Map(
      rooms.map((r) => {
        const pts = [
          [r.x, r.y],
          [r.x + r.w, r.y],
          [r.x + r.w, r.y + r.h],
          [r.x, r.y + r.h],
        ].map(([x, y]) => new THREE.Vector3(wx(x), 0.04, wz(y)));
        const line = new THREE.LineLoop(keep(new THREE.BufferGeometry().setFromPoints(pts)), outlineMat);
        line.computeLineDistances();
        line.visible = false;
        scene.add(line);
        return [r.id, line] as const;
      }),
    );

    // inquadratura: tutta la pianta o una stanza, vista di tre quarti
    const viewDir = new THREE.Vector3(0.25, 1, 0.75).normalize();
    const viewFor = (roomId: string | null) => {
      const r = roomId ? rooms.find((x) => x.id === roomId) : undefined;
      const w = (r ? r.w : PLAN_W) / 100,
        h = (r ? r.h : PLAN_H) / 100;
      const target = r ? new THREE.Vector3(wx(r.x + r.w / 2), 0, wz(r.y + r.h / 2)) : new THREE.Vector3();
      const fit = Math.max(h, w / Math.max(camera.aspect, 0.6));
      const dist = Math.max((fit / 2 / Math.tan(THREE.MathUtils.degToRad(camera.fov / 2))) * (r ? 1.45 : 1.15), 8);
      return { target, pos: target.clone().addScaledVector(viewDir, dist) };
    };
    let fly: ReturnType<typeof viewFor> | null = null;
    controls.addEventListener("start", () => (fly = null));
    const reset = () => {
      const v = viewFor(null);
      camera.position.copy(v.pos);
      controls.target.copy(v.target);
      controls.update();
      fly = null;
      outlines.forEach((l) => (l.visible = false));
    };
    resetRef.current = reset;
    let nav: Nav | null = null;
    navRef.current = (held) => {
      nav = held;
      if (held) fly = null;
    };
    focusRef.current = (roomId) => {
      fly = viewFor(roomId);
      outlines.forEach((l, id) => (l.visible = id === roomId));
    };

    const resize = () => {
      const { clientWidth: w, clientHeight: h } = el;
      if (!w || !h) return;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
      labels.setSize(w, h);
    };
    const ro = new ResizeObserver(resize);
    ro.observe(el);
    resize();
    reset();

    // clic sul cane (non un trascinamento) → seguilo; sopra un cane il cursore diventa la manina
    const groundPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
    const groundHit = new THREE.Vector3();
    const ray = new THREE.Raycaster();
    const ndc = new THREE.Vector2();
    const dogBodies = dogObjs.map((o) => o.body);
    const dogAt = (e: PointerEvent) => {
      const r = renderer.domElement.getBoundingClientRect();
      ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
      ray.setFromCamera(ndc, camera);
      const hit = ray.intersectObjects(dogBodies, true)[0];
      return hit && dogObjs.find((o) => hit.object === o.body || o.body.getObjectById(hit.object.id))?.d.id;
    };
    let pressed: { x: number; y: number } | null = null;
    const onPress = (e: PointerEvent) => (pressed = { x: e.clientX, y: e.clientY });
    const onRelease = (e: PointerEvent) => {
      const p = pressed;
      pressed = null;
      if (!p || Math.hypot(e.clientX - p.x, e.clientY - p.y) > 5) return;
      // modalità «scegli i punti»: clic sul pavimento → punto sulla pianta (null se lì c'è un muro o un oggetto)
      if (pickRef.current) {
        const r = renderer.domElement.getBoundingClientRect();
        ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
        ray.setFromCamera(ndc, camera);
        const hitFloor = ray.ray.intersectPlane(groundPlane, groundHit);
        if (!hitFloor) return;
        const q = { x: Math.round(groundHit.x * 100 + PLAN_W / 2), y: Math.round(groundHit.z * 100 + PLAN_H / 2) };
        pickRef.current(blocked(q.x, q.y) ? null : q);
        return;
      }
      const id = dogAt(e);
      if (id) onDogRef.current(id);
    };
    const onHover = (e: PointerEvent) => {
      if (!pressed) renderer.domElement.style.cursor = pickRef.current ? "crosshair" : dogAt(e) ? "pointer" : "";
    };
    renderer.domElement.addEventListener("pointerdown", onPress);
    renderer.domElement.addEventListener("pointerup", onRelease);
    renderer.domElement.addEventListener("pointermove", onHover);

    // percorso scelto a mano (nuova automazione): linea arancio, rossa tratteggiata dove passa in un muro; A, B, C… sui punti
    const routeGroup = new THREE.Group();
    scene.add(routeGroup);
    const pickMarkGeo = keep(new THREE.CylinderGeometry(0.16, 0.16, 0.04, 28));
    const pickOkMat = keep(new THREE.LineBasicMaterial({ color: accent }));
    const pickBadMat = keep(new THREE.LineDashedMaterial({ color: "#f87171", dashSize: 0.2, gapSize: 0.12 }));
    const pickMarkMat = keep(new THREE.MeshStandardMaterial({ color: accent, emissive: accent, emissiveIntensity: 0.6 }));
    routeRef.current = (pts, loop) => {
      routeGroup.children.forEach((c) => {
        if (c instanceof THREE.Line) c.geometry.dispose();
        if (c instanceof CSS2DObject) c.element.remove();
      });
      routeGroup.clear();
      pts.forEach((p, i) => {
        const m = new THREE.Mesh(pickMarkGeo, pickMarkMat);
        m.position.set(wx(p.x), 0.03, wz(p.y));
        const tag = document.createElement("div");
        tag.className = "grid size-6 place-items-center rounded-full bg-accent font-mono text-sm font-semibold text-app select-none";
        tag.textContent = String.fromCharCode(65 + i);
        const l = new CSS2DObject(tag);
        l.position.set(wx(p.x), 0.45, wz(p.y));
        l.center.set(0.5, 1);
        routeGroup.add(m, l);
      });
      const legs = pts.slice(1).map((p, i) => [pts[i], p]);
      if (loop && pts.length > 1) legs.push([pts[pts.length - 1], pts[0]]);
      for (const [a, b] of legs) {
        const ok = segmentClear(a, b);
        const line = new THREE.Line(
          new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(wx(a.x), 0.05, wz(a.y)), new THREE.Vector3(wx(b.x), 0.05, wz(b.y))]),
          ok ? pickOkMat : pickBadMat,
        );
        if (!ok) line.computeLineDistances();
        routeGroup.add(line);
      }
    };

    // riprese (telecamera di bordo del cane, telecamera fissa): ognuna un suo renderer, creato solo mentre serve
    const feed = (cam: THREE.PerspectiveCamera) => {
      let v: { el: HTMLElement; r: THREE.WebGLRenderer; w: number; h: number } | null = null;
      const drop = () => {
        if (!v) return;
        v.r.dispose();
        v.r.domElement.remove();
        v = null;
      };
      const render = (el: HTMLElement) => {
        if (!v || v.el !== el) {
          drop();
          const r = new THREE.WebGLRenderer({ antialias: true });
          r.setPixelRatio(Math.min(devicePixelRatio, 2));
          r.shadowMap.enabled = true;
          r.shadowMap.type = THREE.PCFSoftShadowMap;
          Object.assign(r.domElement.style, { position: "absolute", inset: "0", width: "100%", height: "100%" });
          el.appendChild(r.domElement);
          v = { el, r, w: 0, h: 0 };
        }
        const { clientWidth: w, clientHeight: h } = el;
        if (w && h && (w !== v.w || h !== v.h)) {
          v.r.setSize(w, h, false);
          cam.aspect = w / h;
          cam.updateProjectionMatrix();
          Object.assign(v, { w, h });
        }
        v.r.render(scene, cam);
      };
      return { render, drop };
    };
    const povCam = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 80);
    const povFeed = feed(povCam);
    const eye = new THREE.Vector3();
    const look = new THREE.Vector3();
    // grandangolo da telecamera di sorveglianza
    const camCam = new THREE.PerspectiveCamera(62, 16 / 9, 0.05, 80);
    const camFeed = feed(camCam);

    // finché il cane vero non manda la posizione, la simuliamo lungo il suo percorso
    const start = performance.now();
    let last = start;
    // la strada che il cane sta facendo (come nella app mobile): tratteggio verde dal cane ai punti che restano
    const pathMat = keep(new THREE.LineDashedMaterial({ color: "#34d399", dashSize: 0.18, gapSize: 0.14 }));
    let pathLine: THREE.Line | null = null;
    let pathKey = "";
    const drawPath = (from: PlanXY, pts: PlanXY[]) => {
      const key = pts.map((p) => `${Math.round(p.x)},${Math.round(p.y)}`).join(";");
      if (key !== pathKey) {
        pathKey = key;
        if (pathLine) {
          scene.remove(pathLine);
          pathLine.geometry.dispose();
          pathLine = null;
        }
        if (pts.length) {
          pathLine = new THREE.Line(
            new THREE.BufferGeometry().setFromPoints([from, ...pts].map((p) => new THREE.Vector3(wx(p.x), 0.05, wz(p.y)))),
            pathMat,
          );
          scene.add(pathLine);
        }
      }
      if (pathLine) {
        // il primo punto segue il cane, così la linea parte sempre da lui
        const a = pathLine.geometry.getAttribute("position") as THREE.BufferAttribute;
        a.setXYZ(0, wx(from.x), 0.05, wz(from.y));
        a.needsUpdate = true;
        pathLine.computeLineDistances();
      }
    };

    let raf = 0;
    const delta = new THREE.Vector3();
    const offset = new THREE.Vector3();
    const tick = (now: number) => {
      const t = (now - start) / 1000;
      const dt = Math.min((now - last) / 1000, 0.05);
      last = now;
      const live = liveRef.current;
      for (const o of dogObjs) {
        // posa vera dal backend (un tick ogni 250 ms): il cane ci arriva morbido; finché non c'è, sta alla base
        const goal = live.pose ?? { ...HOME_PLAN, heading: HOME_HEADING };
        const before = { ...o.pos };
        const jump = Math.hypot(goal.x - o.pos.x, goal.y - o.pos.y) > 300; // «Set home here», reset: niente camminata
        const ease = jump ? 1 : 1 - Math.exp(-dt * 8);
        o.pos.x += (goal.x - o.pos.x) * ease;
        o.pos.y += (goal.y - o.pos.y) * ease;
        const turn = wrapAngle(goal.heading - o.heading);
        o.heading = wrapAngle(o.heading + turn * ease);
        const mx = o.pos.x - before.x,
          my = o.pos.y - before.y;
        // cm/s, per l'andatura; ruotare sul posto fa comunque muovere le zampe
        const speed = jump ? 0 : Math.max(Math.hypot(mx, my) / Math.max(dt, 1e-3), Math.abs(turn) > 0.05 ? 25 : 0);
        const dir = mx * Math.cos(o.heading) + my * Math.sin(o.heading) < -0.01 ? -1 : 1; // -1 quando cammina all'indietro
        o.setLabel(live);
        o.root.position.set(wx(o.pos.x), 0, wz(o.pos.y));
        o.body.rotation.y = -o.heading;

        const v = speed / 100; // m/s
        const walking = !reduced && v > 0.01;
        if (walking) o.phase = (o.phase + dt / GAIT_T) % 1;
        const stride = walking ? dir * v * GAIT_T * 0.5 : 0; // passo = strada fatta in un appoggio
        const k = walking ? Math.min(v / 0.6, 1) : 0;
        const bob = walking ? 0.012 * k * Math.cos(o.phase * Math.PI * 4) : 0;
        o.body.position.y = BODY_Y + bob;
        o.body.rotation.x = 0.025 * k * Math.sin(o.phase * Math.PI * 2);
        const hipH = BODY_Y + HIP_Y + bob;
        for (const leg of o.legs) {
          const q = (o.phase + leg.phase) % 1;
          let dx: number, lift: number;
          if (q < 0.5) {
            // appoggio: il piede resta a terra e scorre indietro
            dx = stride / 2 - stride * (q / 0.5);
            lift = 0;
          } else {
            // volo: si alza e torna avanti
            const s = (q - 0.5) / 0.5;
            dx = -stride / 2 + stride * s * s * (3 - 2 * s);
            lift = walking ? LIFT * k * Math.sin(Math.PI * s) : 0;
          }
          const [a, b] = legIK(dx, -(hipH - FOOT_R) + lift);
          leg.thigh.rotation.z = a;
          leg.knee.rotation.z = b;
        }
        if (!reduced) o.lidar.rotation.y += dt * 6;
      }
      drawPath(dogObjs[0]?.pos ?? HOME_PLAN, dogObjs[0] ? live.path : []);

      // camera che segue il cane scelto
      const followed = followRef.current && dogObjs.find((o) => o.d.id === followRef.current);
      if (followed) {
        delta
          .copy(followed.root.position)
          .sub(controls.target)
          .multiplyScalar(1 - Math.exp(-dt * 5));
        controls.target.add(delta);
        camera.position.add(delta);
        if (zoomRef.current !== null) {
          offset.copy(camera.position).sub(controls.target);
          const len = offset.length();
          const next = len + (zoomRef.current - len) * (1 - Math.exp(-dt * 3));
          camera.position.copy(controls.target).add(offset.setLength(next));
          if (Math.abs(next - zoomRef.current) < 0.02) zoomRef.current = null;
        }
      }
      // pulsanti della camera: sposta (parallelo al pavimento) o ruota intorno al punto guardato
      if (nav) {
        offset.copy(camera.position).sub(controls.target);
        if (nav === "rot-l" || nav === "rot-r") {
          offset.applyAxisAngle(THREE.Object3D.DEFAULT_UP, (nav === "rot-l" ? -1 : 1) * NAV_ROT * dt);
          camera.position.copy(controls.target).add(offset);
        } else {
          const fwd = delta.set(-offset.x, 0, -offset.z).normalize();
          const step = NAV_PAN * dt;
          const move =
            nav === "up" ? fwd.multiplyScalar(step) : nav === "down" ? fwd.multiplyScalar(-step) : fwd.set(-fwd.z, 0, fwd.x).multiplyScalar(nav === "right" ? step : -step);
          controls.target.add(move);
          camera.position.add(move);
        }
      }
      // volo verso la stanza scelta
      if (fly) {
        const k = 1 - Math.exp(-dt * 4);
        camera.position.lerp(fly.pos, k);
        controls.target.lerp(fly.target, k);
        if (camera.position.distanceTo(fly.pos) < 0.02) fly = null;
      }
      if (!reduced)
        for (const p of pings) {
          const k = ((t + p.userData.delay * 1.6) % 1.6) / 1.6;
          p.scale.setScalar(1 + k * 2.2);
          (p.material as THREE.MeshBasicMaterial).opacity = 0.6 * (1 - k);
        }
      for (const pin of pins) {
        if (!reduced) pin.position.y = 1.35 + Math.sin(t * 2.2) * 0.07;
        // pallino bianco sempre dal lato della camera, così il segnaposto si legge da ogni angolo
        const dot = pin.userData.dot as THREE.Mesh;
        dot.position.copy(camera.position).sub(pin.position).setLength(0.14);
      }
      controls.update();

      // telecamera di bordo del cane aperto a tutto schermo: lì la mappa è coperta, quindi si disegna solo questa
      const pov = povRef.current;
      const povDog = pov && dogObjs.find((o) => o.d.id === pov.dogId);
      if (pov && povDog) {
        povDog.root.updateMatrixWorld(true);
        povCam.position.copy(povDog.body.localToWorld(eye.set(0.43, 0.05, 0)));
        povCam.lookAt(povDog.body.localToWorld(look.set(3, -0.35, 0)));
        povDog.halo.visible = false;
        povFeed.render(pov.el);
        povDog.halo.visible = true;
      } else povFeed.drop();

      // telecamera fissa aperta: la stanza vista dal suo obiettivo (la camera stessa non si vede)
      const camPov = camPovRef.current;
      const pose = camPov && camPoses.get(camPov.camId);
      if (camPov && pose) {
        camCam.position.copy(pose.eye);
        camCam.lookAt(pose.look);
        pose.rig.visible = false;
        camFeed.render(camPov.el);
        pose.rig.visible = true;
      } else camFeed.drop();
      if (!pov?.cover) {
        renderer.render(scene, camera);
        labels.render(scene, camera);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    return () => {
      cancelAnimationFrame(raf);
      pathLine?.geometry.dispose();
      povFeed.drop();
      camFeed.drop();
      renderer.domElement.removeEventListener("pointerdown", onPress);
      renderer.domElement.removeEventListener("pointerup", onRelease);
      renderer.domElement.removeEventListener("pointermove", onHover);
      ro.disconnect();
      controls.dispose();
      disposables.forEach((x) => x.dispose());
      renderer.dispose();
      el.replaceChildren();
      resetRef.current = null;
      routeRef.current = null;
      camsRef.current = null;
      pinsRef.current = null;
      patrolRef.current = null;
      pinMats.forEach((m) => m.dispose());
      navRef.current = null;
    };
  }, [host, resetRef, liveRef, camsRef, povRef, camPovRef, focusRef, pickRef, routeRef, navRef]);

  // dopo l'effetto della scena: al primo giro pinsRef è già pronto
  useEffect(() => {
    pinsRef.current?.(JSON.parse(pinsKey));
  }, [pinsKey]);
  useEffect(() => {
    patrolRef.current?.(JSON.parse(patrolKey));
  }, [patrolKey]);
}

// ── componente ────────────────────────────────────────
const stateLabel: Record<BotState, [tone: "amber" | "blue" | "gray" | "red", label: string]> = {
  missione: ["amber", "On mission"],
  ronda: ["blue", "Moving"],
  base: ["gray", "At base"],
  fermo: ["gray", "Idle"],
  manuale: ["amber", "Manual control"],
  estop: ["red", "E-stop"],
  offline: ["gray", "Disconnected"],
  spento: ["gray", "Off"],
};

const DOG_ID = "go1";
const DOG_NAME = "Unitree Go1";
const postureLabel = { standing: "Standing", down: "Lying down", rising: "Standing up" } as const;

/** Stanza (di mock.ts, in cm sulla pianta) che contiene il punto. */

/** Il cane del backend come lo mostra l'interfaccia. Senza backend (o col cane spento) risulta scollegato. */
function toDogInfo(live: Live): DogInfo {
  const d = live.dog;
  const connected = live.backendOnline && !!d?.connected;
  const spots = live.site?.spots ?? [];
  const near = (x: number, y: number) => spots.find((s) => Math.hypot(s.x - x, s.y - y) < 0.5);
  const base = { id: DOG_ID, name: DOG_NAME, adapter: d?.kind === "go1" ? "unitree" : "simulato", connected, armed: d?.armed ?? true } as const;
  const roomId = roomAt(d ? siteToPlan(d.x, d.y) : HOME_PLAN);
  if (!d || !connected)
    return { ...base, battery: null, state: "offline", task: live.backendOnline ? "Dog not connected" : "Backend offline", roomId };
  const info = { ...base, battery: d.battery == null ? null : Math.round(d.battery), roomId };
  if (!d.armed) return { ...info, state: "estop", task: "Emergency stop: reset to move again" };
  if (d.manual) return { ...info, state: "manuale", task: "Driven by hand" };
  if (d.target) {
    const [tx, ty] = d.target;
    return { ...info, state: "missione", task: `Going to ${near(tx, ty)?.name ?? `${tx.toFixed(1)}, ${ty.toFixed(1)} m`}` };
  }
  const idle = `${postureLabel[d.posture] ?? d.posture} · odom ${d.odom}`;
  if (d.moving) return { ...info, state: "ronda", task: idle };
  const home = spots.find((s) => s.id === (live.site?.home ?? "home"));
  return { ...info, state: home && Math.hypot(home.x - d.x, home.y - d.y) < 0.5 ? "base" : "fermo", task: idle };
}

/** Stato di un bot negli elenchi: quelli del cane live più «spento» per i bot registrati ma spenti (mock). */
type BotState = DogStatus | "spento";
/** Un bot nel pannello e nella fila in alto: il cane live (DogInfo) o un bot spento di mock.ts. */
type Bot = { id: string; name: string; battery: number | null; state: BotState; task: string; connected: boolean };
/** I bot spenti (mock): compaiono negli elenchi, disattivati, non sulla mappa. */
const OFF_BOTS: Bot[] = offlineDogs.map((d) => ({ id: d.id, name: d.name, battery: d.battery, state: "spento", task: d.task, connected: false }));

/** Il cane live dal backend: com'è nell'interfaccia (DogInfo) e la sua posa sulla pianta per la scena 3D (liveRef). */
function useLiveDog() {
  const live = useLive();
  const dog = toDogInfo(live);
  const pose = live.dog ? { ...siteToPlan(live.dog.x, live.dog.y), heading: yawToHeading(live.dog.yaw) } : null;
  const path = (live.current?.path ?? []).map(([x, y]) => siteToPlan(x, y));
  const sceneDog: SceneDog = { id: dog.id, name: dog.name, battery: dog.battery, connected: dog.connected, pose, path };
  const liveRef = useRef<SceneDog>(sceneDog);
  useEffect(() => {
    liveRef.current = sceneDog;
  });
  return { live, dog, liveRef };
}

/** Tasti tenuti premuti → velocità nel frame del cane (vx avanti, vy a sinistra, wz antiorario). */
function velocity(held: ReadonlySet<Move>, { vmax, wmax }: Limits): [number, number, number] {
  const on = (m: Move) => (held.has(m) ? 1 : 0);
  return [(on("avanti") - on("indietro")) * vmax, (on("sinistra") - on("destra")) * 0.6 * vmax, (on("ruota-sx") - on("ruota-dx")) * wmax];
}

/** La planimetria in 3D a tutta area: si gira col trascinamento, zoom con la rotella.
 *  In alto: bot (pannello a sinistra), turno e ora, notifiche. */
export function FloorMap3D({ pick }: { pick?: { points: PlanPoint[]; loop?: boolean; onPick: (p: PlanPoint | null) => void } } = {}) {
  const host = useRef<HTMLDivElement>(null);
  const pickRef = useRef<((p: PlanPoint | null) => void) | null>(null);
  const routeRef = useRef<((pts: PlanPoint[], loop: boolean) => void) | null>(null);
  const onPick = pick?.onPick;
  const points = pick?.points;
  const loop = pick?.loop ?? false;
  useEffect(() => {
    pickRef.current = onPick ?? null;
  }, [onPick]);
  const resetRef = useRef<(() => void) | null>(null);
  const focusRef = useRef<((roomId: string | null) => void) | null>(null);
  const navRef = useRef<((held: Nav | null) => void) | null>(null);

  // dati live dal backend: il cane (uno) e le telecamere del sito
  const { live, dog, liveRef } = useLiveDog();
  const dogs = [dog];
  const cams: (SceneCam & { name: string; roomId: string })[] = (live.site?.cameras ?? []).map((c) => {
    const p = siteToPlan(c.x, c.y);
    return {
      id: c.id,
      label: c.id.toUpperCase(),
      name: c.name,
      ...p,
      aim: c.look ? siteToPlan(c.look[0], c.look[1]) : { x: PLAN_W / 2, y: PLAN_H / 2 },
      online: live.backendOnline && !!live.cameras.find((x) => x.id === c.id)?.online,
      roomId: roomAt(p),
    };
  });
  const camsRef = useRef<((cams: SceneCam[]) => void) | null>(null);
  const camsKey = JSON.stringify(cams);

  // guida manuale: finché si tiene premuto, un comando ogni 100 ms (il backend lo tiene buono 0,6 s: se smettiamo, il cane si ferma)
  const driveRef = useRef<Drive | null>(null);
  const limitsRef = useRef(live.limits);
  useEffect(() => {
    limitsRef.current = live.limits;
  });
  useEffect(() => {
    let driving = false;
    const t = setInterval(() => {
      const held = driveRef.current?.held;
      if (held?.size) {
        sendDrive(...velocity(held, limitsRef.current));
        driving = true;
      } else if (driving) {
        // tasti rilasciati: fermo subito, senza aspettare che scada l'ultimo comando
        sendDrive(0, 0, 0);
        driving = false;
      }
    }, 100);
    return () => clearInterval(t);
  }, []);

  // pannello dei bot: si apre dalle icone tonde in alto; dentro, la ricerca. Il cane live più i bot spenti
  const fleet: Bot[] = [dog, ...OFF_BOTS];
  const [botsOpen, setBotsOpen] = useState(false);
  const [selectedBot, setSelectedBot] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();
  const listed = q ? fleet.filter((d) => `${d.name} ${d.task}`.toLowerCase().includes(q)) : fleet;
  const pickBot = (id: string) => {
    if (botsOpen && selectedBot === id) return setBotsOpen(false);
    setSelectedBot(id);
    setBotsOpen(true);
    setQuery("");
    // la card del bot scelto viene in vista
    requestAnimationFrame(() => document.getElementById(`bot-card-${id}`)?.scrollIntoView({ block: "nearest", behavior: "smooth" }));
  };
  const [view, setView] = useState<View | null>(null);
  const [following, setFollowing] = useState<string | null>(null);
  const povRef = useRef<Pov | null>(null);
  const camPovRef = useRef<CamPov | null>(null);
  // due posti per la telecamera di bordo: la vista a tutto schermo vince sul riquadro di «Segui»
  const povSlots = useRef<{ full: Pov | null; pip: Pov | null }>({ full: null, pip: null });
  const setPov = (slot: "full" | "pip", pov: Pov | null) => {
    povSlots.current[slot] = pov;
    povRef.current = povSlots.current.full ?? povSlots.current.pip;
  };
  const followedDog = dogs.find((d) => d.id === following);
  const toggleFollow = (id: string) => setFollowing((f) => (f === id ? null : id));
  useScene(host, (id) => setView({ kind: "camera", id }), toggleFollow, following, resetRef, liveRef, camsRef, povRef, camPovRef, focusRef, pickRef, routeRef, navRef);
  // dopo useScene: al primo giro la scena (e routeRef/camsRef) è già pronta, così percorso e camere si vedono subito
  useEffect(() => {
    routeRef.current?.(points ?? [], loop);
  }, [points, loop]);
  useEffect(() => {
    camsRef.current?.(JSON.parse(camsKey));
  }, [camsKey]);
  const openDog = view?.kind === "dog" ? dogs.find((d) => d.id === view.id) : undefined;
  const openCam = view?.kind === "camera" ? cams.find((c) => c.id === view.id) : undefined;

  // modalità «scegli i punti» (nuova automazione): solo la mappa, si clicca sul pavimento
  if (pick)
    return (
      <div className="absolute inset-0 overflow-hidden">
        <div ref={host} className="absolute inset-0 select-none" role="img" aria-label="3D floor plan: click the floor to add route points" />
        <MapNav navRef={navRef} onReset={() => resetRef.current?.()} />
        <button
          onClick={() => resetRef.current?.()}
          className="absolute right-4 top-4 z-10 flex items-center gap-2 rounded-lg border border-line bg-app/80 px-3 py-1.5 text-sm text-muted backdrop-blur hover:bg-hover hover:text-ink"
        >
          <RotateCcw className="size-4" strokeWidth={1.75} /> Reset view
        </button>
      </div>
    );

  return (
    <div className="absolute inset-0 overflow-hidden">
      <div
        ref={host}
        className="absolute inset-0 cursor-grab active:cursor-grabbing"
        role="img"
        aria-label="3D floor plan with live dog positions"
      />

      {/* barra in alto: bot | turno e ora | notifiche */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-30 grid grid-cols-[1fr_auto_1fr] items-start gap-3 p-4">
        <div className="pointer-events-auto justify-self-start">
          <BotsRow bots={fleet} open={botsOpen} selected={selectedBot} onPick={pickBot} />
        </div>
        <div className="pointer-events-auto hidden md:block">
          <ShiftClock />
        </div>
        <div className="pointer-events-auto col-start-3 flex items-center gap-2 justify-self-end">
          <NotificationsBell />
        </div>
      </div>

      {/* pannello dei bot della stanza: scorre se sono tanti */}
      {botsOpen && (
        <aside
          id="bots-panel"
          aria-label="Bots"
          className="absolute bottom-4 left-4 top-[4.5rem] z-20 flex w-[17rem] flex-col overflow-hidden rounded-2xl border border-line bg-app/70 backdrop-blur"
        >
          <div className="flex items-center gap-2 p-2">
            <label className="flex h-9 min-w-0 flex-1 items-center gap-2 rounded-lg border border-line bg-app/80 px-2.5 focus-within:border-[#3a3a3a]">
              <Search className="size-4 shrink-0 text-muted" strokeWidth={1.75} aria-hidden />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search bots"
                aria-label="Search bots"
                className="min-w-0 flex-1 bg-transparent text-sm text-ink placeholder:text-faint focus:outline-none"
              />
            </label>
            <button onClick={() => setBotsOpen(false)} aria-label="Close bots" title="Close" className="rounded-md p-1.5 text-muted hover:bg-hover hover:text-ink">
              <X className="size-4" />
            </button>
          </div>
          <div className="flex items-center justify-between px-3 pb-2 text-sm">
            <span className="text-muted">All bots</span>
            <span className="font-mono tabular-nums text-faint">{listed.length}</span>
          </div>
          <div className="flex flex-1 flex-col items-center gap-3 overflow-y-auto px-2 pb-2">
            {listed.map((d) => (
              <DogCard
                key={d.id}
                dog={d}
                selected={selectedBot === d.id}
                followed={following === d.id}
                onFollow={() => toggleFollow(d.id)}
                onLive={() => setView({ kind: "dog", id: d.id })}
              />
            ))}
            {!listed.length && (
              <p className="px-2 py-6 text-center text-sm text-muted">{q ? `No bots match “${query.trim()}”.` : "No bots right now."}</p>
            )}
          </div>
        </aside>
      )}

      <div className="absolute right-4 top-[4.5rem] z-10 flex flex-col items-end gap-2">
        <ul className="flex flex-col gap-1 rounded-lg bg-app/80 px-3 py-2 text-sm text-muted backdrop-blur">
          <li className="flex items-center gap-2">
            <span className="size-2 rounded-full bg-accent" /> Dog
          </li>
          <li className="flex items-center gap-2">
            <span className="size-2 rounded-full border border-accent/70" /> Patrol point
          </li>
          <li className="flex items-center gap-2">
            <span className="size-2 rounded-[2px] bg-[#9a9a9a]" /> Camera
          </li>
          <li className="flex items-center gap-2">
            <MapPin className="-ml-0.5 size-3 fill-red-400 text-red-400" aria-hidden /> Event · high priority
          </li>
          <li className="flex items-center gap-2">
            <MapPin className="-ml-0.5 size-3 fill-amber-300 text-amber-300" aria-hidden /> Event · medium / low
          </li>
        </ul>
      </div>

      {/* torna alla vista iniziale: bianco, in basso al centro */}
      <button
        onClick={() => {
          setFollowing(null);
          resetRef.current?.();
        }}
        className="absolute bottom-4 left-1/2 z-20 flex -translate-x-1/2 items-center gap-2 rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app shadow-lg shadow-black/40 transition-opacity hover:opacity-90"
      >
        <RotateCcw className="size-4" strokeWidth={2} /> Reset view
      </button>

      <MapNav navRef={navRef} onReset={() => {
        setFollowing(null);
        resetRef.current?.();
      }} />

      {/* viste live: in basso, accanto al pannello dei bot */}
      <div
        className={`absolute bottom-4 z-20 flex flex-col items-start gap-3 ${botsOpen ? "left-[19rem] max-w-[calc(100%-20rem)]" : "left-4 max-w-[calc(100%-2rem)]"}`}
      >
        {view?.kind === "camera" && (
          <CameraView
            key={view.id}
            camId={view.id}
            cam={openCam}
            onClose={() => setView(null)}
            streamRef={(el) => {
              camPovRef.current = el ? { camId: view.id, el } : null;
            }}
          />
        )}
        {followedDog && (
          <FollowView
            dog={followedDog}
            onOpen={() => setView({ kind: "dog", id: followedDog.id })}
            onControl={() => setView({ kind: "dog", id: followedDog.id, control: true })}
            onClose={() => {
              setFollowing(null);
              resetRef.current?.();
            }}
            streamRef={(el) => setPov("pip", el ? { dogId: followedDog.id, el, cover: false } : null)}
          />
        )}
      </div>

      {openDog && (
        <DogView
          key={`${openDog.id}-${view?.control ? "control" : "view"}`}
          dog={openDog}
          initialControl={view?.control}
          onClose={() => setView(null)}
          onDrive={(held) => (driveRef.current = held ? { dogId: openDog.id, held } : null)}
          onStop={() => void command("stop")}
          onReset={() => void command("reset")}
          streamRef={(el) => setPov("full", el ? { dogId: openDog.id, el, cover: true } : null)}
        />
      )}
    </div>
  );
}

function DogCard({
  dog,
  selected,
  followed,
  onFollow,
  onLive,
}: {
  dog: Bot;
  selected: boolean;
  followed: boolean;
  onFollow: () => void;
  onLive: () => void;
}) {
  const [tone, label] = stateLabel[dog.state];
  // spento: card in grigio, niente «Follow» né «Live view»
  const off = dog.state === "spento";
  return (
    <div
      id={`bot-card-${dog.id}`}
      className={`w-64 shrink-0 overflow-hidden rounded-xl border bg-app/90 backdrop-blur ${selected ? "border-accent/60" : "border-line"}`}
    >
      <div className="relative h-28 bg-[radial-gradient(circle_at_40%_45%,#2a2a2a,#141414)]">
        <Image src="/robot-dog.png" alt="" fill sizes="256px" className={`object-cover object-[40%_45%] ${off ? "opacity-40 grayscale" : ""}`} />
        {/* sfuma verso la card */}
        <div className="absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-app to-transparent" aria-hidden />
        <span className="absolute right-2 top-2 rounded-full bg-app/85 backdrop-blur">
          <Badge tone={tone}>{label}</Badge>
        </span>
      </div>
      <div className="p-3 pt-1">
        <span className="flex min-w-0 items-center gap-2 text-sm">
          <span className={`size-2 shrink-0 rounded-full ${off || !dog.connected ? "bg-faint" : "bg-ok"}`} />
          <span className={`truncate ${off ? "text-muted" : ""}`}>{dog.name}</span>
        </span>
        <div className="mt-1 truncate text-sm text-muted">{dog.task}</div>

        <div className="mt-3">
          {dog.battery == null ? (
            <span className="font-mono text-sm text-faint" aria-label="Battery unknown">
              —
            </span>
          ) : (
            <BatteryTag battery={dog.battery} off={off || !dog.connected} />
          )}
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2">
          <button
            onClick={onFollow}
            disabled={off}
            aria-pressed={followed}
            className={`flex items-center justify-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition-colors disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-muted ${
              followed ? "border-accent/60 bg-accent/10 text-ink" : "border-line text-muted hover:bg-hover hover:text-ink"
            }`}
          >
            <Footprints className="size-4" strokeWidth={1.75} />
            {followed ? "Following" : "Follow"}
          </button>
          <button
            onClick={onLive}
            disabled={off}
            className="flex items-center justify-center gap-2 rounded-lg border border-line px-3 py-1.5 text-sm text-muted transition-colors hover:bg-hover hover:text-ink disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-muted"
          >
            <Video className="size-4" strokeWidth={1.75} />
            Live view
          </button>
        </div>
      </div>
    </div>
  );
}

/** Mentre segui un cane: la sua telecamera di bordo in un riquadro sopra le card.
 *  Sotto: apri a tutto schermo o prendi il controllo; la X in alto chiude (si torna alla vista iniziale). */
function FollowView({
  dog,
  onOpen,
  onControl,
  onClose,
  streamRef,
}: {
  dog: DogInfo;
  onOpen: () => void;
  onControl: () => void;
  onClose: () => void;
  streamRef: (el: HTMLElement | null) => void;
}) {
  const btn = "flex items-center justify-center gap-2 rounded-lg border border-line px-3 py-1.5 text-sm text-muted transition-colors hover:bg-hover hover:text-ink";
  return (
    <div className="w-[400px] max-w-full overflow-hidden rounded-xl border border-accent/60 bg-app/95 shadow-2xl shadow-black/50 backdrop-blur">
      <div className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
        <span className="flex min-w-0 items-center gap-2">
          <Badge tone="red">● LIVE</Badge>
          <span className="truncate">{dog.name} view</span>
        </span>
        <button onClick={onClose} aria-label="Close view" title="Close view" className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink">
          <X className="size-4" />
        </button>
      </div>
      <div className="relative aspect-video bg-[#121212]">
        <div ref={streamRef} className="absolute inset-0" />
        {/* telefono montato sul cane (camera «dog» del backend): quando manda fotogrammi copre la vista simulata */}
        <CameraFeed id="dog" alt={`${dog.name} on-board camera`} className="absolute inset-0 size-full object-cover" />
      </div>
      <div className="grid grid-cols-2 gap-2 border-t border-line p-2">
        <button onClick={onOpen} className={btn}>
          <Maximize2 className="size-4" strokeWidth={1.75} /> Open
        </button>
        {/* l'azione principale: bianca */}
        <button
          onClick={onControl}
          className="flex items-center justify-center gap-2 rounded-lg bg-ink px-3 py-1.5 text-sm font-medium text-app transition-opacity hover:opacity-90"
        >
          Take control
        </button>
      </div>
    </div>
  );
}

/** In basso a destra: pulsanti tondi per spostare e ruotare la camera della mappa (si tengono premuti). Al centro, la vista iniziale. */
function MapNav({ navRef, onReset }: { navRef: React.RefObject<((held: Nav | null) => void) | null>; onReset: () => void }) {
  const round =
    "grid size-10 touch-none select-none place-items-center rounded-full border border-line bg-app/85 text-muted backdrop-blur transition-colors hover:bg-hover hover:text-ink active:bg-active active:text-ink";
  const hold = (n: Nav, label: string, Icon: typeof ArrowUp) => (
    <button
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        navRef.current?.(n);
      }}
      onPointerUp={() => navRef.current?.(null)}
      onPointerCancel={() => navRef.current?.(null)}
      onLostPointerCapture={() => navRef.current?.(null)}
      onContextMenu={(e) => e.preventDefault()}
      aria-label={label}
      title={label}
      className={round}
    >
      <Icon className="size-[18px]" strokeWidth={1.75} />
    </button>
  );
  return (
    <div className="absolute bottom-4 right-4 z-20 grid grid-cols-3 gap-1.5" role="group" aria-label="Map camera">
      {hold("rot-l", "Rotate left", RotateCcw)}
      {hold("up", "Move forward", ArrowUp)}
      {hold("rot-r", "Rotate right", RotateCw)}
      {hold("left", "Move left", ArrowLeft)}
      <button onClick={onReset} aria-label="Reset view" title="Reset view" className={round}>
        <Crosshair className="size-[18px]" strokeWidth={1.75} />
      </button>
      {hold("right", "Move right", ArrowRight)}
      <span />
      {hold("down", "Move back", ArrowDown)}
    </div>
  );
}

/** Una telecamera fissa del sito (dal backend): l'anteprima live del telefono, sopra la ripresa simulata nella scena 3D. */
function CameraView({
  camId,
  cam,
  onClose,
  streamRef,
}: {
  camId: string;
  cam?: { label: string; name: string; online: boolean; roomId: string };
  onClose: () => void;
  streamRef: (el: HTMLElement | null) => void;
}) {
  const now = useNow();
  const stamp = now == null ? "" : new Date(now * 1000).toLocaleString("sv-SE").replace(",", "");
  const title = cam?.label ?? camId;
  const room = roomName(cam?.roomId ?? "");
  return (
    <div className="w-[400px] max-w-full overflow-hidden rounded-xl border border-line bg-app/95 backdrop-blur">
      <div className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
        <span className="flex min-w-0 items-center gap-2">
          {cam?.online ? <Badge tone="red">● LIVE</Badge> : <Badge tone="gray">Offline</Badge>}
          <span className="truncate">
            {title}
            {room && ` · ${room}`}
          </span>
        </span>
        <button onClick={onClose} aria-label="Close camera view" className="rounded-md p-1 text-muted hover:bg-hover hover:text-ink">
          <X className="size-4" />
        </button>
      </div>
      <div className="relative aspect-video bg-[#121212]" role="img" aria-label={`${title} view${room ? ` of ${room}` : ""}`}>
        {/* ripresa simulata nella scena 3D, dal punto della camera */}
        <div ref={streamRef} className="absolute inset-0" />
        {/* anteprima live del telefono: quando manda fotogrammi copre la ripresa simulata */}
        <CameraFeed id={camId} alt={cam?.name ?? title} className="absolute inset-0 size-full object-cover" />
        {/* sovrimpressione da telecamera di sorveglianza */}
        <span className="pointer-events-none absolute left-2 top-2 z-10 rounded bg-app/60 px-1.5 py-0.5 font-mono text-sm tabular-nums text-ink/90">
          {title}
        </span>
        <span className="pointer-events-none absolute bottom-2 right-2 z-10 rounded bg-app/60 px-1.5 py-0.5 font-mono text-sm tabular-nums text-ink/90">
          {stamp}
        </span>
      </div>
    </div>
  );
}

/** La telecamera di bordo di un cane da sola (pagina della missione): la stessa scena 3D, ma si disegna solo
 *  quello che vede il cane. La mappa resta nascosta e non viene disegnata (cover).
 *  Nella scena c'è solo il cane live (il Go1 del backend): le missioni sono ancora di mock, quindi la ripresa è la sua;
 *  se la missione è in corso, sopra c'è l'anteprima del telefono montato sul cane. */
export function DogCam({ dogId, tag, live, at }: { dogId: string; tag: string; live: boolean; at: string }) {
  const host = useRef<HTMLDivElement>(null);
  const resetRef = useRef<(() => void) | null>(null);
  const { liveRef } = useLiveDog();
  const camsRef = useRef<((cams: SceneCam[]) => void) | null>(null);
  const povRef = useRef<Pov | null>(null);
  const camPovRef = useRef<CamPov | null>(null);
  const focusRef = useRef<((roomId: string | null) => void) | null>(null);
  const pickRef = useRef<((p: PlanPoint | null) => void) | null>(null);
  const routeRef = useRef<((pts: PlanPoint[], loop: boolean) => void) | null>(null);
  const navRef = useRef<((held: Nav | null) => void) | null>(null);
  const noop = () => {};
  useScene(host, noop, noop, null, resetRef, liveRef, camsRef, povRef, camPovRef, focusRef, pickRef, routeRef, navRef);
  const now = useNow();
  const name = dogId === DOG_ID ? DOG_NAME : dogName(dogId);
  const clock = now == null ? "--:--:--" : new Date(now * 1000).toLocaleTimeString("en-GB");

  return (
    <div className="relative aspect-video overflow-hidden rounded-lg border border-line bg-[#121212]">
      {/* la mappa serve solo a far girare la scena: invisibile */}
      <div ref={host} className="pointer-events-none absolute inset-0 opacity-0" aria-hidden />
      <div
        ref={(el) => {
          povRef.current = el ? { dogId: DOG_ID, el, cover: true } : null;
        }}
        className="absolute inset-0"
        role="img"
        aria-label={`${name} front camera`}
      />
      {live && <CameraFeed id="dog" alt={`${name} on-board camera`} className="absolute inset-0 size-full object-cover" />}
      {/* vignettatura da telecamera */}
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_center,transparent_55%,rgba(0,0,0,0.55))]" aria-hidden />
      <span className="absolute left-2 top-2 rounded bg-black/60 px-1.5 py-0.5 font-mono text-sm text-ink/80">{tag}</span>
      <span className="absolute right-2 top-2 flex items-center gap-1.5 rounded bg-black/60 px-1.5 py-0.5 font-mono text-sm tabular-nums text-ink/80">
        <span className={`size-1.5 rounded-full ${live ? "animate-pulse bg-red-500" : "bg-red-400"}`} aria-hidden />
        {live ? clock : `REC ${at}`}
      </span>
      <span className="absolute bottom-2 left-2 rounded bg-black/60 px-1.5 py-0.5 text-sm text-ink/80">{name} · front camera</span>
    </div>
  );
}
