import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/dog_drive.dart';
import '../../data/models.dart';

typedef MapInsets = ({double top, double bottom});

/// Telecomando della scena 3D. La scena è la stessa three.js della web app e gira in una WebView:
/// Dart le passa i dati e i comandi, lei risponde con i tocchi (vedi map_src/scene.ts).
class MapController {
  MapController({this.pick = false, this.insets = (top: 0, bottom: 0), this.onCamera, this.onDog, this.onSpot, this.onPick, this.onRoute});

  final bool pick;

  /// Pixel coperti dagli overlay: la pianta si inquadra nello spazio che resta.
  MapInsets insets;
  final ValueChanged<String>? onCamera;
  final ValueChanged<String>? onDog;

  /// Dal vivo: un posto toccato sulla mappa.
  final ValueChanged<String>? onSpot;

  /// Punto toccato sul pavimento; null se lì c'è un muro o un oggetto.
  final ValueChanged<PlanPoint?>? onPick;

  /// Risposta a [setRoute]: i tratti che passano in un muro e il numero della richiesta.
  final void Function(int seq, List<int> badLegs)? onRoute;

  final ready = ValueNotifier<bool>(false);
  final error = ValueNotifier<String?>(null);

  late final WebViewController web = _open();

  WebViewController _open() {
    final controller = WebViewController();
    unawaited(_load(controller));
    return controller;
  }

  /// Un passo alla volta: il canale si registra in modo asincrono e, se la pagina partisse prima,
  /// non lo troverebbe e la scena resterebbe in attesa per sempre senza dare errori.
  Future<void> _load(WebViewController controller) async {
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(AppColors.app);
      await controller.addJavaScriptChannel('GrokMapBridge', onMessageReceived: (m) => _onMessage(m.message));
      await controller.setNavigationDelegate(NavigationDelegate(onWebResourceError: (e) => error.value ??= e.description));
      await controller.loadFlutterAsset('assets/map/index.html');
    } on Exception catch (e) {
      error.value ??= '$e';
    }
  }

  void _onMessage(String raw) {
    final m = jsonDecode(raw) as Map<String, Object?>;
    switch (m['type']) {
      case 'boot':
        _call('init', [_config()]);
      case 'ready':
        ready.value = true;
        _sent.clear();
        sync();
      case 'error':
        error.value = m['message'] as String?;
      case 'camera':
        onCamera?.call(m['id']! as String);
      case 'dog':
        onDog?.call(m['id']! as String);
      case 'spot':
        onSpot?.call(m['id']! as String);
      case 'pick':
        final p = m['point'] as Map<String, Object?>?;
        onPick?.call(p == null ? null : PlanPoint.fromJson(p));
      case 'route':
        onRoute?.call(m['seq']! as int, [for (final i in m['bad']! as List<Object?>) i! as int]);
    }
  }

  Map<String, Object?> _config() {
    final store = ConsoleStore.instance;
    final frame = store.frame.value;
    return {
      'pick': pick,
      'live': store.isLive,
      'insets': _insets(insets),
      'rooms': [
        for (final r in store.rooms) {'id': r.id, 'name': r.name, 'x': r.x, 'y': r.y, 'w': r.w, 'h': r.h},
      ],
      'patrolPoints': [for (final p in store.patrolPoints) _point(p)],
      'spots': [for (final p in store.spots) _point(p)],
      'cameras': [for (final c in store.cameras) _point(c)],
      'dogs': [
        for (final d in store.dogs)
          {
            'id': d.id,
            'name': d.name,
            'battery': d.battery,
            'state': d.state.name,
            'route': [for (final p in d.route) p.toJson()],
            if (frame != null) ...{'x': frame.position.x, 'y': frame.position.y, 'heading': frame.heading},
          },
      ],
      'events': _events(),
    };
  }

  List<Map<String, Object?>> _events() => [
    for (final e in ConsoleStore.instance.events)
      {'id': e.id, 'x': e.x, 'y': e.y, 'anomaly': e.anomaly, 'priority': e.priority.name, 'status': e.status.wire},
  ];

  // quello che è già stato mandato alla scena: ricostruirla a ogni aggiornamento sarebbe uno spreco
  final _sent = <String, String>{};

  void _sendChanged(String method, Object? value) {
    final encoded = jsonEncode(value);
    if (_sent[method] == encoded) return;
    _sent[method] = encoded;
    _send(method, [value]);
  }

  /// Porta nella scena lo stato del server: posizione del cane, eventi, percorso.
  void sync() {
    final store = ConsoleStore.instance;
    final frame = store.frame.value;
    if (!store.isLive || frame == null) return;
    final p = frame.position;
    _send('setDogPose', [store.dogs.first.id, p.x, p.y, frame.heading, frame.speed]);
    _sendChanged('setEvents', _events());
    _sendChanged('setPatrol', [for (final x in store.patrolPoints) _point(x)]);
    _sendChanged('setPath', [for (final x in frame.path) x.toJson()]);
    _sendChanged('setActors', [
      for (final a in frame.actors) {'id': a.id, 'kind': a.kind, 'x': a.at.x, 'y': a.at.y},
    ]);
  }

  /// Ricostruisce la scena: nuovo sito, o passaggio fra demo e server.
  void reload() {
    ready.value = false;
    error.value = null;
    unawaited(web.reload());
  }

  Map<String, Object?> _insets(MapInsets i) => {'top': i.top, 'bottom': i.bottom};

  Map<String, Object?> _point(MapPoint p) => {'id': p.id, 'label': p.label, 'roomId': p.roomId, 'x': p.x, 'y': p.y};

  void _call(String method, List<Object?> args) {
    final js = 'window.grokMap.$method(${args.map(jsonEncode).join(',')})';
    unawaited(web.runJavaScript(js).catchError((Object e) => debugPrint('mappa: $method fallito: $e')));
  }

  /// I comandi prima di «ready» si perderebbero: la scena ha già gli stessi valori di partenza.
  void _send(String method, List<Object?> args) {
    if (ready.value) _call(method, args);
  }

  void reset() => _send('reset', []);
  void focusRoom(String? roomId) => _send('focusRoom', [roomId]);
  void setFollowing(String? dogId) => _send('setFollowing', [dogId]);
  void setDrive(String? dogId, Set<Move> held) => _send('setDrive', [
    dogId,
    [for (final m in held) m.wire],
  ]);
  void setActive(bool active) => _send('setActive', [active]);
  void setCamPov(String? camId, {Rect? rect}) => _send('setCamPov', [
    if (camId == null || rect == null)
      null
    else
      {
        'camId': camId,
        'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
      },
  ]);
  void setInsets(MapInsets next) {
    insets = next;
    _send('setInsets', [_insets(next)]);
  }

  void setRoute(List<PlanPoint> points, {required bool loop, required int seq}) => _send('setRoute', [
    [for (final p in points) p.toJson()],
    loop,
    seq,
  ]);

  /// La telecamera di bordo: [cover] a tutto schermo, altrimenti nel riquadro [rect] (px della mappa).
  void setPov(String? dogId, {bool cover = false, Rect? rect}) => _send('setPov', [
    if (dogId == null)
      null
    else
      {
        'dogId': dogId,
        'cover': cover,
        'rect': rect == null ? null : {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
      },
  ]);

  /// Stato della scena: posizioni dei cani, inseguimento, telecamera di bordo. Serve ai test sul dispositivo.
  Future<Map<String, Object?>> debugState() => _evalJson('window.grokMap.state()');

  /// Dove cade sullo schermo un punto della pianta (0-1). Serve ai test sul dispositivo.
  Future<Map<String, Object?>> debugProject(PlanPoint p) => _evalJson('window.grokMap.project(${p.x}, ${p.y})');

  Future<Map<String, Object?>> _evalJson(String js) async {
    final raw = await web.runJavaScriptReturningResult(js);
    // iOS restituisce la stringa così com'è, Android la restituisce fra virgolette
    final decoded = raw is String ? jsonDecode(raw) : raw;
    return (decoded is String ? jsonDecode(decoded) : decoded)! as Map<String, Object?>;
  }

  void dispose() {
    ready.dispose();
    error.dispose();
  }
}

/// La superficie della mappa, con caricamento ed errore (WebGL mancante, asset non trovato).
class MapView extends StatefulWidget {
  const MapView({super.key, required this.controller, this.semanticLabel = '3D floor plan with live dog positions'});

  final MapController controller;
  final String semanticLabel;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  ConsoleStore get _store => ConsoleStore.instance;

  @override
  void initState() {
    super.initState();
    _store.frame.addListener(widget.controller.sync);
    _store.addListener(widget.controller.sync);
    _store.mapEpoch.addListener(widget.controller.reload);
  }

  @override
  void dispose() {
    _store.frame.removeListener(widget.controller.sync);
    _store.removeListener(widget.controller.sync);
    _store.mapEpoch.removeListener(widget.controller.reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Semantics(
      label: widget.semanticLabel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: controller.web),
          ValueListenableBuilder(
            valueListenable: controller.error,
            builder: (_, error, _) => ValueListenableBuilder(
              valueListenable: controller.ready,
              builder: (_, ready, _) {
                if (error != null) {
                  return const ColoredBox(
                    color: AppColors.app,
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          "The 3D map can't start on this device. Missions, automations and reports still work.",
                          textAlign: TextAlign.center,
                          style: AppText.bodyMuted,
                        ),
                      ),
                    ),
                  );
                }
                return IgnorePointer(
                  ignoring: ready,
                  child: AnimatedOpacity(
                    opacity: ready ? 0 : 1,
                    duration: const Duration(milliseconds: 250),
                    child: const ColoredBox(
                      color: AppColors.app,
                      child: Center(
                        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted)),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
