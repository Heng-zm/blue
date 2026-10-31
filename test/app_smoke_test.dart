import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/state/app_controller.dart';
import 'package:mgs/ui/app.dart';

class _TestController extends AppController {
  void publish() => notifyListeners();
}

void main() {
  testWidgets('boots into onboarding without touching the radio', (
    tester,
  ) async {
    final controller = _TestController();

    await tester.pumpWidget(MgsApp(controller: controller));
    expect(find.text('Opening the mesh…'), findsOneWidget);

    controller
      ..initialized = true
      ..firstRun = true;
    controller.publish();
    await tester.pumpAndSettle();

    expect(find.text('Start meshing'), findsOneWidget);
    expect(find.text('Your display name'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
