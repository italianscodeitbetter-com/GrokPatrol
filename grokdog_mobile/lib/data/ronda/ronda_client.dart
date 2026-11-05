import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'mjpeg.dart';
import 'ronda_models.dart';

/// La pagina che trasforma un telefono in una telecamera.
class PhonePage {
  const PhonePage({required this.url});

  final String url;
}

/// Perché una richiesta al server non è andata.
sealed class RondaFailure implements Exception {
  const RondaFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Server spento, rete sbagliata, tempo scaduto.
class RondaOffline extends RondaFailure {
  const RondaOffline([super.message = "Can't reach the server", this.noRoute = false]);

  /// «No route to host»: su iPhone è anche il modo in cui il sistema blocca la rete locale.
  final bool noRoute;
}

RondaOffline _unreachable(String reason) => RondaOffline("Can't reach the server: $reason", reason.contains('No route to host'));

/// Dal tunnel il server chiede il PIN.
class RondaPinRequired extends RondaFailure {
  const RondaPinRequired([super.message = 'The server asks for its PIN']);
}

class RondaBadPin extends RondaFailure {
  const RondaBadPin([super.message = 'Wrong PIN']);
}

/// Il server ha risposto ma ha rifiutato il comando.
class RondaRejected extends RondaFailure {
  const RondaRejected(super.message);
}

/// Indirizzo scritto dall'operatore → indirizzo completo. `192.168.1.8` diventa `http://192.168.1.8:8000`.
String normalizeServerUrl(String input) {
  var s = input.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri != null && uri.scheme == 'http' && !uri.hasPort) return '$s:8000';
  return s;
}

/// Le chiamate HTTP alla API di Ronda.
class RondaClient {
  RondaClient(String baseUrl, {http.Client? client, http.Client Function()? videoClient, this.cookie})
    : baseUrl = normalizeServerUrl(baseUrl),
      _http = client ?? http.Client(),
      _videoClient = videoClient ?? http.Client.new;

  static const _timeout = Duration(seconds: 6);

  /// Senza fotogrammi per così tanto la telecamera è spenta: chi guarda riprova da capo.
  static const _videoSilence = Duration(seconds: 8);

  /// Le risposte di Grok possono metterci parecchio.
  static const _slowTimeout = Duration(seconds: 45);

  final String baseUrl;
  final http.Client _http;
  final http.Client Function() _videoClient;

  /// Il cookie `ronda_auth` che il server dà dopo il PIN.
  String? cookie;

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// Headers per ogni richiesta, immagini comprese. Il secondo salta la pagina di avviso del piano gratuito di ngrok.
  Map<String, String> get headers => {'ngrok-skip-browser-warning': '1', 'Cookie': ?cookie};

  String imageUrl(String path) => path.startsWith('http') ? path : '$baseUrl$path';

  Uri get socketUri {
    final u = Uri.parse(baseUrl);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws', path: '/ws/console');
  }

  Future<http.Response> _send(Future<http.Response> Function() call, {Duration timeout = _timeout}) async {
    final http.Response r;
    try {
      r = await call().timeout(timeout);
    } on TimeoutException {
      throw const RondaOffline('The server took too long to answer');
    } on SocketException catch (e) {
      throw _unreachable(e.osError?.message ?? e.message);
    } on http.ClientException catch (e) {
      throw _unreachable(e.message);
    } on HandshakeException {
      throw const RondaOffline('The server certificate was refused');
    }
    if (r.statusCode == 401) throw const RondaPinRequired();
    return r;
  }

  Object? _decode(http.Response r) {
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      // fuori dalla rete, il server risponde alle pagine con il form del PIN invece che con JSON
      if (r.statusCode < 300 && r.body.contains('name="pin"')) throw const RondaPinRequired();
      throw const RondaRejected('The server sent something unreadable');
    }
  }

  Future<Json> _getJson(String path, [Map<String, String>? query]) async {
    final r = await _send(() => _http.get(_uri(path, query), headers: headers));
    final body = _decode(r);
    if (r.statusCode >= 400) throw RondaRejected(asString(asJson(body)['error']) ?? 'Server error ${r.statusCode}');
    return asJson(body);
  }

  Future<Json> _post(String path, Json body, {Duration timeout = _timeout}) async {
    final r = await _send(
      () => _http.post(_uri(path), headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)),
      timeout: timeout,
    );
    final reply = asJson(_decode(r));
    if (r.statusCode >= 400 || reply['ok'] == false) throw RondaRejected(asString(reply['error']) ?? 'Not done');
    return reply;
  }

  /// PIN → cookie. Il server risponde con un redirect che porta il cookie: non va seguito.
  Future<void> login(String pin) async {
    final request = http.Request('POST', _uri('/login'))
      ..followRedirects = false
      ..headers.addAll({...headers, 'Content-Type': 'application/x-www-form-urlencoded'})
      ..bodyFields = {'pin': pin, 'next': '/'};
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(request)).timeout(_timeout);
    } on TimeoutException {
      throw const RondaOffline('The server took too long to answer');
    } on SocketException catch (e) {
      throw _unreachable(e.osError?.message ?? e.message);
    } on http.ClientException catch (e) {
      throw _unreachable(e.message);
    }
    final auth = RegExp(r'ronda_auth=[^;,\s]+').firstMatch(r.headers['set-cookie'] ?? '');
    if (r.statusCode != 303 || auth == null) throw const RondaBadPin();
    cookie = auth[0];
  }

  Future<RondaSnapshot> state() async => RondaSnapshot.fromJson(await _getJson('/api/state'));

  /// Lo stesso stato del websocket, per quando il websocket non passa.
  Future<Json> poll({required int logAfter, required double eventsAfter}) =>
      _getJson('/api/poll', {'log_after': '$logAfter', 'ev_after': '$eventsAfter'});

  Future<Json> command(String action, [Json extra = const {}]) => _post('/api/command', {'action': action, ...extra});

  Future<Json> chat(String message) => _post('/api/chat', {'message': message, 'via': 'mobile'}, timeout: _slowTimeout);

  /// Rapporto di fine turno, in Markdown.
  Future<String> shiftReport() async => asString((await _post('/api/report', const {}, timeout: _slowTimeout))['markdown']) ?? '';

  /// Tutto il registro da [since] in poi, il più vecchio per primo.
  Future<List<LogEntry>> logSince(double since) async {
    final r = await _send(() => _http.get(_uri('/api/log.json', {'since': '$since'}), headers: headers), timeout: _slowTimeout);
    return [for (final e in asJsonList(_decode(r))) LogEntry.fromJson(e)];
  }

  Future<void> dogcam(String action) async {
    final r = asJson(_decode(await _send(() => _http.post(_uri('/api/dogcam/$action'), headers: headers), timeout: _slowTimeout)));
    if (r['state'] == 'error') throw RondaRejected(asString(r['error']) ?? 'Dog camera error');
  }

  Future<void> addAutomation(Json body) => _post('/api/automations', body);

  Future<void> setAutomationActive(String id, {required bool active}) => _post('/api/automations/$id', {'active': active});

  Future<void> runAutomation(String id) => _post('/api/automations/$id/run', const {});

  Future<void> setAutomationRoute(String id, List<SitePoint> points, {required bool loop}) => _post('/api/automations/$id/route', {
    'points': [
      for (final p in points) [p.x, p.y],
    ],
    'loop': loop,
  });

  Future<void> deleteAutomation(String id) async {
    final r = await _send(() => _http.delete(_uri('/api/automations/$id'), headers: headers));
    final reply = asJson(_decode(r));
    if (r.statusCode >= 400) throw RondaRejected(asString(reply['error']) ?? 'Not done');
  }

  /// Un fotogramma JPEG, o null se la telecamera non ne ha.
  /// Il video live di una telecamera, un JPEG per volta. Finché c'è chi ascolta, la telecamera manda i
  /// fotogrammi veloci. Ha una connessione tutta sua, che si chiude quando si smette di ascoltare.
  Stream<Uint8List> video(String camera) async* {
    final client = _videoClient();
    try {
      final request = http.Request('GET', _uri('/api/cameras/${Uri.encodeComponent(camera)}/stream'))..headers.addAll(headers);
      final response = await client.send(request).timeout(_timeout);
      if (response.statusCode == 401) throw const RondaPinRequired();
      if (response.statusCode != 200) throw RondaOffline('Camera not available (${response.statusCode})');
      final parser = MjpegParser();
      await for (final chunk in response.stream.timeout(_videoSilence)) {
        for (final frame in parser.add(chunk)) {
          yield frame;
        }
      }
    } on TimeoutException {
      throw const RondaOffline('The camera is not sending video');
    } on SocketException catch (e) {
      throw _unreachable(e.osError?.message ?? e.message);
    } on http.ClientException catch (e) {
      throw _unreachable(e.message);
    } finally {
      client.close();
    }
  }

  /// Dove un telefono apre la pagina telecamera: nel tunnel, se c'è, altrimenti sulla rete locale.
  Future<PhonePage> phonePage() async {
    final j = await _getJson('/api/public');
    final tunnel = asString(j['camera']), pin = asString(j['pin']);
    if (tunnel != null) return PhonePage(url: pin == null || pin.isEmpty ? tunnel : '$tunnel?pin=$pin');
    final host = Uri.parse(baseUrl).host;
    return PhonePage(url: asString(j['lan_camera']) ?? 'https://$host:8443/camera');
  }

  void close() => _http.close();
}
