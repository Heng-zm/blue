import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../services/ble_transport.dart';
import '../../state/app_controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/radio_status.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final status = radioStatus(controller);
        final radioSubtitle = !controller.radioEnabled
            ? 'Off'
            : controller.advertising && controller.scanning
            ? 'Advertising · scanning'
            : controller.advertising
            ? 'Advertising only'
            : controller.scanning
            ? 'Scanning only'
            : 'Starting…';

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: mgsPagePadding,
              children: [
                Row(
                  children: [
                    Text(
                      'Settings',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontSize: 30, letterSpacing: -1),
                    ),
                    const Spacer(),
                    StatusPill(
                      label: status.label,
                      color: status.color,
                      pulsing: status.pulsing,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _ProfileCard(
                  controller: controller,
                  onEdit: () => _editName(context),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('RADIO'),
                const SizedBox(height: 9),
                MgsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      _StatusRow(
                        icon: Icons.bluetooth,
                        title: 'Bluetooth',
                        value: controller.bluetoothStateLabel,
                        color: controller.bluetoothReady
                            ? MgsColors.lime
                            : MgsColors.amber,
                      ),
                      const Divider(),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(
                          Icons.settings_input_antenna,
                          size: 20,
                          color: MgsColors.muted,
                        ),
                        title: const Text(
                          'Radio',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          radioSubtitle,
                          style: const TextStyle(
                            color: MgsColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                        value: controller.radioEnabled,
                        onChanged: (value) => controller.setRadioEnabled(value),
                      ),
                      const Divider(),
                      _StatusRow(
                        icon: Icons.sensors,
                        title: 'In range',
                        value: '${controller.nearbyDevices.length} devices',
                        color: MgsColors.text,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('MESH'),
                const SizedBox(height: 9),
                MgsCard(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(
                          Icons.hub_outlined,
                          size: 20,
                          color: MgsColors.muted,
                        ),
                        title: const Text(
                          'Relay messages',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Pass other people’s messages along',
                          style: TextStyle(
                            color: MgsColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                        value: controller.relayEnabled,
                        onChanged: controller.setRelayEnabled,
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.route_outlined,
                          size: 20,
                          color: MgsColors.muted,
                        ),
                        title: const Text(
                          'Relay hops',
                          style: TextStyle(fontSize: 14),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: MgsColors.lime.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${controller.ttl}',
                            style: const TextStyle(
                              color: MgsColors.lime,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      Slider(
                        value: controller.ttl.toDouble(),
                        min: minTtl.toDouble(),
                        max: maxTtl.toDouble(),
                        divisions: maxTtl - minTtl,
                        onChanged: (value) =>
                            controller.updateTtl(value.round()),
                      ),
                      const Text(
                        'How many times a message may be forwarded. Higher '
                        'values reach further across a crowd, at the cost of '
                        'more radio traffic.',
                        style: TextStyle(
                          color: MgsColors.muted,
                          fontSize: 11.5,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('ENCRYPTION'),
                const SizedBox(height: 9),
                MgsCard(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    children: [
                      _StatusRow(
                        icon: controller.encryptionEnabled
                            ? Icons.lock_outline
                            : Icons.lock_open_outlined,
                        title: 'Mesh passphrase',
                        value: controller.encryptionEnabled ? 'On' : 'Off',
                        color: controller.encryptionEnabled
                            ? MgsColors.mint
                            : MgsColors.amber,
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.key_outlined,
                          size: 20,
                          color: MgsColors.muted,
                        ),
                        title: Text(
                          controller.encryptionEnabled
                              ? 'Change passphrase'
                              : 'Set passphrase',
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Encrypt messages, files, and voice notes with '
                          'AES-256-GCM',
                          style: TextStyle(
                            color: MgsColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: MgsColors.muted,
                        ),
                        onTap: () => _editPassphrase(context),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Everyone in the mesh must use the same passphrase. '
                        'Relays forward ciphertext without being able to read '
                        'it. There is no recovery: if you forget it, old '
                        'encrypted messages stay locked.',
                        style: TextStyle(
                          color: MgsColors.muted,
                          fontSize: 11.5,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('DATA'),
                const SizedBox(height: 9),
                MgsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      _StatusRow(
                        icon: Icons.dataset_outlined,
                        title: 'Messages stored',
                        value: '${controller.messageCount}',
                        color: MgsColors.text,
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: MgsColors.muted,
                        ),
                        title: const Text(
                          'Clear history',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Delete chats on this device only',
                          style: TextStyle(
                            color: MgsColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: MgsColors.muted,
                        ),
                        onTap: () => _confirmClear(context),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('DIAGNOSTICS'),
                const SizedBox(height: 9),
                _Diagnostics(controller: controller),
                const SizedBox(height: 22),
                const _SectionLabel('ABOUT'),
                const SizedBox(height: 9),
                MgsCard(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    children: [
                      _InfoRow(label: 'Version', value: appVersion),
                      const SizedBox(height: 9),
                      _InfoRow(
                        label: 'Protocol',
                        value: 'MGS/$protocolVersion',
                      ),
                      const SizedBox(height: 9),
                      _InfoRow(
                        label: 'Encryption',
                        value: controller.encryptionEnabled
                            ? 'AES-256-GCM'
                            : 'Off',
                      ),
                      const SizedBox(height: 9),
                      _InfoRow(label: 'Transport', value: 'BLE GATT'),
                      const SizedBox(height: 9),
                      _InfoRow(label: 'Internet', value: 'Not used'),
                      const Divider(height: 26),
                      const Text(
                        'With a mesh passphrase set, messages, files (up to '
                        '5 MB), and voice notes (up to 60 seconds) are '
                        'encrypted end to end. Nearby is still public: anyone '
                        'with the same passphrase can read it. iOS and Android '
                        'may pause Bluetooth in the background; keep MGS open '
                        'for reliable meshing.',
                        style: TextStyle(
                          color: MgsColors.muted,
                          fontSize: 11.5,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Center(
                  child: Text(
                    'MGS · built for the mess',
                    style: TextStyle(
                      color: MgsColors.muted,
                      fontSize: 10.5,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editName(BuildContext context) async {
    final text = TextEditingController(text: controller.displayName);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MgsColors.panelHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Display name', style: TextStyle(fontSize: 18)),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLength: maxDisplayNameLength,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Your name',
            counterText: '',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(text.text),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    text.dispose();
    if (result != null) {
      await controller.updateDisplayName(result);
    }
  }

  Future<void> _editPassphrase(BuildContext context) async {
    final text = TextEditingController();
    final enabled = controller.encryptionEnabled;
    var obscure = true;
    String? error;

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = text.text.trim();
            if (value.length < minPassphraseLength) {
              setDialogState(
                () => error = 'Use at least $minPassphraseLength characters.',
              );
              return;
            }
            if (value.length > maxPassphraseLength) {
              setDialogState(
                () => error = 'Use at most $maxPassphraseLength characters.',
              );
              return;
            }
            Navigator.of(dialogContext).pop(value);
          }

          return AlertDialog(
            backgroundColor: MgsColors.panelHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            title: Text(
              enabled ? 'Change passphrase' : 'Set a mesh passphrase',
              style: const TextStyle(fontSize: 18),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Use the same passphrase on every device that should read '
                  'the mesh. Messages, files, and voice notes are encrypted '
                  'with it before they leave this device.',
                  style: TextStyle(
                    color: MgsColors.muted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: text,
                  autofocus: true,
                  obscureText: obscure,
                  maxLength: maxPassphraseLength,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'Shared mesh passphrase',
                    counterText: '',
                    errorText: error,
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(() => obscure = !obscure),
                      icon: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility,
                        size: 19,
                      ),
                      tooltip: obscure ? 'Show' : 'Hide',
                    ),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 8),
                Text(
                  'At least $minPassphraseLength characters. There is no '
                  'recovery if everyone forgets it.',
                  style: const TextStyle(
                    color: MgsColors.muted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
            actions: [
              if (enabled)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(''),
                  style: TextButton.styleFrom(
                    foregroundColor: MgsColors.danger,
                  ),
                  child: const Text('Turn off'),
                ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(enabled ? 'Change' : 'Set'),
              ),
            ],
          );
        },
      ),
    );
    text.dispose();
    if (result == null) return;

    if (result.isEmpty) {
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: MgsColors.panelHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text(
            'Turn off encryption?',
            style: TextStyle(fontSize: 18),
          ),
          content: const Text(
            'New messages and attachments will travel unencrypted. Messages '
            'already encrypted on other devices stay encrypted.',
            style: TextStyle(
              color: MgsColors.muted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: MgsColors.danger,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              child: const Text('Turn off'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final failure = await controller.updatePassphrase(result);
    if (!context.mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isEmpty ? 'Mesh encryption is off' : 'Mesh passphrase updated',
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MgsColors.panelHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Clear history?', style: TextStyle(fontSize: 18)),
        content: const Text(
          'All messages stored on this device will be deleted. This cannot be '
          'undone.',
          style: TextStyle(color: MgsColors.muted, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: MgsColors.danger,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearHistory();
    }
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.controller, required this.onEdit});

  final AppController controller;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final displayName = controller.displayName.isEmpty
        ? 'MGS user'
        : controller.displayName;
    return MgsCard(
      child: Row(
        children: [
          AvatarCircle(label: displayName, size: 54),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: controller.peerId),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Peer ID copied')),
                    );
                  },
                  child: Row(
                    children: [
                      Text(
                        'ID ${controller.peerId.substring(0, 8)}…',
                        style: const TextStyle(
                          color: MgsColors.muted,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.copy, size: 12, color: MgsColors.muted),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            tooltip: 'Edit name',
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
        ],
      ),
    );
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final logs = controller.logs;
    return MgsCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          leading: const Icon(Icons.terminal, size: 20, color: MgsColors.muted),
          title: const Text('Radio log', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '${logs.length} events',
            style: const TextStyle(color: MgsColors.muted, fontSize: 11.5),
          ),
          iconColor: MgsColors.mint,
          collapsedIconColor: MgsColors.muted,
          children: [
            if (logs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No radio events yet.',
                    style: TextStyle(color: MgsColors.muted, fontSize: 11.5),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: MgsColors.ink,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: MgsColors.line),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in logs.reversed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              '${logTimestamp(line.time)}  ${line.message}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                height: 1.35,
                                color: switch (line.level) {
                                  BleLogLevel.info => MgsColors.muted,
                                  BleLogLevel.warning => MgsColors.amber,
                                  BleLogLevel.error => MgsColors.danger,
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: logs.isEmpty
                    ? null
                    : () async {
                        final text = logs
                            .map(
                              (line) =>
                                  '${logTimestamp(line.time)}  ${line.message}',
                            )
                            .join('\n');
                        await Clipboard.setData(ClipboardData(text: text));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Radio log copied')),
                        );
                      },
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('Copy log'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: MgsColors.muted),
          const SizedBox(width: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: MgsColors.muted, fontSize: 12.5),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: MgsColors.muted,
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.6,
      ),
    );
  }
}
