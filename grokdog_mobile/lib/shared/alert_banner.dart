import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../data/console_store.dart';
import 'live_image.dart';

/// L'alert del server: compare sopra a qualsiasi pagina e resta finché l'operatore non lo chiude.
class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: ConsoleStore.instance.alert,
      builder: (context, alert, _) {
        if (alert == null) return const SizedBox.shrink();
        final channels = [for (final r in alert.results) '${r.channel} ${r.ok ? 'sent' : 'failed'}'].join(', ');
        return Positioned(
          left: 12,
          right: 12,
          top: MediaQuery.paddingOf(context).top + 8,
          child: Material(
            color: const Color(0xFF2A1416),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: AppColors.red400.withValues(alpha: 0.5)),
            ),
            clipBehavior: Clip.antiAlias,
            elevation: 12,
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (alert.image case final path?) SizedBox(height: 150, child: ServerImage(path: path)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(LucideIcons.triangleAlert, size: 18, color: AppColors.red400),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(alert.title, style: AppText.medium),
                              const SizedBox(height: 2),
                              Text(alert.body, style: AppText.body),
                              const SizedBox(height: 4),
                              Text(
                                [if (alert.place.isNotEmpty) alert.place, if (channels.isNotEmpty) channels].join(' · '),
                                style: AppText.bodyMuted,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => ConsoleStore.instance.alert.value = null,
                          // niente tooltip: il banner sta sopra il Navigator e lì non c'è un Overlay
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(LucideIcons.x, size: 16, color: AppColors.muted, semanticLabel: 'Dismiss alert'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
