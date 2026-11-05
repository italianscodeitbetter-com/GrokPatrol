import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/mock_data.dart' as demo;
import '../../data/models.dart';
import '../../data/ronda/ronda_client.dart';
import '../../shared/ui.dart';
import '../reports/day_picker.dart';
import 'mission_detail_page.dart';

/// Il giorno si sceglie in alto, come in Reports. In corso sopra, completate sotto: ogni card apre la missione.
class MissionsPage extends StatefulWidget {
  const MissionsPage({super.key, this.today});

  /// Solo per i test; di norma è la data del telefono.
  final String? today;

  @override
  State<MissionsPage> createState() => _MissionsPageState();
}

class _MissionsPageState extends State<MissionsPage> {
  ConsoleStore get _store => ConsoleStore.instance;
  String get _today => widget.today ?? isoDay(DateTime.now());

  late bool _live = _store.isLive;
  late String _day = _live ? _today : demo.shift.day;
  List<Mission>? _past;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (_store.isLive == _live) return;
    setState(() {
      _live = _store.isLive;
      _day = _live ? _today : demo.shift.day;
      _past = null;
    });
  }

  Future<void> _setDay(String day) async {
    setState(() {
      _day = day;
      _past = null;
    });
    if (!_live || day == _today) return;
    final from = parseDay(day);
    final start = DateTime(from.year, from.month, from.day), end = DateTime(from.year, from.month, from.day + 1);
    try {
      final list = await _store.missionsSince(start.millisecondsSinceEpoch / 1000, end.millisecondsSinceEpoch / 1000);
      if (mounted && _day == day) setState(() => _past = list);
    } on RondaFailure catch (e) {
      showMessage(e.message);
      if (mounted && _day == day) setState(() => _past = const []);
    }
  }

  List<Mission>? get _missions {
    if (!_live) return _day == demo.shift.day ? _store.missions : const [];
    return _day == _today ? _store.missions : _past;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final missions = _missions;
        final inProgress = missions?.where((m) => m.live).toList() ?? const <Mission>[];
        final completed = missions?.where((m) => !m.live).toList() ?? const <Mission>[];
        return ListView(
          padding: pagePadding(context),
          children: [
            const PageHeader(title: 'Missions', actions: _NewMissionButton()),
            DayPicker(value: _day, onChanged: _setDay, marked: [if (_live) _today else demo.shift.day], today: widget.today),
            const SizedBox(height: 20),
            if (missions == null)
              const Panel(
                child: Center(child: Text('Loading…', style: AppText.bodyMuted)),
              )
            else if (missions.isEmpty && (_live ? _day != _today : true))
              const Panel(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text('No missions for this day.', textAlign: TextAlign.center, style: AppText.bodyMuted),
                ),
              )
            else ...[
              _Section(
                title: 'In progress',
                icon: const Icon(LucideIcons.clockFading, size: 16, color: AppColors.amber300),
                missions: inProgress,
                empty: 'No missions in progress.',
              ),
              const SizedBox(height: 28),
              _Section(
                title: 'Completed',
                icon: const Icon(LucideIcons.circleCheck, size: 16, color: AppColors.ok),
                missions: completed,
                empty: 'No completed missions yet.',
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.missions, required this.empty});

  final String title;
  final Widget icon;
  final List<Mission> missions;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            icon,
            const SizedBox(width: 8),
            Text(title, style: AppText.section),
            const SizedBox(width: 8),
            CountChip(missions.length),
          ],
        ),
        const SizedBox(height: 12),
        if (missions.isEmpty)
          Panel(child: Text(empty, style: AppText.bodyMuted))
        else
          for (final (i, m) in missions.indexed) ...[if (i > 0) const SizedBox(height: 10), MissionCard(mission: m)],
      ],
    );
  }
}

/// «Automation» (partita da un'automazione) o «New mission» (creata a mano: chi l'ha creata sta nel dettaglio).
class OriginTag extends StatelessWidget {
  const OriginTag({super.key, required this.mission});

  final Mission mission;

  @override
  Widget build(BuildContext context) {
    return mission.automationId != null
        ? const ToneBadge(tone: Tone.blue, label: 'Automation', icon: LucideIcons.bot)
        : const ToneBadge(tone: Tone.gray, label: 'New mission', icon: LucideIcons.userRound, color: AppColors.violet300);
  }
}

/// Un solo stato: finché è in corso il passo (Queued, Verifying…), poi l'esito (Real anomaly / No anomaly).
class MissionState extends StatelessWidget {
  const MissionState({super.key, required this.mission});

  final Mission mission;

  @override
  Widget build(BuildContext context) => mission.live ? StatusBadge(mission.status) : OutcomeBadge(mission.outcome);
}

class MissionCard extends StatelessWidget {
  const MissionCard({super.key, required this.mission});

  final Mission mission;

  @override
  Widget build(BuildContext context) {
    final m = mission, store = ConsoleStore.instance;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => MissionDetailPage(mission: m))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(m.id, style: AppText.code.copyWith(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: m.eventTime, style: AppText.codeFaint),
                          if (m.roomId.isNotEmpty) TextSpan(text: ' · ${store.roomName(m.roomId)}'),
                        ],
                      ),
                      style: AppText.bodyMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  MissionState(mission: m),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Flexible(
                    child: Text(store.dogName(m.dogId), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
                  ),
                  if (m.battery != null) ...[const SizedBox(width: 8), BatteryTag(battery: m.battery)],
                ],
              ),
              const SizedBox(height: 8),
              OriginTag(mission: m),
              const SizedBox(height: 8),
              Text(m.trigger.label, style: AppText.body),
              Text(m.triggerLabel, style: AppText.bodyMuted),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Response ', style: AppText.bodyMuted),
                  Text(m.arrivalSeconds == null ? '—' : '${m.arrivalSeconds} s', style: AppText.code),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewMissionButton extends StatelessWidget {
  const _NewMissionButton();

  @override
  Widget build(BuildContext context) {
    return PrimaryButton(
      label: 'New mission',
      icon: LucideIcons.plus,
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final store = ConsoleStore.instance;
        final what = await showModalBottomSheet<String>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          builder: (_) => const _NewMissionSheet(),
        );
        if (what == null) return;
        if (store.isLive) {
          // la missione va a Grok, che la traduce in comandi per il cane
          messenger.showSnackBar(const SnackBar(content: Text('Asking Grok…')));
          String reply = '';
          final ok = await runCommand(() async => reply = await store.ask(what));
          if (ok) showMessage(reply);
          return;
        }
        // nei dati finti la missione resta locale
        messenger.showSnackBar(
          SnackBar(content: Text('“$what” created locally. Grok is not connected yet.'), duration: const Duration(seconds: 4)),
        );
      },
    );
  }
}

class _NewMissionSheet extends StatefulWidget {
  const _NewMissionSheet();

  @override
  State<_NewMissionSheet> createState() => _NewMissionSheetState();
}

class _NewMissionSheetState extends State<_NewMissionSheet> {
  final _what = TextEditingController();
  late String _room = ConsoleStore.instance.rooms.first.id;

  /// Dal vivo la stanza va nella frase per Grok.
  String get _message {
    final store = ConsoleStore.instance, what = _what.text.trim();
    return store.isLive ? '$what (${store.roomName(_room)})' : what;
  }

  @override
  void dispose() {
    _what.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('New mission', style: AppText.medium),
              const SizedBox(height: 16),
              const Text('What should the dog do', style: AppText.body),
              const SizedBox(height: 6),
              TextField(
                controller: _what,
                autofocus: true,
                textInputAction: TextInputAction.done,
                style: AppText.body,
                decoration: const InputDecoration(hintText: 'e.g. “check the east exit”'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              const Text('Room', style: AppText.body),
              const SizedBox(height: 6),
              SelectField(
                title: 'Room',
                value: _room,
                options: [for (final r in ConsoleStore.instance.rooms) (r.id, r.name)],
                onChanged: (v) => setState(() => _room = v),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
                  ),
                  const SizedBox(width: 8),
                  PrimaryButton(
                    label: 'Create mission',
                    onPressed: _what.text.trim().isEmpty ? null : () => Navigator.pop(context, _message),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
