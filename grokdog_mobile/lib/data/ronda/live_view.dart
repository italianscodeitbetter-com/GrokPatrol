import '../models.dart';
import 'ronda_models.dart';

// Lo stato del server tradotto nei modelli delle schermate. Sono solo funzioni dei dati ricevuti:
// si possono provare con i messaggi veri, senza server (test/live_view_test.dart).

/// Dalla pianta del server (metri, y verso l'alto) a quella dell'app (cm, y verso il basso, origine in alto a sinistra).
/// I due sistemi vengono dallo stesso Pad3.step: i pilastri coincidono al centimetro.
class SiteTransform {
  const SiteTransform({this.x0 = -0.4, this.y1 = 18.4});

  factory SiteTransform.of(Site site) {
    final b = site.bounds;
    return b == null ? const SiteTransform() : SiteTransform(x0: b[0], y1: b[3]);
  }

  final double x0, y1;

  PlanPoint toPlan(double x, double y) => PlanPoint((x - x0) * 100, (y1 - y) * 100);

  SitePoint toSite(PlanPoint p) => (x: p.x / 100 + x0, y: y1 - p.y / 100);

  /// Il server gira in senso antiorario con la y in alto, sulla pianta la y scende.
  double heading(double yaw) => -yaw;
}

String clockOf(double ts) {
  final t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

const liveDogId = 'dog';

const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Le missioni partite da una telecamera con l'allarme inserito.
const alarmAutomationId = 'alarm';

const _kindLabels = {
  'person': 'Person seen, alarm armed',
  'motion': 'Movement, alarm armed',
  'intrusion': 'Person in the restricted zone',
  'abandoned_object': 'Object left in the zone',
  'manual': 'Manual event',
  'patrol_finding': 'Found on patrol',
};

String kindLabel(String kind) => _kindLabels[kind] ?? kind.replaceAll('_', ' ');

String dogLabel(String kind) => switch (kind) {
  'go1' => 'Unitree Go1',
  'mujoco' => 'Unitree Go1 · MuJoCo',
  'sim' => 'Unitree Go1 · simulated',
  _ => 'Robot dog',
};

/// Da che riga del registro viene quale passo della timeline.
LogStep stepOf(String kind) {
  if (kind == 'event.received') return LogStep.trigger;
  if (kind == 'event.assessed' || kind == 'event.second_opinion' || kind == 'event.located') return LogStep.valutazione;
  if (kind == 'mission.verified') return LogStep.verifica;
  if (kind == 'alert.sent') return LogStep.alert;
  if (kind == 'event.dismissed' || kind == 'event.cleared' || kind == 'event.cancelled') return LogStep.chiusura;
  if (kind == 'mission.done' || kind == 'mission.cancelled') return LogStep.chiusura;
  if (kind.startsWith('mission.')) return LogStep.missione;
  return LogStep.sistema;
}

AlertChannel _channelOf(String c) => switch (c) {
  'sms' => AlertChannel.sms,
  'call' => AlertChannel.chiamata,
  'telegram' => AlertChannel.telegram,
  _ => AlertChannel.console,
};

/// Gli alert scritti nel registro: una riga per canale.
List<AlertSent> alertsFromLog(Iterable<LogEntry> log) => [
  for (final e in log)
    if (e.kind == 'alert.sent')
      for (final r in asJsonList(e.data['results']))
        AlertSent(
          time: clockOf(e.ts),
          missionId: e.missionId ?? e.eventId ?? '',
          channel: _channelOf(asString(r['channel']) ?? ''),
          to: '',
          text: asString(asJson(e.data['alert'])['sms']) ?? e.message,
          delivered: asBool(r['ok']),
        ),
];

bool isNoisyKind(String kind) => kind.startsWith('console.') || kind.startsWith('camera.') || kind.startsWith('sim.');

/// Le righe di Activity dal registro, le più recenti prima: una per passo, una per ogni canale di un alert.
List<ActivityRow> activityFromLog(Iterable<LogEntry> log, {required String robot}) {
  final rows = <ActivityRow>[];
  for (final e in log.toList().reversed) {
    if (isNoisyKind(e.kind)) continue;
    final mission = e.missionId ?? e.eventId ?? '—';
    if (e.kind == 'alert.sent') {
      for (final a in alertsFromLog([e])) {
        rows.add(
          ActivityRow(
            time: a.time,
            what: 'Alert · ${a.channel.label}',
            detail: a.text,
            missionId: mission,
            room: '—',
            robot: robot,
            alert: a,
          ),
        );
      }
    } else {
      rows.add(
        ActivityRow(time: clockOf(e.ts), what: stepOf(e.kind).label, detail: e.message, missionId: mission, room: '—', robot: robot),
      );
    }
  }
  return rows;
}

/// I numeri di una giornata, calcolati dal registro: vale per qualsiasi giorno, anche dopo un riavvio del server.
class DayReport {
  const DayReport({
    required this.events,
    required this.confirmed,
    required this.checked,
    required this.blocked,
    required this.forwarded,
    required this.avgArrival,
    required this.completeness,
    required this.alerts,
  });

  factory DayReport.fromLog(List<LogEntry> log) {
    final received = <String>{}, closed = <String>{}, wrong = <String>{};
    var confirmed = 0, checked = 0, blocked = 0;
    final arrivals = <double>[];
    for (final e in log) {
      switch (e.kind) {
        case 'event.received':
          if (e.eventId case final id?) received.add(id);
        case 'event.dismissed' || 'event.cleared':
          blocked++;
          if (e.eventId case final id?) closed.add(id);
        case 'event.cancelled':
          if (e.eventId case final id?) closed.add(id);
        case 'alert.sent':
          if (e.eventId case final id?) closed.add(id);
        case 'mission.arrived':
          if (asDouble(e.data['event_to_arrival_s']) case final s?) arrivals.add(s);
        case 'mission.verified':
          checked++;
          if (e.data['confirmed'] == true) confirmed++;
          if (e.data['confirmed'] == false && e.missionId != null) wrong.add(e.missionId!);
      }
    }
    final forwarded = log.where((e) => e.kind == 'alert.sent' && wrong.contains(e.missionId)).length;
    return DayReport(
      events: received.length,
      confirmed: confirmed,
      checked: checked,
      blocked: blocked,
      forwarded: forwarded,
      avgArrival: arrivals.isEmpty ? null : arrivals.reduce((a, b) => a + b) / arrivals.length,
      completeness: received.isEmpty ? null : (closed.intersection(received).length * 100 / received.length).round(),
      alerts: alertsFromLog(log),
    );
  }

  final int events, confirmed, checked, blocked, forwarded;
  final double? avgArrival;

  /// Eventi arrivati a una chiusura, in percentuale.
  final int? completeness;
  final List<AlertSent> alerts;
}

/// Tutto quello che le schermate mostrano quando sono collegate al server.
class LiveView {
  LiveView({required this.site, required this.tick, required this.serverEvents, required this.serverLog})
    : transform = SiteTransform.of(site);

  final Site site;
  final Tick tick;
  final List<RondaEvent> serverEvents;
  final List<LogEntry> serverLog;
  final SiteTransform transform;

  late final List<Room> rooms = [
    for (final r in site.rooms)
      () {
        final top = transform.toPlan(r.x, r.y + r.h);
        return Room(id: r.id, name: r.name, x: top.x, y: top.y, w: r.w * 100, h: r.h * 100);
      }(),
  ];

  MapPoint _point(String id, String label, String room, double x, double y) {
    final p = transform.toPlan(x, y);
    return MapPoint(id: id, label: label, roomId: room, x: p.x, y: p.y);
  }

  late final List<MapPoint> cameras = [for (final c in site.cameras) _point(c.id, c.id.toUpperCase(), c.room ?? '', c.x, c.y)];

  /// Tutti i posti dove si può mandare il cane.
  late final List<MapPoint> spots = [for (final s in site.spots) _point(s.id, s.id.toUpperCase(), s.room ?? '', s.x, s.y)];

  /// Il giro della ronda in corso, altrimenti il primo percorso del sito.
  late final List<MapPoint> patrolPoints = () {
    RondaMission? patrol = tick.current?.kind == 'patrol' ? tick.current : null;
    patrol ??= tick.queue.where((m) => m.kind == 'patrol').firstOrNull;
    final ids = patrol?.stops ?? site.routes.firstOrNull?.spots ?? const <String>[];
    return [
      for (final id in ids)
        if (site.spot(id) case final s?) _point(s.id, s.id.toUpperCase(), s.room ?? '', s.x, s.y),
    ];
  }();

  late final Dog dog = () {
    final d = tick.dog, m = tick.current;
    final state = m == null
        ? DogState.base
        : m.kind == 'patrol'
        ? DogState.ronda
        : DogState.missione;
    final task = !d.connected
        ? 'Not connected'
        : !d.armed
        ? 'Emergency stop'
        : d.manual
        ? 'Manual control'
        : m?.label ?? (d.posture == 'down' ? 'Lying down' : 'Idle');
    return Dog(
      id: liveDogId,
      name: dogLabel(d.kind),
      adapter: d.isReal ? DogAdapter.unitree : DogAdapter.simulato,
      battery: d.battery,
      state: state,
      task: task,
      roomId: site.roomAt(d.x, d.y)?.id ?? '',
      route: const [],
    );
  }();

  String cameraName(String id) => site.camera(id)?.name ?? (id == 'dog' ? 'Dog camera' : id);

  EventStatus _status(RondaEvent e) => switch (e.status) {
    'received' || 'assessing' => EventStatus.inValutazione,
    'dispatched' => tick.queue.any((m) => m.id == e.missionId) ? EventStatus.inCoda : EventStatus.missione,
    'verifying' => EventStatus.verifica,
    'alerted' => EventStatus.alert,
    'dismissed' || 'cleared' => EventStatus.falsoAllarme,
    _ => EventStatus.chiuso,
  };

  Priority _priority(RondaEvent e) {
    final s = e.assessment?.severity;
    if (s == null) return Priority.media;
    return s >= 4
        ? Priority.alta
        : s == 3
        ? Priority.media
        : Priority.bassa;
  }

  /// Dove è successo: il punto trovato sul pavimento, altrimenti il posto che la telecamera controlla.
  SitePoint _whereOf(RondaEvent e) {
    final located = serverLog.where((l) => l.kind == 'event.located' && l.eventId == e.id).firstOrNull;
    final p = asPoints([located?.data['point']]);
    if (p.isNotEmpty) return p.first;
    final cam = site.camera(e.camera);
    final spot = cam?.inspectSpot == null ? null : site.spot(cam!.inspectSpot!);
    if (spot != null) return (x: spot.x, y: spot.y);
    return (x: cam?.x ?? tick.dog.x, y: cam?.y ?? tick.dog.y);
  }

  late final List<PatrolEvent> events = [
    for (final e in serverEvents)
      () {
        final w = _whereOf(e), p = transform.toPlan(w.x, w.y), a = e.assessment;
        return PatrolEvent(
          id: e.id,
          time: clockOf(e.ts),
          source: e.kind == 'patrol_finding' ? TriggerSource.ronda : TriggerSource.camera,
          sourceLabel: cameraName(e.camera),
          roomId: site.roomAt(w.x, w.y)?.id ?? '',
          x: p.x,
          y: p.y,
          anomaly: kindLabel(e.kind),
          priority: _priority(e),
          status: _status(e),
          grokDecision: a == null
              ? 'Assessing'
              : a.dispatch
              ? 'Send the dog'
              : "Don't send the dog",
          grokReason: a?.reason ?? '',
        );
      }(),
  ];

  Outcome _outcome(RondaEvent e) => switch (e.status) {
    'alerted' => e.verification?.confirmed == true ? Outcome.anomalia : Outcome.daVerificare,
    'dismissed' || 'cleared' => Outcome.falsoAllarme,
    'cancelled' => Outcome.annullata,
    _ => Outcome.inCorso,
  };

  Mission _fromEvent(RondaEvent e) {
    String? at(String key) {
      final t = e.timings[key];
      return t == null ? null : clockOf(e.ts + t);
    }

    final a = e.assessment, v = e.verification, al = e.alert, cam = cameraName(e.camera);
    final arrived = e.timings['arrived'], dispatched = at('dispatched');
    final dismissed = e.status == 'dismissed', cleared = e.status == 'cleared', cancelled = e.status == 'cancelled';
    final closedAt = at('alerted') ?? at('verified') ?? at('cancelled') ?? (dismissed ? at('assessed') : null);
    final trigger = e.kind == 'patrol_finding' ? TriggerSource.ronda : TriggerSource.camera;
    final images = [
      if (e.images['camera'] case final p?) MissionImage(p, 'Camera snapshot'),
      if (e.images['dog'] case final p?) MissionImage(p, 'Dog camera on arrival'),
      if (e.images['check'] case final p?) MissionImage(p, 'Fresh frame on arrival'),
    ];
    return Mission(
      id: e.missionId ?? e.id,
      eventId: e.id,
      dogId: liveDogId,
      sighting: v?.description,
      automationId: alarmAutomationId,
      trigger: trigger,
      triggerLabel: '$cam · ${kindLabel(e.kind)}',
      roomId: site.roomAt(_whereOf(e).x, _whereOf(e).y)?.id ?? '',
      status: _status(e),
      eventTime: clockOf(e.ts),
      arrivalSeconds: arrived?.round(),
      outcome: _outcome(e),
      images: images,
      steps: [
        MissionStep(LogStep.trigger, clockOf(e.ts), '$cam, ${kindLabel(e.kind)}, detector ${(e.score * 100).round()}%'),
        MissionStep(
          LogStep.valutazione,
          at('assessed'),
          a == null ? 'Pending' : '${a.dispatch ? 'Send the dog' : "Don't send the dog"}: ${a.reason}',
        ),
        MissionStep(
          LogStep.missione,
          at('arrived') ?? dispatched,
          dismissed
              ? 'Dog not sent, or recalled'
              : arrived != null
              ? 'Departed $dispatched, arrived ${at('arrived')}, ${arrived.round()} s'
              : dispatched == null
              ? 'Pending'
              : 'Departed $dispatched',
        ),
        MissionStep(LogStep.verifica, at('verified'), v?.description ?? (dismissed ? 'Not needed' : 'Pending')),
        MissionStep(
          LogStep.alert,
          at('alerted'),
          al != null
              ? al.sms
              : cleared || dismissed
              ? 'No alert'
              : 'Pending',
        ),
        MissionStep(
          LogStep.chiusura,
          _outcome(e) == Outcome.inCorso ? null : closedAt,
          cancelled
              ? 'Check not completed'
              : dismissed || cleared
              ? 'False alarm'
              : e.status == 'alerted'
              ? _outcome(e).label
              : 'In progress',
        ),
      ],
    );
  }

  /// Le missioni senza incidente (ronde, comandi dell'operatore): il server non le conserva, si ricostruiscono dal registro.
  List<Mission> _operatorMissions(Set<String> withEvent) {
    final byId = <String, List<LogEntry>>{};
    for (final e in serverLog) {
      final id = e.missionId;
      if (id != null && !withEvent.contains(id)) (byId[id] ??= []).add(e);
    }
    final open = [?tick.current, ...tick.queue];
    final out = <Mission>[];
    for (final m in open) {
      if (!withEvent.contains(m.id)) byId[m.id] ??= [];
    }
    for (final MapEntry(key: id, value: rows) in byId.entries) {
      LogEntry? first(String kind) => rows.where((r) => r.kind == kind).firstOrNull;
      final live = open.where((m) => m.id == id).firstOrNull;
      final queued = first('mission.queued');
      final label =
          live?.label ?? RegExp(r'^(.*) queued \(priority').firstMatch(queued?.message ?? '')?.group(1) ?? rows.firstOrNull?.message ?? id;
      final kind = live?.kind ?? asString(queued?.data['kind']) ?? '';
      final done = first('mission.done'), cancelled = first('mission.cancelled');
      final verified = first('mission.verified'), alert = first('alert.sent'), arrived = first('mission.arrived');
      final confirmed = verified?.data['confirmed'];
      final outcome = alert != null
          ? (confirmed == true ? Outcome.anomalia : Outcome.daVerificare)
          : cancelled != null
          ? Outcome.annullata
          : done != null
          ? Outcome.falsoAllarme
          : live != null
          ? Outcome.inCorso
          : Outcome.annullata;
      final routeId = live?.routeId;
      final closed = done ?? cancelled;
      final started = first('mission.started');
      final created = queued?.ts ?? live?.created ?? rows.firstOrNull?.ts ?? 0;
      out.add(
        Mission(
          id: id,
          eventId: '',
          dogId: liveDogId,
          sighting: asString(verified?.data['description']),
          automationId: kind == 'patrol' ? routeId ?? 'patrol' : null,
          createdBy: 'the operator',
          trigger: kind == 'patrol' ? TriggerSource.ronda : TriggerSource.comando,
          triggerLabel: label,
          roomId: '',
          status: live == null
              ? (alert != null ? EventStatus.alert : EventStatus.chiuso)
              : live.status == 'verifying'
              ? EventStatus.verifica
              : live.status == 'queued' || live.status == 'paused'
              ? EventStatus.inCoda
              : EventStatus.missione,
          eventTime: clockOf(created),
          arrivalSeconds: null,
          outcome: outcome,
          steps: [
            MissionStep(LogStep.trigger, clockOf(created), label),
            MissionStep(LogStep.missione, started == null ? null : clockOf(started.ts), arrived?.message ?? 'Started'),
            MissionStep(LogStep.verifica, verified == null ? null : clockOf(verified.ts), verified?.message ?? 'Pending'),
            MissionStep(LogStep.alert, alert == null ? null : clockOf(alert.ts), alert?.message ?? 'No alert'),
            MissionStep(LogStep.chiusura, closed == null ? null : clockOf(closed.ts), closed?.message ?? 'In progress'),
          ],
        ),
      );
    }
    return out;
  }

  double _tsOfClock(Mission m) {
    final e = serverEvents.where((x) => x.id == m.eventId).firstOrNull;
    if (e != null) return e.ts;
    final rows = serverLog.where((l) => l.missionId == m.id);
    return rows.isEmpty ? double.infinity : rows.first.ts;
  }

  /// Più eventi possono condividere una missione: ne resta una riga per ogni evento, con il suo id.
  late final List<Mission> missions = () {
    final fromEvents = [for (final e in serverEvents) _fromEvent(e)];
    final withEvent = {
      for (final e in serverEvents)
        if (e.missionId != null) e.missionId!,
    };
    final all = [...fromEvents, ..._operatorMissions(withEvent)];
    return all..sort((a, b) => _tsOfClock(b).compareTo(_tsOfClock(a)));
  }();

  late final List<AlertSent> alerts = alertsFromLog(serverLog);

  /// Il registro per il pannello delle attività, il più recente per primo.
  late final List<LogRow> activity = [
    for (final e in serverLog.reversed)
      if (!isNoisyKind(e.kind))
        LogRow(time: clockOf(e.ts), eventId: e.eventId ?? '', step: stepOf(e.kind), detail: e.message, missionId: e.missionId),
  ];

  /// Le righe della pagina Automation: l'allarme, un percorso per ogni ronda del sito, quelle create dall'app.
  late final List<Automation> automations = [
    Automation(
      id: alarmAutomationId,
      name: 'Alarm',
      trigger: 'A camera sees movement while the alarm is armed',
      action: 'Grok decides if the dog goes to check, then the alert goes out',
      dogId: liveDogId,
      active: tick.alarm.armed,
      lastRun: serverEvents.lastOrNull == null ? null : clockOf(serverEvents.last.ts),
      runsToday: tick.stats.events,
    ),
    for (final r in site.routes)
      () {
        final s = tick.schedules.where((x) => x.routeId == r.id).firstOrNull;
        return Automation(
          id: r.id,
          name: r.name,
          trigger: s == null ? 'Not scheduled' : 'Every ${s.everyMin.round()} min, next in ${s.nextIn < 0 ? 0 : s.nextIn} s',
          action: 'The dog visits ${r.spots.map((x) => x.toUpperCase()).join(', ')} and reports what it sees',
          dogId: liveDogId,
          active: s != null,
          lastRun: null,
          runsToday: 0,
          startsAt: null,
          route: [
            for (final id in r.spots)
              if (site.spot(id) case final p?) transform.toPlan(p.x, p.y),
          ],
          loop: true,
        );
      }(),
    for (final a in tick.automations)
      Automation(
        id: a.id,
        name: a.name,
        trigger: switch (a.repeat) {
          'once' => 'Once, at ${a.start}',
          'daily' => 'Every day at ${a.start}',
          'weekdays' => 'Mon–Fri at ${a.start}',
          'days' => 'Selected days at ${a.start}',
          _ => 'Every ${a.everyMin} min, ${a.start}–${a.until}',
        },
        action: 'Walks ${a.points.length} points${a.loop ? ' and back to the first' : ''}, reports what it sees',
        dogId: liveDogId,
        active: a.active,
        lastRun: a.lastRun == null ? null : clockOf(a.lastRun!).substring(0, 5),
        runsToday: a.runsToday,
        custom: true,
        startsAt: a.start,
        repeats: switch (a.repeat) {
          'once' => 'Once',
          'daily' => 'Every day',
          'weekdays' => 'Mon–Fri',
          'days' => a.days.map((d) => weekdayNames[d - 1]).join(', '),
          _ => 'Every day, every ${a.everyMin} min until ${a.until}',
        },
        route: [for (final p in a.points) transform.toPlan(p.x, p.y)],
        loop: a.loop,
      ),
  ];
}
