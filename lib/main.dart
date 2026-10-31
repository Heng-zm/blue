import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/app_controller.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: MgsColors.ink,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final controller = AppController();
  runApp(MgsApp(controller: controller));
  // Bootstrap runs after the first frame so the boot screen is visible even
  // when the state file takes a moment to load.
  unawaited(controller.bootstrap());
}
