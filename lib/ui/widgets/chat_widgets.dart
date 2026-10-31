import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../state/app_controller.dart';
import '../format.dart';
import '../theme.dart';
import 'common.dart';

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.summary, required this.onTap});

  final ChatSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: MgsColors.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: MgsColors.line),
          ),
          child: Row(
            children: [
              AvatarCircle(
                label: summary.title,
                online: summary.online,
                isBroadcast: summary.isBroadcast,
                size: 48,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            summary.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15.5,
                            ),
                          ),
                        ),
                        if (summary.isBroadcast) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.public,
                            size: 13,
                            color: MgsColors.muted,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      summary.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: MgsColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    summary.updatedAt.millisecondsSinceEpoch == 0
                        ? ''
                        : chatTimestamp(summary.updatedAt),
                    style: const TextStyle(
                      color: MgsColors.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                  if (summary.unread > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: MgsColors.lime,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        summary.unread > 99 ? '99+' : '${summary.unread}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF101A00),
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    )
                  else if (summary.isBroadcast)
                    const Icon(
                      Icons.cell_tower,
                      size: 14,
                      color: MgsColors.muted,
                    )
                  else
                    Icon(
                      summary.online ? Icons.bolt : Icons.schedule,
                      size: 14,
                      color: summary.online ? MgsColors.lime : MgsColors.muted,
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

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.showSender = false,
  });

  final Message message;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final mine = message.outgoing;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    final background = mine ? MgsColors.lime : MgsColors.panelHigh;
    final foreground = mine ? const Color(0xFF0E1800) : MgsColors.text;

    return Padding(
      padding: EdgeInsets.only(
        left: mine ? 36 : 0,
        right: mine ? 0 : 36,
        bottom: 9,
      ),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine && showSender) ...[
            AvatarCircle(label: message.fromName, size: 27),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 5),
                  bottomRight: Radius.circular(mine ? 5 : 18),
                ),
                border: mine ? null : Border.all(color: MgsColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSender && !mine) ...[
                    Text(
                      message.fromName,
                      style: const TextStyle(
                        color: MgsColors.mint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    message.text,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 15,
                      height: 1.36,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        clockTime(message.timestamp),
                        style: TextStyle(
                          color: mine
                              ? const Color(0xFF0E1800).withValues(alpha: 0.55)
                              : MgsColors.muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (mine) ...[
                        const SizedBox(width: 5),
                        _StatusIcon(
                          status: message.status,
                          color: const Color(0xFF0E1800).withValues(alpha: 0.6),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final MessageStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor) = switch (status) {
      MessageStatus.queued => (Icons.schedule, color),
      MessageStatus.sent => (Icons.check, color),
      MessageStatus.delivered => (Icons.done_all, const Color(0xFF2C4A00)),
      MessageStatus.failed => (Icons.error_outline, MgsColors.danger),
      MessageStatus.received => (Icons.done, color),
    };
    return Icon(icon, size: 13, color: iconColor);
  }
}
