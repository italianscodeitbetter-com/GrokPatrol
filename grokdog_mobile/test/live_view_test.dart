import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/data/ronda/live_view.dart';
import 'package:grokpatrol/data/ronda/ronda_models.dart';

/// Un incidente vero: allarme, intruso, cane, verifica e alert, registrato dal server con il simulatore.
Json loadFixture() => asJson(jsonDecode(File('test/fixtures/ronda_incident.json').readAsStringSync()));

LiveView viewOf(RondaSnapshot s, {Tick? tick, List<LogEntry>? log}) =>
    LiveView(site: s.site, tick: tick ?? s.tick, serverEvents: s.events, serverLog: log ?? s.log);

void main() {
  final fixture = loadFixture();
  final state = RondaSnapshot.fromJson(asJson(fixture['state']));
  final view = viewOf(state);

  group('coordinate', () {
    const t = SiteTransform();

    test('i pilastri del server cadono sui pilastri della pianta dell\'app', () {
      final a = t.toPlan(5.35, 5.97), b = t.toPlan(11.1, 5.97), c = t.toPlan(11.1, 12.2);
      expect([a.x, a.y], [closeTo(575, 0.01), closeTo(1243, 0.01)]);
      expect([b.x, b.y], [closeTo(1150, 0.01), closeTo(1243, 0.01)]);
      expect([c.x, c.y], [closeTo(1150, 0.01), closeTo(620, 0.01)]);
    });

    test('andata e ritorno', () {
      final s = t.toSite(t.toPlan(8.3, 1.6));
      expect(s.x, closeTo(8.3, 1e-9));
      expect(s.y, closeTo(1.6, 1e-9));
    });

    test('usa i bordi che manda il server', () {
      expect(SiteTransform.of(state.site).toPlan(0, 0).x, closeTo(40, 0.01));
    });
  });

  group('sito', () {
    test('stanze con la y capovolta', () {
      final hall = view.rooms.firstWhere((r) => r.id == 'hall');
      expect(hall.y, closeTo(40, 0.01), reason: 'il bordo alto a y=18 m sta 40 cm sotto il bordo della pianta');
      expect(hall.h, closeTo(1800, 0.01));
    });

    test('telecamere, posti e ronda', () {
      expect(view.cameras.map((c) => c.label), ['CAM-1', 'CAM-2', 'CAM-3']);
      expect(view.spots.length, state.site.spots.length);
      expect(view.patrolPoints.map((p) => p.id), ['p1', 'p2', 'p3']);
    });
  });

  group('cane', () {
    test('un solo cane, dal tipo del server', () {
      expect(view.dog.id, liveDogId);
      expect(view.dog.name, 'Unitree Go1 · MuJoCo');
      expect(view.dog.battery, 100);
      expect(view.dog.adapter, DogAdapter.simulato);
    });

    Tick tickWith(Json dog, {Json? current}) {
      final j = {
        ...asJson(fixture['state']),
        'dog': {...asJson(asJson(fixture['state'])['dog']), ...dog},
        'current': current,
      };
      return Tick.fromJson(j);
    }

    test('dice perché è fermo', () {
      expect(viewOf(state, tick: tickWith({'armed': false})).dog.task, 'Emergency stop');
      expect(viewOf(state, tick: tickWith({'connected': false})).dog.task, 'Not connected');
      expect(viewOf(state, tick: tickWith({'manual': true})).dog.task, 'Manual control');
    });

    test('lo stato viene dalla missione in corso', () {
      final patrol = {
        'id': 'm-1',
        'kind': 'patrol',
        'label': 'Ronda',
        'stops': ['p1', 'p2'],
        'status': 'active',
      };
      final check = {
        'id': 'm-2',
        'kind': 'inspect',
        'label': 'Check Ingresso',
        'stops': ['z1'],
        'status': 'active',
      };
      expect(viewOf(state, tick: tickWith({}, current: patrol)).dog.state, DogState.ronda);
      expect(viewOf(state, tick: tickWith({}, current: check)).dog.state, DogState.missione);
      expect(viewOf(state, tick: tickWith({})).dog.state, DogState.base);
    });

    test('la ronda in corso è il giro disegnato', () {
      final patrol = {
        'id': 'm-1',
        'kind': 'patrol',
        'label': 'Ronda',
        'stops': ['p1', 'p2', 'p4', 'p3'],
        'status': 'active',
      };
      expect(viewOf(state, tick: tickWith({}, current: patrol)).patrolPoints.map((p) => p.id), ['p1', 'p2', 'p4', 'p3']);
    });

    test('la batteria può non esserci ancora', () {
      expect(viewOf(state, tick: tickWith({'battery': null})).dog.battery, isNull);
    });
  });

  group('incidente vero', () {
    late Mission alerted;

    setUpAll(() {
      final e = state.events.firstWhere((x) => x.status == 'alerted');
      alerted = view.missions.firstWhere((m) => m.eventId == e.id);
    });

    test('tutta la timeline', () {
      expect(alerted.steps.map((s) => s.step), [
        LogStep.trigger,
        LogStep.valutazione,
        LogStep.missione,
        LogStep.verifica,
        LogStep.alert,
        LogStep.chiusura,
      ]);
      expect(alerted.steps.every((s) => s.time != null), isTrue);
      expect(alerted.arrivalSeconds, isNotNull);
    });

    test('senza Grok non si dichiara un\'anomalia confermata: va rivista', () {
      expect(alerted.outcome, Outcome.daVerificare);
      expect(alerted.status, EventStatus.alert);
      expect(alerted.sighting, contains('manual check'));
    });

    test('le foto del controllo', () {
      expect(alerted.images.map((i) => i.caption), ['Camera snapshot', 'Dog camera on arrival']);
      expect(alerted.images.first.path, startsWith('/api/snapshots/'));
    });

    test('partita dall\'allarme, nella stanza dove è successo', () {
      expect(alerted.automationId, alarmAutomationId);
      expect(alerted.roomId, 'hall');
    });

    test('i più recenti per primi', () {
      final times = view.missions.map((m) => m.eventTime).toList();
      expect(times, [...times]..sort((a, b) => b.compareTo(a)));
    });

    test('l\'evento sta dove il detector l\'ha trovato, non al posto della telecamera', () {
      final e = state.log.firstWhere((l) => l.kind == 'event.located');
      final p = asPoints([e.data['point']]).single;
      final plan = const SiteTransform().toPlan(p.x, p.y);
      final ev = view.events.firstWhere((x) => x.id == e.eventId);
      expect(ev.x, closeTo(plan.x, 0.01));
      expect(ev.y, closeTo(plan.y, 0.01));
    });

    test('gli alert per canale', () {
      final a = view.alerts.single;
      expect(a.channel, AlertChannel.console);
      expect(a.delivered, isTrue);
      expect(a.text, contains('Teca centrale'));
    });
  });

  group('registro', () {
    test('ogni riga va al passo giusto', () {
      expect(stepOf('event.received'), LogStep.trigger);
      expect(stepOf('event.assessed'), LogStep.valutazione);
      expect(stepOf('mission.dispatched'), LogStep.missione);
      expect(stepOf('mission.verified'), LogStep.verifica);
      expect(stepOf('alert.sent'), LogStep.alert);
      expect(stepOf('event.cleared'), LogStep.chiusura);
      expect(stepOf('mission.done'), LogStep.chiusura);
      expect(stepOf('alarm.armed'), LogStep.sistema);
    });

    test('le attività nascondono il rumore dei sensori, le più recenti prima', () {
      expect(view.activity.any((r) => r.detail.contains('Simulation:')), isFalse);
      final ids = state.log.where((e) => !e.kind.startsWith('sim.') && !e.kind.startsWith('console.') && !e.kind.startsWith('camera.'));
      expect(view.activity.first.detail, ids.last.message);
    });
  });

  group('missioni senza incidente, dal registro', () {
    // nello stato registrato c'è una missione in coda: qui contano solo le righe del registro
    final idle = Tick.fromJson({...asJson(fixture['state']), 'current': null, 'queue': const <Object?>[]});

    LogEntry row(int id, String kind, String message, {Json data = const {}}) =>
        LogEntry(id: id, ts: 1000.0 + id, kind: kind, level: 'info', message: message, eventId: null, missionId: 'm-x', data: data);

    test('una ronda finita', () {
      final log = [
        row(1, 'mission.queued', 'Ronda padiglione queued (priority 0)', data: {'kind': 'patrol'}),
        row(2, 'mission.started', 'Ronda padiglione started'),
        row(3, 'mission.done', 'Ronda padiglione done: 1 round(s)'),
      ];
      final m = LiveView(site: state.site, tick: idle, serverEvents: const [], serverLog: log).missions.single;
      expect(m.triggerLabel, 'Ronda padiglione');
      expect(m.trigger, TriggerSource.ronda);
      expect(m.outcome, Outcome.falsoAllarme);
      expect(m.status, EventStatus.chiuso);
    });

    test('una fermata dall\'operatore non risulta completata', () {
      final log = [
        row(1, 'mission.queued', 'Go to Base queued (priority 1)', data: {'kind': 'goto'}),
        row(2, 'mission.cancelled', 'Go to Base cancelled: operator stop'),
      ];
      final m = LiveView(site: state.site, tick: idle, serverEvents: const [], serverLog: log).missions.single;
      expect(m.outcome, Outcome.annullata);
      expect(m.trigger, TriggerSource.comando);
    });
  });

  group('rapporto del giorno', () {
    LogEntry row(String kind, {String? event = 'e1', String? mission = 'm1', Json data = const {}}) =>
        LogEntry(id: 0, ts: 0, kind: kind, level: 'info', message: kind, eventId: event, missionId: mission, data: data);

    test('dall\'incidente vero', () {
      final r = DayReport.fromLog(state.log);
      expect(r.events, 2);
      expect(r.confirmed, 0, reason: 'senza Grok nulla è confermato');
      expect(r.avgArrival, isNotNull);
      expect(r.alerts.length, 1);
    });

    test('conta conferme, falsi allarmi e tempi', () {
      final r = DayReport.fromLog([
        row('event.received'),
        row('mission.arrived', data: {'event_to_arrival_s': 10.0}),
        row('mission.verified', data: {'confirmed': true}),
        row('alert.sent', data: {'results': []}),
        row('event.received', event: 'e2', mission: 'm2'),
        row('mission.arrived', event: 'e2', mission: 'm2', data: {'event_to_arrival_s': 20.0}),
        row('mission.verified', event: 'e2', mission: 'm2', data: {'confirmed': false}),
        row('event.cleared', event: 'e2', mission: 'm2'),
        row('event.received', event: 'e3', mission: null),
        row('event.dismissed', event: 'e3', mission: null),
      ]);
      expect(r.events, 3);
      expect(r.confirmed, 1);
      expect(r.checked, 2);
      expect(r.blocked, 2);
      expect(r.forwarded, 0);
      expect(r.avgArrival, 15);
      expect(r.completeness, 100);
    });

    test('un alert partito dopo un controllo negativo è un falso allarme inoltrato', () {
      final r = DayReport.fromLog([
        row('event.received'),
        row('mission.verified', data: {'confirmed': false}),
        row('alert.sent', data: {'results': []}),
      ]);
      expect(r.forwarded, 1);
    });

    test('un giorno vuoto non divide per zero', () {
      final r = DayReport.fromLog(const []);
      expect(r.avgArrival, isNull);
      expect(r.completeness, isNull);
    });
  });

  group('automazioni', () {
    test('l\'allarme e i percorsi del sito', () {
      expect(view.automations.first.id, alarmAutomationId);
      expect(view.automations.map((a) => a.id), containsAll(['r1', 'r2']));
      expect(view.automations.firstWhere((a) => a.id == 'r1').trigger, 'Not scheduled');
    });

    test('quelle create dall\'app vengono dal server', () {
      final tick = Tick.fromJson({
        ...asJson(fixture['state']),
        'automations': [
          {
            'id': 'AU-01',
            'name': 'Giro',
            'points': [
              [1, 2],
              [3, 4],
            ],
            'loop': true,
            'start': '09:00',
            'repeat': 'interval',
            'every_min': 30,
            'until': '18:00',
            'active': false,
            'runs_today': 2,
          },
        ],
      });
      final a = viewOf(state, tick: tick).automations.last;
      expect(a.custom, isTrue);
      expect(a.trigger, 'Every 30 min, 09:00–18:00');
      expect(a.action, 'Walks 2 points and back to the first, reports what it sees');
      expect(a.active, isFalse);
      expect(a.runsToday, 2);
    });
  });

  group('payload strani non fanno cadere l\'app', () {
    test('tutto vuoto', () {
      final s = RondaSnapshot.fromJson(const {});
      expect(s.events, isEmpty);
      expect(s.tick.dog.armed, isTrue);
      final v = LiveView(site: s.site, tick: s.tick, serverEvents: s.events, serverLog: s.log);
      expect(v.dog.name, 'Robot dog');
      expect(v.missions, isEmpty);
      expect(v.patrolPoints, isEmpty);
    });

    test('tipi sbagliati', () {
      final d = DogStatus.fromJson(const {'x': 'a', 'battery': 'pieno', 'cmd': 3, 'connected': 'yes'});
      expect(d.x, 0);
      expect(d.battery, isNull);
      expect(d.speed, 0);
      expect(d.connected, isFalse);
      expect(
        RondaEvent.fromJson(const {
          'timings': 3,
          'images': [1],
          'assessment': 'no',
        }).assessment,
        isNull,
      );
      expect(
        asPoints(const [
          [1],
          'x',
          [1, 2],
        ]),
        [(x: 1.0, y: 2.0)],
      );
    });

    test('tutti i messaggi veri si leggono', () {
      final m = asJson(fixture['messages']);
      expect(Tick.fromJson(asJson(m['tick'])).current?.kind, 'inspect');
      expect(RondaEvent.fromJson(asJson(asJson(m['event'])['event'])).status, 'alerted');
      expect(LogEntry.fromJson(asJson(asJson(m['log'])['entry'])).id, greaterThan(0));
      expect(AlertText.fromJson(asJson(asJson(m['alert'])['alert'])).title, startsWith('Allarme'));
    });
  });
}
