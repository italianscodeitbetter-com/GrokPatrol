// Giro completo sul dispositivo: la mappa 3D vera, con la WebView vera.
// flutter test integration_test/app_tour_test.dart -d <simulatore>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/app.dart';
import 'package:grokpatrol/core/nav.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/data/stores.dart';
import 'package:grokpatrol/features/automation/automation_builder_page.dart';
import 'package:grokpatrol/features/dashboard/map_view.dart';
import 'package:grokpatrol/shared/glass_tab_bar.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Con SHOTS=1 si ferma a ogni passo: uno script esterno scatta lo screenshot del simulatore.
const shots = bool.fromEnvironment('SHOTS');

Future<void> settle(WidgetTester t, [int ms = 600]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> shot(WidgetTester t, String name) async {
  if (!shots) return;
  // ignore: avoid_print
  print('SHOT:$name');
  await settle(t, 2200);
}

Future<void> waitFor(WidgetTester t, bool Function() ok, {String what = 'condizione', int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('Timeout: $what');
    await t.pump(const Duration(milliseconds: 100));
  }
}

MapController mapOf(WidgetTester t, {bool last = false}) {
  final views = t.widgetList<MapView>(find.byType(MapView, skipOffstage: false)).toList();
  return (last ? views.last : views.first).controller;
}

Future<Map<String, Object?>> sceneState(WidgetTester t) => mapOf(t).debugState();

Map<String, Object?> dogState(Map<String, Object?> s, String id) =>
    (s['dogs']! as List<Object?>).cast<Map<String, Object?>>().firstWhere((d) => d['id'] == id);

Future<void> mapReady(WidgetTester t, {bool last = false}) => waitFor(t, () {
  final error = mapOf(t, last: last).error.value;
  if (error != null) fail('La mappa non parte: $error');
  return mapOf(t, last: last).ready.value;
}, what: 'mappa pronta');

/// Tocco sul pavimento nel punto [p] della pianta: gli stessi eventi del dito sul canvas.
Future<void> tapFloor(WidgetTester t, PlanPoint p) async {
  final map = mapOf(t, last: true);
  final at = await map.debugProject(p);
  await map.web.runJavaScript('''
    (function () {
      const c = document.querySelector('canvas');
      const r = c.getBoundingClientRect();
      const x = r.left + r.width * ${at['fx']}, y = r.top + r.height * ${at['fy']};
      const o = { bubbles: true, cancelable: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch', button: 0, buttons: 1, isPrimary: true };
      c.dispatchEvent(new PointerEvent('pointerdown', o));
      c.dispatchEvent(new PointerEvent('pointerup', { ...o, buttons: 0 }));
    })();
  ''');
  await settle(t, 350);
}

/// Tap su un'etichetta HTML della scena, con il `click` che manda il dito.
Future<void> tapLabel(WidgetTester t, String selector) async {
  await mapOf(t).web.runJavaScript("document.querySelector('$selector').click()");
  await settle(t, 500);
}

/// Cambia scheda: con il vetro la barra è nativa e il tester di Flutter non può toccarla.
Future<void> goTab(WidgetTester t, int index) async {
  final glass = find.byType(GlassTabBar);
  if (glass.evaluate().isNotEmpty) {
    t.widget<GlassTabBar>(glass).onSelected(index);
  } else {
    await t.tap(find.byType(NavigationDestination).at(index));
  }
  await settle(t);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('giro completo: mappa, cane, missioni, automazione, report, impostazioni', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await AutomationStore.instance.load();

    await t.pumpWidget(const GrokPatrolApp());
    await mapReady(t);
    await settle(t, 1500);
    await shot(t, '01-dashboard');

    // la scena ha i due cani in ronda e si muovono da soli
    final a = dogState(await sceneState(t), 'GD-2');
    expect(a['mode'], 'ronda');
    await settle(t, 800);
    final b = dogState(await sceneState(t), 'GD-2');
    expect(b['x'] != a['x'] || b['y'] != a['y'], isTrue, reason: 'il cane deve camminare');

    // i bot sono tondi in una riga; il pannello si apre toccandone uno
    expect(find.text('Follow', skipOffstage: false), findsNothing, reason: 'chiuso di partenza');
    await t.tap(find.bySemanticsLabel('Unitree Go1 - D1'));
    await settle(t, 900);
    await shot(t, '02-bots-aperti');
    expect(find.text('Follow'), findsWidgets);
    await t.tap(find.byTooltip('Close bots'));
    await settle(t, 600);
    expect(find.text('Follow', skipOffstage: false), findsNothing);
    await t.tap(find.bySemanticsLabel('Unitree Go1 - D1'));
    await settle(t, 600);

    // Segui: la scena segue il cane e disegna il riquadro
    await t.tap(find.text('Follow').first);
    await settle(t, 1800);
    var s = await sceneState(t);
    expect(s['following'], 'GD-1');
    final pov = s['pov']! as Map<String, Object?>;
    expect(pov['dogId'], 'GD-1');
    expect(pov['cover'], false);
    expect(pov['rect'], isNotNull);
    expect(find.text('Unitree Go1 - D1 view'), findsOneWidget);
    await shot(t, '03-segui');
    await t.tap(find.byTooltip('Close view'));
    await settle(t);
    s = await sceneState(t);
    expect(s['following'], isNull);
    expect(s['pov'], isNull);
    expect(find.text('Follow'), findsNothing, reason: 'seguire chiude il pannello: i due non ci stanno insieme');

    // Etichette dentro la scena: arrivano a Dart dal bridge
    await tapLabel(t, '.lbl-btn');
    expect(find.text('CAM-1 · Room 1'), findsOneWidget);
    await shot(t, '05-camera');
    await t.tap(find.byTooltip('Full screen'));
    await settle(t, 1500);
    await shot(t, '05b-camera-tutto-schermo');
    await t.tap(find.byTooltip('Close full screen'));
    await settle(t, 1500);
    await t.tap(find.byTooltip('Close camera view'));
    await settle(t);
    await tapLabel(t, '.lbl-dog');
    expect((await sceneState(t))['following'], 'GD-1');
    await tapLabel(t, '.lbl-dog');
    expect((await sceneState(t))['following'], isNull);

    // Notifiche: «View all» porta su Activity
    await t.tap(find.bySemanticsLabel(RegExp(r'^Activity, \d+ new$')));
    await settle(t);
    await shot(t, '06-attivita');
    await t.tap(find.text('View all'));
    await settle(t, 900);
    expect(showReportsActivity.value, greaterThan(0));
    expect(find.text('Activity'), findsOneWidget, reason: 'siamo su Reports');
    await shot(t, '06b-view-all');
    await goTab(t, 0);
    await settle(t, 800);
    expect(find.bySemanticsLabel(RegExp(r'^Activity, \d+ new$')), findsNothing, reason: 'aperte = lette');

    // Live view a tutto schermo e guida manuale
    await t.tap(find.bySemanticsLabel('Unitree Go1 - D1'));
    await settle(t, 800);
    await shot(t, '06c-pannello');
    await t.tap(find.text('Live view').first);
    await settle(t, 1200);
    expect(find.text('GrokPatrol'), findsNothing, reason: 'le barre spariscono');
    s = await sceneState(t);
    expect((s['pov']! as Map<String, Object?>)['cover'], true);
    await shot(t, '07-live');
    await t.tap(find.text('Take control'));
    await settle(t, 900);
    await shot(t, '08-controllo');
    final before = dogState(await sceneState(t), 'GD-1');
    expect(before['mode'], 'mano');

    final forward = await t.startGesture(t.getCenter(find.bySemanticsLabel('Forward')));
    await settle(t, 1500);
    await shot(t, '09-avanti');
    await forward.up();
    await settle(t, 300);
    final after = dogState(await sceneState(t), 'GD-1');
    final moved = ((after['x']! as num) - (before['x']! as num)).abs() + ((after['y']! as num) - (before['y']! as num)).abs();
    expect(moved, greaterThan(20), reason: 'tenendo premuto il cane cammina');

    await settle(t, 500);
    final still = dogState(await sceneState(t), 'GD-1');
    expect(still['x'], after['x'], reason: 'rilasciato il tasto si ferma');

    await t.tap(find.text('Release control'));
    await settle(t, 500);
    expect(dogState(await sceneState(t), 'GD-1')['mode'], 'ritorno', reason: 'torna al giro');
    await t.tap(find.text('Close'));
    await settle(t, 800);
    expect(find.text('GrokPatrol'), findsOneWidget);
    expect((await sceneState(t))['pov'], isNull);

    // Automation → nuova: A è dove sta il robot, si tocca da B in poi
    await goTab(t, 1);
    expect((await sceneState(t))['paused'], true, reason: 'la mappa nascosta si ferma');
    await shot(t, '10-automation');
    await t.tap(find.text('New automation'));
    await settle(t, 800);
    await mapReady(t, last: true);
    await settle(t, 1200);
    await shot(t, '11-nuova-automazione');
    bool canCreate() => t.widget<RouteFormFooter>(find.byType(RouteFormFooter)).enabled;
    expect(canCreate(), isFalse, reason: 'senza nome e senza B non si crea');

    await t.enterText(find.byType(TextField).first, 'Giro serale');
    await settle(t);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 700);

    // il secondo punto del giro di D1: lo stesso corridoio che il cane fa già
    final route = ConsoleStore.instance.dogs.first.route;
    await tapFloor(t, route[1]);
    await settle(t, 400);
    expect(find.textContaining('through a wall'), findsNothing);
    expect(canCreate(), isTrue);
    await shot(t, '12-percorso');

    // su un tavolo il punto si rifiuta
    await tapFloor(t, const PlanPoint(860, 1290));
    expect(find.text('That spot is a wall or an object: pick a free spot on the floor.'), findsOneWidget);
    await shot(t, '12b-punto-rifiutato');

    // C al di là della parete: il tratto la attraversa, non si può salvare
    await tapFloor(t, const PlanPoint(1240, 1150));
    await settle(t, 400);
    expect(find.textContaining('through a wall'), findsOneWidget);
    expect(find.text('B → C blocked: fix the route'), findsOneWidget);
    await shot(t, '12c-tratto-nel-muro');
    expect(canCreate(), isFalse, reason: 'con un tratto nel muro non si salva');

    await t.tap(find.text('Undo'));
    await settle(t, 500);
    expect(canCreate(), isTrue);

    await t.tap(find.text('Create'));
    await settle(t, 800);
    expect(AutomationStore.instance.items.single.name, 'Giro serale');
    expect(AutomationStore.instance.items.single.id, 'AU-06');
    expect(AutomationStore.instance.items.single.route.first, route.first, reason: 'A è la posizione del robot');
    await t.scrollUntilVisible(find.text('Giro serale'), 200, scrollable: find.byType(Scrollable).first);
    await settle(t, 400);
    await shot(t, '13-automazione-creata');

    // le azioni stanno nel dettaglio
    await t.tap(find.text('Giro serale'));
    await settle(t, 800);
    await shot(t, '13b-dettaglio');
    await t.tap(find.text('Pause'));
    await settle(t, 300);
    expect(AutomationStore.instance.items.single.active, isFalse);
    await t.tap(find.text('Resume'));
    await settle(t, 300);
    expect(AutomationStore.instance.items.single.active, isTrue);

    await t.tap(find.text('Change path'));
    await settle(t, 800);
    await mapReady(t, last: true);
    await settle(t, 1200);
    await shot(t, '13c-cambia-percorso');
    await tapFloor(t, route[2]);
    await settle(t, 400);
    await t.tap(find.text('Save path'));
    await settle(t, 800);
    expect(AutomationStore.instance.items.single.route.length, 3);

    // salvata sul telefono: si rilegge
    await AutomationStore.instance.load();
    expect(AutomationStore.instance.items.single.route.length, 3);
    await t.pageBack();
    await settle(t, 600);

    // Missions
    await goTab(t, 2);
    await shot(t, '14-missions');
    await t.tap(find.text('MS-0086'));
    await settle(t, 700);
    await shot(t, '15-missione');
    expect(find.text('MS-0086 · Room 2'), findsOneWidget);
    expect(find.text('Person sitting on the sculpture plinth'), findsWidgets);
    await t.pageBack();
    await settle(t, 600);

    // Reports: da «View all» è rimasta su Activity, si torna in cima
    await goTab(t, 3);
    await shot(t, '16a-activity');
    expect(find.text('Activity'), findsOneWidget);
    await t.drag(find.byType(ListView).last, const Offset(0, 1200));
    await settle(t, 700);
    await shot(t, '16-reports');
    expect(find.text('Track criteria'), findsNothing);
    await t.tap(find.text('Export data'));
    await settle(t, 600);
    await shot(t, '16b-export');
    expect(find.text('Which type of file do you want?'), findsOneWidget);
    await t.tapAt(const Offset(200, 120));
    await settle(t, 600);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await settle(t);
    expect(find.text('No data for this day.'), findsOneWidget);
    await shot(t, '17-reports-vuoto');
    await t.tap(find.bySemanticsLabel('Next day'));
    await settle(t);

    // Profilo: la card GrokBot si collega e sparisce
    await t.tap(find.bySemanticsLabel('Profile and settings'));
    await settle(t);
    await shot(t, '18-profilo');
    await t.tap(find.text('Connect'));
    await settle(t, 300);
    await shot(t, '18b-connecting');
    await settle(t, 1500);
    expect(GrokBotStore.instance.status, GrokBotStatus.on);
    expect(find.text('GrokBot connected'), findsOneWidget);
    await shot(t, '18c-connesso');
    await t.tap(find.text('Done'));
    await settle(t, 600);
    expect(find.text('Connect'), findsNothing);
    for (final section in ['Alerts', 'GrokBot', 'Cameras']) {
      await t.tap(find.text(section).last);
      await settle(t, 800);
      await shot(t, '19-impostazioni-${section.toLowerCase()}');
      await t.pageBack();
      await settle(t, 600);
      if (find.text('Log out').evaluate().isEmpty) {
        await t.tap(find.bySemanticsLabel('Profile and settings'));
        await settle(t);
      }
    }
    await t.tap(find.text('Bots').last);
    await settle(t, 800);
    await shot(t, '19-impostazioni-bots');
    expect(find.text('Patrol'), findsNothing, reason: 'tolto dal nuovo design');
    expect(find.text('Disconnect'), findsNWidgets(2));
  });
}
