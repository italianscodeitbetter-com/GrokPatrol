import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/console_store.dart';
import 'data/stores.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Future.wait([AutomationStore.instance.load(), ConsoleStore.instance.load()]);
  runApp(const GrokPatrolApp());
}
