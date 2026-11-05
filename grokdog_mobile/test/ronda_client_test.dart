import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/ronda/ronda_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonOk(Object body, {int status = 200}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

void main() {
  group('indirizzo', () {
    test('si completa', () {
      expect(normalizeServerUrl('192.168.1.8'), 'http://192.168.1.8:8000');
      expect(normalizeServerUrl(' 192.168.1.8:9000/ '), 'http://192.168.1.8:9000');
      expect(normalizeServerUrl('http://localhost'), 'http://localhost:8000');
    });

    test('https resta com\'è: il tunnel non ha porta', () {
      expect(normalizeServerUrl('https://abc.ngrok.app/'), 'https://abc.ngrok.app');
    });

    test('vuoto resta vuoto', () => expect(normalizeServerUrl('  '), ''));

    test('websocket con lo stesso schema', () {
      expect(RondaClient('192.168.1.8').socketUri.toString(), 'ws://192.168.1.8:8000/ws/console');
      expect(RondaClient('https://abc.ngrok.app').socketUri.toString(), 'wss://abc.ngrok.app/ws/console');
    });
  });

  group('risposte', () {
    test('un comando rifiutato porta il motivo del server', () async {
      final c = RondaClient('x', client: MockClient((_) async => jsonOk({'ok': false, 'error': 'unknown route r9'})));
      await expectLater(c.command('patrol'), throwsA(isA<RondaRejected>().having((e) => e.message, 'message', 'unknown route r9')));
    });

    test('lo stesso con errore HTTP', () async {
      final c = RondaClient('x', client: MockClient((_) async => jsonOk({'ok': false, 'error': 'boom'}, status: 400)));
      await expectLater(c.addAutomation(const {}), throwsA(isA<RondaRejected>().having((e) => e.message, 'message', 'boom')));
    });

    test('401 = serve il PIN', () async {
      final c = RondaClient('x', client: MockClient((_) async => jsonOk({'ok': false, 'error': 'PIN required'}, status: 401)));
      await expectLater(c.state(), throwsA(isA<RondaPinRequired>()));
    });

    test('il form del PIN al posto del JSON = serve il PIN', () async {
      final c = RondaClient('x', client: MockClient((_) async => http.Response('<input name="pin">', 200)));
      await expectLater(c.state(), throwsA(isA<RondaPinRequired>()));
    });

    test('rete assente', () async {
      final c = RondaClient('x', client: MockClient((_) async => throw const SocketException('no route')));
      await expectLater(c.state(), throwsA(isA<RondaOffline>().having((e) => e.noRoute, 'noRoute', isFalse)));
      final blocked = RondaClient(
        'x',
        client: MockClient((_) async => throw const SocketException('Connection failed', osError: OSError('No route to host', 65))),
      );
      await expectLater(blocked.state(), throwsA(isA<RondaOffline>().having((e) => e.noRoute, 'noRoute', isTrue)));
    });

    test('risposta illeggibile', () async {
      final c = RondaClient('x', client: MockClient((_) async => http.Response('boh', 500)));
      await expectLater(c.state(), throwsA(isA<RondaRejected>()));
    });
  });

  group('PIN', () {
    test('il cookie del redirect viene usato dopo, anche per le immagini', () async {
      http.BaseRequest? seen;
      final c = RondaClient(
        'x',
        client: MockClient((r) async {
          seen = r;
          if (r.url.path == '/login') {
            expect(r.body, 'pin=12345678&next=%2F');
            return http.Response('', 303, headers: {'set-cookie': 'ronda_auth=abc123; Max-Age=2592000; HttpOnly; Path=/'});
          }
          return jsonOk({'ok': true});
        }),
      );
      await c.login('12345678');
      expect(c.cookie, 'ronda_auth=abc123');
      await c.command('stop');
      expect(seen!.headers['Cookie'], 'ronda_auth=abc123');
      expect(c.headers['Cookie'], 'ronda_auth=abc123');
    });

    test('PIN sbagliato', () async {
      final c = RondaClient('x', client: MockClient((_) async => http.Response('<form>PIN sbagliato', 200)));
      await expectLater(c.login('0000'), throwsA(isA<RondaBadPin>()));
    });

    test('il tunnel gratuito non deve mostrare la sua pagina di avviso', () {
      expect(RondaClient('x').headers['ngrok-skip-browser-warning'], '1');
    });
  });

  test('i percorsi delle immagini diventano assoluti', () {
    final c = RondaClient('192.168.1.8');
    expect(c.imageUrl('/api/snapshots/a.jpg'), 'http://192.168.1.8:8000/api/snapshots/a.jpg');
  });

  test('il comando porta azione e parametri', () async {
    late Map<String, Object?> body;
    final c = RondaClient(
      'x',
      client: MockClient((r) async {
        body = jsonDecode(r.body) as Map<String, Object?>;
        expect(r.url.path, '/api/command');
        return jsonOk({'ok': true});
      }),
    );
    await c.command('send', {'spot': 'z1'});
    expect(body, {'action': 'send', 'spot': 'z1'});
  });

  group('video', () {
    const frame = [0xFF, 0xD8, 1, 2, 0xFF, 0xD9];
    List<int> part() => [...'--frame\r\n\r\n'.codeUnits, ...frame];

    test('arriva un JPEG per volta, con il cookie del PIN', () async {
      late Map<String, String> sent;
      final c = RondaClient(
        'x',
        cookie: 'ronda_auth=t',
        videoClient: () => MockClient.streaming((request, _) async {
          sent = request.headers;
          expect(request.url.path, '/api/cameras/dog/stream');
          return http.StreamedResponse(Stream.fromIterable([part(), part()]), 200);
        }),
      );
      expect(await c.video('dog').toList(), [frame, frame]);
      expect(sent['Cookie'], 'ronda_auth=t');
    });

    test('un server che non ha il video lo dice', () async {
      final c = RondaClient('x', videoClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(const Stream.empty(), 404)));
      await expectLater(c.video('dog').toList(), throwsA(isA<RondaOffline>()));
    });

    test('dal tunnel senza PIN lo chiede', () async {
      final c = RondaClient('x', videoClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(const Stream.empty(), 401)));
      await expectLater(c.video('dog').toList(), throwsA(isA<RondaPinRequired>()));
    });
  });

  group('pagina telecamera', () {
    Future<String> url(Map<String, Object?> body) async {
      final c = RondaClient('http://192.168.5.55:8000', client: MockClient((_) async => http.Response(jsonEncode(body), 200)));
      return (await c.phonePage()).url;
    }

    test('sulla rete locale', () async {
      expect(
        await url({'url': null, 'camera': null, 'pin': null, 'lan_camera': 'https://192.168.5.55:8443/camera'}),
        'https://192.168.5.55:8443/camera',
      );
    });

    test('nel tunnel, con il PIN', () async {
      expect(await url({'camera': 'https://a.ngrok.app/camera', 'pin': '1234'}), 'https://a.ngrok.app/camera?pin=1234');
    });

    test('un server che non dice dove sta: si usa lo stesso indirizzo', () async {
      expect(await url({}), 'https://192.168.5.55:8443/camera');
    });
  });
}
