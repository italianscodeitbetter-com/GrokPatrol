import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/mock_data.dart' as demo;
import '../../data/models.dart';
import '../../data/ronda/live_view.dart';
import '../../data/stores.dart';
import '../../shared/ui.dart';
import 'automation_logic.dart';
import 'route_editor.dart';

/// Nuova automazione: A è dove si trova il robot scelto, poi si tocca la mappa 3D per i punti dopo (B, C…)
/// e si sceglie a che ora parte. Collegati al server si salva lì, così parte anche ad app chiusa.
class AutomationBuilderPage extends StatefulWidget {
  const AutomationBuilderPage({super.key});

  @override
  State<AutomationBuilderPage> createState() => _AutomationBuilderPageState();
}

class _AutomationBuilderPageState extends State<AutomationBuilderPage> {
  final _name = TextEditingController();
  ConsoleStore get _console => ConsoleStore.instance;
  late String _dogId = _console.dogs.first.id;
  late final _draft = RouteDraft(anchor: _console.spotOf(_console.dogs.first));

  String _start = '09:00';
  Repeat _repeat = Repeat.daily;
  int _every = 60;
  String _until = '18:00';
  List<int> _days = const [1, 3, 5];

  @override
  void initState() {
    super.initState();
    _draft.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _draft.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _intervalOk => _repeat != Repeat.interval || _until.compareTo(_start) > 0;
  bool get _daysOk => _repeat != Repeat.days || _days.isNotEmpty;
  bool get _canSave => _name.text.trim().isNotEmpty && _draft.valid && _intervalOk && _daysOk;

  Future<void> _save() async {
    if (!_canSave) return;
    final points = _draft.points, loop = _draft.loop;
    if (_console.isLive) {
      final tr = SiteTransform.of(_console.site!);
      final ok = await runCommand(
        () => _console.client!.addAutomation({
          'name': _name.text.trim(),
          'points': [
            for (final p in points) [tr.toSite(p).x, tr.toSite(p).y],
          ],
          'loop': loop,
          'start': _start,
          'repeat': _repeat.name,
          if (_repeat == Repeat.days) 'days': _days,
          if (_repeat == Repeat.interval) ...{'every_min': _every, 'until': _until},
        }),
      );
      if (ok && mounted) Navigator.pop(context);
      return;
    }
    final store = AutomationStore.instance;
    await store.save(
      buildAutomation(
        id: nextAutomationId([...demo.automations, ...store.items]),
        name: _name.text,
        dogId: _dogId,
        points: points,
        loop: loop,
        start: _start,
        repeat: _repeat,
        every: _every,
        until: _until,
        days: _days,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickTime(String current, ValueChanged<String> onChanged) async {
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (picked != null) {
      onChanged('${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _pickRobot() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Robot', style: AppText.bodyMuted),
              ),
            ),
            for (final d in _console.fleet)
              ListTile(
                dense: true,
                enabled: d.state != DogState.spento,
                onTap: () => Navigator.pop(ctx, d.id),
                title: _RobotLine(d),
                trailing: Icon(LucideIcons.check, size: 16, color: d.id == _dogId ? AppColors.accent : Colors.transparent),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (id == null || id == _dogId) return;
    setState(() => _dogId = id);
    _draft.setAnchor(_console.spotOf(_console.fleet.firstWhere((d) => d.id == id)));
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('New automation')),
      body: Column(
        children: [
          // la mappa si chiude mentre si scrive: con la tastiera aperta non resterebbe spazio per il modulo
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: keyboard ? 0 : MediaQuery.sizeOf(context).height * 0.36,
            child: RouteMap(draft: _draft, doneHint: 'or create the automation'),
          ),
          Expanded(child: _form()),
          RouteFormFooter(
            action: 'Create',
            enabled: _canSave,
            onSave: _save,
            blocked: _draft.badLabels.isNotEmpty ? '${_draft.badLabels.join(', ')} blocked: fix the route' : null,
          ),
        ],
      ),
    );
  }

  Widget _form() {
    final dog = _console.fleet.where((d) => d.id == _dogId).firstOrNull ?? _console.fleet.first;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _Label('Name'),
        TextField(
          controller: _name,
          style: AppText.body,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Morning check Room 3'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 18),
        const _Label('Robot'),
        Material(
          color: AppColors.app,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: AppColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _pickRobot,
            child: Container(
              height: 44,
              padding: const EdgeInsets.only(left: 12, right: 10),
              child: Row(
                children: [
                  Expanded(child: _RobotLine(dog)),
                  const SizedBox(width: 8),
                  const Icon(LucideIcons.chevronDown, size: 16, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        RouteSteps(draft: _draft),
        const SizedBox(height: 14),
        const _Label('When it starts'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Field('Start at', _TimeField(value: _start, onTap: () => _pickTime(_start, (v) => setState(() => _start = v)))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Field(
                'Repeat',
                SelectField(
                  title: 'Repeat',
                  value: _repeat,
                  options: const [
                    (Repeat.once, 'Once'),
                    (Repeat.daily, 'Every day'),
                    (Repeat.weekdays, 'Mon–Fri'),
                    (Repeat.days, 'Specific days'),
                    (Repeat.interval, 'Every… until'),
                  ],
                  onChanged: (v) => setState(() => _repeat = v),
                ),
              ),
            ),
          ],
        ),
        if (_repeat == Repeat.days) ...[
          const SizedBox(height: 12),
          _Field(
            'On',
            Row(
              spacing: 4,
              children: [
                for (final (i, w) in weekdays.indexed)
                  Expanded(
                    child: _DayChip(
                      label: w,
                      on: _days.contains(i + 1),
                      onTap: () => setState(() {
                        _days = _days.contains(i + 1) ? [..._days.where((d) => d != i + 1)] : ([..._days, i + 1]..sort());
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (_repeat == Repeat.interval) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Field(
                  'Every',
                  SelectField(
                    title: 'Every',
                    value: _every,
                    options: [
                      for (final m in const [15, 30, 60, 120]) (m, everyLabel(m)),
                    ],
                    onChanged: (v) => setState(() => _every = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Field('Until', _TimeField(value: _until, onTap: () => _pickTime(_until, (v) => setState(() => _until = v)))),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Text(repeatText(_repeat, _start, _every, _until, _days), style: AppText.bodyMuted),
        if (!_daysOk) ...[const SizedBox(height: 6), const _Warning('Pick at least one day.')],
        if (!_intervalOk) ...[const SizedBox(height: 6), const _Warning('«Until» must be after the start time.')],
      ],
    );
  }
}

/// Il fondo fisso dei moduli: Annulla, Salva e, se il percorso non passa, il motivo.
class RouteFormFooter extends StatelessWidget {
  const RouteFormFooter({super.key, required this.action, required this.enabled, required this.onSave, this.blocked});

  final String action;
  final bool enabled;
  final VoidCallback onSave;
  final String? blocked;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: blocked == null
                    ? const SizedBox.shrink()
                    : Text(
                        blocked!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(color: AppColors.red400),
                      ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
              ),
              const SizedBox(width: 8),
              PrimaryButton(label: action, onPressed: enabled ? onSave : null),
            ],
          ),
        ),
      ),
    );
  }
}

class _RobotLine extends StatelessWidget {
  const _RobotLine(this.dog);

  final Dog dog;

  @override
  Widget build(BuildContext context) {
    final off = dog.state == DogState.spento;
    return Row(
      children: [
        RobotAvatar(off: off),
        const SizedBox(width: 10),
        Expanded(
          child: Text(dog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: off ? AppText.bodyFaint : AppText.body),
        ),
        if (off)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text('Off', style: AppText.bodyFaint),
          ),
        BatteryTag(battery: dog.battery, off: off),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: on ? AppColors.accent.withValues(alpha: 0.15) : AppColors.app,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: on ? AppColors.accent.withValues(alpha: 0.6) : AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 36,
          child: Center(
            child: Text(label, style: TextStyle(fontSize: 13, color: on ? AppColors.ink : AppColors.muted)),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: AppText.body),
  );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppText.bodyMuted),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({required this.value, required this.onTap});

  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.app,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(child: Text(value, style: AppText.code.copyWith(fontSize: 14))),
              const Icon(LucideIcons.clock, size: 16, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppText.body.copyWith(color: AppColors.red400));
  }
}
