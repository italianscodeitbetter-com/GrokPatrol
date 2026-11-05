import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/dog_drive.dart';
import 'package:grokpatrol/data/ronda/ronda_client.dart';
import 'package:grokpatrol/data/ronda/ronda_link.dart';
import 'package:grokpatrol/data/ronda/ronda_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSocket implements RondaSocket {
  final controller = StreamController<Object?>();
  final sent = <Json>[];

  @override
  Stream<Object?> get messages => controller.stream;

  @override
  void send(String text) => sent.add(asJson(jsonDecode(text)));

  @override
  Future<void> close() async {}

  void push(Json m) => controller.add(jsonEncode(m));
}

/// Il server finto risponde con lo stato vero registrato.
class Harness {
  Harness() {
    fixture = asJson(jsonDecode(File('test/fixtures/ronda_incident.json').readAsStringSync()));
    store = ConsoleStore(
      clientFactory: (url) => RondaClient(url, client: MockClient(_handle)),
      connector: (_, _) async => socket,
      noRouteWait: const Duration(milliseconds: 1),
    );
  }

  late final Json fixture;
  late final ConsoleStore store;
  final socket = FakeSocket();
  final commands = <Json>[];
  bool down = false, needsPin = false, loggedIn = false;

  /// Quante richieste iOS rifiuta ancora, come appena aperta l'app.
  int noRoute = 0;
  int requests = 0;

  Future<http.Response> _handle(http.Request r) async {
    requests++;
    if (noRoute > 0) {
      noRoute--;
      throw const SocketException('Connection failed', osError: OSError('No route to host', 65));
    }
    if (down) throw const SocketException('down');
    if (r.url.path == '/login') {
      if (r.body.contains('pin=1234')) {
        loggedIn = true;
        return http.Response('', 303, headers: {'set-cookie': 'ronda_auth=t; Path=/'});
      }
      return http.Response('<form>', 200);
    }
    if (needsPin && !loggedIn) return http.Response('{"ok":false}', 401);
    if (r.url.path == '/api/state') return _json(fixture['state']);
    if (r.url.path == '/api/command') {
      commands.add(asJson(jsonDecode(r.body)));
      return _json({'ok': true});
    }
    return _json({'ok': true});
  }

  http.Response _json(Object? o) => http.Response.bytes(utf8.encode(jsonEncode(o)), 200);
}

Json tickWith(Harness h, Json dog) {
  final s = asJson(h.fixture['state']);
  return {
    ...s,
    'type': 'tick',
    'dog': {...asJson(s['dog']), ...dog},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  test('senza server sono dati demo, dichiarati', () {
    final h = Harness();
    expect(h.store.mode, ConsoleMode.demo);
    expect(h.store.isLive, isFalse);
    expect(h.store.dogs.length, 2);
    expect(h.store.online, isFalse);
  });

  group('collegamento', () {
    test('si collega e salva l\'indirizzo', () async {
      final h = Harness();
      await h.store.connect('192.168.1.8');
      expect(h.store.isLive, isTrue);
      expect(h.store.dogs.single.id, 'dog');
      expect((await SharedPreferences.getInstance()).getString('ronda:url'), 'http://192.168.1.8:8000');
    });

    test('se il server non c\'è resta in demo e dice perché', () async {
      final h = Harness()..down = true;
      await expectLater(h.store.connect('192.168.1.8'), throwsA(isA<RondaOffline>()));
      expect(h.store.mode, ConsoleMode.demo);
      expect(h.store.dogs.length, 2);
    });

    test('su iPhone il primo tentativo viene rifiutato: si riprova e si entra', () async {
      final h = Harness()..noRoute = 1;
      await h.store.connect('192.168.5.55');
      expect(h.store.isLive, isTrue);
      expect(h.requests, 2);
    });

    test('anche se l\'operatore ci mette un po\' a dare il permesso Rete locale', () async {
      final h = Harness()..noRoute = 10;
      await h.store.connect('192.168.5.55');
      expect(h.store.isLive, isTrue);
    });

    test('se il sistema continua a bloccare si ferma e spiega cosa controllare', () async {
      final h = Harness()..noRoute = 1000;
      await expectLater(
        h.store.connect('192.168.5.55'),
        throwsA(isA<RondaOffline>().having((e) => e.message, 'message', contains('Local Network'))),
      );
      expect(h.store.mode, ConsoleMode.demo);
      expect(h.requests, 16);
    });

    test('gli altri errori non si ripetono: un indirizzo sbagliato si dice subito', () async {
      final h = Harness()..down = true;
      await expectLater(h.store.connect('192.168.1.8'), throwsA(isA<RondaOffline>()));
      expect(h.requests, 1);
    });

    test('Disconnect durante i tentativi li ferma e non torna live', () async {
      final h = Harness()..noRoute = 1000;
      final going = h.store.connect('192.168.5.55');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await h.store.disconnect();
      h.noRoute = 0;
      await going.catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(h.store.mode, ConsoleMode.demo);
      expect((await SharedPreferences.getInstance()).getString('ronda:url'), isNull);
    });

    test('un secondo Connect vince sul primo, ancora in corso', () async {
      final h = Harness()..noRoute = 1000;
      final first = h.store.connect('192.168.1.8');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      h.noRoute = 0;
      await h.store.connect('192.168.5.55');
      await first.catchError((Object _) {});
      expect(h.store.isLive, isTrue);
      expect(h.store.serverUrl, 'http://192.168.5.55:8000');
    });

    test('dal tunnel senza PIN lo chiede', () async {
      final h = Harness()..needsPin = true;
      await expectLater(h.store.connect('https://x.ngrok.app'), throwsA(isA<RondaPinRequired>()));
    });

    test('con il PIN entra', () async {
      final h = Harness()..needsPin = true;
      await h.store.connect('https://x.ngrok.app', pin: '1234');
      expect(h.store.isLive, isTrue);
    });

    test('PIN sbagliato', () async {
      final h = Harness()..needsPin = true;
      await expectLater(h.store.connect('https://x.ngrok.app', pin: '9'), throwsA(isA<RondaBadPin>()));
      expect(h.store.isLive, isFalse);
    });

    test('scollegarsi torna alla demo e dimentica il server', () async {
      final h = Harness();
      await h.store.connect('192.168.1.8');
      await h.store.disconnect();
      expect(h.store.mode, ConsoleMode.demo);
      expect((await SharedPreferences.getInstance()).getString('ronda:url'), isNull);
    });

    test('la mappa si ricostruisce entrando e uscendo', () async {
      final h = Harness();
      final before = h.store.mapEpoch.value;
      await h.store.connect('192.168.1.8');
      expect(h.store.mapEpoch.value, before + 1);
    });
  });

  group('messaggi dal vivo', () {
    late Harness h;

    setUp(() async {
      h = Harness();
      await h.store.connect('192.168.1.8');
      await Future<void>.delayed(Duration.zero);
    });

    test('la posizione del cane non ridisegna le pagine, ma arriva alla scena', () {
      var notified = 0, frames = 0;
      h.store.debugMessage(tickWith(h, {'x': 1.0}));
      h.store.addListener(() => notified++);
      h.store.frame.addListener(() => frames++);
      h.store.debugMessage(tickWith(h, {'x': 2.0}));
      h.store.debugMessage(tickWith(h, {'x': 3.0}));
      expect(notified, 0);
      expect(frames, 2);
      expect(h.store.frame.value!.position.x, closeTo(340, 0.01));
    });

    test('quello che si vede sì', () {
      h.store.debugMessage(tickWith(h, {}));
      var notified = 0;
      h.store.addListener(() => notified++);
      h.store.debugMessage(tickWith(h, {'armed': false}));
      expect(notified, 1);
      expect(h.store.dogs.single.task, 'Emergency stop');
    });

    test('un alert compare', () {
      h.store.debugMessage(asJson(asJson(h.fixture['messages'])['alert']));
      expect(h.store.alert.value?.title, startsWith('Allarme'));
      expect(h.store.alert.value?.image, startsWith('/api/snapshots/'));
    });

    test('un evento nuovo entra e aggiorna le missioni', () {
      final n = h.store.missions.length;
      h.store.debugMessage({
        'type': 'event',
        'event': {'id': 'ev-new', 'ts': 9999999999.0, 'camera': 'cam-2', 'kind': 'motion', 'status': 'assessing'},
      });
      expect(h.store.missions.length, n + 1);
      expect(h.store.missions.first.eventId, 'ev-new');
    });

    test('le righe del registro non si contano due volte', () {
      final before = h.store.unread;
      final entry = {'id': 999999, 'ts': 1.0, 'kind': 'alarm.armed', 'level': 'warn', 'message': 'x'};
      h.store.debugMessage({'type': 'log', 'entry': entry});
      h.store.debugMessage({'type': 'log', 'entry': entry});
      expect(h.store.unread, before + 1);
      h.store.markActivityRead();
      expect(h.store.unread, 0);
    });

    test('Reset sul server ricarica tutto', () async {
      final calls = <void>[];
      h.store.addListener(() => calls.add(null));
      h.store.debugMessage({'type': 'reset'});
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNotEmpty);
    });
  });

  group('guida: sicurezza', () {
    late Harness h;

    setUp(() async {
      h = Harness();
      await h.store.connect('192.168.1.8');
      await Future<void>.delayed(Duration.zero);
      h.socket.push(tickWith(h, {}));
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() => h.store.drive(null));

    test('dal websocket, con le velocità dei tasti', () {
      h.store.drive({Move.avanti});
      expect(h.store.debugDriving, isTrue);
      expect(h.socket.sent.last, {'type': 'drive', 'vx': 0.4, 'vy': 0.0, 'wz': 0.0});
    });

    test('tasto rilasciato = niente più comandi', () {
      h.store.drive({Move.avanti});
      h.store.drive(const {});
      expect(h.store.debugDriving, isFalse);
    });

    test('con l\'arresto d\'emergenza inserito non parte', () {
      h.store.debugMessage(tickWith(h, {'armed': false}));
      h.store.drive({Move.avanti});
      expect(h.store.debugDriving, isFalse);
    });

    test('l\'app sullo sfondo ferma la guida', () {
      h.store.drive({Move.avanti});
      h.store.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(h.store.debugDriving, isFalse);
    });

    test('in demo non manda nulla', () {
      final demo = Harness();
      demo.store.drive({Move.avanti});
      expect(demo.store.debugDriving, isFalse);
    });
  });

  test('i comandi fuori collegamento dicono che non c\'è il server', () async {
    final h = Harness();
    await expectLater(h.store.command('stop'), throwsA(isA<RondaOffline>()));
  });

  test('i comandi arrivano al server', () async {
    final h = Harness();
    await h.store.connect('192.168.1.8');
    await h.store.command('estop');
    expect(h.commands.single['action'], 'estop');
  });
}
