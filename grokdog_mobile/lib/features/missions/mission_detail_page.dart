import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/models.dart';
import '../../shared/live_image.dart';
import '../../shared/ui.dart';
import '../dashboard/map_view.dart';

/// Una pagina per missione: lo stato, la timeline e il video.
class MissionDetailPage extends StatelessWidget {
  const MissionDetailPage({super.key, required this.mission});

  final Mission mission;

  @override
  Widget build(BuildContext context) {
    // dal vivo la missione va avanti mentre la si guarda
    return ListenableBuilder(
      listenable: ConsoleStore.instance,
      builder: (context, _) => _build(context, ConsoleStore.instance.missionById(mission.id, eventId: mission.eventId) ?? mission),
    );
  }

  Widget _build(BuildContext context, Mission m) {
    final store = ConsoleStore.instance;
    final live = m.live;
    final roomName = store.roomName(m.roomId);
    final title = m.roomId.isEmpty ? m.id : '${m.id} · $roomName';
    final video = live && store.isLive && store.dogHasVideo;
    return Scaffold(
      appBar: AppBar(title: const Text('Missions')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(title, style: AppText.title),
          const SizedBox(height: 12),
          Row(
            children: [
              OutcomeBadge(m.outcome),
              const Spacer(),
              // il server salva le foto del controllo, non i video
              if (!store.isLive)
                GhostButton(
                  label: 'Download video',
                  icon: LucideIcons.download,
                  height: 36,
                  // il file arriverà dalla registrazione del cane: in web va ancora messo a mano in public/videos
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No recording for ${m.id} yet.'))),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (video) ...[
            Panel(
              title: 'Dog video',
              action: const ToneBadge(tone: Tone.red, label: '● LIVE'),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: const LiveImage(camera: 'dog', label: 'Dog camera offline'),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          for (final image in m.images) ...[
            Panel(
              title: image.caption,
              action: Text(m.eventTime, style: AppText.bodyMuted),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ServerImage(path: image.path),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // nella demo la telecamera di bordo è simulata dalla scena 3D: dal vivo se la missione è in corso, altrimenti la registrazione
          if (!store.isLive)
            Panel(
              title: live ? 'Dog video' : 'Recording',
              action: live ? const ToneBadge(tone: Tone.red, label: '● LIVE') : Text(m.eventTime, style: AppText.bodyMuted),
              child: _DogCam(dogId: m.dogId, tag: '${m.id} · ${m.eventId}', live: live, at: m.eventTime),
            ),
          if (!store.isLive) const SizedBox(height: 16),
          Panel(
            title: 'Mission status',
            action: StatusBadge(m.status),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Fact('Trigger', '${m.trigger.label} · ${m.triggerLabel}'),
                _Fact('Event', '${m.eventId} · ${m.eventTime}', mono: true),
                if (m.createdBy case final by? when !store.isLive) _Fact('Created by', by),
                _Fact('Robot', store.dogName(m.dogId)),
                _Fact('Saw', m.sighting ?? (m.live ? 'Not on site yet' : 'Nothing seen on site')),
                _Fact('Response time', m.arrivalSeconds == null ? '—' : '${m.arrivalSeconds} s', mono: true),
                const SizedBox(height: 16),
                Timeline(steps: m.steps),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// La telecamera di bordo di un cane da sola: la stessa scena 3D, disegnata solo da dove guarda il cane.
class _DogCam extends StatefulWidget {
  const _DogCam({required this.dogId, required this.tag, required this.live, required this.at});

  final String dogId, tag, at;
  final bool live;

  @override
  State<_DogCam> createState() => _DogCamState();
}

class _DogCamState extends State<_DogCam> {
  late final MapController _map = MapController();
  Timer? _clock;

  ConsoleStore get _store => ConsoleStore.instance;
  Dog? get _dog => _store.dogs.where((d) => d.id == widget.dogId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _map.ready.addListener(_onReady);
    if (widget.live) _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  void _onReady() {
    if (_map.ready.value) _map.setPov(widget.dogId, cover: true);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _map.ready.removeListener(_onReady);
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dog = _dog, now = TimeOfDay.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final second = DateTime.now().second;
    Widget tag(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: AppText.code.copyWith(color: AppColors.ink.withValues(alpha: 0.8))),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (dog == null)
              const ColoredBox(
                color: AppColors.app,
                child: Center(child: Text('Camera offline', style: AppText.bodyFaint)),
              )
            else
              MapView(controller: _map, semanticLabel: '${dog.name} front camera'),
            Positioned(left: 8, top: 8, child: tag(widget.tag)),
            Positioned(
              right: 8,
              top: 8,
              child: tag(widget.live ? '${two(now.hour)}:${two(now.minute)}:${two(second)}' : 'REC ${widget.at}'),
            ),
            if (dog != null) Positioned(left: 8, bottom: 8, child: tag('${dog.name} · front camera')),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: AppText.bodyMuted)),
          Expanded(child: Text(value, style: mono ? AppText.code.copyWith(fontSize: 14) : AppText.body)),
        ],
      ),
    );
  }
}

class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.steps});

  final List<MissionStep> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final (i, s) in steps.indexed) _TimelineRow(step: s, last: i == steps.length - 1)],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.step, required this.last});

  final MissionStep step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final done = step.time != null;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 11,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? AppColors.accent.withValues(alpha: 0.8) : AppColors.app,
                    border: Border.all(color: done ? AppColors.accent : AppColors.faint),
                  ),
                ),
                if (!last) Expanded(child: Container(width: 1, color: AppColors.line)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(step.step.label, style: done ? AppText.body : AppText.bodyMuted)),
                      Text(step.time ?? '—', style: done ? AppText.code : AppText.codeFaint),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text.rich(TextSpan(children: whiteNumbers(step.detail)), style: AppText.bodyMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Orari, secondi, frame e sigle con numero (CAM-3, MS-0088, P1, #8812) in bianco, il resto del testo resta grigio.
final _number = RegExp(r'((?:\b[A-Z]{2,3}-|\bP|(?<![A-Za-z\d]))[#+]?\d+(?::\d+)*(?![A-Za-z])(?: s\b)?)');

List<TextSpan> whiteNumbers(String text) {
  final spans = <TextSpan>[];
  var at = 0;
  for (final m in _number.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(
      TextSpan(
        text: m[0],
        style: const TextStyle(color: AppColors.ink),
      ),
    );
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}
