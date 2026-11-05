import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import 'ronda_models.dart';

enum LinkState {
  /// Websocket aperto.
  live,

  /// Websocket chiuso ma il server risponde: si chiede lo stato ogni secondo.
  polling,

  offline,
}

/// Il canale in tempo reale. Astratto per poterlo sostituire nei test.
abstract interface class RondaSocket {
  Stream<Object?> get messages;
  void send(String text);
  Future<void> close();
}

typedef SocketConnector = Future<RondaSocket> Function(Uri uri, Map<String, String> headers);

class _IoSocket implements RondaSocket {
  _IoSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<Object?> get messages => _ws;

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close() => _ws.close();
}

Future<RondaSocket> connectIoSocket(Uri uri, Map<String, String> headers) async =>
    _IoSocket(await WebSocket.connect(uri.toString(), headers: headers).timeout(const Duration(seconds: 5)));

/// Tiene aperto il websocket di `/ws/console`. Come la console web: se per 1,5 s non arriva nulla
/// passa a chiedere lo stato ogni secondo, e intanto continua a riprovare il websocket.
class RondaLink {
  RondaLink({
    required this.uri,
    required this.headers,
    required this.onMessage,
    required this.onState,
    required this.poll,
    this.connector = connectIoSocket,
    this.silence = const Duration(milliseconds: 1500),
    this.retry = const Duration(seconds: 2),
    this.pollEvery = const Duration(seconds: 1),
  });

  final Uri uri;
  final Map<String, String> Function() headers;
  final void Function(Json message) onMessage;
  final void Function(LinkState state) onState;

  /// Una richiesta di stato: true se il server ha risposto.
  final Future<bool> Function() poll;
  final SocketConnector connector;
  final Duration silence, retry, pollEvery;

  RondaSocket? _socket;
  StreamSubscription<Object?>? _sub;
  Timer? _retryTimer, _watchdog;
  DateTime _lastMessage = DateTime.fromMillisecondsSinceEpoch(0);
  // ci si collega solo dopo che il server ha risposto: si parte da qui, e una caduta subito dopo viene segnalata
  LinkState _state = LinkState.polling;
  bool _running = false, _polling = false, _connecting = false;

  LinkState get state => _state;

  /// Il comando di guida può passare dal websocket solo se è vivo davvero.
  bool get canSend => _socket != null && _state == LinkState.live;

  void start() {
    if (_running) return;
    _running = true;
    _lastMessage = clock.now(); // un attimo di tempo al websocket prima di passare al polling
    unawaited(_connect());
    _watchdog = Timer.periodic(pollEvery, (_) => _check());
  }

  void send(Json message) {
    if (canSend) _socket?.send(jsonEncode(message));
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    _watchdog?.cancel();
    await _dropSocket();
  }

  Future<void> _dropSocket() async {
    final sub = _sub, socket = _socket;
    _sub = null;
    _socket = null;
    final cancelled = sub?.cancel();
    try {
      await socket?.close();
    } on Object {
      // già chiuso
    }
    await cancelled;
  }

  Future<void> _connect() async {
    if (!_running || _socket != null || _connecting) return;
    _connecting = true;
    try {
      final socket = await connector(uri, headers());
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _sub = socket.messages.listen(_onData, onDone: _lost, onError: (Object _) => _lost(), cancelOnError: true);
    } on Object {
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _onData(Object? data) {
    _lastMessage = clock.now();
    if (_state != LinkState.live) _set(LinkState.live);
    if (data is! String) return;
    try {
      onMessage(asJson(jsonDecode(data)));
    } on FormatException {
      // un messaggio illeggibile non deve chiudere il collegamento
    }
  }

  void _lost() {
    unawaited(_dropSocket());
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_running) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retry, () => unawaited(_connect()));
  }

  Future<void> _check() async {
    if (!_running || _polling) return;
    if (clock.now().difference(_lastMessage) < silence) return;
    _polling = true;
    try {
      final ok = await poll();
      if (_running && clock.now().difference(_lastMessage) >= silence) _set(ok ? LinkState.polling : LinkState.offline);
    } finally {
      _polling = false;
    }
  }

  void _set(LinkState next) {
    if (next == _state) return;
    _state = next;
    onState(next);
  }
}
