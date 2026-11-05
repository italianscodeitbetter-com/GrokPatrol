import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/deep_link.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/models.dart';
import 'mission_detail_page.dart';

/// La pagina aperta da un link di Telegram: sta sopra la barra in basso come il dettaglio aperto dalla lista.
Route<void> deepLinkRoute(DeepLink link, {RouteSettings? settings}) =>
    MaterialPageRoute<void>(settings: settings ?? RouteSettings(name: link.route), builder: (_) => DeepLinkPage(link: link));

/// Un link che l'app non conosce, o grokpatrol://open senza percorso: niente pagina, al massimo un messaggio.
/// Una rotta trasparente che si chiude da sola; non è una PageRoute, così routeObserver non ferma la mappa.
Route<void> closingRoute(RouteSettings settings, {String? message}) => RawDialogRoute<void>(
  settings: settings,
  barrierDismissible: false,
  barrierColor: null,
  transitionDuration: Duration.zero,
  pageBuilder: (_, _, _) => _ClosingPage(message: message),
);

const unknownLinkMessage = "This link can't be opened in GrokPatrol.";

/// Cerca la missione del link nei dati del server. All'avvio da freddo il collegamento può essere ancora in corso:
/// si aspetta con la rotella, poi si mostra il dettaglio. Se non si trova si torna alle schede con un messaggio.
class DeepLinkPage extends StatefulWidget {
  const DeepLinkPage({super.key, required this.link});

  final DeepLink link;

  /// Dopo il collegamento, quanto si aspetta un evento appena nato prima di arrendersi.
  static const grace = Duration(seconds: 5);

  @override
  State<DeepLinkPage> createState() => _DeepLinkPageState();
}

class _DeepLinkPageState extends State<DeepLinkPage> {
  ConsoleStore get _store => ConsoleStore.instance;

  Mission? _mission;
  Timer? _giveUp;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    if (_store.isLive) _mission = missionForLink(widget.link, _store.missions);
    if (_mission != null) return;
    _store.addListener(_resolve);
    // chiudere la pagina o cambiare scheda si fa dopo il primo frame, non mentre il Navigator la sta montando
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  @override
  void dispose() {
    _store.removeListener(_resolve);
    _giveUp?.cancel();
    super.dispose();
  }

  String get _what => widget.link.kind == DeepLinkKind.mission ? 'Mission ${widget.link.id}' : 'Event ${widget.link.id}';

  void _resolve() {
    if (!mounted || _left || _mission != null) return;
    switch (_store.mode) {
      case ConsoleMode.connecting:
        return; // la rotella resta finché il collegamento non finisce, in un senso o nell'altro
      case ConsoleMode.demo:
        _leave(
          _store.serverUrl.isEmpty
              ? 'Links from Telegram need the live server. Connect from the avatar → Server.'
              : "Can't reach the server, so $_what can't be opened. Check the connection from the avatar → Server.",
        );
      case ConsoleMode.live:
        final m = missionForLink(widget.link, _store.missions);
        if (m != null) {
          _giveUp?.cancel();
          _store.removeListener(_resolve);
          setState(() => _mission = m);
          return;
        }
        // un evento appena nato può arrivare un attimo dopo, con il websocket o il refresh al ritorno dallo sfondo
        _giveUp ??= Timer(DeepLinkPage.grace, _notFound);
    }
  }

  void _notFound() {
    if (!mounted || _left || _mission != null) return;
    if (widget.link.kind == DeepLinkKind.mission) {
      _leave("$_what isn't in this shift. Pick its day in Missions.", then: () => showMissions.value++);
    } else {
      _leave('$_what has no mission. Here is the latest activity.', then: () => showActivityPanel.value++);
    }
  }

  /// Toglie questa pagina e torna alle schede.
  void _leave(String message, {VoidCallback? then}) {
    _left = true;
    _giveUp?.cancel();
    _store.removeListener(_resolve);
    final route = ModalRoute.of(context);
    final nav = Navigator.of(context);
    if (route != null && route.isActive) {
      if (route.isCurrent) {
        nav.pop();
      } else {
        nav.removeRoute(route);
      }
    }
    then?.call();
    showMessage(message);
  }

  @override
  Widget build(BuildContext context) {
    final mission = _mission;
    if (mission != null) return MissionDetailPage(mission: mission);
    final connecting = _store.mode == ConsoleMode.connecting;
    return Scaffold(
      appBar: AppBar(title: const Text('Missions')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted)),
            const SizedBox(height: 16),
            Text('Opening ${widget.link.id}…', style: AppText.body),
            if (connecting) ...[const SizedBox(height: 4), const Text('Connecting to the server…', style: AppText.bodyMuted)],
          ],
        ),
      ),
    );
  }
}

class _ClosingPage extends StatefulWidget {
  const _ClosingPage({this.message});

  final String? message;

  @override
  State<_ClosingPage> createState() => _ClosingPageState();
}

class _ClosingPageState extends State<_ClosingPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context), nav = Navigator.of(context);
      if (route != null && route.isActive) {
        if (route.isCurrent) {
          nav.pop();
        } else {
          nav.removeRoute(route);
        }
      }
      if (widget.message case final m?) showMessage(m);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
