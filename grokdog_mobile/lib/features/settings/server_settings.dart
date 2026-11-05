import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/ronda/ronda_client.dart';
import '../../data/ronda/ronda_link.dart';
import '../../shared/live_image.dart';
import '../../shared/ui.dart';
import 'settings_ui.dart';

/// Il collegamento al server Ronda. Sulla stessa rete basta l'indirizzo, dal tunnel pubblico serve anche il PIN.
class ServerSettings extends StatefulWidget {
  const ServerSettings({super.key});

  @override
  State<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettings> {
  final _store = ConsoleStore.instance;
  // RONDA_URL = indirizzo già pronto, per una build fatta per una postazione
  late final _url = TextEditingController(text: _store.serverUrl.isNotEmpty ? _store.serverUrl : const String.fromEnvironment('RONDA_URL'));
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.connect(_url.text, pin: _pin.text.trim().isEmpty ? null : _pin.text.trim());
      _pin.clear();
    } on RondaFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final yes = await confirm(context, text: 'Disconnect from the server? The app goes back to demo data.', yes: 'Disconnect');
    if (yes) await _store.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final live = _store.isLive;
        return Column(
          children: [
            SettingsGroup(
              title: 'Connection',
              note: 'On the same network as the server: http://<server ip>:8000. From anywhere else: the https address printed by ./public.sh, with its PIN.',
              children: [
                SettingsRow(
                  label: 'Server address',
                  below: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(hintText: 'http://192.168.1.8:8000', fillColor: AppColors.panel),
                  ),
                ),
                SettingsRow(
                  label: 'PIN',
                  hint: 'Only through the public tunnel',
                  below: TextField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: AppText.code.copyWith(fontSize: 14),
                    decoration: const InputDecoration(hintText: '••••••••', fillColor: AppColors.panel),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        Text(_error!, style: AppText.body.copyWith(color: AppColors.red400)),
                        const SizedBox(height: 10),
                      ],
                      PrimaryButton(
                        label: _busy ? 'Connecting…' : (live ? 'Connect again' : 'Connect'),
                        onPressed: _busy ? null : _connect,
                      ),
                      if (live) ...[const SizedBox(height: 8), GhostButton(label: 'Disconnect and use demo data', onPressed: _disconnect)],
                    ],
                  ),
                ),
              ],
            ),
            if (live) const _Status(),
          ],
        );
      },
    );
  }
}

class _Status extends StatelessWidget {
  const _Status();

  // ascolta da sé: è const nella pagina, e un widget const non si ridisegna con il padre
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final store = ConsoleStore.instance;
    final tick = store.tick;
    if (tick == null) return const SizedBox.shrink();
    final d = tick.dog, g = tick.grok;
    final fixed = tick.cameras.where((c) => c.id != 'dog' && c.id != 'sim-view');
    return SettingsGroup(
      title: store.site?.name ?? 'Status',
      children: [
        SettingsRow(
          label: 'Link',
          trailing: ValueText(switch (store.link) {
            LinkState.live => 'Live',
            LinkState.polling => 'Polling every second',
            LinkState.offline => 'Offline, retrying',
          }),
        ),
        SettingsRow(label: 'Dog', trailing: ValueText(d.connected ? (d.armed ? d.kind.toUpperCase() : 'Emergency stop') : 'Not connected')),
        SettingsRow(label: 'Grok', trailing: ValueText(grokState(store))),
        SettingsRow(label: 'Cameras', trailing: ValueText('${fixed.where((c) => c.online).length} of ${fixed.length} online')),
        SettingsRow(label: 'Simulator', trailing: ValueText(tick.sim.connected ? 'Connected' : 'Off')),
        SettingsRow(
          label: 'Alert channels',
          trailing: Flexible(child: ValueText(tick.alertChannels.join(', '))),
        ),
        if (g.error != null) SettingsRow(label: 'Grok error', hint: g.error),
      ],
    );
  }
}

String grokState(ConsoleStore store) {
  final g = store.grok;
  if (g == null || !g.configured) return 'No key: rules take over';
  if (!g.enabled) return 'Paused';
  return g.lastMs == null ? 'Ready' : 'Ready · ${g.lastMs} ms';
}

/// Il cane vero: stato, postura, casa e posti da imparare sul campo.
class LiveBots extends StatefulWidget {
  const LiveBots({super.key});

  @override
  State<LiveBots> createState() => _LiveBotsState();
}

class _LiveBotsState extends State<LiveBots> {
  final _store = ConsoleStore.instance;
  final _spotId = TextEditingController();
  final _spotName = TextEditingController();

  @override
  void dispose() {
    _spotId.dispose();
    _spotName.dispose();
    super.dispose();
  }

  Future<void> _teach() async {
    final id = _spotId.text.trim();
    if (id.isEmpty) return;
    final ok = await runCommand(() => _store.command('teach', {'id': id, 'name': _spotName.text.trim()}), done: 'Spot saved here');
    if (ok) {
      _spotId.clear();
      _spotName.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _store, builder: (context, _) => _content());

  Widget _content() {
    final d = _store.dogStatus, dog = _store.dogs.first;
    if (d == null) return const SizedBox.shrink();
    return Column(
      children: [
        SettingsGroup(
          title: 'Robot',
          children: [
            SettingsRow(label: dog.name, hint: dog.task, trailing: ValueText(dog.battery == null ? '—' : '${dog.battery}%')),
            SettingsRow(label: 'Position', trailing: ValueText('${d.x.toStringAsFixed(2)}, ${d.y.toStringAsFixed(2)} m')),
            SettingsRow(label: 'Posture', trailing: ValueText(d.posture)),
            SettingsRow(label: 'Link', trailing: ValueText(d.link)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  GhostButton(label: 'Stand up', height: 36, onPressed: () => runCommand(() => _store.command('stand'))),
                  GhostButton(label: 'Lie down', height: 36, onPressed: () => runCommand(() => _store.command('lie'))),
                  GhostButton(
                    label: 'Set home here',
                    height: 36,
                    onPressed: () async {
                      final yes = await confirm(context, text: "Set the dog's current position as its home spot?", yes: 'Set home');
                      if (yes) await runCommand(() => _store.command('zero'));
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Save spot here',
          note: 'Drive the dog to a place and save it: the spot is added to the map.',
          children: [
            SettingsRow(
              label: 'Id',
              below: TextField(
                controller: _spotId,
                autocorrect: false,
                style: AppText.body,
                decoration: const InputDecoration(hintText: 'p5', fillColor: AppColors.panel),
              ),
            ),
            SettingsRow(
              label: 'Name',
              below: TextField(
                controller: _spotName,
                style: AppText.body,
                decoration: const InputDecoration(hintText: 'Entrance', fillColor: AppColors.panel),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: GhostButton(label: 'Save spot', icon: LucideIcons.mapPinPlus, onPressed: _teach),
            ),
          ],
        ),
      ],
    );
  }
}

class LiveCameras extends StatelessWidget {
  const LiveCameras({super.key});

  void _open(BuildContext context, String id, String name) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(name, style: AppText.medium),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: LiveImage(camera: id, fit: BoxFit.contain),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ascolta da sé: è const nella pagina, e un widget const non si ridisegna con il padre
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final store = ConsoleStore.instance, tick = store.tick;
    if (tick == null) return const SizedBox.shrink();
    final dc = tick.dogcam;
    return Column(
      children: [
        SettingsGroup(
          title: 'Cameras',
          note: 'Tap a camera to watch it live. Calibration is in the console on the Mac.',
          children: [
            for (final c in tick.cameras.where((c) => c.id != 'sim-view'))
              InkWell(
                onTap: c.online ? () => _open(context, c.id, c.name) : null,
                child: SettingsRow(
                  label: c.name,
                  hint: [
                    if (c.isPhone) 'phone',
                    if (c.simulated) 'simulated',
                    if (c.calibrated) 'calibrated',
                    if (c.streamFps > 0) '${c.streamFps.round()} fps',
                  ].join(' · ').ifEmpty(c.id),
                  trailing: ToneBadge(tone: c.online ? Tone.green : Tone.gray, label: c.online ? 'Online' : 'Offline'),
                ),
              ),
          ],
        ),
        const _AddPhone(),
        if (dc != null)
          SettingsGroup(
            title: 'Dog head camera',
            note: "It stops Unitree's camera program on the head Jetson: the obstacle cameras come back only after a reboot of the dog.",
            children: [
              SettingsRow(
                label: dc.state == 'streaming' ? 'Streaming' : 'Stopped',
                hint: dc.error,
                trailing: GhostButton(
                  label: dc.state == 'streaming' ? 'Stop' : 'Start',
                  height: 36,
                  onPressed: () async {
                    final start = dc.state != 'streaming';
                    final yes = await confirm(
                      context,
                      text: '${start ? 'Start' : 'Stop'} the head camera stream on the Go1?',
                      yes: start ? 'Start camera' : 'Stop',
                    );
                    if (yes) unawaited(runCommand(() => store.client!.dogcam(start ? 'start' : 'stop')));
                  },
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Trasforma un telefono in una telecamera: la pagina si apre nel browser del telefono, che gli dà la fotocamera.
class _AddPhone extends StatefulWidget {
  const _AddPhone();

  @override
  State<_AddPhone> createState() => _AddPhoneState();
}

class _AddPhoneState extends State<_AddPhone> {
  late final Future<PhonePage>? _page = ConsoleStore.instance.client?.phonePage();

  @override
  Widget build(BuildContext context) {
    final client = ConsoleStore.instance.client;
    return FutureBuilder<PhonePage>(
      future: _page,
      builder: (context, snap) {
        final page = snap.data;
        if (client == null || page == null) return const SizedBox.shrink();
        return SettingsGroup(
          title: 'Add a phone',
          note: 'Same Wi-Fi as the server. Accept the certificate warning, allow the camera and leave the page open: the phone shows up in the list above.',
          children: [
            SettingsRow(
              label: 'Phone page',
              hint: page.url,
              below: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: Colors.white,
                      child: ServerImage(path: '/api/qr.png?data=${Uri.encodeComponent(page.url)}', fit: BoxFit.contain, size: 160),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: 'Use this phone as a camera',
                    icon: LucideIcons.smartphone,
                    height: 40,
                    onPressed: () => unawaited(launchUrl(Uri.parse(page.url), mode: LaunchMode.externalApplication)),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class LiveGrok extends StatelessWidget {
  const LiveGrok({super.key});

  // ascolta da sé: è const nella pagina, e un widget const non si ridisegna con il padre
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final store = ConsoleStore.instance, g = store.grok;
    if (g == null) return const SizedBox.shrink();
    return SettingsGroup(
      title: 'Grok',
      note: 'The xAI key is on the server, in secrets/.env. Without it, rules take over and the log says so.',
      children: [
        SettingsRow(
          label: 'Status',
          trailing: Flexible(child: ValueText(grokState(store))),
        ),
        SettingsRow(
          label: 'Model',
          trailing: Flexible(child: ValueText(g.model)),
        ),
        SettingsRow(label: 'Calls', trailing: ValueText('${g.calls}')),
        if (g.error != null) SettingsRow(label: 'Last error', hint: g.error),
        if (g.configured && !g.enabled)
          Padding(
            padding: const EdgeInsets.all(16),
            child: GhostButton(label: 'Enable Grok again', onPressed: () => runCommand(() => store.command('grok_retry'))),
          ),
      ],
    );
  }
}

class LiveAlertChannels extends StatelessWidget {
  const LiveAlertChannels({super.key});

  // ascolta da sé: è const nella pagina, e un widget const non si ridisegna con il padre
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final tick = ConsoleStore.instance.tick;
    if (tick == null) return const SizedBox.shrink();
    Widget row(String id, String label, String hint) {
      final on = tick.alertChannels.contains(id);
      return SettingsRow(
        label: label,
        hint: hint,
        trailing: ToneBadge(tone: on ? Tone.green : Tone.gray, label: on ? 'On' : 'Off'),
      );
    }

    return SettingsGroup(
      title: 'Channels',
      note: 'Channels and test numbers are set on the server, in secrets/.env. Alerts only go to the test number.',
      children: [
        row('console', 'Console', 'Banner in this app and in the console'),
        row('telegram', 'Telegram', tick.telegramChats == 0 ? 'Photo of the scene' : 'Photo of the scene, ${tick.telegramChats} chats'),
        row('sms', 'SMS', 'Twilio'),
        row('call', 'Voice call', 'Twilio, severity 3 or more'),
      ],
    );
  }
}
