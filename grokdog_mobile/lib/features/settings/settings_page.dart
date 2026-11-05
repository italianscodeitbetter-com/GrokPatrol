import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/mock_data.dart' show profile;
import '../../data/stores.dart';
import '../../shared/ui.dart';
import 'robots.dart';
import 'server_settings.dart';
import 'settings_ui.dart';

enum SettingsSection {
  server('Server', LucideIcons.server),
  general('Settings', LucideIcons.settings),
  alerts('Alerts', LucideIcons.bell),
  bots('Bots', LucideIcons.bot),
  grokbot('GrokBot', LucideIcons.sparkles),
  cameras('Cameras', LucideIcons.camera);

  const SettingsSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Una pagina per sezione. La sezione Shortcuts della web app non c'è: sono scorciatoie da tastiera.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(section.label)),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            // collegati al server si vede lo stato vero; i dati finti restano per la demo
            ListenableBuilder(
              listenable: ConsoleStore.instance,
              builder: (context, _) {
                final live = ConsoleStore.instance.isLive;
                return switch (section) {
                  SettingsSection.server => const ServerSettings(),
                  SettingsSection.general => _General(live: live),
                  SettingsSection.alerts => live ? const LiveAlertChannels() : const _Alerts(),
                  SettingsSection.bots => live ? const LiveBots() : const _BotsSettings(),
                  SettingsSection.grokbot => live ? const LiveGrok() : const _GrokBotSettings(),
                  SettingsSection.cameras => live ? const LiveCameras() : const _Cameras(),
                };
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _General extends StatelessWidget {
  const _General({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsGroup(
          title: 'Account',
          children: [
            SettingsRow(
              label: 'Name',
              below: SettingsTextField(initialValue: profile.name),
            ),
            SettingsRow(label: 'Email', trailing: ValueText(profile.email)),
            const SettingsRow(label: 'Profile picture', trailing: UserAvatar()),
          ],
        ),
        SettingsGroup(
          title: 'Shift',
          children: [
            SettingsRow(label: 'Role', trailing: ValueText(profile.role)),
            SettingsRow(label: 'Shift', trailing: ValueText(profile.shift)),
          ],
        ),
        if (live)
          SettingsGroup(
            title: 'Keys',
            note: 'The keys are on the server, in secrets/.env.',
            children: [SettingsRow(label: 'xAI', trailing: ValueText(grokState(ConsoleStore.instance)))],
          )
        else
          const SettingsGroup(
            title: 'Keys',
            note: 'Without a key, Grok runs on mock answers and alerts are written to the log instead of being sent.',
            children: [
              KeyRow(
                name: 'xAI',
                hint: 'Grok evaluates events, reads commands, describes what the dog sees and writes the alert.',
                placeholder: 'xai-••••••••••••••••',
              ),
              KeyRow(name: 'Twilio', hint: 'Sends the alert as a text message or a voice call.', placeholder: 'AC••••••••••••••••'),
            ],
          ),
      ],
    );
  }
}

class _Alerts extends StatelessWidget {
  const _Alerts();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SettingsGroup(
          title: 'Messages and calls',
          note: 'Alerts only go to the test number and to GrokBot. No real calls to security or the police.',
          children: [
            SettingsRow(
              label: 'Test number',
              hint: 'Receives every alert',
              below: SettingsTextField(initialValue: '+39 3XX XXX XX01', keyboardType: TextInputType.phone),
            ),
            SettingsRow(
              label: 'Channel',
              below: SettingsSelect(
                title: 'Channel',
                initial: 'sms',
                options: [('sms', 'Text message'), ('call', 'Voice call'), ('grokbot', 'GrokBot message')],
              ),
            ),
            SettingsRow(
              label: 'Also send to GrokBot',
              hint: 'Every alert also lands in the Grok chat, where you can reply to the dog',
              below: SettingsSelect(title: 'Also send to GrokBot', initial: 'yes', options: [('yes', 'Always'), ('no', 'Never')]),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Content',
          children: [
            SettingsRow(
              label: 'Attach frame',
              hint: "Adds the dog's frame to the message",
              below: SettingsSelect(title: 'Attach frame', initial: 'yes', options: [('yes', 'Always'), ('no', 'Never')]),
            ),
          ],
        ),
      ],
    );
  }
}

class _Cameras extends StatelessWidget {
  const _Cameras();

  @override
  Widget build(BuildContext context) {
    final store = ConsoleStore.instance;
    return Column(
      children: [
        SettingsGroup(
          title: 'Cameras',
          note: 'Each camera sends its events to Grok. The ones Grok can see from a chat are chosen in GrokBot.',
          children: [
            for (final c in store.cameras)
              SettingsRow(
                label: c.label,
                hint: '${store.roomName(c.roomId)} · rtsp://192.168.1.${20 + int.parse(c.id.split('-')[1])}/stream',
                trailing: const ToneBadge(tone: Tone.green, label: 'Online'),
              ),
          ],
        ),
        const SettingsGroup(
          title: 'Detection',
          note: 'Grok reads each camera event and decides whether to send the dog.',
          children: [
            SettingsRow(
              label: 'Event source',
              below: SettingsTextField(initialValue: 'http://localhost:5000', keyboardType: TextInputType.url),
            ),
            SettingsRow(
              label: 'Detector',
              below: SettingsSelect(title: 'Detector', initial: 'frigate', options: [('frigate', 'Frigate')]),
            ),
            SettingsRow(
              label: 'Anomalies to report',
              hint: 'Person in a restricted area, abandoned object',
              trailing: ValueText('2 types'),
            ),
          ],
        ),
      ],
    );
  }
}

class _GrokBotSettings extends StatelessWidget {
  const _GrokBotSettings();

  @override
  Widget build(BuildContext context) {
    const permission = [('ask', 'Ask me first'), ('yes', 'Always'), ('no', 'Never')];
    return ListenableBuilder(
      listenable: GrokBotStore.instance,
      builder: (context, _) {
        final store = GrokBotStore.instance;
        final status = store.status;
        return Column(
          children: [
            SettingsGroup(
              title: 'Connection',
              note: 'With GrokBot connected, you can drive the dogs and start missions directly from a Grok chat.',
              children: [
                SettingsRow(
                  label: 'GrokBot',
                  hint: status == GrokBotStatus.on ? 'Connected: Grok can see and drive the bots.' : 'Not connected',
                  trailing: SizedBox(width: 118, child: GrokBotConnectButton(store: store)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'What Grok can do',
              children: [
                const SettingsRow(
                  label: 'Drive the bots',
                  hint: 'Move a dog, stop it, send it to a point',
                  below: SettingsSelect(title: 'Drive the bots', initial: 'ask', options: permission),
                ),
                const SettingsRow(
                  label: 'Start missions',
                  hint: 'Create a mission from a chat message',
                  below: SettingsSelect(title: 'Start missions', initial: 'ask', options: permission),
                ),
                SettingsRow(
                  label: 'Bots Grok can use',
                  below: SettingsSelect(
                    title: 'Bots Grok can use',
                    initial: 'all',
                    options: [('all', 'All bots'), for (final d in ConsoleStore.instance.fleet) (d.id, d.name)],
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Cameras',
              note: 'Grok can show you these cameras in the chat and send a dog to what they see.',
              children: [
                for (final c in ConsoleStore.instance.cameras)
                  SettingsRow(
                    label: c.label,
                    hint: ConsoleStore.instance.roomName(c.roomId),
                    below: SettingsSelect(
                      title: c.label,
                      initial: 'yes',
                      options: const [('yes', 'Grok can see it'), ('ask', 'Ask me first'), ('no', 'Hidden from Grok')],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class GrokBotConnectButton extends StatelessWidget {
  const GrokBotConnectButton({super.key, required this.store});

  final GrokBotStore store;

  @override
  Widget build(BuildContext context) {
    final status = store.status;
    return switch (status) {
      GrokBotStatus.on => GhostButton(label: 'Disconnect', color: AppColors.muted, onPressed: store.toggle),
      GrokBotStatus.connecting => const PrimaryButton(label: 'Connecting…'),
      GrokBotStatus.off => PrimaryButton(label: 'Connect', onPressed: store.toggle),
    };
  }
}

/// I robot: importarli da un file, modificarli, collegarli. Per ora tutto resta in questa pagina.
class _BotsSettings extends StatefulWidget {
  const _BotsSettings();

  @override
  State<_BotsSettings> createState() => _BotsSettingsState();
}

class _BotsSettingsState extends State<_BotsSettings> {
  List<Robot> _robots = initialRobots();
  String? _editing;
  String? _note;

  void _update(String id, Robot Function(Robot) patch) {
    if (!mounted) return;
    setState(() => _robots = [for (final r in _robots) r.id == id ? patch(r) : r]);
  }

  void _toggle(Robot r) {
    if (r.status != RobotStatus.off) return _update(r.id, (x) => x.copyWith(status: RobotStatus.off));
    _update(r.id, (x) => x.copyWith(status: RobotStatus.connecting));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 1200), () => _update(r.id, (x) => x.copyWith(status: RobotStatus.on))));
  }

  Future<void> _import() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
    final f = files.firstOrNull;
    if (f == null) return;
    try {
      final added = parseRobots(utf8.decode(await f.readAsBytes()), startAt: _robots.length);
      if (!mounted) return;
      setState(() {
        _robots = [..._robots, ...added];
        _note = 'Imported ${added.length} ${added.length == 1 ? 'robot' : 'robots'} from ${f.name}. Connect them to start.';
      });
    } on FormatException {
      if (!mounted) return;
      setState(() => _note = "Couldn't read ${f.name}: use a JSON file with at least a \"name\" for each robot.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsGroup(
          header: Row(
            children: [
              const Expanded(child: Text('Robots', style: AppText.section)),
              GhostButton(label: 'Import robot', icon: LucideIcons.upload, height: 36, onPressed: _import),
            ],
          ),
          note: _note ?? 'The real and the simulated dog take the same commands: go to point, frame the scene, report position. Changes stay in this window for now.',
          children: [
            for (final r in _robots)
              if (_editing == r.id)
                _RobotForm(
                  key: ValueKey('edit-${r.id}'),
                  robot: r,
                  onCancel: () => setState(() => _editing = null),
                  onSave: (name, model, adapter) {
                    _update(
                      r.id,
                      (x) => x.copyWith(name: name.isEmpty ? null : name, model: model.isEmpty ? null : model, adapter: adapter),
                    );
                    setState(() => _editing = null);
                  },
                )
              else
                _RobotRow(robot: r, onEdit: () => setState(() => _editing = r.id), onToggle: () => _toggle(r)),
          ],
        ),
      ],
    );
  }
}

class _RobotRow extends StatelessWidget {
  const _RobotRow({required this.robot, required this.onEdit, required this.onToggle});

  final Robot robot;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final r = robot;
    final dot = switch (r.status) {
      RobotStatus.on => AppColors.ok,
      RobotStatus.connecting => AppColors.amber300,
      RobotStatus.off => AppColors.faint,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.row),
              ),
              BatteryTag(battery: r.battery),
            ],
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: r.id, style: AppText.codeMuted),
                TextSpan(text: ' · ${r.model} · ${r.adapter.label}'),
              ],
            ),
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GhostButton(label: 'Edit', icon: LucideIcons.pencil, height: 36, color: AppColors.muted, onPressed: onEdit),
              const SizedBox(width: 8),
              SizedBox(
                width: 136,
                child: switch (r.status) {
                  RobotStatus.on => GhostButton(label: 'Disconnect', height: 36, color: AppColors.muted, onPressed: onToggle),
                  RobotStatus.connecting => const PrimaryButton(label: 'Connecting…', height: 36),
                  RobotStatus.off => PrimaryButton(label: 'Connect', height: 36, onPressed: onToggle),
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RobotForm extends StatefulWidget {
  const _RobotForm({super.key, required this.robot, required this.onSave, required this.onCancel});

  final Robot robot;
  final void Function(String name, String model, Adapter adapter) onSave;
  final VoidCallback onCancel;

  @override
  State<_RobotForm> createState() => _RobotFormState();
}

class _RobotFormState extends State<_RobotForm> {
  late final _name = TextEditingController(text: widget.robot.name);
  late final _model = TextEditingController(text: widget.robot.model);
  late Adapter _adapter = widget.robot.adapter;

  @override
  void dispose() {
    _name.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(t, style: AppText.bodyMuted),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label('Name'),
          TextField(
            controller: _name,
            autofocus: true,
            style: AppText.body,
            decoration: const InputDecoration(fillColor: AppColors.panel),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          label('Model'),
          TextField(
            controller: _model,
            style: AppText.body,
            decoration: const InputDecoration(fillColor: AppColors.panel),
          ),
          const SizedBox(height: 12),
          label('Adapter'),
          SelectField(
            title: 'Adapter',
            value: _adapter,
            fill: AppColors.panel,
            options: [for (final a in Adapter.values) (a, a.label)],
            onChanged: (v) => setState(() => _adapter = v),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
              ),
              const SizedBox(width: 8),
              PrimaryButton(
                label: 'Save',
                onPressed: _name.text.trim().isEmpty ? null : () => widget.onSave(_name.text.trim(), _model.text.trim(), _adapter),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// La foto profilo dell'operatore, tonda.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: ColoredBox(
        color: AppColors.user,
        child: Image.asset('assets/images/avatar.png', width: size, height: size, fit: BoxFit.cover, semanticLabel: profile.name),
      ),
    );
  }
}
