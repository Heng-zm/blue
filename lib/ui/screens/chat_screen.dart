import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../state/app_controller.dart';
import '../theme.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.threadId,
  });

  final AppController controller;
  final String threadId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  int _lastCount = 0;

  bool get _isBroadcast => widget.threadId == broadcastRecipient;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.enterThread(widget.threadId);
      _scrollToBottom(animate: false);
    });
  }

  @override
  void dispose() {
    widget.controller.leaveThread(widget.threadId);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final sent = widget.controller.sendMessage(widget.threadId, text);
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message could not be queued. Messages are limited to '
            '$maxMessageLength characters.',
          ),
        ),
      );
      return;
    }
    _input.clear();
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final messages = controller.messagesFor(widget.threadId);
        final title = controller.titleForThread(widget.threadId);
        final online = controller.isPeerOnline(widget.threadId);
        final status = _isBroadcast
            ? 'Public channel · ${controller.peers.where((p) => p.connected).length} nearby'
            : online
            ? 'Connected · hop-by-hop delivery'
            : 'Offline · queued for the mesh';

        if (messages.length != _lastCount) {
          _lastCount = messages.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToBottom();
          });
        }

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 66,
            titleSpacing: 0,
            title: Row(
              children: [
                AvatarCircle(
                  label: title,
                  online: _isBroadcast ? controller.hasPeers : online,
                  isBroadcast: _isBroadcast,
                  size: 38,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: MgsColors.muted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                onPressed: () => _showInfo(context, title),
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: 'Conversation info',
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (_isBroadcast) const _BroadcastBanner(),
              Expanded(
                child: messages.isEmpty
                    ? _EmptyChat(isBroadcast: _isBroadcast, title: title)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          final showDay =
                              index == 0 ||
                              !_sameDay(
                                messages[index - 1].timestamp,
                                message.timestamp,
                              );
                          return Column(
                            children: [
                              if (showDay) _DayDivider(date: message.timestamp),
                              MessageBubble(
                                message: message,
                                showSender: _isBroadcast,
                              ),
                            ],
                          );
                        },
                      ),
              ),
              _Composer(
                controller: _input,
                focusNode: _focus,
                hint: _isBroadcast
                    ? 'Message everyone nearby'
                    : 'Message $title',
                onSend: _send,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showInfo(BuildContext context, String title) async {
    final controller = widget.controller;
    final info = _isBroadcast
        ? 'The Nearby channel is public. Every MGS device in relay range '
              'receives these messages.'
        : 'Messages are flooded through the mesh and addressed to this peer. '
              'Delivery is confirmed when the recipient is directly connected. '
              'Messages are not end-to-end encrypted yet: a device relaying '
              'them can read the contents.';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MgsColors.panelHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(title, style: const TextStyle(fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info,
              style: const TextStyle(
                color: MgsColors.muted,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            if (!_isBroadcast) ...[
              const SizedBox(height: 16),
              const Text(
                'PEER ID',
                style: TextStyle(
                  color: MgsColors.muted,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                widget.threadId,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: MgsColors.mint,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                controller.isPeerOnline(widget.threadId)
                    ? 'Direct link is active.'
                    : 'No direct link right now.',
                style: const TextStyle(color: MgsColors.muted, fontSize: 11),
              ),
            ],
          ],
        ),
        actions: [
          if (!_isBroadcast)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: widget.threadId));
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Copy ID'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final difference = today.difference(day).inDays;
    final label = difference == 0
        ? 'Today'
        : difference == 1
        ? 'Yesterday'
        : '${date.day}/${date.month}/${date.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: const TextStyle(
                color: MgsColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _BroadcastBanner extends StatelessWidget {
  const _BroadcastBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      color: MgsColors.lime.withValues(alpha: 0.06),
      child: const Row(
        children: [
          Icon(Icons.public, size: 13, color: MgsColors.lime),
          SizedBox(width: 7),
          Expanded(
            child: Text(
              'Anyone running MGS nearby can read this channel.',
              style: TextStyle(color: MgsColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.isBroadcast, required this.title});

  final bool isBroadcast;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: MgsColors.lime.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: MgsColors.lime.withValues(alpha: 0.2),
                ),
              ),
              child: Icon(
                isBroadcast ? Icons.cell_tower : Icons.forum_outlined,
                color: MgsColors.lime,
                size: 27,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isBroadcast ? 'Nobody has said anything yet' : 'No messages yet',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              isBroadcast
                  ? 'Say hello to everyone in Bluetooth range. Your message will '
                        'hop through the mesh.'
                  : 'Send the first message to $title. It will be delivered '
                        'when they are in range, directly or through a relay.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MgsColors.muted,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: MgsColors.ink,
        border: Border(top: BorderSide(color: MgsColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                maxLength: maxMessageLength,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: hint,
                  counterText: '',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final enabled = value.text.trim().isNotEmpty;
                return IconButton.filled(
                  onPressed: enabled ? onSend : null,
                  tooltip: 'Send',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: enabled
                        ? MgsColors.lime
                        : MgsColors.panelHigh,
                    foregroundColor: enabled
                        ? const Color(0xFF101A00)
                        : MgsColors.muted,
                    disabledBackgroundColor: MgsColors.panelHigh,
                    disabledForegroundColor: MgsColors.muted,
                  ),
                  icon: const Icon(Icons.arrow_upward, size: 21),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
