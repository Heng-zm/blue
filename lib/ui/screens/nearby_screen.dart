import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../models/peer.dart';
import '../../state/app_controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/radar.dart';
import '../widgets/radio_status.dart';

class NearbyScreen extends StatelessWidget {
  const NearbyScreen({
    super.key,
    required this.controller,
    required this.onOpenChat,
  });

  final AppController controller;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final devices = controller.nearbyDevices;
        final status = radioStatus(controller);
        final broadcast = controller.chats.firstWhere(
          (chat) => chat.isBroadcast,
          orElse: () => ChatSummary(
            threadId: '*',
            title: 'Nearby',
            subtitle: 'Open channel · everyone in range',
            unread: 0,
            isBroadcast: true,
            online: controller.hasPeers,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
        final blips = devices
            .map(
              (device) => RadarBlip(
                keyLabel: device.peerId ?? device.address,
                rssi: device.rssi,
                online: device.connected,
              ),
            )
            .toList();

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: mgsPagePadding,
              children: [
                Row(
                  children: [
                    Text(
                      'Radar',
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
                const SizedBox(height: 4),
                const Text(
                  'Devices running MGS, within Bluetooth range.',
                  style: TextStyle(color: MgsColors.muted, fontSize: 12.5),
                ),
                const SizedBox(height: 16),
                MgsCard(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                  child: Column(
                    children: [
                      MgsRadar(blips: blips, size: 248),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PulseDot(
                            color: controller.scanning
                                ? MgsColors.lime
                                : MgsColors.muted,
                            active: controller.scanning,
                            size: 6,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            controller.scanning
                                ? 'Scanning · ${devices.length} in range'
                                : 'Scan paused',
                            style: const TextStyle(
                              color: MgsColors.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      if (controller.advertising) ...[
                        const SizedBox(height: 4),
                        const Text(
                          'Broadcasting the MGS service',
                          style: TextStyle(
                            color: MgsColors.muted,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!controller.radioEnabled) ...[
                  const SizedBox(height: 14),
                  _RadioNotice(
                    icon: Icons.power_settings_new,
                    title: 'Radio is off',
                    body:
                        'Turn the radio on to advertise and scan for nearby '
                        'devices.',
                    actionLabel: 'Turn on',
                    onAction: () => controller.setRadioEnabled(true),
                  ),
                ] else if (controller.bluetoothBlocked) ...[
                  const SizedBox(height: 14),
                  _RadioNotice(
                    icon: controller.needsPermission
                        ? Icons.lock_outline
                        : Icons.bluetooth_disabled,
                    title: controller.bluetoothStateLabel,
                    body: controller.needsPermission
                        ? 'MGS needs Bluetooth permission to find people. '
                              'Grant it in system settings.'
                        : 'Turn Bluetooth on to continue meshing.',
                    actionLabel: 'Open settings',
                    onAction: controller.openBluetoothSettings,
                  ),
                ],
                const SizedBox(height: 22),
                const _SectionLabel('OPEN CHANNEL'),
                const SizedBox(height: 10),
                ChatTile(summary: broadcast, onTap: () => onOpenChat('*')),
                if (controller.peers.any(
                  (p) =>
                      p.connected && p.connectionType != PeerConnectionType.ble,
                )) ...[
                  const SizedBox(height: 22),
                  _SectionLabel(
                    'WI-FI & USB PEERS',
                    trailing:
                        '${controller.peers.where((p) => p.connected && p.connectionType != PeerConnectionType.ble).length}',
                  ),
                  const SizedBox(height: 10),
                  for (final peer in controller.peers.where(
                    (p) =>
                        p.connected &&
                        p.connectionType != PeerConnectionType.ble,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _LanPeerTile(
                        peer: peer,
                        onTap: () => onOpenChat(peer.id),
                      ),
                    ),
                ],
                const SizedBox(height: 22),
                _SectionLabel('NEARBY DEVICES', trailing: '${devices.length}'),
                const SizedBox(height: 10),
                if (devices.isEmpty)
                  const _NoDevices()
                else
                  for (final device in devices)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _NearbyTile(
                        device: device,
                        onTap: device.peerId == null
                            ? null
                            : () => onOpenChat(device.peerId!),
                      ),
                    ),
                const SizedBox(height: 16),
                const Text(
                  'Bluetooth range is roughly 10–30 metres indoors. Messages '
                  'can travel further by hopping through other devices that '
                  'have MGS open.',
                  style: TextStyle(
                    color: MgsColors.muted,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LanPeerTile extends StatelessWidget {
  const _LanPeerTile({required this.peer, required this.onTap});

  final Peer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isUsb = peer.connectionType == PeerConnectionType.usb;
    final icon = isUsb ? Icons.usb : Icons.wifi;
    final label = isUsb ? 'USB Link' : 'Same Wi-Fi';
    final addr = peer.ipAddress != null ? ' · ${peer.ipAddress}' : '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: MgsColors.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: MgsColors.mint.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              AvatarCircle(label: peer.name, online: true, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Connected · $label$addr',
                      style: const TextStyle(
                        color: MgsColors.mint,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: MgsColors.mint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: MgsColors.mint),
                    const SizedBox(width: 4),
                    const Text(
                      'FAST',
                      style: TextStyle(
                        color: MgsColors.mint,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NearbyTile extends StatelessWidget {
  const _NearbyTile({required this.device, this.onTap});

  final NearbyDevice device;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final peerId = device.peerId;
    final rawName = device.name?.trim();
    final hasRealName =
        rawName != null && rawName.isNotEmpty && rawName.toUpperCase() != 'MGS';
    final title = hasRealName
        ? rawName
        : peerId != null
        ? 'MGS ${shortPeerId(peerId)}'
        : 'MGS device';
    final subtitle = device.connected
        ? 'Connected · ${signalLabel(device.rssi)} signal'
        : 'Seen ${relativeAge(device.lastSeen)} · ${signalLabel(device.rssi)} signal';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: MgsColors.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: device.connected
                  ? MgsColors.lime.withValues(alpha: 0.3)
                  : MgsColors.line,
            ),
          ),
          child: Row(
            children: [
              if (peerId != null)
                AvatarCircle(label: title, online: device.connected, size: 44)
              else
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: MgsColors.panelHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: MgsColors.line),
                  ),
                  child: const Icon(
                    Icons.bluetooth,
                    color: MgsColors.muted,
                    size: 19,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: MgsColors.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SignalBars(
                    rssi: device.rssi,
                    color: device.connected ? MgsColors.lime : MgsColors.muted,
                  ),
                  const SizedBox(height: 6),
                  if (peerId == null)
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    const Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: MgsColors.muted,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadioNotice extends StatelessWidget {
  const _RadioNotice({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    return MgsCard(
      color: MgsColors.amber.withValues(alpha: 0.07),
      borderColor: MgsColors.amber.withValues(alpha: 0.3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: MgsColors.amber, size: 20),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    color: MgsColors.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => onAction(),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(actionLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoDevices extends StatelessWidget {
  const _NoDevices();

  @override
  Widget build(BuildContext context) {
    return MgsCard(
      child: Column(
        children: [
          const Icon(
            Icons.bluetooth_searching,
            color: MgsColors.muted,
            size: 30,
          ),
          const SizedBox(height: 10),
          const Text(
            'No one in range yet',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Ask the other person to open MGS. Devices appear here as soon as '
            'they are close enough.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MgsColors.muted.withValues(alpha: 0.9),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: MgsColors.muted,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(color: MgsColors.muted, fontSize: 11),
          ),
      ],
    );
  }
}
