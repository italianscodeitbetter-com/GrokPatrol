import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Nei test non c'è la WebView vera: basta che la scena si possa costruire. Quella reale si prova in integration_test.
void useFakeWebView() => WebViewPlatform.instance = _Platform();

/// I passi di avvio arrivati alla WebView, nell'ordine in cui si sono conclusi.
final webViewSteps = <String>[];

class _Platform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) => _Controller(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) => _Navigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) => _Widget(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {
    // come su iOS: il canale non è pronto subito. Senza timer, che resterebbero appesi a fine test
    for (var i = 0; i < 8; i++) {
      await Future<void>.value();
    }
    webViewSteps.add('channel');
  }

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadFlutterAsset(String key) async => webViewSteps.add('load');

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> reload() async {}
}

class _Navigation extends PlatformNavigationDelegate {
  _Navigation(super.params) : super.implementation();

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
