import 'package:flutter/material.dart';

import '../data/ronda/ronda_client.dart';
import 'theme.dart';

/// Serve alla dashboard per fermare la mappa quando una pagina la copre.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

/// «View all» nelle notifiche: porta ai Report, sulla tabella Activity.
final showReportsActivity = ValueNotifier<int>(0);

/// Un link da Telegram con una missione che non c'è: porta alla scheda Missions.
final showMissions = ValueNotifier<int>(0);

/// Un link da Telegram con un evento senza missione: porta alla dashboard e apre le notifiche.
final showActivityPanel = ValueNotifier<int>(0);

/// Per mostrare un messaggio da dove non c'è un contesto a portata di mano.
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showMessage(String text) => rootMessengerKey.currentState
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

/// Esegue un comando al server: se non va, l'operatore deve saperlo. Restituisce true se è andato.
Future<bool> runCommand(Future<Object?> Function() action, {String? done}) async {
  try {
    await action();
    if (done != null) showMessage(done);
    return true;
  } on RondaFailure catch (e) {
    showMessage(e.message);
    return false;
  }
}

/// Domanda prima di un'azione che muove il cane o cancella dati.
Future<bool> confirm(BuildContext context, {required String text, required String yes, bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
      content: Text(text, style: AppText.body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            yes,
            style: TextStyle(color: danger ? AppColors.red400 : AppColors.ink, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
  return ok ?? false;
}
