// Modelli della console. Corrispondono ai tipi di grokdog/src/lib/mock.ts.

enum TriggerSource {
  camera('Camera'),
  ronda('Patrol'),
  comando('Command');

  const TriggerSource(this.label);
  final String label;
}

enum Priority { alta, media, bassa }

enum EventStatus {
  inValutazione('in_valutazione'),
  inCoda('in_coda'),
  missione('missione'),
  verifica('verifica'),
  alert('alert'),
  falsoAllarme('falso_allarme'),
  chiuso('chiuso');

  const EventStatus(this.wire);

  /// Il valore usato dalla web app (mappa 3D ed export JSON).
  final String wire;
}

enum Outcome {
  anomalia('anomalia', 'Real anomaly'),
  falsoAllarme('falso_allarme', 'No anomaly'),
  inCorso('in_corso', 'In progress'),

  /// Il cane è arrivato ma non si è capito cosa ha visto: alert mandato, serve un controllo a mano.
  daVerificare('da_verificare', 'Needs review'),

  /// Fermata prima di finire il controllo.
  annullata('annullata', 'Not completed');

  const Outcome(this.wire, this.label);
  final String wire;
  final String label;
}

/// spento = registrato ma fermo alla base: compare negli elenchi, non sulla mappa.
enum DogState { missione, ronda, base, spento }

enum DogAdapter { simulato, unitree }

enum LogStep {
  trigger('Trigger', 'Trigger'),
  valutazione('Valutazione', 'Assessment'),
  missione('Missione', 'Mission'),
  verifica('Verifica', 'Verification'),
  alert('Alert', 'Alert'),
  chiusura('Chiusura', 'Closure'),

  /// Allarme, comandi, ronde: quello che dal server non è un passo di un incidente.
  sistema('Sistema', 'System');

  const LogStep(this.wire, this.label);
  final String wire;
  final String label;
}

enum AlertChannel {
  sms('SMS', 'SMS'),
  chiamata('Chiamata', 'Call'),
  grokbot('GrokBot', 'GrokBot'),
  console('Console', 'Console'),
  telegram('Telegram', 'Telegram');

  const AlertChannel(this.wire, this.label);
  final String wire;
  final String label;
}

/// Punto sulla pianta, in centimetri: x verso destra, y verso il basso.
class PlanPoint {
  const PlanPoint(this.x, this.y);

  factory PlanPoint.fromJson(Map<String, Object?> j) => PlanPoint((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  final double x;
  final double y;

  Map<String, Object?> toJson() => {'x': x, 'y': y};
}

class Room {
  const Room({required this.id, required this.name, required this.x, required this.y, required this.w, required this.h});

  final String id;
  final String name;
  final double x, y, w, h;
}

class MapPoint {
  const MapPoint({required this.id, required this.label, required this.roomId, required this.x, required this.y});

  final String id;
  final String label;
  final String roomId;
  final double x, y;
}

class Dog {
  const Dog({
    required this.id,
    required this.name,
    required this.adapter,
    required this.battery,
    required this.state,
    required this.task,
    required this.roomId,
    required this.route,
  });

  final String id;
  final String name;
  final DogAdapter adapter;

  /// null = il cane non l'ha ancora detto.
  final int? battery;
  final DogState state;
  final String task;
  final String roomId;

  /// Percorso in loop seguito dal cane simulato.
  final List<PlanPoint> route;
}

class PatrolEvent {
  const PatrolEvent({
    required this.id,
    required this.time,
    required this.source,
    required this.sourceLabel,
    required this.roomId,
    required this.x,
    required this.y,
    required this.anomaly,
    required this.priority,
    required this.status,
    required this.grokDecision,
    required this.grokReason,
  });

  final String id;
  final String time;
  final TriggerSource source;
  final String sourceLabel;
  final String roomId;
  final double x, y;
  final String anomaly;
  final Priority priority;
  final EventStatus status;
  final String grokDecision;
  final String grokReason;
}

class LogRow {
  const LogRow({required this.time, required this.eventId, required this.step, required this.detail, this.missionId});

  final String time;
  final String eventId;
  final LogStep step;
  final String detail;
  final String? missionId;
}

class MissionStep {
  const MissionStep(this.step, this.time, this.detail);

  final LogStep step;
  final String? time;
  final String detail;
}

/// Una foto scattata durante il controllo: percorso sul server e didascalia.
class MissionImage {
  const MissionImage(this.path, this.caption);

  final String path;
  final String caption;
}

class Mission {
  const Mission({
    required this.id,
    required this.eventId,
    required this.dogId,
    required this.sighting,
    required this.automationId,
    this.createdBy,
    required this.trigger,
    required this.triggerLabel,
    required this.roomId,
    required this.status,
    required this.eventTime,
    required this.arrivalSeconds,
    required this.outcome,
    required this.steps,
    this.images = const [],
    this.battery,
  });

  final String id;
  final String eventId;

  /// Batteria del cane al momento della missione (%); dal server non si sa.
  final int? battery;

  /// Il cane che ha fatto la missione (o che la farà, se è in coda).
  final String dogId;

  /// Cosa ha visto il cane sul posto; null se non è ancora arrivato.
  final String? sighting;

  /// Automazione che l'ha fatta partire; null = missione custom creata da una persona.
  final String? automationId;
  final String? createdBy;
  final TriggerSource trigger;
  final String triggerLabel;
  final String roomId;
  final EventStatus status;
  final String eventTime;
  final int? arrivalSeconds;
  final Outcome outcome;
  final List<MissionStep> steps;
  final List<MissionImage> images;

  bool get live => outcome == Outcome.inCorso;
}

class AlertSent {
  const AlertSent({
    required this.time,
    required this.missionId,
    required this.channel,
    required this.to,
    required this.text,
    required this.delivered,
  });

  final String time;
  final String missionId;
  final AlertChannel channel;
  final String to;
  final String text;
  final bool delivered;
}

class Shift {
  const Shift({
    required this.day,
    required this.label,
    required this.name,
    required this.date,
    required this.start,
    required this.end,
    required this.events,
    required this.confirmed,
    required this.falseAlarmsBlocked,
    required this.falseAlarmsForwarded,
    required this.avgArrivalSeconds,
    required this.logCompleteness,
  });

  /// Giorno del turno (YYYY-MM-DD): per ora i dati finti esistono solo per questo giorno.
  final String day;
  final String label, name, date;
  final String start, end;
  final int events, confirmed, falseAlarmsBlocked, falseAlarmsForwarded, avgArrivalSeconds, logCompleteness;
}

class Automation {
  const Automation({
    required this.id,
    required this.name,
    required this.trigger,
    required this.action,
    required this.dogId,
    required this.active,
    required this.lastRun,
    required this.runsToday,
    this.custom = false,
    this.startsAt,
    this.repeats,
    this.route,
    this.loop = false,
  });

  final String id;
  final String name;

  /// Quando parte.
  final String trigger;

  /// Cosa fa quando parte.
  final String action;
  final String? dogId;
  final bool active;
  final String? lastRun;
  final int runsToday;
  final bool custom;

  /// Ora in cui parte (HH:MM); null = parte quando succede qualcosa.
  final String? startsAt;

  /// Se parte a un'ora: quanto si ripete («Every day, every hour until 13:45»).
  final String? repeats;

  /// Il percorso, se ne ha uno: A, B, C…
  final List<PlanPoint>? route;
  final bool loop;
}

/// Una riga di Activity: un passo di una missione o un allarme inviato.
class ActivityRow {
  const ActivityRow({
    required this.time,
    required this.what,
    required this.detail,
    required this.missionId,
    required this.room,
    required this.robot,
    this.alert,
  });

  final String time, what, detail, missionId, room, robot;
  final AlertSent? alert;
}

enum Repeat { once, daily, weekdays, days, interval }

/// Automazione creata dall'operatore, con il percorso disegnato sulla mappa.
class CustomAutomation extends Automation {
  const CustomAutomation({
    required super.id,
    required super.name,
    required super.trigger,
    required super.action,
    required super.dogId,
    required super.active,
    required super.lastRun,
    required super.runsToday,
    required List<PlanPoint> super.route,
    required super.loop,
    required this.start,
    required this.repeat,
    this.days,
    this.everyMinutes,
    this.until,
  }) : super(custom: true, startsAt: start);

  factory CustomAutomation.fromJson(Map<String, Object?> j) => CustomAutomation(
    id: j['id']! as String,
    name: j['name']! as String,
    trigger: j['trigger']! as String,
    action: j['action']! as String,
    dogId: j['dogId'] as String?,
    active: j['active']! as bool,
    lastRun: j['lastRun'] as String?,
    runsToday: j['runsToday']! as int,
    route: [for (final p in j['route']! as List<Object?>) PlanPoint.fromJson(p! as Map<String, Object?>)],
    loop: j['loop']! as bool,
    start: j['start']! as String,
    repeat: Repeat.values.byName(j['repeat']! as String),
    days: (j['days'] as List<Object?>?)?.cast<int>(),
    everyMinutes: j['everyMinutes'] as int?,
    until: j['until'] as String?,
  );

  @override
  List<PlanPoint> get route => super.route!;
  final String start; // HH:MM
  final Repeat repeat;

  /// Per «days»: i giorni della settimana, 1 = lunedì … 7 = domenica.
  final List<int>? days;
  final int? everyMinutes;
  final String? until; // HH:MM, per «interval»

  CustomAutomation copyWith({bool? active, List<PlanPoint>? route, bool? loop, String? action}) => CustomAutomation(
    id: id,
    name: name,
    trigger: trigger,
    action: action ?? this.action,
    dogId: dogId,
    active: active ?? this.active,
    lastRun: lastRun,
    runsToday: runsToday,
    route: route ?? this.route,
    loop: loop ?? this.loop,
    start: start,
    repeat: repeat,
    days: days,
    everyMinutes: everyMinutes,
    until: until,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'trigger': trigger,
    'action': action,
    'dogId': dogId,
    'active': active,
    'lastRun': lastRun,
    'runsToday': runsToday,
    'route': [for (final p in route) p.toJson()],
    'loop': loop,
    'start': start,
    'repeat': repeat.name,
    'days': days,
    'everyMinutes': everyMinutes,
    'until': until,
  };
}
