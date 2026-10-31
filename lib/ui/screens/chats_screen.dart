import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../theme.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/radio_status.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({
    super.key,
    required this.controller,
    required this.onOpenNearby,
    required this.onOpenChat,
  });

  final AppController controller;
  final VoidCallback onOpenNearby;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final chats = controller.chats;
        final status = radioStatus(controller);
        final connected = controller.peers
            .where((peer) => peer.connected)
            .length;
        final nearby = controller.nearbyDevices.length;
        final hasConversations = chats.any(
          (chat) => !chat.isBroadcast || chat.lastMessage != null,
        );

        final subtitle = !controller.radioEnabled
            ? 'Radio is off · turn it on in Settings'
            : controller.bluetoothBlocked
            ? '${controller.bluetoothStateLabel} · check Bluetooth'
            : '$connected connected · $nearby in range';

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: mgsPagePadding,
              children: [
                Row(
                  children: [
                    const MgsWordmark(compact: true),
                    const Spacer(),
                    StatusPill(
                      label: status.label,
                      color: status.color,
                      pulsing: status.pulsing,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _MeshCard(
                  subtitle: subtitle,
                  status: status,
                  connected: connected,
                  nearby: nearby,
                  onTap: onOpenNearby,
                ),
                const SizedBox(height: 24),
                const _SectionLabel('CONVERSATIONS', trailing: null),
                const SizedBox(height: 10),
                for (final chat in chats)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ChatTile(
                      summary: chat,
                      onTap: () => onOpenChat(chat.threadId),
                    ),
                  ),
                if (!hasConversations) ...[
                  const SizedBox(height: 8),
                  _EmptyChats(onOpenNearby: onOpenNearby),
                ],
                const SizedBox(height: 18),
                const _MeshTip(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MeshCard extends StatelessWidget {
  const _MeshCard({
    required this.subtitle,
    required this.status,
    required this.connected,
    required this.nearby,
    required this.onTap,
  });

  final String subtitle;
  final RadioStatus status;
  final int connected;
  final int nearby;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [status.color.withValues(alpha: 0.16), MgsColors.panel],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: status.color.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: status.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                    color: status.color.withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(Icons.radar, color: status.color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.label,
                      style: TextStyle(
                        color: status.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: MgsColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                    if (connected > 0) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          const Icon(
                            Icons.bolt,
                            size: 13,
                            color: MgsColors.lime,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$connected direct ${connected == 1 ? 'link' : 'links'}',
                            style: const TextStyle(
                              color: MgsColors.lime,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '$nearby nearby',
                            style: const TextStyle(
                              color: MgsColors.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: MgsColors.muted, size: 22),
            ],
          ),
        ),
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

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.onOpenNearby});

  final VoidCallback onOpenNearby;

  @override
  Widget build(BuildContext context) {
    return MgsCard(
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: MgsColors.lime.withValues(alpha: 0.09),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.sensors_off,
              color: MgsColors.lime,
              size: 23,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'No conversations yet',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 5),
          const Text(
            'Open the radar and tap someone nearby to start a direct chat, '
            'or say hello on the public Nearby channel.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MgsColors.muted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onOpenNearby,
            icon: const Icon(Icons.radar, size: 17),
            label: const Text('Open radar'),
          ),
        ],
      ),
    );
  }
}

class _MeshTip extends StatelessWidget {
  const _MeshTip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MgsColors.panel.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MgsColors.line),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: MgsColors.muted),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Messages hop from device to device. Keep MGS open for the best '
              'range. Nothing is routed through the internet.',
              style: TextStyle(
                color: MgsColors.muted,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
