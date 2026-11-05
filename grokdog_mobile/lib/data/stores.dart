import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Le automazioni create dall'operatore: per ora salvate sul telefono, finché non c'è un backend.
class AutomationStore extends ChangeNotifier {
  AutomationStore._();

  static final instance = AutomationStore._();
  static const _key = 'grokdog:automations';

  List<CustomAutomation> _items = const [];
  List<CustomAutomation> get items => _items;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    try {
      _items = raw == null
          ? const []
          : [for (final o in jsonDecode(raw) as List<Object?>) CustomAutomation.fromJson(o! as Map<String, Object?>)];
    } on Object {
      _items = const []; // come in web: un salvataggio illeggibile non blocca l'app
    }
    try {
      final saved = prefs.getString(_routesKey);
      _routes = saved == null
          ? const {}
          : {
              for (final e in (jsonDecode(saved) as Map<String, Object?>).entries)
                e.key: (
                  loop: (e.value! as Map)['loop'] == true,
                  route: [
                    for (final p in (e.value! as Map)['route'] as List<Object?>) PlanPoint.fromJson((p! as Map).cast<String, Object?>()),
                  ],
                ),
            };
    } on Object {
      _routes = const {};
    }
    notifyListeners();
  }

  Future<void> save(CustomAutomation a) => _write([..._items, a]);

  Future<void> setActive(String id, {required bool active}) =>
      _write([for (final a in _items) a.id == id ? a.copyWith(active: active) : a]);

  Future<void> delete(String id) => _write(_items.where((a) => a.id != id).toList());

  // i percorsi cambiati con «Change path» delle automazioni di sistema: stanno a parte, per id
  static const _routesKey = 'grokdog:automation-routes';
  Map<String, ({List<PlanPoint> route, bool loop})> _routes = const {};
  Map<String, ({List<PlanPoint> route, bool loop})> get routes => _routes;

  /// Il percorso di un'automazione: quello cambiato a mano, altrimenti il suo.
  ({List<PlanPoint> route, bool loop})? routeOf(Automation a) {
    final own = a.route;
    return _routes[a.id] ?? (own == null ? null : (route: own, loop: a.loop));
  }

  Future<void> setRoute(String id, List<PlanPoint> route, {required bool loop, required String action}) async {
    if (_items.any((a) => a.id == id)) {
      return _write([for (final a in _items) a.id == id ? a.copyWith(route: route, loop: loop, action: action) : a]);
    }
    _routes = {..._routes, id: (route: route, loop: loop)};
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _routesKey,
      jsonEncode({
        for (final e in _routes.entries)
          e.key: {
            'loop': e.value.loop,
            'route': [for (final p in e.value.route) p.toJson()],
          },
      }),
    );
  }

  Future<void> _write(List<CustomAutomation> next) async {
    _items = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final a in next) a.toJson()]));
  }
}

enum GrokBotStatus { off, connecting, on }

/// Stato del collegamento a GrokBot, condiviso fra la card del profilo e le impostazioni.
/// Per ora è finto: «Connect» aspetta un attimo e risulta collegato.
class GrokBotStore extends ChangeNotifier {
  GrokBotStore._();

  static final instance = GrokBotStore._();
  GrokBotStatus _status = GrokBotStatus.off;
  GrokBotStatus get status => _status;

  // la × nasconde la card fino alla prossima apertura dell'app: finché GrokBot non è collegato torna
  bool _cardHidden = false;
  bool get cardHidden => _cardHidden;

  Timer? _timer;

  void toggle() => _set(_status == GrokBotStatus.off ? GrokBotStatus.connecting : GrokBotStatus.off);

  void _set(GrokBotStatus next) {
    _timer?.cancel();
    _status = next;
    if (next == GrokBotStatus.connecting) {
      _timer = Timer(const Duration(milliseconds: 1200), () => _set(GrokBotStatus.on));
    }
    notifyListeners();
  }

  void hideCard() {
    _cardHidden = true;
    notifyListeners();
  }
}
