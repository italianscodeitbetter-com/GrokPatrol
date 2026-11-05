import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/features/dashboard/map_view.dart';

import 'support/fake_webview.dart';

void main() {
  useFakeWebView();

  test('la pagina parte solo quando il canale è pronto', () async {
    webViewSteps.clear();
    final map = MapController();
    addTearDown(map.dispose);
    expect(map.web, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(webViewSteps, ['channel', 'load'], reason: 'al contrario la scena non può mai dire di essere pronta');
    expect(map.error.value, isNull);
  });
}
