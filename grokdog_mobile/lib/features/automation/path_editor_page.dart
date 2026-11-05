import 'package:flutter/material.dart';

import '../../core/nav.dart';
import '../../data/console_store.dart';
import '../../data/models.dart';
import '../../data/ronda/live_view.dart';
import '../../data/stores.dart';
import '../../core/theme.dart';
import 'automation_builder_page.dart';
import 'automation_logic.dart';
import 'route_editor.dart';

/// «Change path»: lo stesso editor della nuova automazione, solo per il percorso. Il percorso di prima si vede subito.
class PathEditorPage extends StatefulWidget {
  const PathEditorPage({super.key, required this.automation});

  final Automation automation;

  @override
  State<PathEditorPage> createState() => _PathEditorPageState();
}

class _PathEditorPageState extends State<PathEditorPage> {
  ConsoleStore get _console => ConsoleStore.instance;
  Dog? get _dog => _console.fleet.where((d) => d.id == widget.automation.dogId).firstOrNull;

  late final RouteDraft _draft = () {
    final anchor = _dog == null ? null : _console.spotOf(_dog!);
    final current = AutomationStore.instance.routeOf(widget.automation);
    final route = current?.route ?? const <PlanPoint>[];
    return RouteDraft(anchor: anchor, picks: route.skip(anchor == null ? 0 : 1).toList(), loop: current?.loop ?? false);
  }();

  @override
  void initState() {
    super.initState();
    _draft.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final points = _draft.points, loop = _draft.loop, a = widget.automation;
    if (_console.isLive) {
      final tr = SiteTransform.of(_console.site!);
      final ok = await runCommand(() => _console.client!.setAutomationRoute(a.id, [for (final p in points) tr.toSite(p)], loop: loop));
      if (ok && mounted) Navigator.pop(context);
      return;
    }
    await AutomationStore.instance.setRoute(
      a.id,
      points,
      loop: loop,
      action: walkText(points, loop: loop),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Change path')),
      body: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: keyboard ? 0 : MediaQuery.sizeOf(context).height * 0.42,
            child: RouteMap(draft: _draft, doneHint: 'or save the path'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('${widget.automation.name} · ${_dog?.name ?? 'No robot'}', style: AppText.bodyMuted),
                const SizedBox(height: 8),
                RouteSteps(draft: _draft),
              ],
            ),
          ),
          RouteFormFooter(
            action: 'Save path',
            enabled: _draft.valid,
            onSave: _save,
            blocked: _draft.badLabels.isNotEmpty ? '${_draft.badLabels.join(', ')} blocked: fix the route' : null,
          ),
        ],
      ),
    );
  }
}
