import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/models.dart';
import '../../data/stores.dart';
import '../../shared/ui.dart';
import 'automation_builder_page.dart';
import 'automation_detail_page.dart';
import 'automation_logic.dart';

/// Le automazioni: quale robot, quando parte, cosa fa. Una card apre la sua pagina.
class AutomationPage extends StatelessWidget {
  const AutomationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AutomationStore.instance, ConsoleStore.instance]),
      builder: (context, _) {
        final rows = automationRows();
        return ListView.separated(
          padding: pagePadding(context),
          itemCount: rows.length + 1,
          separatorBuilder: (_, i) => SizedBox(height: i == 0 ? 0 : 10),
          itemBuilder: (context, i) {
            if (i == 0) {
              return PageHeader(
                title: 'Automation',
                actions: PrimaryButton(
                  label: 'New automation',
                  icon: LucideIcons.plus,
                  onPressed: () => Navigator.of(
                    context,
                    rootNavigator: true,
                  ).push(MaterialPageRoute<void>(builder: (_) => const AutomationBuilderPage())),
                ),
              );
            }
            return _AutomationCard(automation: rows[i - 1]);
          },
        );
      },
    );
  }
}

/// Tutte le automazioni: quelle di sistema più quelle create con «New automation».
List<Automation> automationRows() {
  final console = ConsoleStore.instance;
  return console.isLive ? console.systemAutomations : [...console.systemAutomations, ...AutomationStore.instance.items];
}

class _AutomationCard extends StatelessWidget {
  const _AutomationCard({required this.automation});

  final Automation automation;

  @override
  Widget build(BuildContext context) {
    final a = automation, console = ConsoleStore.instance;
    final dog = console.fleet.where((d) => d.id == a.dogId).firstOrNull;
    final off = dog?.state == DogState.spento;
    final repeats = a is CustomAutomation ? repeatLabel(a) : a.repeats;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => AutomationDetailPage(id: a.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (dog != null) ...[
                    RobotAvatar(off: off),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(dog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
                    ),
                    const SizedBox(width: 8),
                    BatteryTag(battery: dog.battery, off: off),
                  ],
                  const Spacer(),
                  const SizedBox(width: 8),
                  ToneBadge(tone: a.active ? Tone.green : Tone.gray, label: a.active ? 'Active' : 'Paused'),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Flexible(
                    child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.medium),
                  ),
                  const SizedBox(width: 8),
                  Text(a.id, style: AppText.codeFaint),
                  if (a.custom) ...[const SizedBox(width: 8), const ToneBadge(tone: Tone.amber, label: 'Custom')],
                ],
              ),
              const SizedBox(height: 2),
              Text(a.action, style: AppText.bodyMuted),
              const SizedBox(height: 10),
              if (a.startsAt case final start?)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: start, style: AppText.code.copyWith(fontSize: 14)),
                      if (repeats != null) TextSpan(text: '  $repeats'),
                    ],
                  ),
                  style: AppText.bodyMuted,
                )
              else
                const ToneBadge(tone: Tone.gray, label: 'On event'),
            ],
          ),
        ),
      ),
    );
  }
}
