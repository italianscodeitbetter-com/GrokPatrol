import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/core/theme.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/mock_data.dart' as demo;
import 'package:grokpatrol/features/dashboard/dashboard_page.dart';
import 'package:grokpatrol/features/dashboard/map_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'console_store_test.dart' show Harness;
import 'support/fake_webview.dart';

final hours = '${demo.shift.start}–${demo.shift.end}';

void main() {
  useFakeWebView();

  Future<void> dashboard(WidgetTester t, Size size, {ValueChanged<bool>? onImmersive}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: DashboardPage(visible: true, onImmersive: onImmersive ?? (_) {})),
      ),
    );
    await t.pump();
  }

  // il timer dell'orologio si ferma solo smontando la pagina
  Future<void> close(WidgetTester t) => t.pumpWidget(const SizedBox());

  testWidgets('la mappa si muove solo con le dita: niente pulsanti né vista iniziale', (t) async {
    await dashboard(t, const Size(402, 760));
    for (final label in ['Move forward', 'Move back', 'Move left', 'Move right', 'Rotate left', 'Rotate right', 'Center view']) {
      expect(find.bySemanticsLabel(label), findsNothing, reason: label);
    }
    expect(find.text('Reset view'), findsNothing);
    await close(t);
  });

  testWidgets('a sinistra ora e turno, sotto i bot in colonna', (t) async {
    await dashboard(t, const Size(402, 760));
    final clock = t.getRect(find.text(demo.shift.name));
    expect(clock.top, lessThan(40));
    expect(t.getRect(find.text(hours)).top, clock.top, reason: 'una riga sola, come in origine');

    final bots = [for (final d in demo.fleet) t.getRect(find.bySemanticsLabel(RegExp('^${d.name}')))];
    expect(bots.first.top, greaterThan(clock.bottom));
    expect(bots.first.left, lessThan(24), reason: 'sul bordo sinistro');
    for (var i = 1; i < bots.length; i++) {
      expect(bots[i].left, bots.first.left, reason: 'uno sotto l\'altro');
      expect(bots[i].top, greaterThan(bots[i - 1].bottom));
    }
    await close(t);
  });

  testWidgets('le notifiche sulla riga dell\'orario e sotto la legenda, senza card', (t) async {
    await dashboard(t, const Size(402, 760));
    final clock = t.getRect(find.text(demo.shift.name));
    final bell = t.getRect(find.bySemanticsLabel(RegExp('^Activity')));
    final legend = t.getRect(find.text('Medium / low'));
    expect(bell.right, greaterThan(402 - 24 - 18), reason: 'sul bordo destro');
    expect((bell.center.dy - clock.center.dy).abs(), lessThan(4), reason: 'stessa riga');
    expect(legend.left, greaterThan(402 / 2));
    expect(legend.top, greaterThan(bell.bottom));
    final card = find.byWidgetPredicate((w) => w is Container && w.decoration != null);
    expect(find.ancestor(of: find.text('Medium / low'), matching: card), findsNothing);
    await close(t);
  });

  testWidgets('dal vivo tutto su una riga, niente padiglione né E-stop, e l\'allarme acceso si vede', (t) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    final h = Harness(), demoStore = ConsoleStore.instance;
    ConsoleStore.instance = h.store;
    addTearDown(() => ConsoleStore.instance = demoStore);
    await t.runAsync(() => h.store.connect('192.168.1.8'));
    h.store.debugMessage({
      ...h.fixture['state']! as Map<String, Object?>,
      'type': 'tick',
      'alarm': {'armed': false, 'active': false, 'exit_delay_s': 0, 'by': ''},
    });

    await dashboard(t, const Size(360, 760));
    expect(find.text('Controls'), findsNothing, reason: 'solo l\'icona');
    expect(find.text('Alarm off'), findsNothing, reason: 'solo l\'icona');
    expect(find.text('E-stop'), findsNothing, reason: 'sta in Controls e nella vista del cane');
    expect(find.text('Padiglione 3'), findsNothing);

    final shift = find.textContaining('Shift since');
    expect(t.renderObject<RenderParagraph>(shift).didExceedMaxLines, isFalse, reason: 'ci sta anche su un telefono stretto');
    final alarm = t.getRect(find.bySemanticsLabel('Alarm off'));
    final controls = t.getRect(find.bySemanticsLabel('Controls'));
    final bell = t.getRect(find.bySemanticsLabel(RegExp('^Activity')));
    expect(t.getRect(shift).right, lessThan(alarm.left));
    expect(alarm.right, lessThan(controls.left));
    expect(controls.right, lessThan(bell.left));
    expect(alarm.center.dy, bell.center.dy, reason: 'stessa riga');
    expect((alarm.center.dy - t.getRect(shift).center.dy).abs(), lessThan(4), reason: 'stessa riga dell\'orario');
    expect(alarm.left, greaterThan(360 - 150), reason: 'tutte a destra');

    h.store.debugMessage({
      ...h.fixture['state']! as Map<String, Object?>,
      'type': 'tick',
      'alarm': {'armed': true, 'active': true, 'exit_delay_s': 0, 'by': 'test'},
    });
    await t.pump();
    expect(find.bySemanticsLabel('Armed'), findsOneWidget);
    expect(t.widget<Icon>(find.byIcon(LucideIcons.shieldCheck)).color, AppColors.red400);

    await close(t);
    await t.runAsync(() => h.store.disconnect());
  });

  testWidgets('una telecamera va a tutto schermo in orizzontale e torna alla card in verticale', (t) async {
    final orientations = <List<Object?>>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') orientations.add(call.arguments as List<Object?>);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final immersive = <bool>[];
    await dashboard(t, const Size(402, 760), onImmersive: immersive.add);
    final id = ConsoleStore.instance.cameras.first.id;
    t.widget<MapView>(find.byType(MapView)).controller.onCamera!(id);
    await t.pump();

    await t.tap(find.byTooltip('Full screen'));
    await t.pump();
    expect(find.bySemanticsLabel('$id full screen'), findsOneWidget);
    expect(find.byTooltip('Close camera view'), findsNothing, reason: 'la card lascia il posto');
    expect(find.bySemanticsLabel('Controls'), findsNothing);
    expect(immersive, [true], reason: 'la shell nasconde le sue barre');
    expect(orientations.last, ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);

    t.view.physicalSize = const Size(874, 402);
    await t.pump();
    await t.tap(find.byTooltip('Close full screen'));
    await t.pump();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    expect(immersive, [true], reason: 'la barra nativa nata in orizzontale resterebbe fuori posto');

    t.view.physicalSize = const Size(402, 760);
    await t.pump();
    await t.pump();
    expect(immersive, [true, false], reason: 'a rotazione finita le barre tornano');
    expect(find.byTooltip('Full screen'), findsOneWidget, reason: 'si torna alla card');
    await close(t);
  });

  testWidgets('orario e legenda si leggono soltanto: il dito lì sopra muove la mappa', (t) async {
    await dashboard(t, const Size(402, 760));
    for (final finder in [find.text(demo.shift.name), find.text('Medium / low')]) {
      final hit = t.hitTestOnBinding(t.getCenter(finder));
      expect(hit.path.any((e) => e.target == t.renderObject(finder)), isFalse);
    }
    await close(t);
  });

  testWidgets('orario e legenda si leggono per intero, anche su un telefono stretto', (t) async {
    await dashboard(t, const Size(360, 760));
    for (final label in [demo.shift.name, hours, 'Dog', 'Patrol point', 'Camera', 'High priority', 'Medium / low']) {
      expect(t.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines, isFalse, reason: label);
    }
    await close(t);
  });

  testWidgets('aperto il pannello dei bot la legenda sparisce e i bot scorrono invece di coprirlo', (t) async {
    await dashboard(t, const Size(360, 520));
    await t.tap(find.bySemanticsLabel(RegExp('^${demo.fleet.first.name}')));
    await t.pump();
    expect(find.text('Search bots'), findsOneWidget);
    expect(find.text('Medium / low'), findsNothing);
    expect(t.takeException(), isNull, reason: 'niente overflow su un telefono piccolo');
    await close(t);
  });
}
