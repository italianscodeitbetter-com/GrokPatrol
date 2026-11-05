// L'app contro admin/backend vero, con il simulatore MuJoCo. Serve il backend acceso:
//   DOG=mujoco ./admin/run.sh  e  ./sim.sh
//   flutter test integration_test/live_server_test.dart -d <simulatore> --dart-define=RONDA_URL=http://localhost:8000
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/app.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/data/ronda/live_view.dart';
import 'package:grokpatrol/data/ronda/ronda_link.dart';
import 'package:grokpatrol/data/stores.dart';
import 'package:grokpatrol/features/automation/automation_builder_page.dart';
import 'package:grokpatrol/features/dashboard/map_view.dart';
import 'package:grokpatrol/shared/glass_tab_bar.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = String.fromEnvironment('RONDA_URL', defaultValue: 'http://localhost:8000');
const shots = bool.fromEnvironment('SHOTS');

/// Un JPEG vero di 1×1 pixel: quello che manda un telefono.
const testJpeg =
    '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/'
    'yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k=';

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

Future<void> waitFor(WidgetTester t, bool Function() ok, String what, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('Timeout: $what');
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Lo stato visto dal server, non dall'app: è lui che dice cosa è successo davvero.
Future<Map<String, Object?>> serverState() async {
  final r = await http.get(Uri.parse('$server/api/state'));
  return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, Object?>;
}

Future<void> serverCommand(String action, [Map<String, Object?> extra = const {}]) async {
  await http.post(
    Uri.parse('$server/api/command'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'action': action, ...extra}),
  );
}

Map<String, Object?> dogOf(Map<String, Object?> s) => s['dog']! as Map<String, Object?>;

MapController mapOf(WidgetTester t) => t.widget<MapView>(find.byType(MapView, skipOffstage: false).first).controller;

Future<void> tapFloor(MapController map, PlanPoint p) async {
  final at = await map.debugProject(p);
  await map.web.runJavaScript('''
    (function () {
      const c = document.querySelector('canvas'), r = c.getBoundingClientRect();
      const x = r.left + r.width * ${at['fx']}, y = r.top + r.height * ${at['fy']};
      const o = { bubbles: true, cancelable: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch', button: 0, buttons: 1, isPrimary: true };
      c.dispatchEvent(new PointerEvent('pointerdown', o));
      c.dispatchEvent(new PointerEvent('pointerup', { ...o, buttons: 0 }));
    })();
  ''');
}

/// Il cane è dove l'ha lasciato la prova: si cerca intorno a lui un punto libero raggiungibile in linea retta.
Future<void> pickFreePoint(WidgetTester t, MapController map, PlanPoint from) async {
  bool ok() => t.widget<RouteFormFooter>(find.byType(RouteFormFooter)).enabled;
  for (final d in const [
    (120.0, 0.0),
    (0.0, 120.0),
    (-120.0, 0.0),
    (0.0, -120.0),
    (90.0, 90.0),
    (-90.0, 90.0),
    (90.0, -90.0),
    (-90.0, -90.0),
  ]) {
    await tapFloor(map, PlanPoint(from.x + d.$1, from.y + d.$2));
    await settle(t, 500);
    if (ok()) return;
    final undo = find.text('Undo');
    if (find.textContaining('through a wall').evaluate().isNotEmpty && undo.evaluate().isNotEmpty) {
      await t.tap(undo);
      await settle(t, 300);
    }
  }
  fail('Nessun punto libero intorno al cane');
}

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

  testWidgets('app e server veri: mappa, guida, incidente, E-stop, automazione, report', (t) async {
    await serverCommand('reset_all');
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ConsoleStore.instance;
    await AutomationStore.instance.load();

    await t.pumpWidget(const GrokPatrolApp());
    await settle(t, 800);
    expect(find.text('Demo data'), findsOneWidget, reason: 'senza server i dati finti sono dichiarati');

    // ── collegamento dalla pagina Server ──
    await t.tap(find.bySemanticsLabel('Server: Demo data'));
    await settle(t, 700);
    await shot(t, 'L01-server');
    await t.enterText(find.byType(TextField).first, server);
    await settle(t, 200);
    await t.tap(find.text('Connect'));
    await waitFor(t, () => store.isLive, 'collegato');
    await waitFor(t, () => store.link == LinkState.live, 'websocket vivo');
    await settle(t, 800);
    expect(find.text('Disconnect and use demo data'), findsOneWidget);
    await shot(t, 'L02-collegato');
    await t.pageBack();
    await settle(t, 600);

    await waitFor(t, () => mapOf(t).ready.value, 'mappa dal vivo pronta');
    await settle(t, 1500);
    expect(find.text('Live'), findsOneWidget);
    expect(find.bySemanticsLabel('Controls'), findsOneWidget);
    expect(store.dogs.single.name, 'Unitree Go1 · MuJoCo');
    await shot(t, 'L03-dashboard');

    // ── la scena segue il cane del server ──
    await serverCommand('patrol', {'route': 'r1', 'loops': 0});
    await waitFor(t, () => store.tick?.current?.kind == 'patrol', 'ronda partita');
    final pose1 = await mapOf(t).debugState();
    await settle(t, 3000);
    final pose2 = await mapOf(t).debugState();
    final d1 = (pose1['dogs']! as List).single as Map, d2 = (pose2['dogs']! as List).single as Map;
    expect(d2['mode'], 'live');
    expect(
      ((d2['x']! as num) - (d1['x']! as num)).abs() + ((d2['y']! as num) - (d1['y']! as num)).abs(),
      greaterThan(10),
      reason: 'il cane cammina nella scena',
    );
    final f = store.frame.value!, sceneDog = ((await mapOf(t).debugState())['dogs']! as List).single as Map;
    expect(((sceneDog['x']! as num) - f.position.x).abs(), lessThan(60), reason: 'la scena sta dove dice il server');
    await shot(t, 'L04-ronda');
    await t.tap(find.bySemanticsLabel(store.dogs.single.name));
    await settle(t, 800);
    expect(find.textContaining('Ronda padiglione'), findsWidgets, reason: 'il pannello dice cosa sta facendo il cane');
    await shot(t, 'L04b-pannello');
    await serverCommand('stop');
    await waitFor(t, () => store.tick?.current == null, 'fermo');

    // ── guida manuale: il cane vero del simulatore si muove ──
    await serverCommand('stop');
    await t.tap(find.text('Live view'));
    await settle(t, 4000);
    await shot(t, 'L05-video-cane');
    // il video è quello fluido, e il simulatore lo manda perché qualcuno guarda
    final dogCam = (await serverState())['cameras']! as List;
    final watched = dogCam.cast<Map<String, Object?>>().firstWhere((c) => c['id'] == 'dog');
    expect(watched['viewers'], 1, reason: 'l\'app sta guardando');
    expect(watched['stream_fps']! as num, greaterThan(8), reason: 'video fluido, non un fotogramma al secondo');
    await t.tap(find.text('Take control'));
    await settle(t, 600);
    final before = dogOf(await serverState());
    final forward = await t.startGesture(t.getCenter(find.bySemanticsLabel('Forward')));
    await settle(t, 2500);
    await shot(t, 'L06-guida');
    await forward.up();
    await settle(t, 300);
    final after = dogOf(await serverState());
    final moved = ((after['x']! as num) - (before['x']! as num)).abs() + ((after['y']! as num) - (before['y']! as num)).abs();
    expect(moved, greaterThan(0.3), reason: 'tenendo premuto il cane si è mosso sul server');

    await settle(t, 1800);
    final still1 = dogOf(await serverState());
    await settle(t, 1200);
    final still2 = dogOf(await serverState());
    expect(((still2['x']! as num) - (still1['x']! as num)).abs(), lessThan(0.05), reason: 'rilasciato il tasto si ferma');
    expect(still2['manual'], false);

    // ── E-stop: blocca davvero, e la guida non passa ──
    await t.tap(find.text('E-stop'));
    await waitFor(t, () => store.dogStatus?.armed == false, 'arresto inserito');
    expect(dogOf(await serverState())['armed'], false);
    await settle(t, 500);
    expect(find.text('Emergency stop engaged: release it to drive.'), findsOneWidget);
    await shot(t, 'L07-estop');
    final g = await t.startGesture(t.getCenter(find.bySemanticsLabel('Forward')));
    await settle(t, 1000);
    await g.up();
    expect(dogOf(await serverState())['manual'], false, reason: 'con l\'E-stop la guida non parte');
    await t.tap(find.text('Release'));
    await settle(t, 500);
    await t.tap(find.text('Release').last);
    await waitFor(t, () => store.dogStatus?.armed == true, 'arresto rilasciato');

    await t.tap(find.text('Release control'));
    await settle(t, 400);
    await t.tap(find.text('Close'));
    await settle(t, 1500);
    final closed = ((await serverState())['cameras']! as List).cast<Map<String, Object?>>().firstWhere((c) => c['id'] == 'dog');
    expect(closed['viewers'], 0, reason: 'chiusa la vista, il flusso si ferma');

    // ── un incidente intero: allarme, scena, cane, alert ──
    await t.tap(find.bySemanticsLabel('Controls'));
    await settle(t, 700);
    await shot(t, 'L08-controlli');
    await t.tapAt(const Offset(200, 60));
    await settle(t, 500);
    await serverCommand('arm', {'delay': 0, 'by': 'test'});
    await waitFor(t, () => store.alarm?.active == true, 'allarme attivo');
    await settle(t, 500);
    expect(find.bySemanticsLabel('Armed'), findsOneWidget);
    await serverCommand('stage', {'scenario': 'intruder', 'camera': 'cam-2'});
    await waitFor(t, () => store.events.isNotEmpty, 'evento arrivato', seconds: 20);
    await settle(t, 1500);
    await shot(t, 'L09-evento');
    await waitFor(t, () => store.alert.value != null, 'alert arrivato', seconds: 60);
    await settle(t, 1000);
    expect(find.text(store.alert.value!.title), findsOneWidget);
    await shot(t, 'L10-alert');
    await t.tap(find.bySemanticsLabel('Dismiss alert'));
    await settle(t, 500);
    expect(store.alert.value, isNull);

    await goTab(t, 2);
    await settle(t, 600);
    await shot(t, 'L11-missioni');
    final done = store.missions.firstWhere((m) => m.outcome != Outcome.inCorso);
    expect(done.steps.first.time, isNotNull);
    expect(done.images, isNotEmpty);
    await t.tap(find.text(done.id).first);
    await settle(t, 1500);
    await shot(t, 'L12-missione');
    await t.pageBack();
    await settle(t, 500);

    await serverCommand('disarm', {'by': 'test'});
    await serverCommand('stage', {'scenario': 'clear'});
    await serverCommand('stop');

    // ── automazione creata dall'app, sul server ──
    await goTab(t, 1);
    await shot(t, 'L13-automation');
    expect(find.text('Alarm'), findsOneWidget);
    await t.tap(find.text('New automation'));
    await settle(t, 1000);
    final maps = find.byType(MapView, skipOffstage: false);
    await waitFor(t, () => t.widget<MapView>(maps.last).controller.ready.value, 'mappa del percorso pronta');
    await settle(t, 1200);
    await t.enterText(find.byType(TextField).first, 'Giro di prova');
    await settle(t, 200);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 700);
    final builderMap = t.widget<MapView>(maps.last).controller;
    final start = store.frame.value!.position;
    await pickFreePoint(t, builderMap, start);
    await shot(t, 'L13b-percorso');
    await t.tap(find.text('Create'));
    await waitFor(t, () => (store.tick?.automations ?? const []).isNotEmpty, 'automazione sul server');
    await settle(t, 800);
    var remote = ((await serverState())['automations']! as List).single as Map;
    expect(remote['name'], 'Giro di prova');
    final pts = remote['points']! as List;
    expect(pts.length, 2);
    // A è il cane, e i punti arrivano in metri nel sistema del sito
    final tr = SiteTransform.of(store.site!);
    final a0 = tr.toSite(start);
    expect(((pts.first as List)[0] as num), closeTo(a0.x, 0.3), reason: 'A è dove sta il cane');
    expect(((pts.first as List)[1] as num), closeTo(a0.y, 0.3));
    final id = remote['id']! as String;
    await t.scrollUntilVisible(find.text('Giro di prova'), 300, scrollable: find.byType(Scrollable).first);
    await settle(t, 400);
    await shot(t, 'L14-automazione-server');

    // ── dettaglio: cambia percorso sul server, avvio, cancellazione ──
    await t.tap(find.text('Giro di prova'));
    await settle(t, 800);
    await shot(t, 'L14b-dettaglio');
    await t.tap(find.text('Change path'));
    await settle(t, 1000);
    final pathMaps = find.byType(MapView, skipOffstage: false);
    await waitFor(t, () => t.widget<MapView>(pathMaps.last).controller.ready.value, 'mappa del percorso pronta');
    await settle(t, 1200);
    final pathMap = t.widget<MapView>(pathMaps.last).controller;
    await t.tap(find.text('Clear'));
    await settle(t, 400);
    await pickFreePoint(t, pathMap, start);
    await tapFloor(pathMap, start);
    await settle(t, 500);
    await shot(t, 'L14c-cambia-percorso');
    await t.tap(find.text('Save path'));
    await waitFor(t, () => (store.tick?.automations.single.points.length ?? 0) == 3, 'percorso cambiato sul server');
    await settle(t, 800);
    remote = ((await serverState())['automations']! as List).single as Map;
    expect(remote['id'], id, reason: 'stessa automazione, percorso nuovo');
    expect((remote['points']! as List).length, 3);

    await t.tap(find.text('Run now'));
    await waitFor(t, () => store.tick?.current?.label == 'Giro di prova', 'automazione partita');
    await serverCommand('stop');
    await settle(t, 500);
    await t.tap(find.text('Delete'));
    await settle(t, 500);
    await t.tap(find.text('Delete').last);
    await waitFor(t, () => store.tick?.automations.isEmpty ?? false, 'automazione cancellata');
    await settle(t, 800);

    // ── report dal registro vero ──
    await goTab(t, 3);
    await waitFor(t, () => find.text('Activity').evaluate().isNotEmpty, 'report caricato');
    await settle(t, 800);
    await shot(t, 'L15-report');
    expect(find.text('Confirmed anomalies'), findsOneWidget);
    expect(find.text('No data for this day.'), findsNothing);
    expect(find.textContaining(' of '), findsWidgets, reason: 'righe di Activity');
    await t.tap(find.byTooltip('Filter activity'));
    await settle(t, 500);
    await t.tap(find.text('Alerts sent').last);
    await settle(t, 500);
    await shot(t, 'L15b-allarmi');
    await t.tap(find.bySemanticsLabel('Previous day'));
    await waitFor(t, () => find.text('No data for this day.').evaluate().isNotEmpty, 'ieri è vuoto');

    // ── un telefono come telecamera: compare nell'elenco e si guarda dal vivo ──
    final phone = await WebSocket.connect('${server.replaceFirst('http', 'ws')}/ws/camera/phone-test');
    final jpeg = base64Decode(testJpeg);
    final live = <bool>[];
    final phoneInbox = phone.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, Object?>;
      if (m['type'] == 'live') live.add(m['on']! as bool);
    });
    void sendFrame() => phone.add(jsonEncode({'type': 'preview', 'jpeg': base64Encode(jpeg)}));
    sendFrame();
    await t.tap(find.bySemanticsLabel('Profile and settings'));
    await settle(t, 700);
    await t.tap(find.text('Cameras').last);
    await waitFor(t, () => find.text('Phone test').evaluate().isNotEmpty, 'il telefono è in elenco');
    await waitFor(t, () => find.text('Add a phone').evaluate().isNotEmpty, 'pagina del telefono caricata');
    await settle(t, 800);
    await shot(t, 'L16-telecamere');
    await t.tap(find.text('Phone test'));
    await settle(t, 800);
    await waitFor(t, () => live.lastOrNull == true, 'il telefono sa di essere guardato');
    for (var i = 0; i < 12; i++) {
      sendFrame();
      await settle(t, 100);
    }
    await shot(t, 'L17-preview-telefono');
    expect(find.byType(RawImage), findsOneWidget, reason: 'nell\'app si vede il video del telefono');
    await t.tapAt(const Offset(200, 120));
    await waitFor(t, () => live.lastOrNull == false, 'chiusa la preview, il telefono torna lento', seconds: 8);
    await phoneInbox.cancel();
    await phone.close();
    await t.pageBack();
    await settle(t, 700);

    // ── rete persa e ritrovata non si simula qui: si torna alla demo ──
    await store.disconnect();
    await settle(t, 1000);
    expect(store.mode, ConsoleMode.demo);
    expect(find.text('Demo data'), findsOneWidget);
  });
}
