import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../dashboard/map_view.dart';
import 'automation_logic.dart';

/// Il percorso che si sta disegnando. A è dove si trova il robot e non si toglie, i punti a mano partono da B.
/// I controlli su muri e oggetti li fa la scena 3D, in modo asincrono: finché la risposta non è quella dell'ultima modifica non si salva.
class RouteDraft extends ChangeNotifier {
  RouteDraft({this.anchor, List<PlanPoint> picks = const [], this.loop = false}) : _picks = picks; // ignore: prefer_initializing_formals

  PlanPoint? anchor;
  List<PlanPoint> _picks;
  bool loop;
  int _seq = 0, _checkedSeq = 0;
  List<int> _bad = const [];

  List<PlanPoint> get picks => _picks;
  List<PlanPoint> get points => [?anchor, ..._picks];
  int get seq => _seq;
  bool get checked => _checkedSeq == _seq;
  List<String> get badLabels => legLabels(_bad, points.length);

  /// Il percorso si può salvare: almeno due punti, controllato, nessun tratto nel muro.
  bool get valid => points.length >= 2 && checked && _bad.isEmpty;

  void _changed() {
    _seq++;
    notifyListeners();
  }

  void add(PlanPoint p) {
    _picks = [..._picks, p];
    _changed();
  }

  void undo() {
    _picks = _picks.sublist(0, _picks.length - 1);
    _changed();
  }

  void clear() {
    _picks = const [];
    _changed();
  }

  /// [index] è la posizione nel percorso: A del robot non si toglie.
  void removeAt(int index) {
    _picks = [..._picks]..removeAt(index - (anchor == null ? 0 : 1));
    _changed();
  }

  void setLoop(bool value) {
    loop = value;
    _changed();
  }

  void setAnchor(PlanPoint value) {
    anchor = value;
    _changed();
  }

  void checkedBy(int seq, List<int> bad) {
    if (seq != _seq) return;
    _checkedSeq = seq;
    _bad = bad;
    notifyListeners();
  }
}

/// La mappa 3D dove si toccano i punti, con la riga d'aiuto in alto e gli avvisi: sul telefono il modulo sta sotto la piega.
class RouteMap extends StatefulWidget {
  const RouteMap({super.key, required this.draft, required this.doneHint});

  final RouteDraft draft;

  /// Cosa fare quando il percorso è pronto, es. «or create the automation».
  final String doneHint;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  late final MapController _map = MapController(pick: true, insets: (top: 44, bottom: 0), onPick: _onPick, onRoute: widget.draft.checkedBy);
  bool _miss = false;
  Timer? _missTimer;
  int _sentSeq = -1;

  RouteDraft get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_onDraft);
    _map.ready.addListener(_sync); // il percorso che c'era già si vede subito
  }

  @override
  void dispose() {
    _missTimer?.cancel();
    _draft.removeListener(_onDraft);
    _map.ready.removeListener(_sync);
    _map.dispose();
    super.dispose();
  }

  void _onDraft() {
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    if (!_map.ready.value || _sentSeq == _draft.seq) return;
    _sentSeq = _draft.seq;
    _map.setRoute(_draft.points, loop: _draft.loop, seq: _draft.seq);
  }

  void _onPick(PlanPoint? p) {
    _missTimer?.cancel();
    if (p == null) {
      setState(() => _miss = true);
      _missTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _miss = false);
      });
      return;
    }
    setState(() => _miss = false);
    _draft.add(p);
  }

  String get _hint {
    final n = _draft.points.length;
    if (n == 0) return 'Tap the floor to set A, where the bot starts';
    if (n == 1) {
      return _draft.anchor != null ? 'A is where the robot is. Tap the floor to set B, where it goes' : 'Now tap where it goes: B';
    }
    return 'Tap to add ${letter(n)}, ${widget.doneHint}';
  }

  @override
  Widget build(BuildContext context) {
    final bad = _draft.badLabels;
    final alert = _miss
        ? 'That spot is a wall or an object: pick a free spot on the floor.'
        : bad.isEmpty
        ? null
        : '${bad.join(', ')} ${bad.length == 1 ? 'goes' : 'go'} through a wall or an object: add a point in between.';
    return Stack(
      fit: StackFit.expand,
      children: [
        MapView(controller: _map, semanticLabel: '3D floor plan: tap the floor to add route points'),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: IgnorePointer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: AppColors.app.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)),
                        child: Text(_hint, style: const TextStyle(fontSize: 13, color: AppColors.ink)),
                      ),
                      if (alert case final text?) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A1A1C),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.red400.withValues(alpha: 0.3)),
                          ),
                          child: Text(text, style: const TextStyle(fontSize: 13, color: AppColors.red400)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: AppColors.app.withValues(alpha: 0.85),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: AppColors.line),
                ),
                clipBehavior: Clip.antiAlias,
                child: IconButton(
                  onPressed: _map.reset,
                  tooltip: 'Reset view',
                  constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                  padding: EdgeInsets.zero,
                  icon: const Icon(LucideIcons.rotateCcw, size: 16, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// L'elenco dei punti con Undo / Clear e «Return to A».
class RouteSteps extends StatelessWidget {
  const RouteSteps({super.key, required this.draft});

  final RouteDraft draft;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) {
        final points = draft.points, skip = draft.anchor == null ? 0 : 1, none = draft.picks.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Route', style: AppText.body)),
                TextButton.icon(
                  onPressed: none ? null : draft.undo,
                  icon: const Icon(LucideIcons.undo2, size: 14),
                  label: const Text('Undo'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted, visualDensity: VisualDensity.compact),
                ),
                TextButton(
                  onPressed: none ? null : draft.clear,
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted, visualDensity: VisualDensity.compact),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (points.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line),
                ),
                child: Column(
                  children: [
                    for (final (i, p) in points.indexed)
                      Container(
                        padding: const EdgeInsets.only(left: 12, right: 4),
                        constraints: const BoxConstraints(minHeight: 44),
                        decoration: BoxDecoration(
                          border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.line)),
                        ),
                        child: Row(
                          children: [
                            RoutePoint(i),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  text: roomAt(p),
                                  children: [
                                    if (i < skip)
                                      const TextSpan(
                                        text: ' · where the robot is',
                                        style: TextStyle(color: AppColors.muted),
                                      ),
                                  ],
                                ),
                                style: AppText.body,
                              ),
                            ),
                            Text('${meters(p.x)} m, ${meters(p.y)} m', style: AppText.codeMuted),
                            if (i < skip)
                              const SizedBox(width: 36)
                            else
                              IconButton(
                                onPressed: () => draft.removeAt(i),
                                tooltip: 'Remove point ${letter(i)}',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(LucideIcons.x, size: 14, color: AppColors.faint),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (none) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(LucideIcons.mousePointerClick, size: 16, color: AppColors.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        draft.anchor != null
                            ? 'A is where the robot is now. Tap the floor on the map to choose where it goes: B, then C…'
                            : 'Tap the floor on the map: the first tap is A (where it starts), the next ones B, C…',
                        style: AppText.bodyMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            CheckboxListTile(
              value: draft.loop,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Return to A at the end', style: AppText.bodyMuted),
              onChanged: (v) => draft.setLoop(v ?? false),
            ),
          ],
        );
      },
    );
  }
}

/// Il pallino arancione con la lettera del punto.
class RoutePoint extends StatelessWidget {
  const RoutePoint(this.index, {super.key});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
      child: Text(
        letter(index),
        style: const TextStyle(fontFamily: AppText.mono, fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.app),
      ),
    );
  }
}
