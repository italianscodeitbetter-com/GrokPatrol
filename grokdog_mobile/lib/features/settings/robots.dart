import 'dart:convert';

import '../../data/console_store.dart';
import '../../data/models.dart';

enum Adapter {
  sim('Simulated'),
  unitree('Unitree (unitree_sdk2_python)'),
  ros2('Unitree (go2_ros2_sdk)');

  const Adapter(this.label);
  final String label;
}

enum RobotStatus { on, connecting, off }

class Robot {
  const Robot({
    required this.id,
    required this.name,
    required this.model,
    required this.adapter,
    required this.battery,
    required this.status,
  });

  final String id;
  final String name;
  final String model;
  final Adapter adapter;
  final int? battery;
  final RobotStatus status;

  Robot copyWith({String? name, String? model, Adapter? adapter, RobotStatus? status}) => Robot(
    id: id,
    name: name ?? this.name,
    model: model ?? this.model,
    adapter: adapter ?? this.adapter,
    battery: battery,
    status: status ?? this.status,
  );
}

List<Robot> initialRobots() => [
  for (final d in ConsoleStore.instance.fleet)
    Robot(
      id: d.id,
      name: d.name,
      model: 'Unitree Go1',
      adapter: d.adapter == DogAdapter.unitree ? Adapter.unitree : Adapter.sim,
      battery: d.battery,
      status: d.state == DogState.spento ? RobotStatus.off : RobotStatus.on,
    ),
];

/// File JSON con `{ name, model?, adapter? }` oppure un elenco di robot.
/// Lancia [FormatException] se un robot non ha il nome.
List<Robot> parseRobots(String text, {required int startAt}) {
  final data = jsonDecode(text);
  final list = data is List ? data : [data];
  return [for (final (i, x) in list.indexed) _parseRobot(x, id: 'GD-${startAt + i + 1}')];
}

Robot _parseRobot(Object? x, {required String id}) {
  final name = x is Map ? x['name'] : null;
  if (name is! String || name.trim().isEmpty) throw const FormatException('missing name');
  final o = x! as Map;
  final model = o['model'];
  return Robot(
    id: id,
    name: name.trim(),
    model: model is String ? model : 'Unitree Go1',
    adapter: Adapter.values.where((a) => a.name == o['adapter']).firstOrNull ?? Adapter.sim,
    battery: null,
    status: RobotStatus.off,
  );
}
