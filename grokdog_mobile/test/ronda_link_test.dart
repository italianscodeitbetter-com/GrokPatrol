import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/ronda/ronda_link.dart';
import 'package:grokpatrol/data/ronda/ronda_models.dart';

class FakeSocket implements RondaSocket {
  final controller = StreamController<Object?>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<Object?> get messages => controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late List<LinkState> states;
  late List<Json> messages;
  late int polls;
  late bool serverUp;

  RondaLink link(SocketConnector connector) => RondaLink(
    uri: Uri.parse('ws://x/ws/console'),
    headers: () => const {},
    onMessage: messages.add,
    onState: states.add,
    poll: () async {
      polls++;
      return serverUp;
    },
    connector: connector,
  );

  setUp(() {
    states = [];
    messages = [];
    polls = 0;
    serverUp = true;
  });

  test('un messaggio dal websocket = dal vivo', () {
    fakeAsync((t) {
      final s = FakeSocket();
      final l = link((_, _) async => s)..start();
      t.flushMicrotasks();
      s.controller.add(jsonEncode({'type': 'tick'}));
      t.flushMicrotasks();
      expect(states, [LinkState.live]);
      expect(messages.single['type'], 'tick');
      expect(l.canSend, isTrue);
      l.stop();
    });
  });

  test('se il websocket non parte, si chiede lo stato ogni secondo', () {
    fakeAsync((t) {
      final l = link((_, _) async => throw Exception('bloccato'))..start();
      t.elapse(const Duration(seconds: 3));
      expect(l.state, LinkState.polling);
      expect(polls, greaterThan(0));
      expect(l.canSend, isFalse);
      l.stop();
    });
  });

  test('se il server cade subito dopo il collegamento lo dice', () {
    fakeAsync((t) {
      serverUp = false;
      final l = link((_, _) async => throw Exception('no'))..start();
      t.elapse(const Duration(seconds: 3));
      expect(states, [LinkState.offline]);
      l.stop();
    });
  });

  test('si riconnette da solo quando il websocket cade', () {
    fakeAsync((t) {
      final sockets = <FakeSocket>[];
      final l = link((_, _) async {
        final s = FakeSocket();
        sockets.add(s);
        return s;
      })..start();
      t.flushMicrotasks();
      sockets.first.controller.add('{}');
      t.flushMicrotasks();
      unawaited(sockets.first.controller.close());
      t.flushMicrotasks();
      expect(l.canSend, isFalse, reason: 'caduto: la guida non deve passare da un socket morto');
      t.elapse(const Duration(seconds: 3));
      expect(sockets.length, 2);
      sockets.last.controller.add('{}');
      t.flushMicrotasks();
      expect(l.canSend, isTrue);
      l.stop();
    });
  });

  test('un messaggio illeggibile non chiude il collegamento', () {
    fakeAsync((t) {
      final s = FakeSocket();
      final l = link((_, _) async => s)..start();
      t.flushMicrotasks();
      s.controller.add('non è json');
      s.controller.add(jsonEncode({'type': 'log'}));
      t.flushMicrotasks();
      expect(messages.single['type'], 'log');
      l.stop();
    });
  });

  test('un websocket muto passa al polling, anche se è aperto', () {
    fakeAsync((t) {
      final s = FakeSocket();
      final l = link((_, _) async => s)..start();
      t.flushMicrotasks();
      s.controller.add('{}');
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 4));
      expect(states.last, LinkState.polling);
      expect(l.canSend, isFalse);
      l.stop();
    });
  });

  test('fermato, chiude il socket e non riprova più', () {
    fakeAsync((t) {
      final s = FakeSocket();
      var connects = 0;
      final l = link((_, _) async {
        connects++;
        return s;
      })..start();
      t.flushMicrotasks();
      unawaited(l.stop());
      t.elapse(const Duration(seconds: 10));
      expect(s.closed, isTrue);
      expect(connects, 1);
      expect(polls, 0);
    });
  });
}
