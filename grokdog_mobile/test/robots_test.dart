import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/features/settings/robots.dart';

void main() {
  test('parte dalla flotta della web app: i robot spenti risultano scollegati', () {
    final r = initialRobots();
    expect(r.map((x) => x.id), ['GD-1', 'GD-2', 'GD-3', 'GD-4', 'GD-5']);
    expect(r.first.adapter, Adapter.sim);
    expect(r.map((x) => x.status), [RobotStatus.on, RobotStatus.on, RobotStatus.off, RobotStatus.off, RobotStatus.off]);
  });

  group('import', () {
    test('un robot solo', () {
      final r = parseRobots('{"name":" D3 ","model":"Go2","adapter":"ros2"}', startAt: 2).single;
      expect(r.id, 'GD-3');
      expect(r.name, 'D3');
      expect(r.model, 'Go2');
      expect(r.adapter, Adapter.ros2);
      expect(r.status, RobotStatus.off);
      expect(r.battery, isNull);
    });

    test('un elenco, con i valori predefiniti', () {
      final r = parseRobots('[{"name":"A"},{"name":"B","adapter":"boh"}]', startAt: 2);
      expect(r.map((x) => x.id), ['GD-3', 'GD-4']);
      expect(r.first.model, 'Unitree Go1');
      expect(r.last.adapter, Adapter.sim);
    });

    for (final bad in ['{}', '{"name":"  "}', '{"name":3}', '[1]', 'not json']) {
      test('rifiuta $bad', () => expect(() => parseRobots(bad, startAt: 0), throwsFormatException));
    }
  });
}
