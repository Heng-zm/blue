import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Root widget. Owns lifecycle handling and swaps between onboarding and the
/// main shell as the controller becomes ready.
class MgsApp extends StatefulWidget {
  const MgsApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<MgsApp> createState() => _MgsAppState();
}

class _MgsAppState extends State<MgsApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(widget.controller.resumeFromBackground());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(widget.controller.pauseForBackground());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MGS',
      debugShowCheckedModeBanner: false,
      theme: buildMgsTheme(),
      home: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          if (!controller.initialized) {
            return const _BootScreen();
          }
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            child: controller.firstRun
                ? OnboardingScreen(controller: controller)
                : HomeShell(controller: controller),
          );
        },
      ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.6, -0.7),
            radius: 1.2,
            colors: [Color(0xFF15230F), MgsColors.ink],
          ),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MgsWordmark(),
              SizedBox(height: 30),
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              SizedBox(height: 16),
              Text(
                'Opening the mesh…',
                style: TextStyle(
                  color: MgsColors.muted,
                  fontSize: 12,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
