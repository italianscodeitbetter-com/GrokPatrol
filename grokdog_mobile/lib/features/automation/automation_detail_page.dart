import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/models.dart';
import '../../data/ronda/live_view.dart';
import '../../data/stores.dart';
import '../../shared/ui.dart';
import '../missions/mission_detail_page.dart';
import 'automation_logic.dart';
import 'automation_page.dart';
import 'path_editor_page.dart';
import 'route_editor.dart';

/// La pagina di un'automazione: cosa fa, con quale robot, quando parte, il percorso e le missioni che ha fatto partire.
class AutomationDetailPage extends StatelessWidget {
  const AutomationDetailPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AutomationStore.instance, ConsoleStore.instance]),
      builder: (context, _) {
        final a = automationRows().where((x) => x.id == id).firstOrNull;
        return Scaffold(
          appBar: AppBar(title: const Text('Automation')),
          body: a == null
              ? Center(child: Text('Automation $id not found.', style: AppText.bodyMuted))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: _content(context, a)),
        );
      },
    );
  }

  List<Widget> _content(BuildContext context, Automation a) {
    final console = ConsoleStore.instance;
    final dog = console.fleet.where((d) => d.id == a.dogId).firstOrNull;
    final off = dog?.state == DogState.spento;
    final path = AutomationStore.instance.routeOf(a);
    final launched = console.missions.where((m) => m.automationId == a.id).toList();
    return [
      Text(a.name, style: AppText.title),
      const SizedBox(height: 2),
      Text(a.id, style: AppText.codeMuted),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ToneBadge(tone: a.active ? Tone.green : Tone.gray, label: a.active ? 'Active' : 'Paused'),
          for (final b in _actions(context, a)) IntrinsicWidth(child: b),
        ],
      ),
      const SizedBox(height: 16),
      Panel(
        title: 'Details',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            _Field(
              'Robot',
              dog == null
                  ? const Text('No robot', style: AppText.bodyFaint)
                  : Row(
                      children: [
                        RobotAvatar(off: off),
                        const SizedBox(width: 8),
                        Flexible(child: Text(dog.name, style: AppText.body)),
                        const SizedBox(width: 8),
                        BatteryTag(battery: dog.battery, off: off),
                      ],
                    ),
            ),
            _Field('Start', Text(a.startsAt ?? 'On event', style: a.startsAt == null ? AppText.body : AppText.code.copyWith(fontSize: 14))),
            _Field('When', Text(a.trigger, style: AppText.body)),
            _Field('What it does', Text(a.action, style: AppText.body)),
            Row(
              children: [
                Expanded(child: _Field('Last run', Text(a.lastRun ?? '—', style: AppText.code.copyWith(fontSize: 14)))),
                Expanded(child: _Field('Runs today', Text('${a.runsToday}', style: AppText.code.copyWith(fontSize: 14)))),
              ],
            ),
          ],
        ),
      ),
      if (path != null && path.route.isNotEmpty) ...[
        const SizedBox(height: 16),
        Panel(
          title: 'Route',
          count: path.route.length,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line),
                ),
                child: Column(
                  children: [
                    for (final (i, p) in path.route.indexed)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.line)),
                        ),
                        child: Row(
                          children: [
                            RoutePoint(i),
                            const SizedBox(width: 12),
                            Expanded(child: Text(roomAt(p), style: AppText.body)),
                            Text('${meters(p.x)} m, ${meters(p.y)} m', style: AppText.codeMuted),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (path.loop) ...[const SizedBox(height: 10), const Text('Returns to A at the end.', style: AppText.bodyMuted)],
            ],
          ),
        ),
      ],
      if (!a.custom) ...[
        const SizedBox(height: 16),
        Panel(
          title: 'Missions started',
          count: launched.length,
          padding: EdgeInsets.zero,
          child: launched.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No missions from this automation today.', style: AppText.bodyMuted),
                )
              : Column(
                  children: [
                    for (final (i, m) in launched.indexed)
                      InkWell(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MissionDetailPage(mission: m))),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.line)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(m.id, style: AppText.code),
                                    Text('${m.eventTime} · ${console.roomName(m.roomId)}', style: AppText.bodyMuted),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (m.live) StatusBadge(m.status) else OutcomeBadge(m.outcome),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    ];
  }

  List<Widget> _actions(BuildContext context, Automation a) {
    final console = ConsoleStore.instance, client = console.client;
    final store = AutomationStore.instance;
    Widget changePath() => GhostButton(
      label: 'Change path',
      icon: LucideIcons.route,
      height: 36,
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PathEditorPage(automation: a))),
    );
    Widget pause(VoidCallback run) => GhostButton(
      label: a.active ? 'Pause' : 'Resume',
      icon: a.active ? LucideIcons.pause : LucideIcons.play,
      height: 36,
      onPressed: run,
    );
    Widget delete(Future<void> Function() run) => GhostButton(
      label: 'Delete',
      icon: LucideIcons.trash2,
      height: 36,
      color: AppColors.red400,
      onPressed: () async {
        final yes = await confirm(context, text: 'Delete ${a.name}?', yes: 'Delete', danger: true);
        if (!yes) return;
        await run();
        if (context.mounted) Navigator.of(context).pop();
      },
    );

    if (!console.isLive) {
      return [
        changePath(),
        if (a.custom) ...[pause(() => store.setActive(a.id, active: !a.active)), delete(() => store.delete(a.id))],
      ];
    }
    if (a.id == alarmAutomationId) {
      return [
        GhostButton(
          label: a.active ? 'Disarm' : 'Arm alarm',
          icon: a.active ? LucideIcons.shieldOff : LucideIcons.shieldCheck,
          height: 36,
          onPressed: () => runCommand(() => console.command(a.active ? 'disarm' : 'arm', {'by': 'mobile'})),
        ),
      ];
    }
    if (a.custom && client != null) {
      return [
        changePath(),
        GhostButton(label: 'Run now', icon: LucideIcons.play, height: 36, onPressed: () => runCommand(() => client.runAutomation(a.id))),
        pause(() => runCommand(() => client.setAutomationActive(a.id, active: !a.active))),
        delete(() async => runCommand(() => client.deleteAutomation(a.id))),
      ];
    }
    // i percorsi del sito stanno nel file di configurazione del server: si avviano o si programmano, non si cambiano da qui
    return [
      GhostButton(
        label: 'Start now',
        icon: LucideIcons.play,
        height: 36,
        onPressed: () => runCommand(() => console.command('patrol', {'route': a.id, 'loops': 1})),
      ),
      GhostButton(
        label: a.active ? 'Change schedule' : 'Schedule',
        icon: LucideIcons.clock,
        height: 36,
        onPressed: () async {
          final every = await showChoiceSheet<int>(
            context,
            title: 'Repeat every',
            value: 0,
            options: const [(15, '15 minutes'), (30, '30 minutes'), (60, '1 hour'), (120, '2 hours'), (0, 'Never')],
          );
          if (every != null) await runCommand(() => console.command('schedule', {'route': a.id, 'every_min': every}));
        },
      ),
    ];
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.bodyFaint),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}
