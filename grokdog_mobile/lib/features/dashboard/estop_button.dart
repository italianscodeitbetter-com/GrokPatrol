import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';

/// L'arresto d'emergenza. Parte subito, senza domande; per sbloccarlo invece si conferma, come nella console.
class EstopButton extends StatelessWidget {
  const EstopButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ConsoleStore.instance,
      builder: (context, _) {
        final store = ConsoleStore.instance;
        final engaged = store.dogStatus?.armed == false;
        return Semantics(
          button: true,
          label: engaged ? 'Release emergency stop' : 'Emergency stop',
          excludeSemantics: true,
          child: Material(
            color: engaged ? AppColors.amber300 : AppColors.red600,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                if (!engaged) {
                  await HapticFeedback.heavyImpact();
                  // nessun messaggio: coprirebbe il pulsante, che diventa già «Release»
                  await runCommand(() => store.command('estop'));
                  return;
                }
                final yes = await confirm(context, text: 'Release the emergency stop? The dog can move again.', yes: 'Release');
                if (yes) await runCommand(() => store.command('reset'));
              },
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.octagon, size: 15, color: engaged ? AppColors.app : Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      engaged ? 'Release' : 'E-stop',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: engaged ? AppColors.app : Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
