import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/mock_data.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/features/reports/day_picker.dart';
import 'package:grokpatrol/features/reports/report_export.dart';

void main() {
  group('CSV', () {
    final csv = buildCsv('2026-11-04');
    final lines = csv.split('\r\n');

    test('comincia con il BOM e l\'intestazione, separata da «;»', () {
      expect(csv.startsWith('﻿Day;Mission;Event;Room;Time;Step;Detail;Outcome'), isTrue);
    });

    test('una riga per passo e per alert', () {
      final steps = missions.fold<int>(0, (n, m) => n + m.steps.length);
      expect(lines.length, 1 + steps + alerts.length);
    });

    test('usa le etichette, non i valori interni', () {
      expect(lines[1], '2026-11-04;MS-0088;EV-0142;Room 3;11:02:14;Trigger;CAM-3, abandoned object, frame #8812;In progress');
      expect(lines.last, startsWith('2026-11-04;MS-0079;;;08:58:21;Alert Call;'));
    });

    test('mette fra virgolette le celle con virgolette, raddoppiandole', () {
      expect(csv, contains('"Voice command from console: ""patrol room 2"""'));
    });
  });

  group('JSON', () {
    final data = jsonDecode(buildJson('2026-11-04')) as Map<String, Object?>;

    test('ha giorno, turno, missioni e alert', () {
      expect(data['day'], '2026-11-04');
      expect((data['shift']! as Map)['events'], 14);
      expect((data['missions']! as List).length, missions.length);
      expect((data['alerts']! as List).length, alerts.length);
    });

    test('tiene i valori come la web app e aggiunge il nome della stanza', () {
      final m = (data['missions']! as List).first as Map<String, Object?>;
      expect(m['status'], 'verifica');
      expect(m['outcome'], 'in_corso');
      expect(m['room'], 'Room 3');
      expect(((m['steps']! as List)[1] as Map)['step'], 'Valutazione');
    });

    test('createdBy compare solo nelle missioni custom', () {
      final list = (data['missions']! as List).cast<Map<String, Object?>>();
      expect(list.firstWhere((m) => m['id'] == 'MS-0086')['createdBy'], 'Gabriel Spicuglia');
      expect(list.firstWhere((m) => m['id'] == 'MS-0088').containsKey('createdBy'), isFalse);
    });
  });

  group('Day report', () {
    String html({List<ActivityRow> activity = const []}) => buildDayReport(
      subtitle: 'Morning shift',
      stats: const [('Events', '14')],
      missions: missions,
      activity: activity,
      alerts: alerts,
      roomOf: (id) => 'Room of $id',
      robotOf: (id) => 'Robot of $id',
    );

    test('ha numeri, missioni, attività e allarmi', () {
      final r = html();
      expect(r, startsWith('<!doctype html>'));
      expect(r, contains('Morning shift'));
      expect(r, contains('<b>14</b>'));
      for (final m in missions) {
        expect(r, contains(m.id));
      }
      expect(r, contains('<h2>Alerts sent</h2>'));
    });

    test('non lascia passare markup dai dati', () {
      final r = html(
        activity: const [
          ActivityRow(time: '10:00:00', what: '<script>x</script>', detail: 'a & b', missionId: 'MS-1', room: '—', robot: 'D1'),
        ],
      );
      expect(r, isNot(contains('<script>x')));
      expect(r, contains('&lt;script&gt;'));
      expect(r, contains('a &amp; b'));
    });

    test('l\'attività va dalla più vecchia alla più recente', () {
      final r = html(
        activity: const [
          ActivityRow(time: '12:00:00', what: 'Second', detail: '', missionId: 'MS-1', room: '—', robot: 'D1'),
          ActivityRow(time: '10:00:00', what: 'First', detail: '', missionId: 'MS-1', room: '—', robot: 'D1'),
        ],
      );
      expect(r.indexOf('First'), lessThan(r.indexOf('Second')));
    });
  });

  group('giorni', () {
    test('addDays passa bene i confini del mese e il cambio dell\'ora', () {
      expect(addDays('2026-11-01', -1), '2026-10-31');
      expect(addDays('2026-12-31', 1), '2027-01-01');
      expect(addDays('2026-10-25', 1), '2026-10-26'); // ora legale in Italia
    });

    test('formatDay', () => expect(formatDay('2026-11-04'), '4 November 2026'));
  });
}
