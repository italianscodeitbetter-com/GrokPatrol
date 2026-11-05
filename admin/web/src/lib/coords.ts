import { PLAN_H, PLAN_W } from "@/lib/floorplan";

// Frame del sito (metri, quelli di config/site.pad3.json e del backend: x a destra, y in su, yaw antiorario da +x)
// ↔ pianta di floorplan.ts (centimetri, origine in alto a sinistra, y in giù).
//
// Come è stata ricavata la trasformazione (non a occhio):
// - sim/assets/site/plan.json (sezione dello stesso Pad3.step, in metri) ha bounds [-0.4, -2.15, 17.1, 18.4]:
//   17,5 × 20,55 m, esattamente PLAN_W × PLAN_H = 1750 × 2055 cm → scala 100, nessuna rotazione.
// - Il muro est del padiglione in plan.json va da (16.7, 0) a (17.1, 7.25); in PLAN_WALLS c'è
//   "L1710 1840 … L1710 1115L1750 1115L1750 1880": x_cm = (x + 0.4)·100 e y_cm = (18.4 − y)·100, cioè y ribaltata.
// - La stanza interna di site.pad3.json (x 0…5.3, y 12.26…18) cade su x 40…570, y 614…40 cm: è il rettangolo
//   "L40 614 … L569 40" di PLAN_WALLS.
// - Controllo automatico: 112 dei 117 vertici di PLAN_WALLS coincidono al centimetro con i vertici di plan.json
//   trasformati così (gli altri sono dettagli dei pilastri tagliati a un'altra quota).
// Il ribaltamento della y inverte il verso degli angoli: sulla pianta l'heading (avanti = (cos, sin) in cm) è −yaw.
const X0 = -0.4; // m: bordo sinistro della pianta
const Y1 = 18.4; // m: bordo alto della pianta

export type PlanXY = { x: number; y: number };

export const siteToPlan = (x: number, y: number): PlanXY => ({ x: (x - X0) * 100, y: (Y1 - y) * 100 });
export const planToSite = (p: PlanXY): { x: number; y: number } => ({ x: p.x / 100 + X0, y: Y1 - p.y / 100 });

/** yaw del sito (rad, antiorario) → heading sulla pianta (rad, con la y in giù). Vale anche al contrario. */
export const yawToHeading = (yaw: number) => -yaw;
export const headingToYaw = (h: number) => -h;

/** Spot «home» di config/site.pad3.json (8.3, 1.6): dove disegnare il cane finché il backend non risponde. */
export const HOME_PLAN = siteToPlan(8.3, 1.6);
export const HOME_HEADING = yawToHeading(1.571);

// controllo di coerenza: la pianta copre esattamente i bounds di plan.json
export const PLAN_BOUNDS_M = { x0: X0, y0: Y1 - PLAN_H / 100, x1: X0 + PLAN_W / 100, y1: Y1 };
