import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/mock_data.dart' as demo;
import '../../data/models.dart';
import '../../data/ronda/live_view.dart';
import '../../data/ronda/ronda_client.dart';
import '../../data/ronda/ronda_models.dart';
import '../../shared/ui.dart';
import '../missions/mission_detail_page.dart';
import 'day_picker.dart';
import 'report_export.dart';

/// Righe di Activity per pagina: la lista si allunga verso il basso, oltre si cambia pagina.
const activityPage = 50;

enum ActivityKind {
  all('All activity'),
  steps('Mission steps'),
  alerts('Alerts sent');

  const ActivityKind(this.label);
  final String label;
}

/// Il filtro e la ricerca di Activity.
List<ActivityRow> filterActivity(List<ActivityRow> rows, ActivityKind kind, String query) {
  final q = query.trim().toLowerCase();
  return rows.where((r) {
    if (kind != ActivityKind.all && (kind == ActivityKind.alerts) != (r.alert != null)) return false;
    if (q.isEmpty) return true;
    return [r.time, r.what, r.detail, r.missionId, r.room, r.robot, r.alert?.to ?? ''].any((v) => v.toLowerCase().contains(q));
  }).toList();
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, this.today});

  /// Solo per i test; di norma è la data del telefono.
  final String? today;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  ConsoleStore get _store => ConsoleStore.instance;
  String get _today => widget.today ?? isoDay(DateTime.now());

  late bool _live = _store.isLive;
  late String _day = _live ? _today : demo.shift.day;
  List<LogEntry>? _entries;
  String? _error;
  bool _loading = false;
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final _activityKey = GlobalKey();
  final _search = TextEditingController();
  bool _searching = false;
  ActivityKind _kind = ActivityKind.all;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    showReportsActivity.addListener(_goToActivity);
    if (_live) unawaited(_load());
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    showReportsActivity.removeListener(_goToActivity);
    _search.dispose();
    super.dispose();
  }

  /// «View all» dalle notifiche: si arriva direttamente su Activity.
  void _goToActivity() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = _activityKey.currentContext;
    if (target != null) unawaited(Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 250)));
  });

  void _onStore() {
    if (_store.isLive != _live) {
      setState(() {
        _live = _store.isLive;
        _day = _live ? _today : demo.shift.day;
        _entries = null;
        _error = null;
      });
      if (_live) unawaited(_load());
      return;
    }
    // la giornata in corso si aggiorna da sola, senza interrogare il server a ogni messaggio
    if (_live && _day == _today && DateTime.now().difference(_loadedAt) > const Duration(seconds: 5)) unawaited(_load());
  }

  Future<void> _load() async {
    final client = _store.client;
    if (client == null || _loading) return;
    final day = _day, from = parseDay(day);
    final start = DateTime(from.year, from.month, from.day), end = DateTime(from.year, from.month, from.day + 1);
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadedAt = DateTime.now();
    try {
      final all = await client.logSince(start.millisecondsSinceEpoch / 1000);
      final limit = end.millisecondsSinceEpoch / 1000;
      if (mounted && day == _day) setState(() => _entries = all.where((e) => e.ts < limit).toList());
    } on RondaFailure catch (e) {
      if (mounted && day == _day) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setDay(String day) {
    setState(() {
      _day = day;
      _entries = null;
      _page = 0;
    });
    if (_live) unawaited(_load());
  }

  bool get _hasData => _live ? (_entries?.isNotEmpty ?? false) : _day == demo.shift.day;

  DayReport? get _report => _live && _entries != null ? DayReport.fromLog(_entries!) : null;

  List<ActivityRow> get _rows {
    if (!_live) return _store.activityRows();
    return activityFromLog(_entries ?? const [], robot: _store.dogs.first.name);
  }

  /// Il contenuto del file per il formato scelto.
  Future<({String name, String body, String mime})> _file(_Format f) async {
    final base = 'grokpatrol-report-$_day';
    final entries = _entries;
    final live = _live && entries != null;
    return switch (f) {
      _Format.report => (name: '$base.html', body: await _dayReport(), mime: 'text/html'),
      _Format.csv => (name: '$base.csv', body: live ? buildLogCsv(entries) : buildCsv(_day), mime: 'text/csv'),
      _Format.json => (name: '$base.json', body: live ? buildLogJson(_day, entries) : buildJson(_day), mime: 'application/json'),
    };
  }

  Future<String> _dayReport() async {
    final r = _report;
    final from = parseDay(_day);
    final start = DateTime(from.year, from.month, from.day), end = DateTime(from.year, from.month, from.day + 1);
    final missions = _live
        ? await _store.missionsSince(start.millisecondsSinceEpoch / 1000, end.millisecondsSinceEpoch / 1000)
        : _store.missions;
    return buildDayReport(
      subtitle: _live ? formatDay(_day) : '${demo.shift.name} · ${demo.shift.date} · ${demo.shift.start}–${demo.shift.end}',
      stats: [
        ('Events', '${r?.events ?? demo.shift.events}'),
        ('Confirmed anomalies', '${r?.confirmed ?? demo.shift.confirmed}'),
        ('False alarms blocked', '${r?.blocked ?? demo.shift.falseAlarmsBlocked}'),
        ('Avg. time to arrival', _arrival(r)),
      ],
      missions: missions,
      activity: _rows,
      alerts: r?.alerts ?? demo.alerts,
      roomOf: _store.roomName,
      robotOf: _store.dogName,
    );
  }

  String _arrival(DayReport? r) {
    if (r == null) return '${demo.shift.avgArrivalSeconds} s';
    return r.avgArrival == null ? '—' : '${r.avgArrival!.toStringAsFixed(1)} s';
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _hasData, r = _report;
    return ListView(
      padding: pagePadding(context),
      children: [
        PageHeader(
          title: 'Reports',
          actions: _ExportButton(enabled: hasData, file: _file),
        ),
        DayPicker(value: _day, onChanged: _setDay, marked: [if (_live) _today else demo.shift.day], today: widget.today),
        const SizedBox(height: 16),
        if (_error case final error?)
          _Empty(text: error, retry: _load)
        else if (hasData) ...[
          _Stats(
            events: r?.events ?? demo.shift.events,
            confirmed: r?.confirmed ?? demo.shift.confirmed,
            blocked: r?.blocked ?? demo.shift.falseAlarmsBlocked,
            arrival: _arrival(r),
          ),
          if (_live && _day == _today) ...[const SizedBox(height: 16), const _ShiftReportButton()],
          const SizedBox(height: 24),
          _activity(),
        ] else if (_loading)
          const _Empty(text: 'Loading…')
        else
          const _Empty(text: 'No data for this day.'),
      ],
    );
  }

  Widget _activity() {
    final filtered = filterActivity(_rows, _kind, _search.text);
    final pages = ((filtered.length + activityPage - 1) ~/ activityPage).clamp(1, 1 << 30);
    final page = _page.clamp(0, pages - 1);
    final rows = filtered.skip(page * activityPage).take(activityPage).toList();
    return Column(
      key: _activityKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Activity', style: AppText.section),
            const SizedBox(width: 8),
            CountChip(filtered.length),
            const Spacer(),
            IconButton(
              tooltip: 'Filter activity',
              onPressed: () async {
                final k = await showChoiceSheet(
                  context,
                  title: 'Filter activity',
                  value: _kind,
                  options: [for (final k in ActivityKind.values) (k, k.label)],
                );
                if (k != null) {
                  setState(() {
                    _kind = k;
                    _page = 0;
                  });
                }
              },
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(LucideIcons.arrowDownUp, size: 20, color: AppColors.ink),
                  if (_kind != ActivityKind.all)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Search activity',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
                _page = 0;
              }),
              icon: Icon(_searching ? LucideIcons.x : LucideIcons.search, size: 20, color: AppColors.ink),
            ),
          ],
        ),
        if (_searching) ...[
          TextField(
            controller: _search,
            autofocus: true,
            style: AppText.body,
            decoration: const InputDecoration(hintText: 'Search activity'),
            onChanged: (_) => setState(() => _page = 0),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 6),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No activity matches.', style: AppText.bodyMuted),
                )
              else
                for (final (i, r) in rows.indexed) _ActivityTile(row: r, first: i == 0),
              Container(
                padding: const EdgeInsets.only(left: 14, right: 4),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${rows.isEmpty ? 0 : page * activityPage + 1}–${page * activityPage + rows.length} of ${filtered.length}',
                        style: AppText.bodyMuted,
                      ),
                    ),
                    IconButton(
                      onPressed: page == 0 ? null : () => setState(() => _page = page - 1),
                      tooltip: 'Previous page',
                      icon: const Icon(LucideIcons.chevronLeft, size: 16),
                      color: AppColors.muted,
                    ),
                    Text('Page ${page + 1} of $pages', style: AppText.bodyMuted),
                    IconButton(
                      onPressed: page >= pages - 1 ? null : () => setState(() => _page = page + 1),
                      tooltip: 'Next page',
                      icon: const Icon(LucideIcons.chevronRight, size: 16),
                      color: AppColors.muted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ogni GrokBot prende uno dei colori dei personaggi, sempre lo stesso per la stessa missione.
Color _botColor(String missionId) => AppColors.botColors[missionId.codeUnits.fold(0, (h, c) => h + c) % AppColors.botColors.length];

/// Un passo di una missione, o un allarme inviato (con icona del canale, destinatario e se è arrivato).
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.row, required this.first});

  final ActivityRow row;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final r = row, a = r.alert, store = ConsoleStore.instance;
    final mission = store.missions.where((m) => m.id == r.missionId).firstOrNull;
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(r.time, style: AppText.codeMuted),
              const SizedBox(width: 10),
              if (a != null) ...[
                if (a.channel == AlertChannel.grokbot)
                  GrokBotIcon(size: 16, color: _botColor(r.missionId), eyes: Colors.white)
                else
                  Icon(
                    switch (a.channel) {
                      AlertChannel.sms => LucideIcons.messageSquare,
                      AlertChannel.chiamata => LucideIcons.phone,
                      AlertChannel.telegram => LucideIcons.send,
                      _ => LucideIcons.monitor,
                    },
                    size: 14,
                    color: AppColors.muted,
                  ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(r.what, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
              ),
              if (a != null) ToneBadge(tone: a.delivered ? Tone.green : Tone.red, label: a.delivered ? 'Delivered' : 'Failed'),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [if (r.missionId != '—') r.missionId, if (r.room != '—') r.room, r.robot].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyMuted,
          ),
          if (a != null && a.to.isNotEmpty) Text('To ${a.to}', style: AppText.bodyMuted),
          const SizedBox(height: 4),
          Text(r.detail, style: AppText.body.copyWith(color: AppColors.ink.withValues(alpha: 0.9))),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: first ? null : const Border(top: BorderSide(color: AppColors.line)),
      ),
      child: mission == null
          ? body
          : InkWell(
              onTap: () => Navigator.of(
                context,
                rootNavigator: true,
              ).push(MaterialPageRoute<void>(builder: (_) => MissionDetailPage(mission: mission))),
              child: body,
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text, this.retry});

  final String text;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Text(text, textAlign: TextAlign.center, style: AppText.bodyMuted),
            if (retry != null) ...[const SizedBox(height: 12), GhostButton(label: 'Try again', height: 36, onPressed: retry)],
          ],
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.events, required this.confirmed, required this.blocked, required this.arrival});

  final int events, confirmed, blocked;
  final String arrival;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StatRow(Stat(label: 'Events', value: '$events'), Stat(label: 'Confirmed anomalies', value: '$confirmed')),
        const SizedBox(height: 10),
        _StatRow(Stat(label: 'False alarms blocked', value: '$blocked'), Stat(label: 'Avg. time to arrival', value: arrival)),
      ],
    );
  }
}

/// Due riquadri affiancati, alti uguali: crescono con il testo (etichette su due righe, caratteri grandi).
class _StatRow extends StatelessWidget {
  const _StatRow(this.left, this.right);

  final Stat left;
  final Stat right;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 10),
          Expanded(child: right),
        ],
      ),
    );
  }
}

/// Il rapporto di fine turno che scrive il server (con Grok, se c'è).
class _ShiftReportButton extends StatefulWidget {
  const _ShiftReportButton();

  @override
  State<_ShiftReportButton> createState() => _ShiftReportButtonState();
}

class _ShiftReportButtonState extends State<_ShiftReportButton> {
  bool _busy = false;

  Future<void> _run() async {
    final client = ConsoleStore.instance.client;
    if (client == null) return;
    setState(() => _busy = true);
    try {
      final text = await client.shiftReport();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('End-of-shift report', style: AppText.medium)),
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(LucideIcons.share2, size: 18, color: AppColors.muted),
                        onPressed: () {
                          final box = ctx.findRenderObject() as RenderBox?;
                          final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
                          unawaited(SharePlus.instance.share(ShareParams(text: text, sharePositionOrigin: origin)));
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.line),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(text, style: AppText.body.copyWith(height: 1.55)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } on RondaFailure catch (e) {
      showMessage(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GhostButton(
      label: _busy ? 'Writing the report…' : 'End-of-shift report',
      icon: LucideIcons.fileText,
      onPressed: _busy ? null : _run,
    );
  }
}

enum _Format {
  report('Day report', 'A document of everything done that day, ready to print or save as PDF', LucideIcons.fileText),
  csv('Excel / Google Sheets', '.csv sheet: every activity of the day', LucideIcons.fileSpreadsheet),
  json('JSON', 'All data for the day, for other tools', LucideIcons.braces);

  const _Format(this.label, this.hint, this.icon);
  final String label;
  final String hint;
  final IconData icon;
}

/// «Export data» → chiede che tipo di file, poi apre la condivisione del telefono.
class _ExportButton extends StatelessWidget {
  const _ExportButton({required this.enabled, required this.file});

  final bool enabled;
  final Future<({String name, String body, String mime})> Function(_Format format) file;

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final format = await showModalBottomSheet<_Format>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Which type of file do you want?', style: AppText.bodyMuted),
            ),
            for (final f in _Format.values)
              ListTile(
                leading: Icon(f.icon, size: 18, color: AppColors.muted),
                title: Text(f.label, style: AppText.body),
                subtitle: Text(f.hint, style: AppText.bodyMuted),
                onTap: () => Navigator.pop(ctx, f),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (format == null) return;
    try {
      final f = await file(format);
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/${f.name}');
      await out.writeAsString(f.body, encoding: utf8);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(out.path, mimeType: f.mime)],
          sharePositionOrigin: origin,
        ),
      );
    } on Object {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't export the report. Try again.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) =>
          PrimaryButton(label: 'Export data', icon: LucideIcons.download, onPressed: enabled ? () => _export(context) : null),
    );
  }
}
