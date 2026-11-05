import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/dog_drive.dart';
import '../../data/models.dart';
import '../../shared/ui.dart';
import 'estop_button.dart';

/// Il cane a tutto schermo: la sua telecamera di bordo e, se lo prendi, il controllo manuale.
/// Il cane si muove finché tieni premuto e si ferma quando lasci. La scena sta sotto, nella WebView: qui ci sono solo i comandi.
class DogView extends StatefulWidget {
  const DogView({super.key, required this.dog, required this.onClose, required this.onDrive, this.initialControl = false});

  final Dog dog;
  final VoidCallback onClose;

  /// Apre già col controllo preso («Take control» dalla vista che segue il cane).
  final bool initialControl;

  /// Comandi tenuti premuti; null = controllo rilasciato.
  final ValueChanged<Set<Move>?> onDrive;

  @override
  State<DogView> createState() => _DogViewState();
}

class _DogViewState extends State<DogView> {
  late bool _control = widget.initialControl;
  Set<Move> _held = const {};

  ConsoleStore get _store => ConsoleStore.instance;

  @override
  void initState() {
    super.initState();
    if (_control) _confirmInitialControl();
  }

  void _confirmInitialControl() => WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!mounted) return;
    if (_store.dogStatus?.isReal == true) {
      setState(() => _control = false);
      await _takeControl();
    } else {
      widget.onDrive(const {});
    }
  });

  @override
  void dispose() {
    widget.onDrive(null); // chiudendo la vista il controllo si rilascia
    super.dispose();
  }

  void _setHeld(Set<Move> next) {
    setState(() => _held = next);
    widget.onDrive(next);
  }

  /// Dal vivo i tasti funzionano solo se il comando può arrivare e il cane può muoversi.
  bool get _canDrive {
    if (!_store.isLive) return true;
    final d = _store.dogStatus;
    return _store.online && d != null && d.connected && d.armed && d.posture == 'standing';
  }

  void _press(Move m) {
    if (!_canDrive) return;
    HapticFeedback.selectionClick();
    if (!_held.contains(m)) _setHeld({..._held, m});
  }

  void _release(Move m) {
    if (_held.contains(m)) _setHeld({..._held}..remove(m));
  }

  Future<void> _takeControl() async {
    if (_store.dogStatus?.isReal == true) {
      final yes = await confirm(
        context,
        text: 'This is the real dog: it moves while you hold an arrow, and any mission is paused. People nearby?',
        yes: 'Take control',
      );
      if (!yes || !mounted) return;
    }
    setState(() => _control = true);
    widget.onDrive(const {});
  }

  void _releaseControl() {
    setState(() {
      _control = false;
      _held = const {};
    });
    widget.onDrive(null);
  }

  /// Perché i tasti non funzionano, da dire subito invece di lasciarli muti.
  String? get _blockedReason {
    if (_canDrive) return null;
    final d = _store.dogStatus;
    if (!_store.online) return 'No connection to the server: the dog stops by itself.';
    if (d == null || !d.connected) return 'The dog is not connected.';
    if (!d.armed) return 'Emergency stop engaged: release it to drive.';
    return 'The dog is lying down: stand it up from Controls.';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _store, builder: (context, _) => _buildView());

  Widget _buildView() {
    final dog = widget.dog, live = _store.isLive;
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: '${dog.name} full screen',
      child: Column(
        children: [
          _TopBar(dog: dog, onClose: widget.onClose),
          if (_control) _ControlInfo(live: live, blocked: _blockedReason, dogName: dog.name, held: _held),
          const Spacer(),
          _Bottom(
            child: _control
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Pad(held: _held, onPress: _press, onRelease: _release),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PrimaryButton(label: 'Release control', onPressed: _releaseControl),
                          // il cane si ferma lasciando i tasti: dal vivo resta però l'arresto d'emergenza
                          if (live) ...[const SizedBox(width: 8), const EstopButton()],
                        ],
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GhostButton(label: 'Close', onPressed: widget.onClose),
                      const SizedBox(width: 8),
                      PrimaryButton(label: 'Take control', onPressed: _takeControl),
                      if (live) ...[const SizedBox(width: 8), const EstopButton()],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.dog, required this.onClose});

  final Dog dog;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        // anche su un video chiaro i testi si devono leggere
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xF2000000), Color(0xB3000000), Color(0x00000000)],
          stops: [0, 0.65, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ToneBadge(tone: Tone.red, label: '● LIVE'),
                    const SizedBox(height: 4),
                    Text(dog.task, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(maxWidth: 210),
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(dog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
                    ),
                    const SizedBox(width: 8),
                    BatteryTag(battery: dog.battery),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: IconButton(
                  onPressed: onClose,
                  tooltip: 'Close',
                  constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                  padding: EdgeInsets.zero,
                  icon: const Icon(LucideIcons.x, size: 20, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le info del controllo manuale: in alto al centro.
class _ControlInfo extends StatelessWidget {
  const _ControlInfo({required this.live, required this.blocked, required this.dogName, required this.held});

  final bool live;
  final String? blocked;
  final String dogName;
  final Set<Move> held;

  @override
  Widget build(BuildContext context) {
    final status = held.isNotEmpty ? 'Moving: ${held.map((m) => m.label).join(' + ')}' : 'Hold an arrow to move, the round ones turn';
    return Container(
      width: double.infinity,
      // il video può essere chiarissimo: l'avviso dell'arresto d'emergenza deve leggersi comunque
      color: Colors.black.withValues(alpha: 0.78),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Pulse(),
              SizedBox(width: 8),
              Text('Manual control: mission paused', style: AppText.body),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            blocked ?? status,
            textAlign: TextAlign.center,
            style: blocked == null ? AppText.bodyMuted : AppText.body.copyWith(color: AppColors.red400),
          ),
          const SizedBox(height: 2),
          Text(
            live
                ? 'You are driving $dogName. When you let go, it stops within a second.'
                : 'You are driving the simulated dog. When released, it returns to its patrol.',
            textAlign: TextAlign.center,
            style: AppText.bodyMuted,
          ),
        ],
      ),
    );
  }
}

class _Bottom extends StatelessWidget {
  const _Bottom({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xF2000000), Color(0xB3000000), Color(0x00000000)],
          stops: [0, 0.7, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 32, 16, 16), child: child),
      ),
    );
  }
}

/// I tasti, in basso al centro: si tengono premuti.
class _Pad extends StatelessWidget {
  const _Pad({required this.held, required this.onPress, required this.onRelease});

  final Set<Move> held;
  final ValueChanged<Move> onPress, onRelease;

  @override
  Widget build(BuildContext context) {
    Widget pad(Move m, IconData icon) => _PadButton(move: m, icon: icon, held: held.contains(m), onPress: onPress, onRelease: onRelease);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            pad(Move.ruotaSx, LucideIcons.rotateCcw),
            pad(Move.avanti, LucideIcons.arrowUp),
            pad(Move.ruotaDx, LucideIcons.rotateCw),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            pad(Move.sinistra, LucideIcons.arrowLeft),
            pad(Move.indietro, LucideIcons.arrowDown),
            pad(Move.destra, LucideIcons.arrowRight),
          ],
        ),
      ],
    );
  }
}

/// Si tiene premuto: il cane va finché il dito resta giù. Listener e non GestureDetector, così parte subito al tocco.
class _PadButton extends StatelessWidget {
  const _PadButton({required this.move, required this.icon, required this.held, required this.onPress, required this.onRelease});

  final Move move;
  final IconData icon;
  final bool held;
  final ValueChanged<Move> onPress;
  final ValueChanged<Move> onRelease;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: move.label,
      onTap: () {
        onPress(move);
        onRelease(move);
      },
      child: Listener(
        onPointerDown: (_) => onPress(move),
        onPointerUp: (_) => onRelease(move),
        onPointerCancel: (_) => onRelease(move),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: held ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: held ? AppColors.accent : Colors.white.withValues(alpha: 0.10), width: held ? 2 : 1),
          ),
          child: Icon(icon, size: 20, color: AppColors.ink),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(color: AppColors.amber300, shape: BoxShape.circle),
      ),
    );
  }
}
