import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GlassTabItem {
  const GlassTabItem(this.title, this.icon);

  final String title;
  final IconData icon;
}

/// La barra in basso con il Liquid Glass: è il `UITabBar` di iOS (vedi ios/Runner/GlassTabBar.swift).
/// Flutter non ha il Liquid Glass e sopra una WebView un'imitazione non rifrangerebbe la mappa.
class GlassTabBar extends StatefulWidget {
  const GlassTabBar({super.key, required this.items, required this.selected, required this.onSelected});

  static const _viewType = 'grokpatrol/tab-bar';
  static const _height = 62.0;

  /// Il Liquid Glass esiste da iOS 26.
  static bool get supported {
    if (kIsWeb || !Platform.isIOS) return false;
    final major = RegExp(r'\d+').firstMatch(Platform.operatingSystemVersion)?.group(0);
    return (int.tryParse(major ?? '') ?? 0) >= 26;
  }

  final List<GlassTabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  State<GlassTabBar> createState() => _GlassTabBarState();
}

class _GlassTabBarState extends State<GlassTabBar> {
  late final Future<List<Uint8List>> _faces = Future.wait([for (final item in widget.items) _renderFace(item)]);
  MethodChannel? _channel;

  @override
  void didUpdateWidget(GlassTabBar old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _channel?.invokeMethod<void>('select', widget.selected);
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _attach(int id) {
    _channel = MethodChannel('${GlassTabBar._viewType}/$id')
      ..setMethodCallHandler((call) async {
        if (call.method == 'select') widget.onSelected(call.arguments as int);
      })
      // la scheda può essere cambiata mentre la vista nativa nasceva
      ..invokeMethod<void>('select', widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: GlassTabBar._height + MediaQuery.paddingOf(context).bottom,
      child: FutureBuilder(
        future: _faces,
        builder: (context, snapshot) {
          final faces = snapshot.data;
          if (faces == null) return const SizedBox.shrink();
          return UiKitView(
            viewType: GlassTabBar._viewType,
            creationParams: {
              'selected': widget.selected,
              'items': [
                for (final (i, item) in widget.items.indexed) {'title': item.title, 'icon': faces[i]},
              ],
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _attach,
          );
        },
      ),
    );
  }
}

/// Icona ed etichetta di una voce, bianche: UIKit ne regola solo l'opacità (vedi `faded` in GlassTabBar.swift).
/// L'etichetta sta nell'immagine perché sul vetro iOS non lascia cambiare il colore di quella nativa.
/// Le icone restano quelle Lucide della web app, il testo usa il font di sistema come una barra iOS normale.
Future<Uint8List> _renderFace(GlassTabItem item) async {
  const width = 84.0, height = 42.0, iconSize = 24.0, scale = 3.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(item.icon.codePoint),
        style: TextStyle(
          fontFamily: item.icon.fontFamily,
          package: item.icon.fontPackage,
          fontSize: iconSize,
          height: 1,
          color: Colors.white,
        ),
      ),
    )
    ..layout()
    ..paint(canvas, const Offset((width - iconSize) / 2, 0));
  final label = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: item.title,
      style: const TextStyle(
        fontFamily: 'CupertinoSystemText',
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
    ),
  )..layout();
  label.paint(canvas, Offset((width - label.width) / 2, iconSize + 4));
  final image = await recorder.endRecording().toImage((width * scale).ceil(), (height * scale).ceil());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
