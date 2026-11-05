import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/console_store.dart';
import 'ui.dart';

/// Il video live di una telecamera del server. La telecamera manda fotogrammi veloci solo finché qualcuno guarda;
/// se decodificare un fotogramma richiede più del prossimo, si salta all'ultimo arrivato invece di restare indietro.
class LiveImage extends StatefulWidget {
  const LiveImage({super.key, required this.camera, this.label = 'Camera offline', this.fit = BoxFit.cover});

  final String camera;
  final String label;
  final BoxFit fit;

  @override
  State<LiveImage> createState() => _LiveImageState();
}

class _LiveImageState extends State<LiveImage> {
  static const _retry = Duration(seconds: 1);

  StreamSubscription<Uint8List>? _stream;
  Timer? _again;
  ui.Image? _image;
  Uint8List? _next;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(LiveImage old) {
    super.didUpdateWidget(old);
    if (old.camera != widget.camera) {
      _clear();
      _connect();
    }
  }

  @override
  void dispose() {
    _again?.cancel();
    unawaited(_stream?.cancel());
    _next = null;
    _image?.dispose();
    super.dispose();
  }

  void _connect() {
    _again?.cancel();
    unawaited(_stream?.cancel());
    final client = ConsoleStore.instance.client;
    if (client == null) return _lost();
    _stream = client.video(widget.camera).listen(_onFrame, onError: (Object _) => _lost(), onDone: _lost, cancelOnError: true);
  }

  /// Video perso: niente immagine ferma spacciata per dal vivo, e si riprova.
  void _lost() {
    if (!mounted) return;
    _clear();
    _again = Timer(_retry, _connect);
  }

  void _clear() {
    final old = _image;
    _next = null;
    setState(() => _image = null);
    old?.dispose();
  }

  void _onFrame(Uint8List bytes) {
    _next = bytes;
    if (!_decoding) unawaited(_decode());
  }

  Future<void> _decode() async {
    _decoding = true;
    while (_next != null && mounted) {
      final bytes = _next!;
      _next = null;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) {
          frame.image.dispose();
          break;
        }
        final old = _image;
        setState(() => _image = frame.image);
        old?.dispose();
      } on Exception {
        // un fotogramma rovinato: arriva il prossimo
      }
    }
    _decoding = false;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return StripedPlaceholder(label: widget.label, dark: true);
    return SizedBox.expand(
      child: RawImage(image: image, fit: widget.fit),
    );
  }
}

/// Una foto salvata sul server (snapshot di un evento), con il cookie del PIN se serve.
class ServerImage extends StatelessWidget {
  const ServerImage({super.key, required this.path, this.fit = BoxFit.cover, this.size});

  final String path;
  final BoxFit fit;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final client = ConsoleStore.instance.client;
    if (client == null) return const StripedPlaceholder(label: 'Not connected');
    return Image.network(
      client.imageUrl(path),
      headers: client.headers,
      fit: fit,
      width: size,
      height: size,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: AppColors.panel,
        child: Center(child: Text('Image not available', style: AppText.bodyFaint)),
      ),
    );
  }
}
