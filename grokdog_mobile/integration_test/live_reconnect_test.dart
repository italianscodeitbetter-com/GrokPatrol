// Il server cade e torna mentre l'app è aperta. Lo spegne e lo riaccende uno script esterno,
// quando legge i marcatori SERVER:OFF e SERVER:ON.
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/app.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/dog_drive.dart';
import 'package:grokpatrol/data/ronda/ronda_client.dart';
import 'package:grokpatrol/data/ronda/ronda_link.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = String.fromEnvironment('RONDA_URL', defaultValue: 'http://localhost:8000');

Future<void> waitFor(WidgetTester t, bool Function() ok, String what, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('Timeout: $what');
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('il server cade e torna: l\'app lo dice, ferma la guida e si ricollega', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ConsoleStore.instance;
    await t.pumpWidget(const GrokPatrolApp());
    await store.connect(server);
    await waitFor(t, () => store.link == LinkState.live, 'websocket vivo');
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Live'), findsOneWidget);

    store.drive({Move.avanti});
    expect(store.debugDriving, isTrue);

    // ignore: avoid_print
    print('SERVER:OFF');
    await waitFor(t, () => store.link == LinkState.offline, 'offline segnalato', seconds: 20);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text("Can't reach the server, retrying. Commands won't reach the dog."), findsOneWidget);
    expect(store.debugDriving, isFalse, reason: 'senza rete la guida si ferma');
    store.drive({Move.avanti});
    expect(store.debugDriving, isFalse, reason: 'e non riparte');
    await expectLater(store.command('stop'), throwsA(isA<RondaFailure>()), reason: 'un comando fallito si vede');

    // ignore: avoid_print
    print('SERVER:ON');
    await waitFor(t, () => store.link == LinkState.live, 'ricollegato', seconds: 40);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Live'), findsOneWidget);
    expect(find.text("Can't reach the server, retrying. Commands won't reach the dog."), findsNothing);
    expect((await store.command('stand'))['ok'], isTrue, reason: 'i comandi tornano a passare');
    await store.disconnect();
  });
}
