import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/core/theme.dart';
import 'package:grokpatrol/data/mock_data.dart';
import 'package:grokpatrol/data/models.dart';
import 'package:grokpatrol/data/stores.dart';
import 'package:grokpatrol/features/automation/automation_detail_page.dart';
import 'package:grokpatrol/features/automation/automation_page.dart';
import 'package:grokpatrol/features/missions/mission_detail_page.dart';
import 'package:grokpatrol/features/missions/missions_page.dart';
import 'package:grokpatrol/features/reports/reports_page.dart';
import 'package:grokpatrol/features/settings/profile_sheet.dart';
import 'package:grokpatrol/features/settings/settings_page.dart';
import 'package:grokpatrol/shared/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_webview.dart';

Widget app(Widget child) => MaterialApp(
  theme: buildTheme(),
  home: Scaffold(body: child),
);

void main() {
  useFakeWebView();

  // telefono stretto: i layout non devono andare in overflow
  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(360, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AutomationStore.instance.load();
  });

  testWidgets('Missions: in corso sopra, completate sotto, con l\'origine di ognuna', (t) async {
    phone(t);
    await t.pumpWidget(app(const MissionsPage(today: '2026-11-04')));
    expect(t.getTopLeft(find.text('In progress').first).dy, lessThan(t.getTopLeft(find.text('MS-0088')).dy));
    expect(t.getTopLeft(find.text('MS-0087')).dy, lessThan(t.getTopLeft(find.text('Completed')).dy));
    final handMade = missions.where((m) => m.automationId == null).length;
    expect(find.widgetWithText(ToneBadge, 'New mission', skipOffstage: false), findsNWidgets(handMade));
    expect(find.widgetWithText(ToneBadge, 'Automation', skipOffstage: false), findsNWidgets(missions.length - handMade));
  });

  testWidgets('Missions: un altro giorno non ha missioni', (t) async {
    phone(t);
    await t.pumpWidget(app(const MissionsPage(today: '2026-11-04')));
    await t.tap(find.bySemanticsLabel('Previous day'));
    await t.pump();
    expect(find.text('MS-0088'), findsNothing);
  });

  testWidgets('Una riga apre il dettaglio della missione', (t) async {
    phone(t);
    await t.pumpWidget(app(const MissionsPage(today: '2026-11-04')));
    await t.tap(find.text('MS-0088'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('MS-0088 · Room 3'), findsOneWidget);
    expect(find.text('Mission status'), findsOneWidget);
    expect(find.text('● LIVE'), findsOneWidget);
  });

  testWidgets('New mission: si crea solo con un testo', (t) async {
    phone(t);
    await t.pumpWidget(app(const MissionsPage(today: '2026-11-04')));
    await t.tap(find.widgetWithText(PrimaryButton, 'New mission'));
    await t.pumpAndSettle();
    await t.tap(find.text('Create mission'));
    await t.pumpAndSettle();
    expect(find.text('Create mission'), findsOneWidget, reason: 'senza testo resta aperto');
    await t.enterText(find.byType(TextField), 'check the east exit');
    await t.pump();
    await t.tap(find.text('Create mission'));
    await t.pumpAndSettle();
    expect(find.text('“check the east exit” created locally. Grok is not connected yet.'), findsOneWidget);
  });

  testWidgets('Dettaglio: una missione in coda non ha ancora tempi', (t) async {
    phone(t);
    final queued = missions.firstWhere((m) => m.id == 'MS-0087');
    await t.pumpWidget(app(MissionDetailPage(mission: queued)));
    expect(find.text('Not on site yet'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
  });

  testWidgets('Dettaglio: mostra chi ha creato la missione a mano', (t) async {
    phone(t);
    final custom = missions.firstWhere((m) => m.createdBy != null);
    await t.pumpWidget(app(MissionDetailPage(mission: custom)));
    expect(find.text('Created by', skipOffstage: false), findsOneWidget);
    expect(find.text(custom.createdBy!, skipOffstage: false), findsOneWidget);
  });

  test('whiteNumbers evidenzia sigle, orari e secondi', () {
    final white = [
      for (final s in whiteNumbers('Departed 11:02:17, arrived after 41 s on CAM-3 frame #8812 at P2'))
        if (s.style != null) s.text,
    ];
    expect(white, ['11:02:17', '41 s', 'CAM-3', '#8812', 'P2']);
  });

  group('Automation', () {
    testWidgets('elenco a schede: le azioni stanno nel dettaglio', (t) async {
      phone(t);
      await t.pumpWidget(app(const AutomationPage()));
      expect(find.text('Abandoned object'), findsOneWidget);
      expect(find.text('Pause'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('quelle di sistema si leggono ma non si cancellano', (t) async {
      phone(t);
      final system = automationRows().first;
      await t.pumpWidget(app(AutomationDetailPage(id: system.id)));
      await t.pump();
      expect(find.text(system.name), findsWidgets);
      expect(find.text('Delete', skipOffstage: false), findsNothing);
    });

    testWidgets('un id che non esiste più lo dice', (t) async {
      phone(t);
      await t.pumpWidget(app(const AutomationDetailPage(id: 'AU-99')));
      await t.pump();
      expect(find.text('Automation AU-99 not found.'), findsOneWidget);
    });
  });

  group('Reports', () {
    testWidgets('mostra i numeri del turno e la lista Activity', (t) async {
      phone(t);
      await t.pumpWidget(app(const ReportsPage(today: '2026-11-04')));
      expect(find.text('Events'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Track criteria'), findsNothing, reason: 'tolto dal nuovo design');
      expect(find.text('Alerts sent'), findsNothing, reason: 'ora sono righe di Activity');
    });

    testWidgets('Activity si filtra per tipo e si cerca', (t) async {
      phone(t);
      await t.pumpWidget(app(const ReportsPage(today: '2026-11-04')));
      await t.tap(find.byTooltip('Filter activity'));
      await t.pumpAndSettle();
      await t.tap(find.text('Alerts sent').last);
      await t.pumpAndSettle();
      expect(find.text('1–${alerts.length} of ${alerts.length}'), findsOneWidget);

      await t.tap(find.byTooltip('Search activity'));
      await t.pump();
      await t.enterText(find.byType(TextField), 'nobody will ever match this');
      await t.pump();
      expect(find.text('No activity matches.'), findsOneWidget);
      expect(find.text('0–0 of 0'), findsOneWidget);
    });

    test('filterActivity: tipo, testo e righe di allarme', () {
      const step = ActivityRow(time: '11:00:00', what: 'Trigger', detail: 'CAM-3', missionId: 'MS-1', room: 'Room 3', robot: 'D1');
      final alert = ActivityRow(
        time: '11:00:05',
        what: 'Alert',
        detail: 'Intruder',
        missionId: 'MS-1',
        room: 'Room 3',
        robot: 'D1',
        alert: alerts.first,
      );
      final rows = [step, alert];
      expect(filterActivity(rows, ActivityKind.all, ''), rows);
      expect(filterActivity(rows, ActivityKind.steps, ''), [step]);
      expect(filterActivity(rows, ActivityKind.alerts, ''), [alert]);
      expect(filterActivity(rows, ActivityKind.all, 'cam-3'), [step]);
      expect(filterActivity(rows, ActivityKind.all, alerts.first.to.toUpperCase()), [alert]);
    });

    testWidgets('senza dati il giorno è vuoto e non si esporta', (t) async {
      phone(t);
      await t.pumpWidget(app(const ReportsPage(today: '2026-11-04')));
      await t.tap(find.bySemanticsLabel('Previous day'));
      await t.pump();
      expect(find.text('3 November 2026'), findsOneWidget);
      expect(find.text('No data for this day.'), findsOneWidget);
      await t.tap(find.text('Export data'));
      await t.pumpAndSettle();
      expect(find.text('Which type of file do you want?'), findsNothing);
    });

    testWidgets('Export chiede il tipo di file', (t) async {
      phone(t);
      await t.pumpWidget(app(const ReportsPage(today: '2026-11-04')));
      await t.tap(find.text('Export data'));
      await t.pumpAndSettle();
      expect(find.text('Which type of file do you want?'), findsOneWidget);
      expect(find.text('Day report'), findsOneWidget);
      expect(find.text('Excel / Google Sheets'), findsOneWidget);
      expect(find.text('JSON'), findsOneWidget);
    });

    testWidgets('non si può andare oltre oggi', (t) async {
      phone(t);
      await t.pumpWidget(app(const ReportsPage(today: '2026-11-04')));
      await t.tap(find.bySemanticsLabel('Next day'));
      await t.pump();
      expect(find.text('4 November 2026'), findsOneWidget);
    });
  });

  group('Settings', () {
    for (final s in SettingsSection.values) {
      testWidgets('${s.label} si apre senza overflow', (t) async {
        phone(t);
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: SettingsPage(section: s),
          ),
        );
        expect(find.text(s.label), findsWidgets);
      });
    }

    testWidgets('Bots: scollegare e ricollegare un robot', (t) async {
      phone(t);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const SettingsPage(section: SettingsSection.bots),
        ),
      );
      expect(find.text('Connect'), findsNWidgets(3), reason: 'i tre robot spenti della flotta');
      await t.tap(find.text('Disconnect').first);
      await t.pump();
      expect(find.text('Connect'), findsNWidgets(4));
      await t.tap(find.text('Connect').first);
      await t.pump();
      expect(find.text('Connecting…'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1300));
      expect(find.text('Disconnect'), findsNWidgets(2));
    });

    testWidgets('Bots: rinominare un robot', (t) async {
      phone(t);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const SettingsPage(section: SettingsSection.bots),
        ),
      );
      await t.tap(find.text('Edit').first);
      await t.pump();
      await t.enterText(find.byType(TextField).first, 'Fido');
      await t.pump();
      await t.tap(find.text('Save'));
      await t.pump();
      expect(find.text('Fido'), findsOneWidget);
    });

    testWidgets('Chiave: Save si attiva solo con un valore', (t) async {
      phone(t);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const SettingsPage(section: SettingsSection.general),
        ),
      );
      await t.scrollUntilVisible(find.text('xAI'), 200, scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(find.text('Check').first);
      await t.pump();
      await t.tap(find.text('Check').first);
      await t.pump();
      expect(find.text('Paste a key first'), findsOneWidget);
    });
  });

  group('Nuove impostazioni', () {
    Widget section(SettingsSection s) => MaterialApp(
      theme: buildTheme(),
      home: SettingsPage(section: s),
    );

    testWidgets('Alerts: canale GrokBot e copia automatica a GrokBot', (t) async {
      phone(t);
      await t.pumpWidget(section(SettingsSection.alerts));
      expect(find.text('Also send to GrokBot'), findsWidgets);
      expect(find.text('Alerts only go to the test number and to GrokBot. No real calls to security or the police.'), findsOneWidget);
    });

    testWidgets('Cameras: ogni telecamera col suo stream, poi Detection', (t) async {
      phone(t);
      await t.pumpWidget(section(SettingsSection.cameras));
      expect(find.text('Online'), findsWidgets);
      expect(find.textContaining('rtsp://192.168.1.'), findsWidgets);
      expect(find.text('Detection', skipOffstage: false), findsOneWidget);
    });

    testWidgets('Bots: niente gruppo Patrol', (t) async {
      phone(t);
      await t.pumpWidget(section(SettingsSection.bots));
      expect(find.text('Patrol', skipOffstage: false), findsNothing);
      expect(find.text('Appearance', skipOffstage: false), findsNothing);
    });
  });

  testWidgets('Profilo: la card GrokBot si collega, conferma e sparisce', (t) async {
    phone(t);
    addTearDown(() {
      if (GrokBotStore.instance.status != GrokBotStatus.off) GrokBotStore.instance.toggle();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => showProfileSheet(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Connect'));
    await t.pump();
    expect(find.widgetWithText(PrimaryButton, 'Connecting…'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('GrokBot connected'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('GrokBot connected'), findsNothing);
    expect(find.widgetWithText(PrimaryButton, 'Connect'), findsNothing, reason: 'collegato: la card non serve più');
  });
}
