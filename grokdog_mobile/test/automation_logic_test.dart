import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/mock_data.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/features/automation/automation_logic.dart';

void main() {
  group('roomAt', () {
    test('trova la stanza che contiene il punto', () {
      expect(roomAt(const PlanPoint(300, 300)), 'Room 1');
      expect(roomAt(const PlanPoint(1240, 1300)), 'Room 3');
    });

    test('fuori dai rettangoli sceglie la stanza più vicina', () {
      expect(roomAt(const PlanPoint(575, 300)), anyOf('Room 1', 'Room 2'));
      expect(roomAt(const PlanPoint(100, 2050)), 'Restrooms');
    });
  });

  test('repeatText usa le stesse frasi della web app', () {
    expect(repeatText(Repeat.once, '09:00', 60, '18:00'), 'Once, at 09:00');
    expect(repeatText(Repeat.daily, '09:00', 60, '18:00'), 'Every day at 09:00');
    expect(repeatText(Repeat.weekdays, '09:00', 60, '18:00'), 'Mon–Fri at 09:00');
    expect(repeatText(Repeat.interval, '09:00', 30, '18:00'), 'Every 30 min, 09:00–18:00');
  });

  test('everyLabel', () {
    expect(everyLabel(15), '15 minutes');
    expect(everyLabel(60), '1 hour');
    expect(everyLabel(120), '2 hours');
  });

  group('legLabels', () {
    test('un tratto normale', () => expect(legLabels([1], 3), ['B → C']));
    test('il tratto di ritorno chiude su A', () => expect(legLabels([2], 3), ['C → A']));
  });

  test('missingFields dice cosa manca', () {
    expect(missingFields('  ', 1), ['a name', 'at least two points (A and B)']);
    expect(missingFields('Giro', 1), ['at least two points (A and B)']);
    expect(missingFields('Giro', 2), isEmpty);
  });

  group('nextAutomationId', () {
    test('continua dopo quelle di sistema', () => expect(nextAutomationId(automations), 'AU-06'));

    test('non riusa un id quando se ne cancella uno in mezzo', () {
      const kept = Automation(id: 'AU-07', name: 'x', trigger: 't', action: 'a', dogId: null, active: true, lastRun: null, runsToday: 0);
      expect(nextAutomationId([...automations, kept]), 'AU-08');
    });
  });

  group('buildAutomation', () {
    const a = PlanPoint(300, 300), b = PlanPoint(1240, 1300);

    CustomAutomation build({bool loop = false, Repeat repeat = Repeat.daily}) => buildAutomation(
      id: 'AU-06',
      name: '  Giro  ',
      dogId: 'GD-1',
      points: const [a, b],
      loop: loop,
      start: '09:00',
      repeat: repeat,
      every: 30,
      until: '18:00',
    );

    test('scrive trigger e azione', () {
      final x = build();
      expect(x.name, 'Giro');
      expect(x.trigger, 'Every day at 09:00');
      expect(x.action, 'Walks A → B (Room 1 → Room 3) and reports what it sees');
      expect(x.custom, isTrue);
    });

    test('con il ritorno il percorso si chiude', () {
      expect(build(loop: true).action, startsWith('Walks A → B → A '));
    });

    test('every e until valgono solo per «interval»', () {
      expect(build().everyMinutes, isNull);
      expect(build().until, isNull);
      expect(build(repeat: Repeat.interval).everyMinutes, 30);
      expect(build(repeat: Repeat.interval).until, '18:00');
    });

    test('sopravvive al salvataggio', () {
      final back = CustomAutomation.fromJson(build(repeat: Repeat.interval).toJson());
      expect(back.id, 'AU-06');
      expect(back.route.last.y, 1300);
      expect(back.repeat, Repeat.interval);
      expect(back.copyWith(active: false).active, isFalse);
    });
  });
}
