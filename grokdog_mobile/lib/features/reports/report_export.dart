import 'dart:convert';

import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../data/ronda/ronda_models.dart';

// Gli stessi file di ReportsView.tsx.

/// Un foglio per Excel/Sheets: CSV con «;» (il separatore di Excel in italiano) e BOM, così gli accenti restano giusti.
String buildCsv(String day) {
  const header = ['Day', 'Mission', 'Event', 'Room', 'Time', 'Step', 'Detail', 'Outcome'];
  final rows = <List<String>>[
    for (final m in missions)
      for (final s in m.steps) [day, m.id, m.eventId, roomName(m.roomId), s.time ?? '', s.step.label, s.detail, m.outcome.label],
    for (final a in alerts)
      [day, a.missionId, '', '', a.time, 'Alert ${a.channel.label}', '${a.to}: ${a.text}', a.delivered ? 'Delivered' : 'Failed'],
  ];
  String cell(String v) => RegExp(r'[;"\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
  return '﻿${[header, ...rows].map((r) => r.map(cell).join(';')).join('\r\n')}';
}

/// Tutti i dati del giorno così come sono, per chi li vuole leggere da un altro programma.
String buildJson(String day) {
  final data = {
    'day': day,
    'shift': {
      'day': shift.day,
      'label': shift.label,
      'start': shift.start,
      'end': shift.end,
      'events': shift.events,
      'confirmed': shift.confirmed,
      'falseAlarmsBlocked': shift.falseAlarmsBlocked,
      'falseAlarmsForwarded': shift.falseAlarmsForwarded,
      'avgArrivalSeconds': shift.avgArrivalSeconds,
      'logCompleteness': shift.logCompleteness,
    },
    'missions': [for (final m in missions) _mission(m)],
    'alerts': [
      for (final a in alerts)
        {'time': a.time, 'missionId': a.missionId, 'channel': a.channel.wire, 'to': a.to, 'text': a.text, 'delivered': a.delivered},
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(data);
}

Map<String, Object?> _mission(Mission m) => {
  'id': m.id,
  'automationId': m.automationId,
  'createdBy': ?m.createdBy,
  'dogId': m.dogId,
  'sighting': m.sighting,
  'eventId': m.eventId,
  'trigger': m.trigger.name,
  'triggerLabel': m.triggerLabel,
  'roomId': m.roomId,
  'status': m.status.wire,
  'eventTime': m.eventTime,
  'arrivalSeconds': m.arrivalSeconds,
  'outcome': m.outcome.wire,
  'steps': [
    for (final s in m.steps) {'step': s.step.wire, 'time': s.time, 'detail': s.detail},
  ],
  'room': roomName(m.roomId),
};

/// Il registro del giorno dal server: stesse colonne di `/api/log.csv`, ma limitato al giorno scelto.
String buildLogCsv(List<LogEntry> entries) {
  const header = ['id', 'time', 'kind', 'level', 'message', 'event_id', 'mission_id', 'data'];
  String stamp(double ts) {
    final t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  final rows = [
    for (final e in entries)
      ['${e.id}', stamp(e.ts), e.kind, e.level, e.message, e.eventId ?? '', e.missionId ?? '', e.data.isEmpty ? '' : jsonEncode(e.data)],
  ];
  String cell(String v) => RegExp(r'[;"\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
  return '﻿${[header, ...rows].map((r) => r.map(cell).join(';')).join('\r\n')}';
}

String buildLogJson(String day, List<LogEntry> entries) {
  final data = {
    'day': day,
    'log': [
      for (final e in entries)
        {
          'id': e.id,
          'ts': e.ts,
          'kind': e.kind,
          'level': e.level,
          'message': e.message,
          'event_id': e.eventId,
          'mission_id': e.missionId,
          'data': e.data,
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(data);
}

String _esc(String v) => const HtmlEscape().convert(v);

/// Il report della giornata: un documento da aprire, stampare o salvare in PDF, con numeri, missioni, attività e allarmi.
String buildDayReport({
  required String subtitle,
  required List<(String, String)> stats,
  required List<Mission> missions,
  required List<ActivityRow> activity,
  required List<AlertSent> alerts,
  required String Function(String id) roomOf,
  required String Function(String id) robotOf,
}) {
  String row(List<String> cells) => '<tr>${cells.map((c) => '<td>${_esc(c)}</td>').join()}</tr>';
  String head(List<String> cells) => '<tr>${cells.map((c) => '<th>${_esc(c)}</th>').join()}</tr>';
  return '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>GrokPatrol · Day report</title>
<style>
  body{font:14px/1.5 -apple-system,system-ui,sans-serif;color:#111;margin:32px;max-width:900px}
  h1{font-size:22px;margin:0}h2{font-size:16px;margin:32px 0 8px}
  .sub{color:#666;margin:4px 0 24px}
  .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
  .stat{border:1px solid #ddd;border-radius:8px;padding:10px 12px}.stat b{display:block;font-size:20px}
  table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #e5e5e5;vertical-align:top}
  th{color:#666;font-weight:500}
</style></head><body>
<h1>GrokPatrol · Day report</h1>
<p class="sub">${_esc(subtitle)}</p>
<div class="stats">${stats.map((s) => '<div class="stat">${_esc(s.$1)}<b>${_esc(s.$2)}</b></div>').join()}</div>
<h2>Missions</h2>
<table>${head(['Mission', 'Time', 'Room', 'Robot', 'What the dog found', 'Outcome'])}
${missions.map((m) => row([m.id, m.eventTime, m.roomId.isEmpty ? '—' : roomOf(m.roomId), robotOf(m.dogId), m.sighting ?? 'Not on site yet', m.outcome.label])).join('\n')}
</table>
<h2>Activity</h2>
<table>${head(['Time', 'Step', 'Detail', 'Mission', 'Room', 'Robot'])}
${activity.reversed.map((r) => row([r.time, r.what, r.detail, r.missionId, r.room, r.robot])).join('\n')}
</table>
<h2>Alerts sent</h2>
<table>${head(['Time', 'Channel', 'To', 'Message', 'Status'])}
${alerts.map((a) => row([a.time, a.channel.label, a.to, a.text, if (a.delivered) 'Delivered' else 'Failed'])).join('\n')}
</table>
</body></html>''';
}
