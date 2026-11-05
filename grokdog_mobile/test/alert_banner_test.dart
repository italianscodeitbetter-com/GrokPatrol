import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/core/theme.dart';
import 'package:grokpatrol/data/console_store.dart';
import 'package:grokpatrol/data/ronda/ronda_models.dart';
import 'package:grokpatrol/shared/alert_banner.dart';

void main() {
  // come in app.dart: sta sopra il Navigator, dove non c'è un Overlay. Un Tooltip qui manda in crash il banner.
  Widget app() => MaterialApp(
    theme: buildTheme(),
    builder: (context, child) => Stack(children: [?child, const AlertBanner()]),
    home: const Scaffold(body: Text('page')),
  );

  tearDown(() => ConsoleStore.instance.alert.value = null);

  testWidgets('niente alert, niente banner', (t) async {
    await t.pumpWidget(app());
    expect(find.byType(Material), findsWidgets);
    expect(find.text('Allarme: intrusione'), findsNothing);
  });

  testWidgets('si mostra sopra il Navigator, con canali e luogo, e si chiude', (t) async {
    await t.pumpWidget(app());
    ConsoleStore.instance.alert.value = const LiveAlert(
      title: 'Allarme: intrusione',
      body: 'Persona vicino alla teca',
      place: 'Teca centrale',
      results: [
        AlertResult(channel: 'console', ok: true),
        AlertResult(channel: 'sms', ok: false),
      ],
      image: null,
    );
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('Allarme: intrusione'), findsOneWidget);
    expect(find.text('Persona vicino alla teca'), findsOneWidget);
    expect(find.text('Teca centrale · console sent, sms failed'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Dismiss alert'));
    await t.pump();
    expect(ConsoleStore.instance.alert.value, isNull);
    expect(find.text('Allarme: intrusione'), findsNothing);
  });
}
