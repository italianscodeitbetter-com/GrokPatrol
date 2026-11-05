import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../shared/ui.dart';
import 'estop_button.dart';
import 'grok_chat_sheet.dart';

void showControls(BuildContext context) {
  showModalBottomSheet<void>(context: context, useRootNavigator: true, isScrollControlled: true, builder: (_) => const _ControlsSheet());
}

/// Manda il cane in un posto. Prima lo chiede: il cane si muove davvero.
Future<void> sendDogTo(BuildContext context, String spotId) async {
  final store = ConsoleStore.instance;
  final name = store.site?.spot(spotId)?.name ?? spotId;
  final yes = await confirm(context, text: 'Send the dog to check $name?', yes: 'Send the dog');
  if (yes) await runCommand(() => store.command('send', {'spot': spotId}), done: 'Dog sent to $name');
}

const _scenes = {
  'intruder': 'Intruder',
  'visitor': 'Person passing',
  'bag': 'Bag left behind',
  'lights': 'Light change',
  'clear': 'Clear scene',
};

/// I comandi della console di Ronda.
class _ControlsSheet extends StatefulWidget {
  const _ControlsSheet();

  @override
  State<_ControlsSheet> createState() => _ControlsSheetState();
}

class _ControlsSheetState extends State<_ControlsSheet> {
  String? _route, _camera;

  ConsoleStore get _store => ConsoleStore.instance;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.82),
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final site = _store.site, alarm = _store.alarm, dog = _store.dogStatus, sim = _store.sim;
            if (site == null || dog == null) return const SizedBox(height: 120);
            final route = _route ?? site.routes.firstOrNull?.id;
            final camera = _camera ?? site.cameras.firstOrNull?.id;
            final patrolling = _store.tick?.current?.kind == 'patrol';
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                const Row(
                  children: [
                    Expanded(child: Text('Controls', style: AppText.medium)),
                    EstopButton(),
                  ],
                ),
                _Section(
                  'Alarm',
                  note: alarm?.armed == true && alarm?.active != true ? 'Active in ${alarm?.exitDelay} s' : null,
                  children: [
                    _Action(
                      alarm?.armed == true ? 'Disarm' : 'Arm alarm',
                      alarm?.armed == true ? LucideIcons.shieldOff : LucideIcons.shieldCheck,
                      () => runCommand(() => _store.command(alarm?.armed == true ? 'disarm' : 'arm', {'by': 'mobile'})),
                    ),
                  ],
                ),
                if (route != null)
                  _Section(
                    'Patrol',
                    head: SelectField(
                      title: 'Route',
                      value: route,
                      options: [for (final r in site.routes) (r.id, r.name)],
                      onChanged: (v) => setState(() => _route = v),
                    ),
                    children: [
                      _Action(
                        'Start patrol',
                        LucideIcons.route,
                        () => runCommand(() => _store.command('patrol', {'route': route, 'loops': 0})),
                      ),
                      if (patrolling) _Action('Stop patrol', LucideIcons.circleStop, () => runCommand(() => _store.command('stop_patrol'))),
                    ],
                  ),
                _Section(
                  'Dog',
                  children: [
                    _Action('Return to base', LucideIcons.house, () => runCommand(() => _store.command('home'))),
                    _Action(
                      'Stop',
                      LucideIcons.hand,
                      () => runCommand(() => _store.command('stop'), done: 'Missions cancelled, dog standing'),
                    ),
                    if (dog.posture == 'standing')
                      _Action('Lie down', LucideIcons.arrowDownToLine, () => runCommand(() => _store.command('lie')))
                    else
                      _Action('Stand up', LucideIcons.arrowUpFromLine, () => runCommand(() => _store.command('stand'))),
                  ],
                ),
                _Section(
                  'Send the dog to',
                  children: [for (final s in site.spots) _Action(s.name, LucideIcons.mapPin, () => sendDogTo(context, s.id))],
                ),
                if (sim?.connected == true && camera != null)
                  _Section(
                    'Stage a scene',
                    note: 'Simulator only',
                    head: SelectField(
                      title: 'Camera',
                      value: camera,
                      options: [for (final c in site.cameras) (c.id, c.name)],
                      onChanged: (v) => setState(() => _camera = v),
                    ),
                    children: [
                      for (final id in sim!.scenarios)
                        _Action(
                          _scenes[id] ?? id,
                          LucideIcons.clapperboard,
                          () => runCommand(() => _store.command('stage', {'scenario': id, 'camera': camera})),
                        ),
                    ],
                  ),
                _Section(
                  'Shift',
                  children: [
                    _Action('Ask Grok', LucideIcons.sparkles, () => showGrokChat(context)),
                    _Action(
                      'Test event',
                      LucideIcons.flaskConical,
                      () => runCommand(() => _store.command('test_event', {'camera': camera, 'kind': 'manual'})),
                    ),
                    _Action('New shift', LucideIcons.calendarPlus, () async {
                      final yes = await confirm(
                        context,
                        text: 'Start a new shift? Counters and the incident list are reset.',
                        yes: 'New shift',
                      );
                      if (yes) await runCommand(() => _store.command('new_shift'));
                    }),
                    _Action('Reset everything', LucideIcons.rotateCcw, () async {
                      final where = dog.isReal ? 'The real dog stops where it is.' : 'The dog goes back to its base.';
                      final yes = await confirm(
                        context,
                        text:
                            'Reset everything?\n\nThe alarm is disarmed. Missions, schedules, staged scenes, incidents, counters and the chat are cleared. $where\nThe full log stays in the database.',
                        yes: 'Reset',
                        danger: true,
                      );
                      if (yes) await runCommand(() => _store.command('reset_all'));
                    }),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.children, this.head, this.note});

  final String title;
  final Widget? head;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppText.bodyMuted)),
              if (note != null) Text(note!, style: AppText.bodyFaint),
            ],
          ),
          const SizedBox(height: 8),
          if (head != null) ...[head!, const SizedBox(height: 8)],
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
    child: GhostButton(label: label, icon: icon, height: 38, onPressed: onTap),
  );
}
