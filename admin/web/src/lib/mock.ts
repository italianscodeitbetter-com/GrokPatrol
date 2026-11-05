// Dati finti per la console. Quando colleghiamo Grok, Frigate, il cane e
// Twilio, questo modulo viene sostituito dalle chiamate alle API vere.

export type TriggerSource = "camera" | "ronda" | "comando";
export type Priority = "alta" | "media" | "bassa";
export type EventStatus = "in_valutazione" | "in_coda" | "missione" | "verifica" | "alert" | "falso_allarme" | "chiuso";
/** `annullata` (fermata prima di finire) e `da_verificare` (allarme partito senza conferma, va rivisto) arrivano dal backend. */
export type Outcome = "anomalia" | "falso_allarme" | "in_corso" | "annullata" | "da_verificare";

// Coordinate in centimetri sulla planimetria di Pad3.step (vedi floorplan.ts): x verso destra, y verso il basso.
export type Room = { id: string; name: string; x: number; y: number; w: number; h: number };
export type Point = { id: string; label: string; roomId: string; x: number; y: number };

export const rooms: Room[] = [
  { id: "sala-1", name: "Room 1", x: 48, y: 58, w: 515, h: 535 },
  { id: "sala-2", name: "Room 2", x: 590, y: 58, w: 1105, h: 780 },
  { id: "sala-3", name: "Room 3", x: 330, y: 840, w: 1365, h: 990 },
  { id: "servizi", name: "Restrooms", x: 70, y: 1845, w: 600, h: 200 },
];

export const patrolPoints: Point[] = [
  { id: "P1", label: "P1", roomId: "sala-2", x: 1110, y: 470 },
  { id: "P2", label: "P2", roomId: "sala-2", x: 1460, y: 300 },
  { id: "P3", label: "P3", roomId: "sala-2", x: 1380, y: 740 },
];

export const cameras: Point[] = [
  { id: "CAM-1", label: "CAM-1", roomId: "sala-1", x: 80, y: 90 },
  { id: "CAM-2", label: "CAM-2", roomId: "sala-2", x: 1650, y: 230 },
  { id: "CAM-3", label: "CAM-3", roomId: "sala-3", x: 1660, y: 1790 },
];

// Etichette in inglese per i valori delle union mostrati a schermo.
export const triggerLabels: Record<TriggerSource, string> = { camera: "Camera", ronda: "Patrol", comando: "Command" };
export const priorityLabels: Record<Priority, string> = { alta: "High", media: "Medium", bassa: "Low" };

export type DogState = "missione" | "ronda" | "base" | "spento";

export type Dog = {
  id: string;
  name: string;
  adapter: "simulato" | "unitree";
  battery: number;
  state: DogState;
  task: string;
  roomId: string;
  /** Percorso in loop seguito dal cane simulato (cm). */
  route: { x: number; y: number }[];
};

export const dogs: Dog[] = [
  {
    id: "GD-1",
    name: "Unitree Go1 - D1",
    adapter: "simulato",
    battery: 78,
    state: "missione",
    task: "MS-0088 · check east exit",
    roomId: "sala-3",
    route: [
      { x: 580, y: 1470 },
      { x: 870, y: 1470 },
      { x: 870, y: 1760 },
      { x: 580, y: 1760 },
    ],
  },
  {
    id: "GD-2",
    name: "Unitree Go1 - D2",
    adapter: "simulato",
    battery: 41,
    state: "ronda",
    task: "Patrol Room 2 · P1 → P2 → P3",
    roomId: "sala-2",
    route: [
      { x: 1110, y: 470 },
      { x: 1460, y: 300 },
      { x: 1380, y: 740 },
    ],
  },
];

/** Bot registrati ma spenti: compaiono negli elenchi (disattivati), non sulla mappa. */
export const offlineDogs: Dog[] = [
  { id: "GD-3", name: "Unitree Go1 - D3", adapter: "simulato", battery: 100, state: "spento", task: "Off · docked at base", roomId: "servizi", route: [] },
  { id: "GD-4", name: "Unitree Go1 - D4", adapter: "simulato", battery: 64, state: "spento", task: "Off · docked at base", roomId: "servizi", route: [] },
  { id: "GD-5", name: "Unitree Go1 - D5", adapter: "simulato", battery: 12, state: "spento", task: "Off · needs charging", roomId: "servizi", route: [] },
];

/** Tutti i bot: quelli accesi (sulla mappa) e quelli spenti. */
export const fleet: Dog[] = [...dogs, ...offlineDogs];

/** Dove si trova adesso il robot (cm sulla pianta): per ora l'inizio del suo giro, o il centro della sua stanza se è spento.
 *  Quando c'è l'adapter vero arriva dalla posizione del cane. */
export function dogSpot(d: Dog): { x: number; y: number } {
  if (d.route[0]) return d.route[0];
  const r = rooms.find((r) => r.id === d.roomId) ?? rooms[0];
  return { x: Math.round(r.x + r.w / 2), y: Math.round(r.y + r.h / 2) };
}

export type Event = {
  id: string;
  time: string;
  source: TriggerSource;
  sourceLabel: string;
  roomId: string;
  x: number;
  y: number;
  anomaly: string;
  priority: Priority;
  status: EventStatus;
  grokDecision: string;
  grokReason: string;
};

export const events: Event[] = [
  {
    id: "EV-0142",
    time: "11:02:14",
    source: "camera",
    sourceLabel: "CAM-3",
    roomId: "sala-3",
    x: 1730, y: 950,
    anomaly: "Abandoned object",
    priority: "alta",
    status: "verifica",
    grokDecision: "Send the dog",
    grokReason: "Backpack left near the exit for over 4 minutes, no associated person in frame.",
  },
  {
    id: "EV-0141",
    time: "10:57:40",
    source: "camera",
    sourceLabel: "CAM-1",
    roomId: "sala-1",
    x: 300, y: 330,
    anomaly: "Person in restricted area",
    priority: "media",
    status: "in_coda",
    grokDecision: "Send the dog",
    grokReason: "Person past the rope of the central display case, posture not consistent with staff.",
  },
  {
    id: "EV-0140",
    time: "10:51:03",
    source: "camera",
    sourceLabel: "CAM-2",
    roomId: "sala-2",
    x: 1250, y: 560,
    anomaly: "Person in restricted area",
    priority: "bassa",
    status: "falso_allarme",
    grokDecision: "Don't send the dog",
    grokReason: "Person with staff badge and uniform: scheduled maintenance.",
  },
  {
    id: "EV-0139",
    time: "10:45:00",
    source: "ronda",
    sourceLabel: "Patrol Room 2",
    roomId: "sala-2",
    x: 1380, y: 740,
    anomaly: "Scheduled patrol",
    priority: "bassa",
    status: "chiuso",
    grokDecision: "Automatic start",
    grokReason: "Patrol P1 → P2 → P3 completed, no anomalies.",
  },
];

export type LogStep = "Trigger" | "Valutazione" | "Missione" | "Verifica" | "Alert" | "Chiusura";

export const stepLabels: Record<LogStep, string> = {
  Trigger: "Trigger",
  Valutazione: "Assessment",
  Missione: "Mission",
  Verifica: "Verification",
  Alert: "Alert",
  Chiusura: "Closure",
};

export type LogRow = { time: string; eventId: string; step: LogStep; detail: string };

export const log: LogRow[] = [
  { time: "11:02:14", eventId: "EV-0142", step: "Trigger", detail: "CAM-3 · abandoned object · frame #8812" },
  { time: "11:02:16", eventId: "EV-0142", step: "Valutazione", detail: "Grok: send the dog. Backpack left for over 4 min" },
  { time: "11:02:17", eventId: "EV-0142", step: "Missione", detail: "Departed for Room 3, east exit" },
  { time: "11:02:58", eventId: "EV-0142", step: "Missione", detail: "Arrived after 41 s" },
  { time: "11:03:04", eventId: "EV-0142", step: "Verifica", detail: "Grok reports: black backpack on the floor, nobody nearby" },
  { time: "10:57:40", eventId: "EV-0141", step: "Trigger", detail: "CAM-1 · person in restricted area · frame #8790" },
  { time: "10:57:42", eventId: "EV-0141", step: "Valutazione", detail: "Grok: send the dog. Person past the rope" },
  { time: "10:57:43", eventId: "EV-0141", step: "Missione", detail: "Queued: dog busy on EV-0142" },
  { time: "10:51:03", eventId: "EV-0140", step: "Trigger", detail: "CAM-2 · person in restricted area · frame #8755" },
  { time: "10:51:05", eventId: "EV-0140", step: "Valutazione", detail: "Grok: don't send the dog. Staff with badge" },
  { time: "10:51:05", eventId: "EV-0140", step: "Chiusura", detail: "False alarm, no alert" },
];

export type MissionStep = { step: LogStep; time: string | null; detail: string };

export type Mission = {
  id: string;
  eventId: string;
  /** Il cane che ha fatto la missione (o che la farà, se è in coda). */
  dogId: string;
  /** Batteria del cane al momento della missione (%). */
  battery: number;
  /** Cosa ha visto il cane sul posto; null se non è ancora arrivato. */
  sighting: string | null;
  /** Automazione che l'ha fatta partire (AU-…); null = missione custom creata da una persona. */
  automationId: string | null;
  /** Per le custom: chi l'ha creata. */
  createdBy?: string;
  trigger: TriggerSource;
  triggerLabel: string;
  roomId: string;
  status: EventStatus;
  eventTime: string;
  arrivalSeconds: number | null;
  outcome: Outcome;
  steps: MissionStep[];
};

export const missions: Mission[] = [
  {
    id: "MS-0088",
    battery: 78,
    automationId: "AU-01",
    dogId: "GD-1",
    sighting: "Black backpack on the floor near the east exit, nobody nearby",
    eventId: "EV-0142",
    trigger: "camera",
    triggerLabel: "CAM-3 · abandoned object",
    roomId: "sala-3",
    status: "verifica",
    eventTime: "11:02:14",
    arrivalSeconds: 41,
    outcome: "in_corso",
    steps: [
      { step: "Trigger", time: "11:02:14", detail: "CAM-3, abandoned object, frame #8812" },
      { step: "Valutazione", time: "11:02:16", detail: "Send the dog: backpack left near the exit for over 4 minutes" },
      { step: "Missione", time: "11:02:58", detail: "Departed 11:02:17, arrived 11:02:58, 41 s" },
      { step: "Verifica", time: "11:03:04", detail: "Black backpack on the floor, nobody nearby. Awaiting confirmation" },
      { step: "Alert", time: null, detail: "Not sent yet" },
      { step: "Chiusura", time: null, detail: "In progress" },
    ],
  },
  {
    id: "MS-0087",
    battery: 78,
    automationId: "AU-02",
    dogId: "GD-1",
    sighting: null,
    eventId: "EV-0141",
    trigger: "camera",
    triggerLabel: "CAM-1 · person in restricted area",
    roomId: "sala-1",
    status: "in_coda",
    eventTime: "10:57:40",
    arrivalSeconds: null,
    outcome: "in_corso",
    steps: [
      { step: "Trigger", time: "10:57:40", detail: "CAM-1, person in restricted area, frame #8790" },
      { step: "Valutazione", time: "10:57:42", detail: "Send the dog: person past the display case rope" },
      { step: "Missione", time: "10:57:43", detail: "Queued: dog busy on MS-0088" },
      { step: "Verifica", time: null, detail: "Pending" },
      { step: "Alert", time: null, detail: "Pending" },
      { step: "Chiusura", time: null, detail: "In progress" },
    ],
  },
  {
    id: "MS-0086",
    battery: 64,
    automationId: null,
    createdBy: "Gabriel Spicuglia",
    dogId: "GD-2",
    sighting: "Person sitting on the sculpture plinth",
    eventId: "EV-0137",
    trigger: "comando",
    triggerLabel: "\"patrol room 2\"",
    roomId: "sala-2",
    status: "alert",
    eventTime: "10:31:12",
    arrivalSeconds: 28,
    outcome: "anomalia",
    steps: [
      { step: "Trigger", time: "10:31:12", detail: "Voice command from console: \"patrol room 2\"" },
      { step: "Valutazione", time: "10:31:13", detail: "Grok reads it as: mission to Room 2, point P2" },
      { step: "Missione", time: "10:31:41", detail: "Departed 10:31:13, arrived 10:31:41, 28 s" },
      { step: "Verifica", time: "10:31:47", detail: "Person sitting on the sculpture plinth. Confirmed" },
      { step: "Alert", time: "10:31:50", detail: "SMS to +39 3XX XXX XX01: sent" },
      { step: "Chiusura", time: "10:31:50", detail: "Real anomaly" },
    ],
  },
  {
    id: "MS-0085",
    battery: 71,
    automationId: "AU-01",
    dogId: "GD-2",
    sighting: "Bag belonging to a visitor sitting on the bench",
    eventId: "EV-0135",
    trigger: "camera",
    triggerLabel: "CAM-2 · abandoned object",
    roomId: "sala-2",
    status: "falso_allarme",
    eventTime: "10:12:05",
    arrivalSeconds: 33,
    outcome: "falso_allarme",
    steps: [
      { step: "Trigger", time: "10:12:05", detail: "CAM-2, abandoned object, frame #8601" },
      { step: "Valutazione", time: "10:12:07", detail: "Send the dog: bag on the floor near the bench" },
      { step: "Missione", time: "10:12:40", detail: "Departed 10:12:08, arrived 10:12:40, 33 s" },
      { step: "Verifica", time: "10:12:46", detail: "The bag belongs to a visitor sitting on the bench. Not confirmed" },
      { step: "Alert", time: null, detail: "No alert" },
      { step: "Chiusura", time: "10:12:46", detail: "False alarm" },
    ],
  },
  {
    id: "MS-0084",
    battery: 83,
    automationId: "AU-03",
    dogId: "GD-2",
    sighting: "No anomalies at P1, P2, P3",
    eventId: "EV-0133",
    trigger: "ronda",
    triggerLabel: "Patrol Room 2 · P1 → P2 → P3",
    roomId: "sala-2",
    status: "chiuso",
    eventTime: "09:45:00",
    arrivalSeconds: 22,
    outcome: "falso_allarme",
    steps: [
      { step: "Trigger", time: "09:45:00", detail: "Scheduled patrol, 3 points" },
      { step: "Valutazione", time: "09:45:00", detail: "Automatic start, no assessment" },
      { step: "Missione", time: "09:47:10", detail: "P1 22 s, P2 31 s, P3 27 s" },
      { step: "Verifica", time: "09:47:15", detail: "No anomalies at the three points" },
      { step: "Alert", time: null, detail: "No alert" },
      { step: "Chiusura", time: "09:47:15", detail: "Patrol completed" },
    ],
  },
];

export type AlertSent = {
  time: string;
  missionId: string;
  /** Console e Telegram sono i canali del backend (admin/backend/app/alerts.py). */
  channel: "SMS" | "Chiamata" | "GrokBot" | "Console" | "Telegram";
  to: string;
  text: string;
  delivered: boolean;
};

export const channelLabels: Record<AlertSent["channel"], string> = { SMS: "SMS", Chiamata: "Call", GrokBot: "GrokBot", Console: "Console", Telegram: "Telegram" };

export const alerts: AlertSent[] = [
  {
    time: "11:03:10",
    missionId: "MS-0088",
    channel: "GrokBot",
    to: "Grok chat · Control room",
    text: "Room 3, 11:02: black backpack near the east exit, nobody nearby. Dog on site, frame attached. Reply to send it back on patrol.",
    delivered: true,
  },
  {
    time: "10:31:50",
    missionId: "MS-0086",
    channel: "SMS",
    to: "+39 3XX XXX XX01",
    text: "Room 2, 10:31: person sitting on the sculpture plinth. Verified by the dog, frame attached.",
    delivered: true,
  },
  {
    time: "08:58:21",
    missionId: "MS-0079",
    channel: "Chiamata",
    to: "+39 3XX XXX XX01",
    text: "Room 3, 08:57: abandoned backpack near the east exit, nobody nearby.",
    delivered: true,
  },
];

export const shift = {
  /** Giorno del turno (YYYY-MM-DD): per ora i dati finti esistono solo per questo giorno. */
  day: "2026-11-04",
  label: "Morning shift · 4 November",
  name: "Morning shift",
  date: "4 November",
  start: "08:00",
  end: "14:00",
  events: 14,
  confirmed: 3,
  falseAlarmsBlocked: 9,
  falseAlarmsForwarded: 0,
  avgArrivalSeconds: 31,
  logCompleteness: 100,
};

export type Automation = {
  id: string;
  name: string;
  /** Quando parte. */
  trigger: string;
  /** Cosa fa quando parte. */
  action: string;
  /** Ora in cui parte (HH:MM); null = parte quando succede qualcosa. */
  startsAt: string | null;
  /** Se parte a un'ora: quanto si ripete («Every day, every hour until 13:45»). */
  repeats?: string;
  /** Il robot dell'automazione: c'è sempre. */
  dogId: string;
  /** Il percorso, se l'automazione ne ha uno (cm sulla pianta, A, B, C…). */
  route?: { x: number; y: number }[];
  loop?: boolean;
  active: boolean;
  lastRun: string | null;
  runsToday: number;
};

export const automations: Automation[] = [
  {
    id: "AU-01",
    startsAt: null,
    name: "Abandoned object",
    trigger: "A camera sees an object left for over 3 minutes",
    action: "Grok assesses the frame and, if needed, sends the nearest dog to check",
    dogId: "GD-1",
    active: true,
    lastRun: "11:02:14",
    runsToday: 4,
  },
  {
    id: "AU-02",
    startsAt: null,
    name: "Person in restricted area",
    trigger: "A camera sees a person past a rope",
    action: "Grok ignores badged staff, otherwise sends the dog",
    dogId: "GD-1",
    active: true,
    lastRun: "10:57:40",
    runsToday: 6,
  },
  {
    id: "AU-03",
    startsAt: "08:45",
    repeats: "Every day, every hour until 13:45",
    name: "Patrol Room 2",
    trigger: "Every hour, 08:45–13:45",
    action: "The dog visits P1, P2 and P3 and reports what it sees",
    dogId: "GD-2",
    route: [
      { x: 1110, y: 470 },
      { x: 1460, y: 300 },
      { x: 1380, y: 740 },
    ],
    loop: true,
    active: true,
    lastRun: "10:45:00",
    runsToday: 3,
  },
  {
    id: "AU-04",
    startsAt: null,
    name: "Alert the supervisor",
    trigger: "The dog confirms an anomaly",
    action: "SMS to the supervisor on shift; call if no reply within 2 minutes",
    dogId: "GD-1",
    active: true,
    lastRun: "10:31:50",
    runsToday: 1,
  },
  {
    id: "AU-05",
    startsAt: "22:00",
    repeats: "Every day, every 30 min until 06:00",
    name: "Night patrol",
    trigger: "Every 30 minutes, 22:00–06:00",
    action: "The dog covers all rooms and returns to base to recharge",
    dogId: "GD-2",
    active: false,
    lastRun: null,
    runsToday: 0,
  },
];

export const automationName = (id: string) => automations.find((a) => a.id === id)?.name ?? id;

export const dogName = (id: string) => fleet.find((d) => d.id === id)?.name ?? id;

export const roomName = (id: string) => rooms.find((r) => r.id === id)?.name ?? id;
