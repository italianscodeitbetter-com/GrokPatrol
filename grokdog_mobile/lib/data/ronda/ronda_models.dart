// I messaggi del server Ronda (server/main.py, server/mission.py) in tipi Dart.
// Il parsing non lancia mai: un campo mancante o del tipo sbagliato diventa null o un valore neutro,
// così un server più vecchio o un messaggio strano non fanno cadere l'app.

typedef Json = Map<String, Object?>;

Json asJson(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

List<Json> asJsonList(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) e.cast<String, Object?>(),
      ]
    : const [];

List<String> asStrings(Object? v) => v is List ? [for (final e in v) '$e'] : const [];

String? asString(Object? v) => v is String ? v : null;

double? asDouble(Object? v) => v is num ? v.toDouble() : null;

int? asInt(Object? v) => v is num ? v.toInt() : null;

bool asBool(Object? v) => v == true;

/// Coppia di coordinate in metri, nel sistema del server.
typedef SitePoint = ({double x, double y});

List<SitePoint> asPoints(Object? v) => v is List
    ? [
        for (final p in v)
          if (p is List && p.length >= 2 && p[0] is num && p[1] is num) (x: (p[0] as num).toDouble(), y: (p[1] as num).toDouble()),
      ]
    : const [];

class DogStatus {
  const DogStatus({
    required this.kind,
    required this.connected,
    required this.armed,
    required this.x,
    required this.y,
    required this.yaw,
    required this.moving,
    required this.manual,
    required this.posture,
    required this.battery,
    required this.link,
    required this.speed,
  });

  factory DogStatus.fromJson(Json j) {
    final cmd = j['cmd'];
    return DogStatus(
      kind: asString(j['kind']) ?? '',
      connected: asBool(j['connected']),
      armed: j['armed'] != false, // senza il dato non si mostra un arresto d'emergenza che non c'è
      x: asDouble(j['x']) ?? 0,
      y: asDouble(j['y']) ?? 0,
      yaw: asDouble(j['yaw']) ?? 0,
      moving: asBool(j['moving']),
      manual: asBool(j['manual']),
      posture: asString(j['posture']) ?? 'standing',
      battery: asInt(j['battery']),
      link: asString(j['link']) ?? '',
      speed: cmd is List && cmd.isNotEmpty && cmd[0] is num ? (cmd[0] as num).toDouble().abs() : 0,
    );
  }

  final String kind; // mujoco | sim | go1
  final bool connected;

  /// false dopo un arresto d'emergenza.
  final bool armed;
  final double x, y, yaw;
  final bool moving;
  final bool manual;
  final String posture; // standing | down | rising
  final int? battery;
  final String link;

  /// m/s comandati.
  final double speed;

  bool get isReal => kind == 'go1';
}

class RondaMission {
  const RondaMission({
    required this.id,
    required this.kind,
    required this.stops,
    required this.priority,
    required this.label,
    required this.idx,
    required this.eventIds,
    required this.status,
    required this.phase,
    required this.path,
    required this.routeId,
    required this.created,
    required this.note,
  });

  factory RondaMission.fromJson(Json j) => RondaMission(
    id: asString(j['id']) ?? '',
    kind: asString(j['kind']) ?? '',
    stops: asStrings(j['stops']),
    priority: asInt(j['priority']) ?? 0,
    label: asString(j['label']) ?? '',
    idx: asInt(j['idx']) ?? 0,
    eventIds: asStrings(j['event_ids']),
    status: asString(j['status']) ?? '',
    phase: asString(j['phase']) ?? '',
    path: asPoints(j['path']),
    routeId: asString(j['route_id']),
    created: asDouble(j['created']) ?? 0,
    note: asString(j['note']) ?? '',
  );

  final String id;
  final String kind; // patrol | inspect | goto | home
  final List<String> stops;
  final int priority;
  final String label;
  final int idx;
  final List<String> eventIds;
  final String status; // queued | active | paused | verifying | done | cancelled
  final String phase;
  final List<SitePoint> path;
  final String? routeId;
  final double created;
  final String note;
}

class Assessment {
  const Assessment({required this.by, required this.verdict, required this.severity, required this.dispatch, required this.reason});

  factory Assessment.fromJson(Json j) => Assessment(
    by: asString(j['by']) ?? '',
    verdict: asString(j['verdict']) ?? '',
    severity: asInt(j['severity']),
    dispatch: asBool(j['dispatch']),
    reason: asString(j['reason']) ?? '',
  );

  final String by;
  final String verdict;
  final int? severity;
  final bool dispatch;
  final String reason;
}

class Verification {
  const Verification({required this.confirmed, required this.risk, required this.description, required this.action});

  factory Verification.fromJson(Json j) => Verification(
    confirmed: j['confirmed'] is bool ? j['confirmed'] as bool : null,
    risk: asString(j['risk']) ?? '',
    description: asString(j['description']) ?? '',
    action: asString(j['action']) ?? '',
  );

  /// null = non è stato possibile capirlo: serve un controllo a mano.
  final bool? confirmed;
  final String risk;
  final String description;
  final String action;
}

class AlertResult {
  const AlertResult({required this.channel, required this.ok});

  factory AlertResult.fromJson(Json j) => AlertResult(channel: asString(j['channel']) ?? '', ok: asBool(j['ok']));

  final String channel; // console | telegram | sms | call
  final bool ok;
}

class AlertText {
  const AlertText({required this.title, required this.sms});

  factory AlertText.fromJson(Json j) => AlertText(title: asString(j['title']) ?? 'Alert', sms: asString(j['sms']) ?? '');

  final String title;
  final String sms;
}

class RondaEvent {
  const RondaEvent({
    required this.id,
    required this.ts,
    required this.camera,
    required this.kind,
    required this.score,
    required this.status,
    required this.assessment,
    required this.verification,
    required this.alert,
    required this.alertResults,
    required this.missionId,
    required this.images,
    required this.timings,
    required this.duplicates,
  });

  factory RondaEvent.fromJson(Json j) {
    final a = j['assessment'], v = j['verification'], al = j['alert'];
    return RondaEvent(
      id: asString(j['id']) ?? '',
      ts: asDouble(j['ts']) ?? 0,
      camera: asString(j['camera']) ?? '',
      kind: asString(j['kind']) ?? '',
      score: asDouble(j['score']) ?? 0,
      status: asString(j['status']) ?? '',
      assessment: a is Map ? Assessment.fromJson(asJson(a)) : null,
      verification: v is Map ? Verification.fromJson(asJson(v)) : null,
      alert: al is Map ? AlertText.fromJson(asJson(al)) : null,
      alertResults: [for (final r in asJsonList(j['alert_results'])) AlertResult.fromJson(r)],
      missionId: asString(j['mission_id']),
      images: {
        for (final e in asJson(j['images']).entries)
          if (e.value is String) e.key: e.value! as String,
      },
      timings: {
        for (final e in asJson(j['timings']).entries)
          if (e.value is num) e.key: (e.value! as num).toDouble(),
      },
      duplicates: asInt(j['duplicates']) ?? 0,
    );
  }

  final String id;
  final double ts;
  final String camera;
  final String kind; // motion | person | intrusion | abandoned_object | manual | patrol_finding
  final double score;
  final String status; // received | assessing | dispatched | verifying | alerted | cleared | dismissed | cancelled
  final Assessment? assessment;
  final Verification? verification;
  final AlertText? alert;
  final List<AlertResult> alertResults;
  final String? missionId;

  /// camera | dog | check → percorso sul server.
  final Map<String, String> images;

  /// Secondi dall'evento: received, assessed, dispatched, arrived, verified, alerted, cancelled.
  final Map<String, double> timings;
  final int duplicates;
}

class LogEntry {
  const LogEntry({
    required this.id,
    required this.ts,
    required this.kind,
    required this.level,
    required this.message,
    required this.eventId,
    required this.missionId,
    required this.data,
  });

  factory LogEntry.fromJson(Json j) => LogEntry(
    id: asInt(j['id']) ?? 0,
    ts: asDouble(j['ts']) ?? 0,
    kind: asString(j['kind']) ?? '',
    level: asString(j['level']) ?? 'info',
    message: asString(j['message']) ?? '',
    eventId: asString(j['event_id']),
    missionId: asString(j['mission_id']),
    data: asJson(j['data']),
  );

  final int id;
  final double ts;
  final String kind;
  final String level; // info | warn | error | alert
  final String message;
  final String? eventId;
  final String? missionId;
  final Json data;
}

class CameraStatus {
  const CameraStatus({
    required this.id,
    required this.name,
    required this.online,
    required this.simulated,
    required this.calibrated,
    this.streamFps = 0,
  });

  factory CameraStatus.fromJson(Json j) => CameraStatus(
    id: asString(j['id']) ?? '',
    name: asString(j['name']) ?? '',
    online: asBool(j['online']),
    simulated: asJson(j['info'])['detector'] == 'simulated',
    calibrated: j['calib_m'] != null,
    streamFps: asDouble(j['stream_fps']) ?? 0,
  );

  final String id;
  final String name;
  final bool online;
  final bool simulated;
  final bool calibrated;

  /// Fotogrammi al secondo che stanno arrivando, mentre qualcuno guarda.
  final double streamFps;

  bool get isPhone => id.startsWith('phone-');
}

class Stats {
  const Stats({
    required this.events,
    required this.dispatched,
    required this.filtered,
    required this.confirmed,
    required this.cleared,
    required this.alerts,
    required this.avgArrival,
    required this.open,
  });

  factory Stats.fromJson(Json j) => Stats(
    events: asInt(j['events']) ?? 0,
    dispatched: asInt(j['dispatched']) ?? 0,
    filtered: asInt(j['filtered']) ?? 0,
    confirmed: asInt(j['confirmed']) ?? 0,
    cleared: asInt(j['cleared']) ?? 0,
    alerts: asInt(j['alerts']) ?? 0,
    avgArrival: asDouble(j['avg_arrival_s']),
    open: asInt(j['open']) ?? 0,
  );

  final int events, dispatched, filtered, confirmed, cleared, alerts, open;
  final double? avgArrival;
}

class AlarmState {
  const AlarmState({required this.armed, required this.active, required this.exitDelay, required this.by});

  factory AlarmState.fromJson(Json j) =>
      AlarmState(armed: asBool(j['armed']), active: asBool(j['active']), exitDelay: asInt(j['exit_delay_s']) ?? 0, by: asString(j['by']));

  final bool armed;

  /// Armato e con il tempo di uscita finito.
  final bool active;
  final int exitDelay;
  final String? by;
}

class GrokStatus {
  const GrokStatus({
    required this.enabled,
    required this.configured,
    required this.lastMs,
    required this.calls,
    required this.error,
    required this.model,
  });

  factory GrokStatus.fromJson(Json j) => GrokStatus(
    enabled: asBool(j['enabled']),
    configured: asBool(j['configured']),
    lastMs: asInt(j['last_ms']),
    calls: asInt(j['calls']) ?? 0,
    error: asString(j['error']),
    model: asString(asJson(j['models'])['main']) ?? '',
  );

  final bool enabled;

  /// C'è la chiave xAI.
  final bool configured;
  final int? lastMs;
  final int calls;
  final String? error;
  final String model;
}

class SimActor {
  const SimActor({required this.id, required this.kind, required this.x, required this.y});

  factory SimActor.fromJson(Json j) =>
      SimActor(id: asString(j['id']) ?? '', kind: asString(j['kind']) ?? '', x: asDouble(j['x']) ?? 0, y: asDouble(j['y']) ?? 0);

  final String id;
  final String kind; // person | bag
  final double x, y;
}

class SimStatus {
  const SimStatus({required this.connected, required this.actors, required this.scenarios});

  factory SimStatus.fromJson(Json j) => SimStatus(
    connected: asBool(j['connected']),
    actors: [for (final a in asJsonList(j['actors'])) SimActor.fromJson(a)],
    scenarios: asStrings(j['scenarios']),
  );

  final bool connected;
  final List<SimActor> actors;
  final List<String> scenarios;
}

class DogcamStatus {
  const DogcamStatus({required this.state, required this.fps, required this.error});

  factory DogcamStatus.fromJson(Json j) =>
      DogcamStatus(state: asString(j['state']) ?? '', fps: asDouble(j['fps']), error: asString(j['error']));

  final String state; // streaming | starting | error | ...
  final double? fps;
  final String? error;
}

class Schedule {
  const Schedule({required this.routeId, required this.everyMin, required this.nextIn});

  final String routeId;
  final double everyMin;
  final int nextIn;
}

class RondaAutomation {
  const RondaAutomation({
    required this.id,
    required this.name,
    required this.points,
    required this.loop,
    required this.start,
    required this.repeat,
    required this.everyMin,
    required this.until,
    required this.days,
    required this.active,
    required this.lastRun,
    required this.runsToday,
  });

  factory RondaAutomation.fromJson(Json j) => RondaAutomation(
    id: asString(j['id']) ?? '',
    name: asString(j['name']) ?? '',
    points: asPoints(j['points']),
    loop: asBool(j['loop']),
    start: asString(j['start']) ?? '',
    repeat: asString(j['repeat']) ?? '',
    everyMin: asInt(j['every_min']),
    until: asString(j['until']),
    days: j['days'] is List ? [for (final d in j['days']! as List) ?asInt(d)] : const [],
    active: asBool(j['active']),
    lastRun: asDouble(j['last_run']),
    runsToday: asInt(j['runs_today']) ?? 0,
  );

  final String id;
  final String name;
  final List<SitePoint> points;
  final bool loop;
  final String start;
  final String repeat;
  final int? everyMin;
  final String? until;

  /// 1 = lunedì … 7 = domenica.
  final List<int> days;
  final bool active;
  final double? lastRun;
  final int runsToday;
}

class Tick {
  const Tick({
    required this.dog,
    required this.current,
    required this.queue,
    required this.stats,
    required this.alarm,
    required this.shift,
    required this.grok,
    required this.alertChannels,
    required this.telegramChats,
    required this.dogcam,
    required this.schedules,
    required this.automations,
    required this.cameras,
    required this.sim,
  });

  factory Tick.fromJson(Json j) {
    final cur = j['current'], dc = j['dogcam'];
    return Tick(
      dog: DogStatus.fromJson(asJson(j['dog'])),
      current: cur is Map ? RondaMission.fromJson(asJson(cur)) : null,
      queue: [for (final m in asJsonList(j['queue'])) RondaMission.fromJson(m)],
      stats: Stats.fromJson(asJson(j['stats'])),
      alarm: AlarmState.fromJson(asJson(j['alarm'])),
      shift: asDouble(j['shift']) ?? 0,
      grok: GrokStatus.fromJson(asJson(j['grok'])),
      alertChannels: asStrings(j['alerts']),
      telegramChats: asInt(asJson(j['telegram'])['chats']) ?? 0,
      dogcam: dc is Map ? DogcamStatus.fromJson(asJson(dc)) : null,
      schedules: [
        for (final e in asJson(j['schedules']).entries)
          Schedule(routeId: e.key, everyMin: asDouble(asJson(e.value)['every_min']) ?? 0, nextIn: asInt(asJson(e.value)['next_in_s']) ?? 0),
      ],
      automations: [for (final a in asJsonList(j['automations'])) RondaAutomation.fromJson(a)],
      cameras: [for (final c in asJsonList(j['cameras'])) CameraStatus.fromJson(c)],
      sim: SimStatus.fromJson(asJson(j['sim'])),
    );
  }

  final DogStatus dog;
  final RondaMission? current;
  final List<RondaMission> queue;
  final Stats stats;
  final AlarmState alarm;

  /// Inizio del turno: cambia con Reset e New shift.
  final double shift;
  final GrokStatus grok;
  final List<String> alertChannels;
  final int telegramChats;

  /// Solo con il Go1 vero.
  final DogcamStatus? dogcam;
  final List<Schedule> schedules;
  final List<RondaAutomation> automations;
  final List<CameraStatus> cameras;
  final SimStatus sim;
}

class SiteRoom {
  const SiteRoom(this.id, this.name, this.x, this.y, this.w, this.h);

  final String id, name;
  final double x, y, w, h;

  bool contains(double px, double py) => px >= x && px <= x + w && py >= y && py <= y + h;
}

class SiteSpot {
  const SiteSpot(this.id, this.name, this.room, this.x, this.y);

  final String id, name;
  final String? room;
  final double x, y;
}

class SiteCamera {
  const SiteCamera(this.id, this.name, this.room, this.x, this.y, this.inspectSpot);

  final String id, name;
  final String? room;
  final double x, y;
  final String? inspectSpot;
}

class SiteRoute {
  const SiteRoute(this.id, this.name, this.spots);

  final String id, name;
  final List<String> spots;
}

class Site {
  const Site({
    required this.name,
    required this.rooms,
    required this.spots,
    required this.cameras,
    required this.routes,
    required this.bounds,
  });

  factory Site.fromJson(Json j) {
    final b = asJson(j['plan'])['bounds'];
    return Site(
      name: asString(j['name']) ?? '',
      rooms: [
        for (final r in asJsonList(j['rooms']))
          SiteRoom(
            asString(r['id']) ?? '',
            asString(r['name']) ?? '',
            asDouble(r['x']) ?? 0,
            asDouble(r['y']) ?? 0,
            asDouble(r['w']) ?? 0,
            asDouble(r['h']) ?? 0,
          ),
      ],
      spots: [
        for (final s in asJsonList(j['spots']))
          SiteSpot(asString(s['id']) ?? '', asString(s['name']) ?? '', asString(s['room']), asDouble(s['x']) ?? 0, asDouble(s['y']) ?? 0),
      ],
      cameras: [
        for (final c in asJsonList(j['cameras']))
          SiteCamera(
            asString(c['id']) ?? '',
            asString(c['name']) ?? '',
            asString(c['room']),
            asDouble(c['x']) ?? 0,
            asDouble(c['y']) ?? 0,
            asString(c['inspect_spot']),
          ),
      ],
      routes: [
        for (final r in asJsonList(j['routes'])) SiteRoute(asString(r['id']) ?? '', asString(r['name']) ?? '', asStrings(r['spots'])),
      ],
      bounds: b is List && b.length == 4 && b.every((v) => v is num) ? [for (final v in b) (v as num).toDouble()] : null,
    );
  }

  final String name;
  final List<SiteRoom> rooms;
  final List<SiteSpot> spots;
  final List<SiteCamera> cameras;
  final List<SiteRoute> routes;

  /// x0, y0, x1, y1 in metri.
  final List<double>? bounds;

  SiteSpot? spot(String id) => spots.where((s) => s.id == id).firstOrNull;
  SiteCamera? camera(String id) => cameras.where((c) => c.id == id).firstOrNull;
  SiteRoute? route(String id) => routes.where((r) => r.id == id).firstOrNull;

  /// Come `room_at` del server: la prima stanza che contiene il punto, quelle piccole sono prima in elenco.
  SiteRoom? roomAt(double x, double y) => rooms.where((r) => r.contains(x, y)).firstOrNull;
}

class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.actions = const [], this.offline = false});

  factory ChatMessage.fromJson(Json j) => ChatMessage(
    role: asString(j['role']) ?? 'assistant',
    text: asString(j['text']) ?? '',
    actions: [for (final a in asJsonList(j['actions'])) ?asString(a['tool'])],
    offline: j['by'] == 'offline',
  );

  final String role; // user | assistant
  final String text;
  final List<String> actions;

  /// Risposta delle regole di riserva: Grok non c'era.
  final bool offline;
}

/// Tutto `/api/state`.
class RondaSnapshot {
  const RondaSnapshot({required this.tick, required this.site, required this.events, required this.log, required this.chat});

  factory RondaSnapshot.fromJson(Json j) => RondaSnapshot(
    tick: Tick.fromJson(j),
    site: Site.fromJson(asJson(j['site'])),
    events: [for (final e in asJsonList(j['events'])) RondaEvent.fromJson(e)],
    log: [for (final e in asJsonList(j['log'])) LogEntry.fromJson(e)],
    chat: [for (final m in asJsonList(j['chat'])) ChatMessage.fromJson(m)],
  );

  final Tick tick;
  final Site site;
  final List<RondaEvent> events;
  final List<LogEntry> log;
  final List<ChatMessage> chat;
}
