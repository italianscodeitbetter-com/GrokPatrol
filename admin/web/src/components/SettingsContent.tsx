"use client";

import { useRef, useState } from "react";
import { Pencil, Upload } from "lucide-react";
import { Avatar } from "@/components/Avatar";
import { KeyRow } from "@/components/KeyRow";
import { BatteryTag } from "@/components/robot";
import { GhostButton, Group, Key, Row, Select, TextInput } from "@/components/settings-ui";
import { Badge } from "@/components/ui";
import { CameraFeed } from "@/components/CameraFeed";
import { command, qrUrl, useLive, type Action } from "@/lib/backend";
import { toggleGrokBot, useGrokBot } from "@/lib/grokbot";
import { cameras, fleet, roomName } from "@/lib/mock";
import { profile } from "@/lib/profile";
import type { SettingsSection } from "@/lib/settings";

/** Il contenuto di ogni sezione delle impostazioni (nel modale). */
export function SettingsContent({ section }: { section: SettingsSection }) {
  switch (section) {
    case "general":
      return (
        <>
          <Group title="Account">
            <Row label="Name" htmlFor="name">
              <TextInput id="name" defaultValue={profile.name} />
            </Row>
            <Row label="Email">
              <span className="text-[15px] text-muted">{profile.email}</span>
            </Row>
            <Row label="Profile picture">
              <Avatar className="size-9" />
            </Row>
          </Group>

          <Group title="Shift">
            <Row label="Role">
              <span className="text-[15px] text-muted">{profile.role}</span>
            </Row>
            <Row label="Shift">
              <span className="text-[15px] text-muted">{profile.shift}</span>
            </Row>
          </Group>

          <Group title="Keys" note="Without a key, Grok runs on mock answers and alerts are written to the log instead of being sent.">
            <KeyRow name="xAI" hint="Grok evaluates events, reads commands, describes what the dog sees and writes the alert." placeholder="xai-••••••••••••••••" />
            <KeyRow name="Twilio" hint="Sends the alert as a text message or a voice call." placeholder="AC••••••••••••••••" />
          </Group>
        </>
      );

    case "alerts":
      return (
        <>
          <Group title="Messages and calls" note="Alerts only go to the test number and to GrokBot. No real calls to security or the police.">
            <Row label="Test number" hint="Receives every alert" htmlFor="test-number">
              <TextInput id="test-number" type="tel" defaultValue="+39 3XX XXX XX01" />
            </Row>
            <Row label="Channel" htmlFor="channel">
              <Select id="channel" defaultValue="sms">
                <option value="sms">Text message</option>
                <option value="call">Voice call</option>
                <option value="grokbot">GrokBot message</option>
              </Select>
            </Row>
            <Row label="Also send to GrokBot" hint="Every alert also lands in the Grok chat, where you can reply to the dog" htmlFor="alert-grokbot">
              <Select id="alert-grokbot" defaultValue="yes">
                <option value="yes">Always</option>
                <option value="no">Never</option>
              </Select>
            </Row>
          </Group>
          <Group title="Content">
            <Row label="Attach frame" hint="Adds the dog's frame to the message" htmlFor="frame">
              <Select id="frame" defaultValue="yes">
                <option value="yes">Always</option>
                <option value="no">Never</option>
              </Select>
            </Row>
          </Group>
        </>
      );

    case "bots":
      return (
        <>
          <BotsList />
        </>
      );

    case "grokbot":
      return <GrokBotSettings />;

    case "cameras":
      return (
        <>
          <LiveCameras />
          <Group title="Detection" note="Grok reads each camera event and decides whether to send the dog.">
          <Row label="Event source" htmlFor="source">
            <TextInput id="source" defaultValue="http://localhost:5000" />
          </Row>
          <Row label="Detector" htmlFor="detector">
            <Select id="detector" defaultValue="frigate">
              <option value="frigate">Frigate</option>
            </Select>
          </Row>
          <Row label="Anomalies to report" hint="Person in a restricted area, abandoned object">
            <span className="text-[15px] text-muted">2 types</span>
          </Row>
        </Group>
        </>
      );

    case "shortcuts":
      return (
        <>
          {shortcuts.map((g) => (
            <Group key={g.group} title={g.group}>
              {g.items.map((x) => (
                <Row key={x.what} label={x.what}>
                  <span className="flex items-center gap-1.5">
                    {x.keys.map((k) => (
                      <Key key={k} k={k} />
                    ))}
                  </span>
                </Row>
              ))}
            </Group>
          ))}
        </>
      );
  }
}

// ── Bots ──────────────────────────────────────────────
type Adapter = "sim" | "unitree" | "ros2";
type Robot = { id: string; name: string; model: string; adapter: Adapter; battery: number | null; status: "on" | "connecting" | "off" };

const adapterLabels: Record<Adapter, string> = {
  sim: "Simulated",
  unitree: "Unitree (unitree_sdk2_python)",
  ros2: "Unitree (go2_ros2_sdk)",
};

// il Go1 vero (o simulato) arriva dal backend: vedi LiveRobot. Qui restano solo i robot importati da file.
const initialRobots: Robot[] = [];

const fieldCls =
  "h-9 w-full rounded-lg bg-panel px-3 text-sm text-ink placeholder:text-faint outline-none ring-1 ring-transparent transition focus:ring-[#3a3a3a]";

/** I robot: importarli da un file, modificarli, collegarli. Per ora tutto resta in questa finestra. */
function BotsList() {
  const [robots, setRobots] = useState(initialRobots);
  const [editing, setEditing] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);

  const update = (id: string, patch: Partial<Robot>) => setRobots((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)));

  const toggle = (r: Robot) => {
    if (r.status !== "off") return update(r.id, { status: "off" });
    update(r.id, { status: "connecting" });
    setTimeout(() => update(r.id, { status: "on" }), 1200);
  };

  // file JSON con { name, model?, adapter? } oppure un elenco di robot
  const importFile = async (f: File) => {
    try {
      const data = JSON.parse(await f.text());
      const list: unknown[] = Array.isArray(data) ? data : [data];
      const added: Robot[] = list.map((x, i) => {
        const o = x as Partial<Record<"name" | "model" | "adapter", unknown>>;
        if (typeof o.name !== "string" || !o.name.trim()) throw new Error("missing name");
        const adapter = (["sim", "unitree", "ros2"] as const).find((a) => a === o.adapter) ?? "sim";
        return {
          id: `GD-${robots.length + i + 1}`,
          name: o.name.trim(),
          model: typeof o.model === "string" ? o.model : "Unitree Go1",
          adapter,
          battery: null,
          status: "off",
        };
      });
      setRobots((rs) => [...rs, ...added]);
      setNote(`Imported ${added.length} ${added.length === 1 ? "robot" : "robots"} from ${f.name}. Connect them to start.`);
    } catch {
      setNote(`Couldn't read ${f.name}: use a JSON file with at least a "name" for each robot.`);
    }
  };

  return (
    <section className="mb-12">
      <div className="mb-3 flex items-center justify-between gap-3 px-6">
        <h2 className="text-[15px] font-medium">Robots</h2>
        <input
          ref={file}
          type="file"
          accept="application/json,.json"
          className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) importFile(f);
            e.target.value = "";
          }}
        />
        <GhostButton onClick={() => file.current?.click()}>
          <span className="flex items-center gap-2">
            <Upload className="size-4" strokeWidth={1.75} /> Import robot
          </span>
        </GhostButton>
      </div>
      <div className="divide-y divide-line rounded-2xl border border-line bg-white/[0.015]">
        <LiveRobot />
        {robots.map((r) =>
          editing === r.id ? (
            <form
              key={r.id}
              className="grid gap-3 px-6 py-4 sm:grid-cols-3"
              onSubmit={(e) => {
                e.preventDefault();
                const data = new FormData(e.currentTarget);
                update(r.id, {
                  name: String(data.get("name") || r.name),
                  model: String(data.get("model") || r.model),
                  adapter: data.get("adapter") as Adapter,
                });
                setEditing(null);
              }}
            >
              <label className="grid gap-1 text-sm text-muted">
                Name
                <input name="name" defaultValue={r.name} required autoFocus className={fieldCls} />
              </label>
              <label className="grid gap-1 text-sm text-muted">
                Model
                <input name="model" defaultValue={r.model} className={fieldCls} />
              </label>
              <label className="grid gap-1 text-sm text-muted">
                Adapter
                <select name="adapter" defaultValue={r.adapter} className={fieldCls}>
                  {Object.entries(adapterLabels).map(([v, l]) => (
                    <option key={v} value={v}>
                      {l}
                    </option>
                  ))}
                </select>
              </label>
              <div className="flex justify-end gap-2 sm:col-span-3">
                <button type="button" onClick={() => setEditing(null)} className="rounded-lg px-3 py-2 text-sm text-muted hover:bg-hover hover:text-ink">
                  Cancel
                </button>
                <button type="submit" className="rounded-lg bg-ink px-3 py-2 text-sm font-medium text-app hover:opacity-90">
                  Save
                </button>
              </div>
            </form>
          ) : (
            <div key={r.id} className="flex flex-wrap items-center gap-x-6 gap-y-3 px-6 py-3.5">
              <div className="min-w-0 flex-1 basis-56">
                <div className="flex items-center gap-2 text-[15px]">
                  <span
                    className={`size-2 shrink-0 rounded-full ${r.status === "on" ? "bg-ok" : r.status === "connecting" ? "animate-pulse bg-amber-300" : "bg-faint"}`}
                    aria-hidden
                  />
                  <span className="truncate">{r.name}</span>
                </div>
                <p className="mt-0.5 text-sm text-muted">
                  <span className="font-mono">{r.id}</span> · {r.model} · {adapterLabels[r.adapter]}
                </p>
              </div>
              <span className="flex w-20 justify-end">
                {r.battery == null ? <span className="text-sm text-faint">—</span> : <BatteryTag battery={r.battery} />}
              </span>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => setEditing(r.id)}
                  aria-label={`Edit ${r.name}`}
                  title="Edit"
                  className="grid size-9 place-items-center rounded-lg border border-line text-muted transition-colors hover:bg-hover hover:text-ink"
                >
                  <Pencil className="size-4" strokeWidth={1.75} />
                </button>
                <button
                  onClick={() => toggle(r)}
                  disabled={r.status === "connecting"}
                  className={`flex h-9 w-[8.5rem] items-center justify-center gap-2 rounded-lg px-3 text-sm font-medium transition-opacity disabled:opacity-60 ${
                    r.status === "off" ? "bg-ink text-app hover:opacity-90" : "border border-line text-muted hover:bg-hover hover:text-ink"
                  }`}
                >
                  {r.status === "on" ? "Disconnect" : r.status === "connecting" ? "Connecting…" : "Connect"}
                </button>
              </div>
            </div>
          ),
        )}
      </div>
      <p className="mt-2.5 px-6 text-[13px] leading-relaxed text-faint" role="status">
        {note ?? "The real and the simulated dog take the same commands: go to point, frame the scene, report position. Changes stay in this window for now."}
      </p>
    </section>
  );
}

/** Il Go1 collegato al backend: stato live, batteria e i comandi di postura. */
function LiveRobot() {
  const { dog, backendOnline } = useLive();
  const [note, setNote] = useState<string | null>(null);
  const status: Robot["status"] = backendOnline && dog?.connected ? "on" : backendOnline ? "connecting" : "off";
  const adapter: Adapter = dog?.kind === "go1" ? "unitree" : "sim";
  const run = async (action: Action, done: string) => {
    const r = await command(action);
    setNote(r.ok ? done : `Couldn't ${done.toLowerCase()}: ${r.error ?? "error"}`);
  };
  const off = status !== "on";
  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-3 px-6 py-3.5">
      <div className="min-w-0 flex-1 basis-56">
        <div className="flex items-center gap-2 text-[15px]">
          <span
            className={`size-2 shrink-0 rounded-full ${status === "on" ? "bg-ok" : status === "connecting" ? "animate-pulse bg-amber-300" : "bg-faint"}`}
            aria-hidden
          />
          <span className="truncate">Unitree Go1</span>
          {dog && !dog.armed && <Badge tone="red">E-stop</Badge>}
        </div>
        <p className="mt-0.5 text-sm text-muted">
          <span className="font-mono">go1</span> · Unitree Go1 · {adapterLabels[adapter]} ·{" "}
          {status === "on" ? `odom ${dog?.odom}` : status === "connecting" ? "waiting for the dog" : "backend offline"}
        </p>
        {note && (
          <p className="mt-0.5 text-sm text-faint" role="status">
            {note}
          </p>
        )}
      </div>
      <span className="flex w-20 justify-end">
        {dog?.battery == null ? <span className="text-sm text-faint">—</span> : <BatteryTag battery={Math.round(dog.battery)} off={off} />}
      </span>
      <div className="flex flex-wrap items-center gap-2">
        <GhostButton disabled={off} onClick={() => run("stand", "Standing up")}>
          Stand
        </GhostButton>
        <GhostButton disabled={off} onClick={() => run("lie", "Lying down")}>
          Lie down
        </GhostButton>
        <GhostButton disabled={off} onClick={() => run("zero", "Home set here")}>
          Set home here
        </GhostButton>
        {dog && !dog.armed ? (
          <GhostButton disabled={off} onClick={() => run("reset", "Reset")}>
            Reset
          </GhostButton>
        ) : (
          <GhostButton disabled={off} onClick={() => run("estop", "E-stop")}>
            E-stop
          </GhostButton>
        )}
      </div>
    </div>
  );
}

// ── Cameras ───────────────────────────────────────────
/** Le telecamere del backend (fisse e telefoni) e come collegare un telefono. */
function LiveCameras() {
  const { cameras, backendOnline } = useLive();
  const [host, setHost] = useState(() => (typeof window === "undefined" ? "localhost" : location.hostname));
  const phoneUrl = `https://${host || "localhost"}:8443/camera`;
  const [watching, setWatching] = useState<string | null>(null);
  const shown = cameras.find((c) => c.id === watching && c.online);
  return (
    <>
      <Group
        title="Cameras"
        note={backendOnline ? "Each camera sends its events to Grok. The ones Grok can see from a chat are chosen in GrokBot." : "Backend offline: start it to see the cameras."}
      >
        {cameras.map((c) => (
          <Row
            key={c.id}
            label={c.name || c.id}
            hint={[c.id === "dog" ? "On the dog" : c.id, c.zone, c.info?.fps != null ? `${c.info.fps} fps` : null, c.info?.people ? `${c.info.people} people` : null]
              .filter(Boolean)
              .join(" · ")}
          >
            <span className="flex items-center gap-2">
              {backendOnline && c.online && (
                <button
                  onClick={() => setWatching(watching === c.id ? null : c.id)}
                  className="h-8 rounded-lg border border-line px-3 text-sm text-muted transition-colors hover:bg-hover hover:text-ink"
                >
                  {watching === c.id ? "Close" : "Watch"}
                </button>
              )}
              {backendOnline && c.online ? <Badge tone="green">Online</Badge> : <Badge tone="gray">Offline</Badge>}
            </span>
          </Row>
        ))}
        {!cameras.length && (
          <Row label="No cameras" hint={backendOnline ? "Open the phone page below to add one." : "Waiting for the backend"} />
        )}
      </Group>
      {shown && (
        <Group title={`Live preview · ${shown.name || shown.id}`}>
          <div className="aspect-video overflow-hidden rounded-lg bg-black">
            <CameraFeed id={shown.id} alt={`${shown.name || shown.id} live preview`} className="size-full object-contain" />
          </div>
        </Group>
      )}
      <Group title="Add a phone" note="Open the link on the phone (same Wi-Fi), accept the certificate warning and allow the camera. Use the laptop's IP address, not localhost.">
        <Row label="Laptop address" hint="IP of this computer on the local network" htmlFor="cam-host">
          <TextInput id="cam-host" value={host} onChange={(e) => setHost(e.target.value.trim())} placeholder="192.168.1.20" />
        </Row>
        <Row label="Phone page">
          <span className="font-mono text-sm text-muted">{phoneUrl}</span>
        </Row>
        <Row label="QR code" hint="Scan it with the phone">
          {/* eslint-disable-next-line @next/next/no-img-element -- generato dal backend */}
          <img src={qrUrl(phoneUrl)} alt={`QR code for ${phoneUrl}`} className="size-36 rounded-lg bg-white p-2" />
        </Row>
      </Group>
    </>
  );
}

// ── GrokBot ───────────────────────────────────────────
function GrokBotSettings() {
  const status = useGrokBot();
  return (
    <>
      <Group title="Connection" note="With GrokBot connected, you can drive the dogs and start missions directly from a Grok chat.">
        <Row label="GrokBot" hint={status === "on" ? "Connected: Grok can see and drive the bots." : "Not connected"}>
          <button
            onClick={toggleGrokBot}
            disabled={status === "connecting"}
            className={`h-10 w-[9rem] rounded-lg px-4 text-[15px] font-medium transition-opacity disabled:opacity-60 ${
              status === "on" ? "border border-line text-muted hover:bg-hover hover:text-ink" : "bg-ink text-app hover:opacity-90"
            }`}
          >
            {status === "on" ? "Disconnect" : status === "connecting" ? "Connecting…" : "Connect"}
          </button>
        </Row>
      </Group>
      <Group title="What Grok can do">
        <Row label="Drive the bots" hint="Move a dog, stop it, send it to a point" htmlFor="gb-drive">
          <Select id="gb-drive" defaultValue="ask">
            <option value="ask">Ask me first</option>
            <option value="yes">Always</option>
            <option value="no">Never</option>
          </Select>
        </Row>
        <Row label="Start missions" hint="Create a mission from a chat message" htmlFor="gb-missions">
          <Select id="gb-missions" defaultValue="ask">
            <option value="ask">Ask me first</option>
            <option value="yes">Always</option>
            <option value="no">Never</option>
          </Select>
        </Row>
        <Row label="Bots Grok can use" htmlFor="gb-bots">
          <Select id="gb-bots" defaultValue="all">
            <option value="all">All bots</option>
            {fleet.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </Select>
        </Row>
      </Group>
      <Group title="Cameras" note="Grok can show you these cameras in the chat and send a dog to what they see.">
        {cameras.map((c) => (
          <Row key={c.id} label={c.label} hint={roomName(c.roomId)} htmlFor={`gb-${c.id}`}>
            <Select id={`gb-${c.id}`} defaultValue="yes">
              <option value="yes">Grok can see it</option>
              <option value="ask">Ask me first</option>
              <option value="no">Hidden from Grok</option>
            </Select>
          </Row>
        ))}
      </Group>
    </>
  );
}

const shortcuts: { group: string; items: { keys: string[]; what: string }[] }[] = [
  {
    group: "Anywhere",
    items: [
      { keys: ["⌘", ","], what: "Open settings" },
      { keys: ["Esc"], what: "Close menus and dialogs" },
    ],
  },
  {
    group: "Dog control",
    items: [
      { keys: ["↑", "W"], what: "Forward" },
      { keys: ["↓", "S"], what: "Back" },
      { keys: ["←", "A"], what: "Strafe left" },
      { keys: ["→", "D"], what: "Strafe right" },
      { keys: ["Q", "E"], what: "Turn left / right" },
      { keys: ["Space"], what: "Stop" },
    ],
  },
];
