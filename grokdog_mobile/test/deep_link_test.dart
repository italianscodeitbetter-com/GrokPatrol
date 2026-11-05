import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/core/deep_link.dart';
import 'package:grokpatrol/core/nav.dart';
import 'package:grokpatrol/core/theme.dart';
import 'package:grokpatrol/data/mock_data.dart' as demo;
import 'package:grokpatrol/features/missions/deep_link_page.dart';

void main() {
  group('parseDeepLink', () {
    test('il link intero di Telegram', () {
      expect(parseDeepLink('grokpatrol://open/mission/m-348f5'), const DeepLink(DeepLinkKind.mission, 'm-348f5'));
      expect(parseDeepLink('grokpatrol://open/event/ev-1f3da'), const DeepLink(DeepLinkKind.event, 'ev-1f3da'));
    });

    test('la rotta che Flutter passa al Navigator', () {
      expect(parseDeepLink('/mission/m-348f5'), const DeepLink(DeepLinkKind.mission, 'm-348f5'));
      expect(parseDeepLink('/event/ev-1f3da'), const DeepLink(DeepLinkKind.event, 'ev-1f3da'));
    });

    test('tollera barra finale, query e maiuscole nello schema', () {
      expect(parseDeepLink('/mission/m-348f5/'), const DeepLink(DeepLinkKind.mission, 'm-348f5'));
      expect(parseDeepLink('/mission/m-348f5?from=telegram'), const DeepLink(DeepLinkKind.mission, 'm-348f5'));
      expect(parseDeepLink('GrokPatrol://open/mission/m-348f5'), const DeepLink(DeepLinkKind.mission, 'm-348f5'));
    });

    test('la rotta è quella di partenza', () {
      expect(parseDeepLink('grokpatrol://open/mission/m-348f5')!.route, '/mission/m-348f5');
    });

    test('rifiuta quello che non è nostro', () {
      for (final bad in [
        '',
        '/',
        '/mission',
        '/mission/',
        '/mission/a/b',
        '/robot/m-1',
        '/mission/../x',
        '/mission/%20',
        'https://example.com/mission/m-1',
        'grokpatrol://other/mission/m-1',
        '//open/mission/m-1',
      ]) {
        expect(parseDeepLink(bad), isNull, reason: bad);
      }
    });
  });

  group('missionForLink', () {
    test('missione per id, evento per la missione che ha fatto partire', () {
      final m = demo.missions.first;
      expect(missionForLink(DeepLink(DeepLinkKind.mission, m.id), demo.missions), same(m));
      expect(missionForLink(DeepLink(DeepLinkKind.event, m.eventId), demo.missions), same(m));
      expect(missionForLink(const DeepLink(DeepLinkKind.mission, 'm-nope'), demo.missions), isNull);
      expect(missionForLink(const DeepLink(DeepLinkKind.event, 'ev-nope'), demo.missions), isNull);
    });
  });

  testWidgets('in demo il link dice che serve il server e torna alle schede', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        scaffoldMessengerKey: rootMessengerKey,
        home: const Scaffold(body: Text('tabs')),
      ),
    );
    final nav = t.state<NavigatorState>(find.byType(Navigator));
    nav.push(deepLinkRoute(const DeepLink(DeepLinkKind.mission, 'm-348f5')));
    await t.pumpAndSettle();
    expect(find.byType(DeepLinkPage), findsNothing);
    expect(find.text('tabs'), findsOneWidget);
    expect(find.textContaining('need the live server'), findsOneWidget);
  });
}
