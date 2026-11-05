// Mappa 3D di GrokPatrol per la WebView di Flutter.
// È la scena di grokdog/src/components/FloorMap3D.tsx: geometria, arredi, cane e camminata sono gli stessi.
// Cambiano solo i bordi: i dati arrivano da Dart (init), i clic tornano a Dart (post), le etichette usano il CSS di index.html.
// La planimetria si importa direttamente dalla web app: se cambia lì, basta rifare `npm run build`.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { CSS2DObject, CSS2DRenderer } from "three/addons/renderers/CSS2DRenderer.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { PLAN_FLOOR, PLAN_H, PLAN_OBJECTS, PLAN_W, PLAN_WALLS, type PlanObject } from "../../grokdog/src/lib/floorplan";

type PlanPoint = { x: number; y: number };
type Move = "avanti" | "indietro" | "sinistra" | "destra" | "ruota-sx" | "ruota-dx" | "stop";
type DogState = "missione" | "ronda" | "base";
type Room = { id: string; name: string; x: number; y: number; w: number; h: number };
type Point = { id: string; label: string; roomId: string; x: number; y: number };
/** Dal vivo il percorso è vuoto: la posizione arriva dal server con setDogPose. */
type Dog = { id: string; name: string; battery: number | null; state: DogState; route: PlanPoint[]; x?: number; y?: number; heading?: number };
type Actor = { id: string; kind: string; x: number; y: number };
type MapEvent = { id: string; x: number; y: number; anomaly: string; priority: "alta" | "media" | "bassa"; status: string };
/** Pixel coperti dagli overlay di Flutter, sopra e sotto: la pianta si centra nello spazio che resta. */
type Insets = { top: number; bottom: number };
type Config = { rooms: Room[]; cameras: Point[]; patrolPoints: Point[]; spots: Point[]; dogs: Dog[]; events: MapEvent[]; pick: boolean; live: boolean; insets: Insets };
/** Dove disegnare la telecamera di bordo: cover = a tutto schermo; rect = riquadro di «Segui», in px della pagina. */
type Pov = { dogId: string; cover: boolean; rect?: { x: number; y: number; w: number; h: number } | null };

/** Comandi della camera della mappa (pulsanti tondi), tenuti premuti. */

type Bridge = { postMessage: (m: string) => void };
declare global {
  interface Window {
    GrokMapBridge?: Bridge;
    grokMap: typeof api;
  }
}

const post = (m: Record<string, unknown>) => window.GrokMapBridge?.postMessage(JSON.stringify(m));

/** Quello che Dart può chiamare. I metodi legati alla scena si riempiono in init. */
const api = {
  init(cfg: Config) {
    try {
      build(cfg);
      post({ type: "ready" });
    } catch (e) {
      post({ type: "error", message: String(e) });
    }
  },
  reset: () => {},
  focusRoom: (_roomId: string | null) => {},
  setRoute: (_pts: PlanPoint[], _loop: boolean, _seq: number) => {},
  setFollowing: (_id: string | null) => {},
  setDrive: (_dogId: string | null, _held: Move[]) => {},
  setPov: (_pov: Pov | null) => {},
  setActive: (_active: boolean) => {},
  setInsets: (_insets: Insets) => {},
  setDogPose: (_id: string, _x: number, _y: number, _heading: number, _speed: number) => {},
  setEvents: (_events: MapEvent[]) => {},
  setPatrol: (_points: Point[]) => {},
  setPath: (_points: PlanPoint[]) => {},
  setActors: (_actors: Actor[]) => {},
  setCamPov: (_pov: { camId: string; rect: { x: number; y: number; w: number; h: number } } | null) => {},
  /** Stato della scena e proiezione di un punto della pianta sullo schermo (0-1): servono ai test sul dispositivo. */
  state: () => "{}",
  project: (_x: number, _y: number) => "{}",
};
window.grokMap = api;

const ACTIVE = new Set(["in_valutazione", "in_coda", "missione", "verifica"]);
const SPEED = 60; // cm/s del cane simulato
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

// guida manuale («Prendi il controllo»)
const DRIVE_FWD = 60; // cm/s avanti
const DRIVE_BACK = 35; // cm/s indietro
const DRIVE_SIDE = 40; // cm/s di lato
const DRIVE_TURN = 1.6; // rad/s
const DOG_R = 24; // cm: ingombro del cane contro i muri
const CHAIR = 0.45; // m: fascia delle sedie intorno al piano del tavolo (dentro il rettangolo del tavolo)
const TRAIL_STEP = 12; // cm tra due briciole del percorso fatto a mano

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


/** Il tratto in linea retta da a a b passa senza toccare muri o oggetti? */
function segmentClear(a: PlanPoint, b: PlanPoint) {
  const n = Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / 10);
  for (let i = 0; i <= n; i++) if (blocked(a.x + ((b.x - a.x) * i) / n, a.y + ((b.y - a.y) * i) / n)) return false;
  return true;
}

/** Punto a `dist` cm lungo il percorso chiuso, con quanto manca dall'angolo più vicino. */
function along(route: PlanPoint[], dist: number) {
  const legs = route.map((p, i) => {
    const q = route[(i + 1) % route.length];
    return { p, q, len: Math.hypot(q.x - p.x, q.y - p.y) };
  });
  const total = legs.reduce((s, l) => s + l.len, 0);
  let d = ((dist % total) + total) % total;
  for (const l of legs) {
    if (d <= l.len) {
      const t = d / l.len;
      return { x: l.p.x + (l.q.x - l.p.x) * t, y: l.p.y + (l.q.y - l.p.y) * t, corner: Math.min(d, l.len - d) };
    }
    d -= l.len;
  }
  return { ...route[0], corner: 0 };
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

// ── scena ─────────────────────────────────────────────
function build(cfg: Config) {
  const { rooms, cameras } = cfg;
  const patrolPoints = cfg.pick ? [] : cfg.patrolPoints;
  const spots = cfg.pick ? [] : cfg.spots;
  const dogs = cfg.pick ? [] : cfg.dogs;
  const events = cfg.pick ? [] : cfg.events;
  const el = document.getElementById("map") as HTMLDivElement;
  let following: string | null = null;
  let zoom: number | null = null; // distanza a cui portare la camera quando si inizia a seguire
  let drive: { dogId: string; held: ReadonlySet<Move> } | null = null;
  let pov: Pov | null = null;
  let paused = false;
  let camPov: { camId: string; rect: { x: number; y: number; w: number; h: number } } | null = null;
  // creando un'automazione si tocca solo il pavimento: si vede la mappa, senza cani, ronda ed eventi
  const picking = cfg.pick;
  let insets = cfg.insets;
  let viewShift = (insets.bottom - insets.top) / 2; // px di cui salire: controbilancia gli overlay

  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color("#121212");
  scene.fog = new THREE.Fog("#121212", 80, 150);

  const camera = new THREE.PerspectiveCamera(35, 1, 0.1, 200);
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.shadowMap.autoUpdate = false; // aggiornata a mano una volta per frame: con il riquadro la scena si disegna due volte
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
  controls.maxDistance = 95;
  // se l'utente zooma mentre la camera si avvicina, vince lui
  controls.addEventListener("start", () => (zoom = null));

  // luci
  scene.add(new THREE.HemisphereLight("#ffffff", "#202020", 1.6));
  const sun = new THREE.DirectionalLight("#ffffff", 1.4);
  sun.position.set(-10, 25, 12);
  sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024); // sul telefono basta e pesa un quarto
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
    const l = label(r.name, "lbl-room");
    l.position.set(wx(r.x + r.w / 2), 0.05, wz(r.y + 80));
    l.center.set(0.5, 0.5);
    scene.add(l);
  }

  // ronda
  const accent = new THREE.Color("#e99a3c"); // = --color-accent
  const routeMat = keep(new THREE.LineDashedMaterial({ color: accent, dashSize: 0.25, gapSize: 0.25, transparent: true, opacity: 0.6 }));
  let routeLine: THREE.Line | null = null;
  const drawPatrol = (pts: Point[]) => {
    if (routeLine) {
      scene.remove(routeLine);
      routeLine.geometry.dispose();
      routeLine = null;
    }
    if (pts.length < 2) return;
    routeLine = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([...pts, pts[0]].map((p) => new THREE.Vector3(wx(p.x), 0.03, wz(p.y)))),
      routeMat,
    );
    routeLine.computeLineDistances();
    scene.add(routeLine);
  };
  drawPatrol(patrolPoints);
  api.setPatrol = drawPatrol;
  const ringGeo = keep(new THREE.RingGeometry(0.16, 0.22, 32).rotateX(-Math.PI / 2));
  const ringMat = keep(new THREE.MeshBasicMaterial({ color: accent, transparent: true, opacity: 0.8 }));
  for (const p of spots) {
    const m = new THREE.Mesh(ringGeo, ringMat);
    m.position.set(wx(p.x), 0.03, wz(p.y));
    scene.add(m);
    // dal vivo i posti si toccano per mandarci il cane
    let l: CSS2DObject;
    if (cfg.live) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "lbl-spot";
      btn.textContent = p.label;
      btn.addEventListener("click", () => post({ type: "spot", id: p.id }));
      btn.addEventListener("pointerdown", (e) => e.stopPropagation());
      l = new CSS2DObject(btn);
    } else l = label(p.label, "lbl-point");
    l.position.set(wx(p.x) + 0.35, 0.05, wz(p.y));
    l.center.set(0, 0.5);
    scene.add(l);
  }

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
  const camPoses = new Map<string, { rig: THREE.Group; eye: THREE.Vector3; look: THREE.Vector3 }>();
  for (const c of cameras) {
    const room = rooms.find((r) => r.id === c.roomId);
    const aimX = room ? room.x + room.w / 2 : PLAN_W / 2;
    const aimY = room ? room.y + room.h / 2 : PLAN_H / 2;
    const rig = new THREE.Group();
    rig.position.set(wx(c.x), WALL_H, wz(c.y));
    rig.rotation.y = -Math.atan2(aimY - c.y, aimX - c.x); // +x locale verso il centro della stanza
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
    const led = new THREE.Mesh(ledGeo, camLed);
    led.position.set(0.262, -0.045, 0.035);
    const fov = new THREE.Mesh(fovGeo, coneMat);
    fov.position.x = 0.265;
    head.add(body, hood, lens, led, fov);
    rig.add(base, stem, joint, head);
    rig.traverse((m) => m !== fov && (m.castShadow = true));
    scene.add(rig);
    rig.updateMatrixWorld(true);
    camPoses.set(c.id, { rig, eye: head.localToWorld(new THREE.Vector3(0.28, 0, 0)), look: head.localToWorld(new THREE.Vector3(5, 0, 0)) });
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "lbl-btn";
    btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5"/><rect x="2" y="6" width="14" height="12" rx="2"/></svg>${c.id}`;
    btn.setAttribute("aria-label", `Open ${c.id}`);
    if (picking) btn.style.pointerEvents = "none";
    btn.addEventListener("click", () => post({ type: "camera", id: c.id }));
    btn.addEventListener("pointerdown", (e) => e.stopPropagation());
    const l = new CSS2DObject(btn);
    l.position.set(wx(c.x), WALL_H + 0.1, wz(c.y));
    l.center.set(0.5, 1);
    scene.add(l);
  }

  // eventi attivi = waypoint: segnaposto che fluttua sopra il punto, raggio verso terra, bersaglio a terra che pulsa
  // e un'etichetta con cosa è successo. Rosso alta priorità, ambra il resto.
  const pings: THREE.Mesh[] = [];
  const edgeLabels: CSS2DObject[] = []; // etichette lunghe da tenere dentro lo schermo
  const pinsGroup = new THREE.Group();
  scene.add(pinsGroup);
  const pinLabels: CSS2DObject[] = [];
  const pinDisposables: { dispose: () => void }[] = [];
  const pinKeep = <T extends { dispose: () => void }>(x: T) => (pinDisposables.push(x), x);
  const pins: THREE.Group[] = [];
  const pinHeadGeo = keep(new THREE.SphereGeometry(0.2, 28, 20));
  const pinTipGeo = keep(new THREE.ConeGeometry(0.17, 0.42, 28).rotateX(Math.PI).translate(0, -0.25, 0));
  const pinDotGeo = keep(new THREE.SphereGeometry(0.085, 20, 14));
  const beamGeo = keep(new THREE.CylinderGeometry(0.012, 0.012, 1, 8).translate(0, 0.5, 0));
  const targetGeo = keep(new THREE.RingGeometry(0.22, 0.3, 40).rotateX(-Math.PI / 2));
  const discGeo = keep(new THREE.CircleGeometry(0.12, 32).rotateX(-Math.PI / 2));
  const pingGeo = keep(new THREE.RingGeometry(0.3, 0.38, 48).rotateX(-Math.PI / 2));
  const whiteMat = keep(new THREE.MeshBasicMaterial({ color: "#ffffff" }));
  const addPin = (e: MapEvent) => {
    const color = e.priority === "alta" ? "#f87171" : "#fcd34d";
    const solidMat = pinKeep(new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.7, roughness: 0.35 }));
    const flatMat = pinKeep(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.85 }));
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
    pinsGroup.add(pin);
    pins.push(pin);
    const beam = new THREE.Mesh(beamGeo, pinKeep(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.45 })));
    beam.position.set(x, 0, z);
    beam.scale.y = 0.95;
    pinsGroup.add(beam);
    const target = new THREE.Mesh(targetGeo, flatMat);
    target.position.set(x, 0.03, z);
    const disc = new THREE.Mesh(discGeo, flatMat);
    disc.position.set(x, 0.031, z);
    pinsGroup.add(target, disc);
    for (const delay of [0, 0.5]) {
      const ping = new THREE.Mesh(pingGeo, pinKeep(new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.6 })));
      ping.position.set(x, 0.03, z);
      ping.userData.delay = delay;
      pinsGroup.add(ping);
      pings.push(ping);
    }
    const tag = document.createElement("div");
    tag.className = "lbl-event";
    tag.style.borderColor = color;
    const idEl = document.createElement("span");
    idEl.className = "mono";
    idEl.style.color = color;
    idEl.textContent = e.id;
    const what = document.createElement("span");
    what.textContent = e.anomaly;
    tag.append(idEl, what);
    const l = new CSS2DObject(tag);
    l.position.set(0, 0.32, 0);
    l.center.set(0.5, 1);
    pin.add(l);
    edgeLabels.push(l);
    pinLabels.push(l);
  };
  const drawEvents = (list: MapEvent[]) => {
    for (const l of pinLabels) {
      l.element.remove();
      edgeLabels.splice(edgeLabels.indexOf(l), 1);
    }
    pinLabels.length = pings.length = pins.length = 0;
    pinsGroup.clear();
    pinDisposables.splice(0).forEach((x) => x.dispose());
    list.filter((e) => ACTIVE.has(e.status)).forEach(addPin);
  };
  drawEvents(events);
  api.setEvents = drawEvents;

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

  const dogObjs = dogs.map((d, i) => {
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

    // etichetta cliccabile: segue il cane con la camera
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "lbl-dog";
    const nameEl = document.createElement("span");
    nameEl.textContent = d.name;
    // batteria: l'icona si svuota col livello; verde, rossa sotto il 30%
    const level = d.battery ?? 0;
    // verde, arancione sotto il 50%, rossa dal 30% in giù: come BatteryTag
    const low = d.battery != null ? (d.battery <= 30 ? " low" : d.battery < 50 ? " mid" : "") : "";
    const batt = document.createElement("span");
    batt.className = `batt${low}`;
    batt.innerHTML = `<span class="cell"><i style="width:${level}%"></i></span><span class="mono">${d.battery == null ? "—" : d.battery + "%"}</span>`;
    btn.append(nameEl, batt);
    btn.setAttribute("aria-label", `Follow ${d.name}, battery ${d.battery ?? "unknown"}%`);
    btn.addEventListener("click", () => post({ type: "dog", id: d.id }));
    btn.addEventListener("pointerdown", (e) => e.stopPropagation());
    const l = new CSS2DObject(btn);
    l.position.y = 1.0;
    l.center.set(0.5, 1);
    edgeLabels.push(l);

    const root = new THREE.Group();
    root.add(body, halo, l);
    scene.add(root);
    const live = d.route.length === 0;
    const start = live ? { x: d.x ?? 0, y: d.y ?? 0 } : along(d.route, i * 300);
    const ahead = live ? start : along(d.route, i * 300 + 40);
    return {
      d,
      root,
      body,
      halo,
      legs,
      lidar,
      dist: i * 300, // cm percorsi lungo il giro
      heading: live ? (d.heading ?? 0) : Math.atan2(ahead.y - start.y, ahead.x - start.x),
      phase: i * 0.37,
      // ronda = segue il giro; mano = guidato da chi ha preso il controllo; ritorno = ripercorre la strada fatta fino al giro
      // dal vivo = segue la posizione che arriva dal server
      mode: (live ? "live" : "ronda") as "ronda" | "mano" | "ritorno" | "live",
      goal: { x: start.x, y: start.y, heading: d.heading ?? 0, speed: 0 },
      pos: { x: start.x, y: start.y }, // cm sulla pianta
      trail: [] as { x: number; y: number }[],
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
    // in verticale comanda la larghezza; l'altezza utile è quella che lasciano libera gli overlay
    const free = Math.max(el.clientHeight - insets.top - insets.bottom, 120) / Math.max(el.clientHeight, 1);
    const fit = Math.max(h / free, w / camera.aspect);
    const dist = Math.max((fit / 2 / Math.tan(THREE.MathUtils.degToRad(camera.fov / 2))) * (r ? 1.2 : 1.02), 8);
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
  api.reset = reset;
  api.focusRoom = (roomId) => {
    fly = viewFor(roomId);
    outlines.forEach((l, id) => (l.visible = id === roomId));
  };

  const resize = () => {
    const { clientWidth: w, clientHeight: h } = el;
    if (!w || !h) return;
    camera.setViewOffset(w, h, 0, viewShift, w, h);
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
    if (!p || Math.hypot(e.clientX - p.x, e.clientY - p.y) > 8) return; // col dito serve un po' più di tolleranza
    // modalità «scegli i punti»: clic sul pavimento → punto sulla pianta (null se lì c'è un muro o un oggetto)
    if (cfg.pick) {
      const r = renderer.domElement.getBoundingClientRect();
      ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
      ray.setFromCamera(ndc, camera);
      const hitFloor = ray.ray.intersectPlane(groundPlane, groundHit);
      if (!hitFloor) return;
      const q = { x: Math.round(groundHit.x * 100 + PLAN_W / 2), y: Math.round(groundHit.z * 100 + PLAN_H / 2) };
      post({ type: "pick", point: blocked(q.x, q.y) ? null : q });
      return;
    }
    const id = dogAt(e);
    if (id) post({ type: "dog", id });
  };
  renderer.domElement.addEventListener("pointerdown", onPress);
  renderer.domElement.addEventListener("pointerup", onRelease);

  // percorso scelto a mano (nuova automazione): linea arancio, rossa tratteggiata dove passa in un muro; A, B, C… sui punti
  const routeGroup = new THREE.Group();
  scene.add(routeGroup);
  const pickMarkGeo = keep(new THREE.CylinderGeometry(0.16, 0.16, 0.04, 28));
  const pickOkMat = keep(new THREE.LineBasicMaterial({ color: accent }));
  const pickBadMat = keep(new THREE.LineDashedMaterial({ color: "#f87171", dashSize: 0.2, gapSize: 0.12 }));
  const pickMarkMat = keep(new THREE.MeshStandardMaterial({ color: accent, emissive: accent, emissiveIntensity: 0.6 }));
  api.setRoute = (pts, loop, seq) => {
    routeGroup.children.forEach((c) => {
      if (c instanceof THREE.Line) c.geometry.dispose();
      if (c instanceof CSS2DObject) c.element.remove();
    });
    routeGroup.clear();
    pts.forEach((p, i) => {
      const m = new THREE.Mesh(pickMarkGeo, pickMarkMat);
      m.position.set(wx(p.x), 0.03, wz(p.y));
      const tag = document.createElement("div");
      tag.className = "lbl-route mono";
      tag.textContent = String.fromCharCode(65 + i);
      const l = new CSS2DObject(tag);
      l.position.set(wx(p.x), 0.45, wz(p.y));
      l.center.set(0.5, 1);
      routeGroup.add(m, l);
    });
    const legs = pts.slice(1).map((p, i) => [pts[i], p]);
    if (loop && pts.length > 1) legs.push([pts[pts.length - 1], pts[0]]);
    const bad: number[] = [];
    legs.forEach(([a, b], i) => {
      const ok = segmentClear(a, b);
      if (!ok) bad.push(i);
      const line = new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(wx(a.x), 0.05, wz(a.y)), new THREE.Vector3(wx(b.x), 0.05, wz(b.y))]),
        ok ? pickOkMat : pickBadMat,
      );
      if (!ok) line.computeLineDistances();
      routeGroup.add(line);
    });
    post({ type: "route", seq, bad });
  };

  // telecamera di bordo: stesso contesto WebGL della mappa. A tutto schermo sostituisce la mappa, in «Segui» si disegna nel riquadro.
  const povCam = new THREE.PerspectiveCamera(70, 16 / 9, 0.05, 80);
  // grandangolo da telecamera di sorveglianza
  const camCam = new THREE.PerspectiveCamera(62, 16 / 9, 0.05, 80);
  const eye = new THREE.Vector3();
  const look = new THREE.Vector3();

  // finché il cane vero non manda la posizione, la simuliamo lungo il suo percorso
  const start = performance.now();
  let last = start;
  let raf = 0;
  const delta = new THREE.Vector3();
  const offset = new THREE.Vector3();
  const tick = (now: number) => {
    const t = (now - start) / 1000;
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
      for (const o of dogObjs) {
      const driven = o.mode !== "live" && drive?.dogId === o.d.id;
      if (driven && o.mode !== "mano") {
        // preso il controllo: lascia il giro (se tornava, continua la stessa scia)
        if (o.mode === "ronda") o.trail = [{ ...o.pos }];
        o.mode = "mano";
      } else if (!driven && o.mode === "mano") o.mode = "ritorno";

      let speed: number; // cm/s, per l'andatura
      let dir = 1; // -1 quando cammina all'indietro
      if (o.mode === "live") {
        // la posizione arriva 4 volte al secondo: il cane la insegue, così cammina invece di saltare
        const g = o.goal,
          dx = g.x - o.pos.x,
          dy = g.y - o.pos.y;
        const k = Math.hypot(dx, dy) > 300 ? 1 : 1 - Math.exp(-dt * 7); // oltre i 3 m è un teletrasporto (Reset)
        o.pos.x += dx * k;
        o.pos.y += dy * k;
        o.heading = wrapAngle(o.heading + wrapAngle(g.heading - o.heading) * k);
        speed = g.speed;
      } else if (o.mode === "mano") {
        const h = drive!.held;
        const fwd = (h.has("avanti") ? DRIVE_FWD : 0) - (h.has("indietro") ? DRIVE_BACK : 0);
        const side = ((h.has("destra") ? 1 : 0) - (h.has("sinistra") ? 1 : 0)) * DRIVE_SIDE;
        const turn = (h.has("ruota-dx") ? 1 : 0) - (h.has("ruota-sx") ? 1 : 0);
        o.heading = wrapAngle(o.heading + turn * DRIVE_TURN * dt);
        const c = Math.cos(o.heading),
          s = Math.sin(o.heading);
        // avanti = (cos, sin) sulla pianta; destra = (-sin, cos)
        const mx = (c * fwd - s * side) * dt;
        const my = (s * fwd + c * side) * dt;
        // contro un muro scivola lungo il muro; se è già incastrato può comunque uscire
        const stuck = blocked(o.pos.x, o.pos.y);
        const ok = (x: number, y: number) => stuck || !blocked(x, y);
        const before = { ...o.pos };
        if (ok(o.pos.x + mx, o.pos.y + my)) {
          o.pos.x += mx;
          o.pos.y += my;
        } else if (ok(o.pos.x + mx, o.pos.y)) o.pos.x += mx;
        else if (ok(o.pos.x, o.pos.y + my)) o.pos.y += my;
        const moved = Math.hypot(o.pos.x - before.x, o.pos.y - before.y);
        speed = Math.max(moved / Math.max(dt, 1e-3), turn ? 25 : 0);
        if (fwd < 0 && !side) dir = -1;
        const tip = o.trail[o.trail.length - 1];
        if (!tip || Math.hypot(o.pos.x - tip.x, o.pos.y - tip.y) >= TRAIL_STEP) o.trail.push({ ...o.pos });
      } else if (o.mode === "ritorno") {
        // ripercorre la scia al contrario: non passa nei muri e torna dove ha lasciato il giro
        const tgt = o.trail[o.trail.length - 1];
        if (!tgt) {
          o.mode = "ronda";
          speed = 0;
        } else {
          const dx = tgt.x - o.pos.x,
            dy = tgt.y - o.pos.y;
          const d = Math.hypot(dx, dy);
          const step = SPEED * dt;
          if (d <= step) {
            o.pos = { ...tgt };
            o.trail.pop();
          } else {
            o.pos.x += (dx / d) * step;
            o.pos.y += (dy / d) * step;
          }
          if (d > 1) o.heading += wrapAngle(Math.atan2(dy, dx) - o.heading) * (1 - Math.exp(-dt * 6));
          speed = SPEED;
        }
      } else {
        // rallenta negli angoli, così la curva si vede
        const here = along(o.d.route, o.dist);
        const base = o.d.state === "base" ? 0 : SPEED * (o.d.state === "missione" ? 0.4 : 1);
        speed = base * THREE.MathUtils.clamp(here.corner / 70, 0.35, 1);
        o.dist += speed * dt;
        const p = along(o.d.route, o.dist);
        const ahead = along(o.d.route, o.dist + 45);
        o.pos = { x: p.x, y: p.y };
        // guarda un po' più avanti sul percorso e gira con calma
        const target = Math.atan2(ahead.y - p.y, ahead.x - p.x);
        o.heading += wrapAngle(target - o.heading) * (1 - Math.exp(-dt * 6));
      }
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

    // camera che segue il cane scelto
    const followed = following && dogObjs.find((o) => o.d.id === following);
    if (followed) {
      delta
        .copy(followed.root.position)
        .sub(controls.target)
        .multiplyScalar(1 - Math.exp(-dt * 5));
      controls.target.add(delta);
      camera.position.add(delta);
      if (zoom !== null) {
        offset.copy(camera.position).sub(controls.target);
        const len = offset.length();
        const next = len + (zoom - len) * (1 - Math.exp(-dt * 3));
        camera.position.copy(controls.target).add(offset.setLength(next));
        if (Math.abs(next - zoom) < 0.02) zoom = null;
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

    // gli overlay cambiano (card aperte o chiuse): la pianta scivola nel nuovo spazio libero invece di saltare
    const wantShift = (insets.bottom - insets.top) / 2;
    if (Math.abs(wantShift - viewShift) > 0.5) {
      viewShift += (wantShift - viewShift) * (1 - Math.exp(-dt * 10));
      camera.setViewOffset(el.clientWidth, el.clientHeight, 0, viewShift, el.clientWidth, el.clientHeight);
    }

    // telecamera di bordo
    const povDog = pov && dogObjs.find((o) => o.d.id === pov!.dogId);
    const { clientWidth: W, clientHeight: H } = el;
    renderer.shadowMap.needsUpdate = true;
    if (povDog) {
      povDog.root.updateMatrixWorld(true);
      povCam.position.copy(povDog.body.localToWorld(eye.set(0.43, 0.05, 0)));
      povCam.lookAt(povDog.body.localToWorld(look.set(3, -0.35, 0)));
    }
    const drawPov = () => {
      povDog!.halo.visible = false;
      renderer.render(scene, povCam);
      povDog!.halo.visible = true;
    };
    if (povDog && pov!.cover) {
      labels.domElement.style.display = "none";
      povCam.aspect = W / Math.max(H, 1);
      povCam.updateProjectionMatrix();
      drawPov();
    } else {
      labels.domElement.style.display = "";
      renderer.render(scene, camera);
      labels.render(scene, camera);
      // sullo schermo stretto le etichette lunghe scivolano dentro al bordo, restando ancorate al loro punto
      for (const l of edgeLabels) {
        const b = l.element.getBoundingClientRect();
        if (!b.width) continue;
        const anchor = b.left + l.center.x * b.width;
        const left = Math.max(Math.min(anchor - b.width / 2, W - 6 - b.width), 6);
        l.center.x = (anchor - left) / b.width;
      }
      // la ripresa di una telecamera fissa, nel suo riquadro
      const pose = camPov && camPoses.get(camPov.camId);
      if (camPov && pose) {
        const q = camPov.rect;
        camCam.position.copy(pose.eye);
        camCam.lookAt(pose.look);
        camCam.aspect = q.w / q.h;
        camCam.updateProjectionMatrix();
        const y = H - q.y - q.h;
        pose.rig.visible = false;
        renderer.setScissorTest(true);
        renderer.setScissor(q.x, y, q.w, q.h);
        renderer.setViewport(q.x, y, q.w, q.h);
        renderer.render(scene, camCam);
        renderer.setScissorTest(false);
        renderer.setViewport(0, 0, W, H);
        pose.rig.visible = true;
      }
      const r = pov?.rect;
      if (povDog && r && r.w > 1 && r.h > 1) {
        // il riquadro arriva in coordinate della pagina (origine in alto), WebGL conta dal basso
        const y = H - r.y - r.h;
        povCam.aspect = r.w / r.h;
        povCam.updateProjectionMatrix();
        renderer.setScissorTest(true);
        renderer.setScissor(r.x, y, r.w, r.h);
        renderer.setViewport(r.x, y, r.w, r.h);
        drawPov();
        renderer.setScissorTest(false);
        renderer.setViewport(0, 0, W, H);
      }
    }
    raf = paused ? 0 : requestAnimationFrame(tick);
  };

  api.setFollowing = (id) => {
    following = id;
    zoom = id ? FOLLOW_DIST : null;
  };
  api.setDrive = (dogId, held) => {
    drive = dogId ? { dogId, held: new Set(held) } : null;
  };
  // i riquadri delle card sono buchi nell'interfaccia: lì sotto non devono passare le etichette della pianta
  const clipLabels = () => {
    const holes = [pov?.cover ? undefined : pov?.rect, camPov?.rect].filter((r): r is NonNullable<typeof r> => !!r && r.w > 1 && r.h > 1);
    const box = `M0 0H${el.clientWidth}V${el.clientHeight}H0Z`;
    const cut = holes.map((r) => `M${r.x} ${r.y}h${r.w}v${r.h}h${-r.w}Z`).join("");
    labels.domElement.style.clipPath = holes.length ? `path(evenodd, "${box}${cut}")` : "";
  };

  api.setPov = (next) => {
    pov = next;
    clipLabels();
  };
  // la mappa nascosta (altra scheda, pagina sopra) non consuma batteria
  api.setCamPov = (next) => {
    camPov = next;
    clipLabels();
  };
  api.setInsets = (next) => {
    insets = next;
  };
  api.state = () =>
    JSON.stringify({
      following,
      pov,
      paused,
      dogs: dogObjs.map((o) => ({ id: o.d.id, x: o.pos.x, y: o.pos.y, heading: o.heading, mode: o.mode })),
    });
  api.setDogPose = (id, x, y, heading, speed) => {
    const o = dogObjs.find((d) => d.d.id === id);
    if (o) Object.assign(o.goal, { x, y, heading, speed });
  };

  // la strada che il cane sta facendo
  const pathMat = keep(new THREE.LineDashedMaterial({ color: "#34d399", dashSize: 0.18, gapSize: 0.14 }));
  let pathLine: THREE.Line | null = null;
  api.setPath = (pts) => {
    if (pathLine) {
      scene.remove(pathLine);
      pathLine.geometry.dispose();
      pathLine = null;
    }
    const dog = dogObjs[0];
    if (!pts.length || !dog) return;
    pathLine = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([dog.pos, ...pts].map((p) => new THREE.Vector3(wx(p.x), 0.05, wz(p.y)))),
      pathMat,
    );
    pathLine.computeLineDistances();
    scene.add(pathLine);
  };

  // persone e valigie della scena simulata
  const personGeo = keep(new THREE.CapsuleGeometry(0.2, 1.2, 4, 12).translate(0, 0.8, 0));
  const bagGeo = keep(new THREE.BoxGeometry(0.42, 0.62, 0.26).translate(0, 0.31, 0));
  const actorMats = new Map<string, THREE.Material>();
  const actorMat = (color: string) => {
    let m = actorMats.get(color);
    if (!m) actorMats.set(color, (m = keep(new THREE.MeshStandardMaterial({ color, roughness: 0.6 }))));
    return m;
  };
  const actors = new Map<string, THREE.Mesh>();
  api.setActors = (list) => {
    for (const [id, mesh] of actors)
      if (!list.some((a) => a.id === id)) {
        scene.remove(mesh);
        actors.delete(id);
      }
    for (const a of list) {
      let mesh = actors.get(a.id);
      if (!mesh) {
        const color = a.kind === "bag" ? "#b0703a" : a.id === "intruder" ? "#ff9f43" : a.id === "staff" ? "#ffd60a" : "#c9ccd1";
        mesh = new THREE.Mesh(a.kind === "bag" ? bagGeo : personGeo, actorMat(color));
        mesh.castShadow = true;
        actors.set(a.id, mesh);
        scene.add(mesh);
      }
      mesh.position.set(wx(a.x), 0, wz(a.y));
    }
  };

  api.project = (x, y) => {
    const v = new THREE.Vector3(wx(x), 0, wz(y)).project(camera);
    return JSON.stringify({ fx: (v.x + 1) / 2, fy: (1 - v.y) / 2 });
  };
  api.setActive = (active) => {
    if (active === !paused) return;
    paused = !active;
    if (active) {
      last = performance.now();
      raf = requestAnimationFrame(tick);
    }
  };

  raf = requestAnimationFrame(tick);
}

post({ type: "boot" });
