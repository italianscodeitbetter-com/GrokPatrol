import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// I test misurano il testo con i font veri: con quello di prova ogni lettera è larga un quadrato e gli overflow non dicono nulla.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (family, name) in const [('Geist', 'Geist'), ('GeistMono', 'GeistMono')]) {
    final loader = FontLoader(family);
    for (final weight in const ['Regular', 'Medium', 'SemiBold']) {
      final bytes = File('assets/fonts/$name-$weight.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
  await testMain();
}
