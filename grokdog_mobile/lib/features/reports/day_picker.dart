import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _week = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

String isoDay(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime parseDay(String s) => DateTime.parse('${s}T12:00:00');
String addDays(String s, int n) {
  final d = parseDay(s);
  return isoDay(DateTime(d.year, d.month, d.day + n, 12));
}

String formatDay(String s) {
  final d = parseDay(s);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// Si può andare solo indietro: dopo oggi non ci sono dati, quindi freccia e giorni futuri sono disattivati.
class DayPicker extends StatelessWidget {
  const DayPicker({super.key, required this.value, required this.onChanged, this.marked = const [], this.today});

  final String value;
  final ValueChanged<String> onChanged;
  final List<String> marked;

  /// Solo per i test; di norma è la data del telefono.
  final String? today;

  @override
  Widget build(BuildContext context) {
    final now = today ?? isoDay(DateTime.now());
    final atToday = value.compareTo(now) >= 0;
    return Row(
      children: [
        _Arrow(icon: LucideIcons.chevronLeft, label: 'Previous day', onTap: () => onChanged(addDays(value, -1))),
        const SizedBox(width: 6),
        Expanded(
          child: Material(
            color: AppColors.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                final picked = await showModalBottomSheet<String>(
                  context: context,
                  useRootNavigator: true,
                  builder: (_) => _CalendarSheet(value: value, today: now, marked: marked),
                );
                if (picked != null) onChanged(picked);
              },
              child: SizedBox(
                height: 36,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(LucideIcons.calendar, size: 16, color: AppColors.muted),
                    const SizedBox(width: 8),
                    Text(formatDay(value), style: AppText.body),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _Arrow(icon: LucideIcons.chevronRight, label: 'Next day', onTap: atToday ? null : () => onChanged(addDays(value, 1))),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.35 : 1,
      child: Material(
        color: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: 36,
            child: Icon(icon, size: 16, color: AppColors.muted, semanticLabel: label),
          ),
        ),
      ),
    );
  }
}

class _CalendarSheet extends StatefulWidget {
  const _CalendarSheet({required this.value, required this.today, required this.marked});

  final String value;
  final String today;
  final List<String> marked;

  @override
  State<_CalendarSheet> createState() => _CalendarSheetState();
}

class _CalendarSheetState extends State<_CalendarSheet> {
  late DateTime _month = parseDay(widget.value);

  bool _isFuture(String d) => d.compareTo(widget.today) > 0;

  @override
  Widget build(BuildContext context) {
    final y = _month.year, mo = _month.month;
    final lead = (DateTime(y, mo).weekday + 6) % 7; // lunedì per primo
    final days = DateTime(y, mo + 1, 0).day;
    final nextFirst = isoDay(DateTime(y, mo + 1));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _month = DateTime(y, mo - 1)),
                  tooltip: 'Previous month',
                  icon: const Icon(LucideIcons.chevronLeft, size: 16, color: AppColors.muted),
                ),
                Expanded(
                  child: Text('${_months[mo - 1]} $y', textAlign: TextAlign.center, style: AppText.body),
                ),
                IconButton(
                  onPressed: _isFuture(nextFirst) ? null : () => setState(() => _month = DateTime(y, mo + 1)),
                  tooltip: 'Next month',
                  icon: const Icon(LucideIcons.chevronRight, size: 16),
                  color: AppColors.muted,
                  disabledColor: AppColors.faint.withValues(alpha: 0.5),
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              childAspectRatio: 1.15,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final w in _week) Center(child: Text(w, style: AppText.bodyFaint)),
                for (var i = 0; i < lead; i++) const SizedBox.shrink(),
                for (var day = 1; day <= days; day++) _dayCell(isoDay(DateTime(y, mo, day)), day),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayCell(String d, int n) {
    final selected = d == widget.value;
    final future = _isFuture(d);
    final color = selected
        ? AppColors.app
        : future
        ? AppColors.faint.withValues(alpha: 0.5)
        : d == widget.today
        ? AppColors.accent
        : AppColors.ink.withValues(alpha: 0.9);
    return Padding(
      padding: const EdgeInsets.all(1),
      child: Material(
        color: selected ? AppColors.ink : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: future ? null : () => Navigator.pop(context, d),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                '$n',
                style: TextStyle(fontSize: 14, color: color, fontFeatures: AppText.tabular),
              ),
              if (widget.marked.contains(d) && !selected)
                Positioned(
                  bottom: 4,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
