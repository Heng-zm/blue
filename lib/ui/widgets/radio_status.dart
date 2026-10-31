import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../theme.dart';

class RadioStatus {
  const RadioStatus(this.label, this.color, this.pulsing);

  final String label;
  final Color color;
  final bool pulsing;
}

RadioStatus radioStatus(AppController controller) {
  if (!controller.radioEnabled) {
    return const RadioStatus('RADIO OFF', MgsColors.amber, false);
  }
  if (controller.needsPermission) {
    return const RadioStatus('PERMISSION', MgsColors.amber, false);
  }
  if (!controller.bluetoothReady) {
    if (controller.bluetoothStateLabel == 'Starting…') {
      return const RadioStatus('STARTING', MgsColors.amber, true);
    }
    return RadioStatus(
      controller.bluetoothStateLabel.toUpperCase(),
      MgsColors.danger,
      false,
    );
  }
  if (controller.advertising || controller.scanning) {
    return const RadioStatus('MESH ACTIVE', MgsColors.lime, true);
  }
  return const RadioStatus('STARTING', MgsColors.amber, true);
}
