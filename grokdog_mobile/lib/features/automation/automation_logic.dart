import 'dart:math' as math;

import '../../data/console_store.dart';
import '../../data/models.dart';

// La logica di AutomationBuilder.tsx, separata dalla UI. I controlli su muri e oggetti li fa la scena 3D.

String letter(int i) => String.fromCharCode(65 + i);

String meters(double cm) => (cm / 100).toStringAsFixed(1);

/// La stanza che contiene il punto; se cade fuori dai rettangoli delle stanze (bordi, porte), la più vicina.
String roomAt(PlanPoint p) {
  double gap(Room r) {
    final dx = [r.x - p.x, 0.0, p.x - r.x - r.w].reduce(math.max);
    final dy = [r.y - p.y, 0.0, p.y - r.y - r.h].reduce(math.max);
    return math.sqrt(dx * dx + dy * dy);
  }

  return ConsoleStore.instance.rooms.reduce((best, r) => gap(r) < gap(best) ? r : best).name;
}

const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayList(List<int> days) => days.isEmpty ? 'No days' : days.map((d) => weekdays[d - 1]).join(', ');

String repeatText(Repeat repeat, String start, int every, String until, [List<int> days = const []]) => switch (repeat) {
  Repeat.once => 'Once, at $start',
  Repeat.daily => 'Every day at $start',
  Repeat.weekdays => 'Mon–Fri at $start',
  Repeat.days => '${_dayList(days)} at $start',
  Repeat.interval => 'Every $every min, $start–$until',
};

/// Quanto si ripete, senza l'ora di partenza (sta accanto): «Every day», «Mon–Fri», «Every day, every 30 min until 18:00»…
String repeatLabel(CustomAutomation a) => switch (a.repeat) {
  Repeat.once => 'Once',
  Repeat.daily => 'Every day',
  Repeat.weekdays => 'Mon–Fri',
  Repeat.days => _dayList(a.days ?? const []),
  Repeat.interval => 'Every day, every ${a.everyMinutes ?? 60} min until ${a.until ?? '—'}',
};

/// «Walks A → B → A (Room 2 → Room 3) and reports what it sees»: cosa fa un'automazione col suo percorso.
String walkText(List<PlanPoint> route, {required bool loop}) {
  final legs = [for (var i = 0; i < route.length; i++) letter(i)].join(' → ') + (loop ? ' → A' : '');
  final roomsOnPath = {for (final p in route) roomAt(p)}.join(' → ');
  return 'Walks $legs ($roomsOnPath) and reports what it sees';
}

String everyLabel(int m) => m < 60 ? '$m minutes' : '${m ~/ 60} ${m == 60 ? 'hour' : 'hours'}';

/// I tratti indicati dalla scena come «A → B»; con il ritorno l'ultimo chiude su A.
List<String> legLabels(List<int> legs, int pointCount) => [
  for (final i in legs) '${letter(i)} → ${i + 1 == pointCount ? 'A' : letter(i + 1)}',
];

List<String> missingFields(String name, int pointCount) => [
  if (name.trim().isEmpty) 'a name',
  if (pointCount < 2) 'at least two points (A and B)',
];

/// Il prossimo id libero: non riusa quello di un'automazione cancellata.
String nextAutomationId(Iterable<Automation> existing) {
  final used = existing.map((a) => int.tryParse(a.id.replaceFirst('AU-', '')) ?? 0);
  return 'AU-${(used.fold(0, math.max) + 1).toString().padLeft(2, '0')}';
}

CustomAutomation buildAutomation({
  required String id,
  required String name,
  required String dogId,
  required List<PlanPoint> points,
  required bool loop,
  required String start,
  required Repeat repeat,
  required int every,
  required String until,
  List<int> days = const [],
}) {
  final interval = repeat == Repeat.interval;
  return CustomAutomation(
    id: id,
    name: name.trim(),
    trigger: repeatText(repeat, start, every, until, days),
    action: walkText(points, loop: loop),
    dogId: dogId,
    active: true,
    lastRun: null,
    runsToday: 0,
    route: points,
    loop: loop,
    start: start,
    repeat: repeat,
    days: repeat == Repeat.days ? days : null,
    everyMinutes: interval ? every : null,
    until: interval ? until : null,
  );
}
