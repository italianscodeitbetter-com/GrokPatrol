import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dog_drive.dart';
import 'mock_data.dart' as demo;
import 'models.dart';
import 'ronda/live_view.dart';
import 'ronda/ronda_client.dart';
import 'ronda/ronda_link.dart';
import 'ronda/ronda_models.dart';

enum ConsoleMode {
  /// Dati finti della web app: niente server configurato.
  demo,
  connecting,
  live,
}

/// Quello che cambia 4 volte al secondo: va alla scena 3D senza ridisegnare le pagine.
class LiveFrame {
  const LiveFrame({required this.position, required this.heading, required this.speed, required this.path, required this.actors});

  final PlanPoint position;
  final double heading;

  /// cm/s.
  final double speed;
  final List<PlanPoint> path;
  final List<({String id, String kind, PlanPoint at})> actors;
}

class LiveAlert {
  const LiveAlert({required this.title, required this.body, required this.place, required this.results, required this.image});

  final String title, body, place;
  final List<AlertResult> results;
  final String? image;
}

/// L'unica fonte dei dati per le schermate. Senza server dà i dati finti della web app, collegato dà quelli veri:
/// le pagine non devono sapere da dove arrivano.
class ConsoleStore extends ChangeNotifier with WidgetsBindingObserver {
  ConsoleStore({
    RondaClient Function(String url)? clientFactory,
    this.connector = connectIoSocket,
    FlutterSecureStorage? secure,
    this.noRouteWait = const Duration(seconds: 1),
  }) : _clientFactory = clientFactory ?? RondaClient.new,
       _secure = secure ?? const FlutterSecureStorage();

  static ConsoleStore instance = ConsoleStore();

  static const _urlKey = 'ronda:url';
  static const _pinKey = 'ronda:pin';
  static const _logLimit = 500;

  final RondaClient Function(String url) _clientFactory;
  final SocketConnector connector;

  /// Quanto si aspetta fra un tentativo e l'altro quando iOS non lascia ancora passare (vedi [_firstState]).
  final Duration noRouteWait;
  static const _noRouteTries = 15;

  // ogni collegamento ha il suo numero: uno superato da un altro, o da Disconnect, non deve toccare più nulla
  int _attempt = 0;
  final FlutterSecureStorage _secure;

  ConsoleMode _mode = ConsoleMode.demo;
  ConsoleMode get mode => _mode;
  bool get isLive => _mode == ConsoleMode.live;

  LinkState _link = LinkState.offline;
  LinkState get link => _link;

  /// C'è un collegamento vivo: si possono mandare comandi.
  bool get online => isLive && _link != LinkState.offline;

  String _url = '';
  String get serverUrl => _url;

  RondaClient? _client;
  RondaClient? get client => _client;
  RondaLink? _socket;
  String? _pin;

  Site? _site;
  Tick? _tick;
  final _events = <String, RondaEvent>{};
  final _log = <LogEntry>[];
  List<ChatMessage> _chat = const [];
  int _lastLogId = 0;
  double _lastPoll = 0;
  String _tickKey = '';

  LiveView? _view;
  LiveView? get view => _view;

  /// Posizione del cane e movimento in scena: 4 aggiornamenti al secondo.
  final frame = ValueNotifier<LiveFrame?>(null);

  /// L'ultimo alert, finché l'operatore non lo chiude.
  final alert = ValueNotifier<LiveAlert?>(null);

  /// Cambia quando la mappa va ricostruita: nuovo sito o passaggio demo/server.
  final mapEpoch = ValueNotifier<int>(0);

  int _unread = 0;

  /// Attività nuove da quando è stato aperto il pannello.
  int get unread => _unread;

  List<ChatMessage> get chat => _chat;

  // ── dati per le schermate ──────────────────────────────
  Site? get site => _site;
  Tick? get tick => _tick;
  DogStatus? get dogStatus => _tick?.dog;
  AlarmState? get alarm => _tick?.alarm;
  GrokStatus? get grok => _tick?.grok;
  SimStatus? get sim => _tick?.sim;

  List<Room> get rooms => _view?.rooms ?? demo.rooms;
  List<MapPoint> get cameras => _view?.cameras ?? demo.cameras;
  List<MapPoint> get patrolPoints => _view?.patrolPoints ?? demo.patrolPoints;
  List<MapPoint> get spots => _view?.spots ?? demo.patrolPoints;
  List<Dog> get dogs => _view == null ? demo.dogs : [_view!.dog];

  /// Tutti i bot, anche quelli spenti.
  List<Dog> get fleet => _view == null ? demo.fleet : [_view!.dog];

  /// Dove si trova adesso un robot: il punto A di un percorso.
  PlanPoint spotOf(Dog d) {
    if (frame.value case final f?) return f.position;
    if (d.route.isNotEmpty) return d.route.first;
    final r = rooms.where((x) => x.id == d.roomId).firstOrNull ?? rooms.first;
    return PlanPoint((r.x + r.w / 2).roundToDouble(), (r.y + r.h / 2).roundToDouble());
  }

  /// Tutto quello che è successo nel turno, una riga per passo (missioni e allarmi), dal più recente.
  List<ActivityRow> activityRows() {
    if (_view != null) return activityFromLog(_log, robot: _view!.dog.name);
    return [
      for (final m in demo.missions)
        for (final s in m.steps)
          if (s.time case final t?)
            ActivityRow(
              time: t,
              what: s.step.label,
              detail: s.detail,
              missionId: m.id,
              room: demo.roomName(m.roomId),
              robot: demo.dogName(m.dogId),
            ),
      for (final a in demo.alerts)
        () {
          final m = demo.missions.where((x) => x.id == a.missionId).firstOrNull;
          return ActivityRow(
            time: a.time,
            what: 'Alert · ${a.channel.label}',
            detail: a.text,
            missionId: a.missionId,
            room: m == null ? '—' : demo.roomName(m.roomId),
            robot: m == null ? '—' : demo.dogName(m.dogId),
            alert: a,
          );
        }(),
    ]..sort((a, b) => b.time.compareTo(a.time));
  }

  /// Le missioni di un giorno passato: il server non conserva gli eventi, si ricostruiscono dal registro.
  Future<List<Mission>> missionsSince(double from, double until) async {
    final client = _client, site = _site, tick = _tick;
    if (client == null || site == null || tick == null) return const [];
    final log = (await client.logSince(from)).where((e) => e.ts < until).toList();
    return LiveView(site: site, tick: tick, serverEvents: const [], serverLog: log).missions;
  }

  List<PatrolEvent> get events => _view?.events ?? demo.events;
  List<LogRow> get activity => _view?.activity ?? demo.log;
  List<Mission> get missions => _view?.missions ?? demo.missions;
  List<AlertSent> get alerts => _view?.alerts ?? demo.alerts;
  List<Automation> get systemAutomations => _view?.automations ?? demo.automations;

  String roomName(String id) => rooms.where((r) => r.id == id).firstOrNull?.name ?? id;
  String dogName(String id) => fleet.where((d) => d.id == id).firstOrNull?.name ?? id;
  String automationName(String id) {
    if (id == alarmAutomationId) return 'Alarm';
    if (id == 'patrol') return 'Patrol';
    return systemAutomations.where((a) => a.id == id).firstOrNull?.name ?? id;
  }

  Mission? missionById(String id, {String? eventId}) {
    final list = missions;
    if (eventId != null && eventId.isNotEmpty) {
      final hit = list.where((m) => m.eventId == eventId).firstOrNull;
      if (hit != null) return hit;
    }
    return list.where((m) => m.id == id).firstOrNull;
  }

  /// Da riga del registro a missione, per aprirla dal pannello delle attività.
  Mission? missionOf(LogRow row) => missionById(row.missionId ?? '', eventId: row.eventId);

  /// Il turno per l'orologio, separato dalle lineette: sta sulla stessa riga delle azioni e dev'essere corto.
  List<String> get shiftParts =>
      _tick == null ? [demo.shift.name, '${demo.shift.start}–${demo.shift.end}'] : ['Shift since ${clockOf(_tick!.shift).substring(0, 5)}'];

  CameraStatus? cameraStatus(String id) => _tick?.cameras.where((c) => c.id == id).firstOrNull;

  /// Il percorso dell'immagine dal vivo del cane: la sua telecamera se è collegata.
  bool get dogHasVideo => cameraStatus('dog')?.online == true;

  // ── collegamento ───────────────────────────────────────
  /// All'avvio: se c'è un server salvato ci si ricollega.
  Future<void> load() async {
    WidgetsBinding.instance.addObserver(this);
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey);
    if (url == null || url.isEmpty) return;
    try {
      _pin = await _secure.read(key: _pinKey);
    } on PlatformException {
      _pin = null;
    }
    _url = url;
    unawaited(connect(url, pin: _pin).catchError((Object _) {}));
  }

  /// Si collega al server. Lancia [RondaFailure] con il motivo se non ci riesce, e l'app resta dov'era.
  Future<void> connect(String url, {String? pin}) async {
    final address = normalizeServerUrl(url);
    if (address.isEmpty) throw const RondaOffline('Write the address of the server');
    await _teardown();
    final attempt = ++_attempt;
    _mode = ConsoleMode.connecting;
    _url = address;
    notifyListeners();
    final client = _clientFactory(address);
    try {
      RondaSnapshot snap;
      try {
        snap = await _firstState(client, attempt);
      } on RondaPinRequired {
        if (pin == null || pin.isEmpty) rethrow;
        await client.login(pin);
        snap = await client.state();
      }
      if (attempt != _attempt) {
        client.close();
        return;
      }
      _client = client;
      _pin = pin;
      _applySnapshot(snap);
      _mode = ConsoleMode.live;
      _link = LinkState.polling;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_urlKey, address);
      await _savePin(pin);
      _socket = RondaLink(
        uri: client.socketUri,
        headers: () => client.headers,
        onMessage: _onMessage,
        onState: _onLink,
        poll: _poll,
        connector: connector,
      )..start();
      mapEpoch.value++;
      notifyListeners();
    } on RondaFailure {
      client.close();
      if (attempt != _attempt) return;
      _mode = ConsoleMode.demo;
      _reset();
      notifyListeners();
      rethrow;
    }
  }

  /// Il primo contatto col server. Appena aperta l'app, iOS rifiuta la prima connessione alla rete locale
  /// con «No route to host», e così fa finché l'operatore non risponde alla richiesta Rete locale:
  /// poco dopo la stessa connessione passa, quindi si riprova invece di arrendersi al primo tentativo.
  Future<RondaSnapshot> _firstState(RondaClient client, int attempt) async {
    for (var left = _noRouteTries; ; left--) {
      try {
        return await client.state();
      } on RondaOffline catch (e) {
        if (!e.noRoute || attempt != _attempt) rethrow;
        if (left == 0) {
          throw const RondaOffline(
            "Can't reach the server. Check that the phone is on the same network as the server, and on iPhone that Local Network is on for GrokPatrol in Settings.",
            true,
          );
        }
        await Future<void>.delayed(noRouteWait);
      }
    }
  }

  Future<void> _savePin(String? pin) async {
    try {
      if (pin == null || pin.isEmpty) {
        await _secure.delete(key: _pinKey);
      } else {
        await _secure.write(key: _pinKey, value: pin);
      }
    } on PlatformException {
      // senza portachiavi il PIN si richiede al prossimo avvio
    }
  }

  /// Torna ai dati finti e dimentica il server.
  Future<void> disconnect() async {
    _attempt++;
    await _teardown();
    _mode = ConsoleMode.demo;
    _url = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_urlKey);
    await _savePin(null);
    mapEpoch.value++;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _driver.release();
    await _socket?.stop();
    _socket = null;
    _client?.close();
    _client = null;
    _reset();
  }

  void _reset() {
    _site = null;
    _tick = null;
    _view = null;
    _events.clear();
    _log.clear();
    _chat = const [];
    _lastLogId = 0;
    _lastPoll = 0;
    _tickKey = '';
    _unread = 0;
    _link = LinkState.offline;
    frame.value = null;
  }

  void _applySnapshot(RondaSnapshot s) {
    final firstSite = _site == null;
    _site = s.site;
    _tick = s.tick;
    _events
      ..clear()
      ..addEntries(s.events.map((e) => MapEntry(e.id, e)));
    _log
      ..clear()
      ..addAll(s.log);
    _lastLogId = s.log.isEmpty ? _lastLogId : s.log.last.id;
    _chat = s.chat;
    _rebuild();
    _publishFrame();
    if (!firstSite) mapEpoch.value++;
  }

  void _rebuild() {
    final site = _site, tick = _tick;
    if (site == null || tick == null) return;
    _view = LiveView(site: site, tick: tick, serverEvents: _events.values.toList(), serverLog: List.of(_log));
  }

  void _onLink(LinkState state) {
    final wasDown = _link != LinkState.live;
    _link = state;
    if (state == LinkState.offline) _driver.release(); // niente rete: il cane si ferma da solo in 0,6 s
    if (state == LinkState.live && wasDown) unawaited(refresh());
    notifyListeners();
  }

  /// Ricarica tutto: dopo una riconnessione, un reset o il ritorno dallo sfondo.
  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    try {
      final s = await client.state();
      if (!identical(client, _client)) return;
      _applySnapshot(s);
      notifyListeners();
    } on RondaFailure {
      // il prossimo controllo del collegamento lo segnala
    }
  }

  void _onMessage(Json m) {
    switch (m['type']) {
      case 'tick':
        _applyTick(Tick.fromJson(m));
      case 'log':
        _addLog(LogEntry.fromJson(asJson(m['entry'])));
        _rebuild();
        notifyListeners();
      case 'event':
        final e = RondaEvent.fromJson(asJson(m['event']));
        _events[e.id] = e;
        _rebuild();
        notifyListeners();
      case 'alert':
        _onAlert(m);
      case 'site':
        _site = Site.fromJson(asJson(m['site']));
        _rebuild();
        mapEpoch.value++;
        notifyListeners();
      case 'reset':
        unawaited(refresh());
    }
  }

  void _addLog(LogEntry e) {
    if (e.id <= _lastLogId) return;
    _lastLogId = e.id;
    _log.add(e);
    if (_log.length > _logLimit) _log.removeRange(0, _log.length - _logLimit);
    if (e.level == 'warn' || e.level == 'alert' || e.level == 'error') _unread++;
  }

  void _onAlert(Json m) {
    final a = AlertText.fromJson(asJson(m['alert']));
    alert.value = LiveAlert(
      title: a.title,
      body: a.sms,
      place: asString(m['spot']) ?? '',
      results: [for (final r in asJsonList(m['results'])) AlertResult.fromJson(r)],
      image: asString(m['image']),
    );
    unawaited(HapticFeedback.heavyImpact());
    unawaited(SystemSound.play(SystemSoundType.alert));
  }

  void _applyTick(Tick t) {
    final shiftChanged = _tick != null && t.shift != _tick!.shift;
    _tick = t;
    _publishFrame();
    if (shiftChanged) {
      unawaited(refresh());
      return;
    }
    final key = _keyOf(t);
    if (key == _tickKey) return;
    _tickKey = key;
    _rebuild();
    notifyListeners();
  }

  /// Quello che si vede nelle pagine: finché non cambia, la posizione del cane non le ridisegna.
  String _keyOf(Tick t) {
    final d = t.dog;
    return jsonEncode([
      d.connected, d.armed, d.manual, d.posture, d.battery, d.link, d.moving, //
      t.current?.id, t.current?.status, t.current?.label, t.current?.idx, [for (final m in t.queue) m.id],
      t.alarm.armed, t.alarm.active, t.alarm.exitDelay,
      t.stats.events, t.stats.alerts, t.stats.confirmed, t.stats.filtered,
      t.grok.enabled, t.grok.configured, t.grok.calls, t.grok.error,
      t.alertChannels, t.telegramChats, t.dogcam?.state, t.dogcam?.fps,
      [for (final s in t.schedules) '${s.routeId}:${s.everyMin}:${s.nextIn ~/ 10}'],
      [for (final a in t.automations) '${a.id}:${a.active}:${a.runsToday}'],
      [for (final c in t.cameras) '${c.id}:${c.online}'],
      t.sim.connected, t.sim.scenarios,
    ]);
  }

  void _publishFrame() {
    final t = _tick, site = _site;
    if (t == null || site == null) return;
    final tr = SiteTransform.of(site), d = t.dog, path = t.current?.path ?? const <SitePoint>[];
    frame.value = LiveFrame(
      position: tr.toPlan(d.x, d.y),
      heading: tr.heading(d.yaw),
      speed: d.speed * 100,
      path: [for (final p in path) tr.toPlan(p.x, p.y)],
      actors: [for (final a in t.sim.actors) (id: a.id, kind: a.kind, at: tr.toPlan(a.x, a.y))],
    );
  }

  Future<bool> _poll() async {
    final client = _client;
    if (client == null) return false;
    try {
      final r = await client.poll(logAfter: _lastLogId, eventsAfter: _lastPoll);
      _lastPoll = asDouble(r['now']) ?? _lastPoll;
      for (final e in asJsonList(r['log'])) {
        _addLog(LogEntry.fromJson(e));
      }
      for (final e in asJsonList(r['events'])) {
        final ev = RondaEvent.fromJson(e);
        _events[ev.id] = ev;
      }
      _tickKey = ''; // dopo un buco si ridisegna comunque
      _applyTick(Tick.fromJson(asJson(r['tick'])));
      return true;
    } on RondaPinRequired {
      return _relogin();
    } on RondaFailure {
      return false;
    }
  }

  Future<bool> _relogin() async {
    final client = _client, pin = _pin;
    if (client == null || pin == null || pin.isEmpty) return false;
    try {
      await client.login(pin);
      return true;
    } on RondaFailure {
      return false;
    }
  }

  void markActivityRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  // ── comandi ────────────────────────────────────────────
  Future<Json> command(String action, [Json extra = const {}]) async {
    final client = _client;
    if (client == null) throw const RondaOffline('Not connected to a server');
    return client.command(action, extra);
  }

  late final DogDriver _driver = DogDriver(_sendDrive);

  void _sendDrive(DriveVector v) {
    final socket = _socket;
    if (socket != null && socket.canSend) {
      socket.send({'type': 'drive', 'vx': v.vx, 'vy': v.vy, 'wz': v.wz});
    } else {
      // come la console: se il websocket non c'è passa da HTTP, un comando perso lo copre quello dopo
      unawaited(command('drive', {'vx': v.vx, 'vy': v.vy, 'wz': v.wz}).then((_) {}, onError: (Object _) {}));
    }
  }

  /// I tasti tenuti premuti, null o vuoto = fermo. Senza rete non parte nulla.
  void drive(Set<Move>? held) {
    if (held == null || held.isEmpty || !online || dogStatus?.armed == false) {
      _driver.release();
      return;
    }
    _driver.hold(held);
  }

  Future<String> ask(String message) async {
    final client = _client;
    if (client == null) throw const RondaOffline('Not connected to a server');
    _chat = [..._chat, ChatMessage(role: 'user', text: message)];
    notifyListeners();
    final r = await client.chat(message);
    final reply = asString(r['reply']) ?? '';
    _chat = [
      ..._chat,
      ChatMessage(
        role: 'assistant',
        text: reply,
        offline: r['by'] == 'offline',
        actions: [for (final a in asJsonList(r['actions'])) ?asString(a['tool'])],
      ),
    ];
    notifyListeners();
    return reply;
  }

  // Sullo sfondo l'app non può garantire il tasto premuto: la guida si ferma subito.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _driver.release();
    } else if (isLive) {
      unawaited(refresh());
    }
  }

  @visibleForTesting
  void debugMessage(Json m) => _onMessage(m);

  @visibleForTesting
  bool get debugDriving => _driver.driving;

  @override
  void dispose() {
    _driver.release();
    unawaited(_socket?.stop());
    frame.dispose();
    alert.dispose();
    mapEpoch.dispose();
    super.dispose();
  }
}
