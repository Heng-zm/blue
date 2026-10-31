import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../state/app_controller.dart';
import '../../services/voice_recorder.dart';
import '../format.dart';
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
  final VoiceRecorder _recorder = VoiceRecorder();
  int _lastCount = 0;

  Timer? _recordTimer;
  int _recordSeconds = 0;
  bool _recording = false;
  bool _startingRecording = false;
  bool _finishingRecording = false;
  bool _pickingFile = false;

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
    _recordTimer?.cancel();
    unawaited(_recorder.dispose());
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final sent = await widget.controller.sendMessage(widget.threadId, text);
    if (!mounted) return;
    if (!sent) {
      _showMessage(
        'Message could not be queued. Messages are limited to '
        '$maxMessageLength characters.',
      );
      return;
    }
    _input.clear();
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _pickFile({bool imageOnly = false}) async {
    if (_pickingFile || _recording) return;
    setState(() => _pickingFile = true);
    try {
      final file = await FilePicker.pickFile(
        type: imageOnly ? FileType.image : FileType.any,
        dialogTitle: imageOnly ? 'Send an image' : 'Send a file',
      );
      if (file == null || !mounted) return;

      final length = await file.length();
      if (length != null && length > maxFileBytes) {
        _showMessage(
          'Files are limited to ${maxFileBytes ~/ (1024 * 1024)} MB.',
        );
        return;
      }

      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        _showMessage('The selected file is empty.');
        return;
      }
      if (bytes.length > maxFileBytes) {
        _showMessage(
          'Files are limited to ${maxFileBytes ~/ (1024 * 1024)} MB.',
        );
        return;
      }

      final error = await widget.controller.sendFile(
        widget.threadId,
        name: file.name,
        bytes: bytes,
      );
      if (error != null && mounted) _showMessage(error);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (error) {
      if (mounted) _showMessage('Could not pick the file: $error');
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_startingRecording || _finishingRecording) return;
    if (_recording) {
      await _finishRecording(send: true);
      return;
    }

    setState(() => _startingRecording = true);
    try {
      final started = await _recorder.start();
      if (!mounted) {
        if (started) await _recorder.cancel();
        return;
      }
      if (!started) {
        _showMessage(
          'MGS needs microphone access to record a voice note. '
          'Allow the microphone permission and try again.',
        );
        return;
      }

      _focus.unfocus();
      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_recordSeconds >= maxVoiceSeconds - 1) {
          setState(() => _recordSeconds = maxVoiceSeconds);
          unawaited(_finishRecording(send: true));
        } else {
          setState(() => _recordSeconds++);
        }
      });
    } finally {
      if (mounted) setState(() => _startingRecording = false);
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    if (!_recording || _finishingRecording) return;
    _finishingRecording = true;
    _recordTimer?.cancel();
    _recordTimer = null;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordSeconds = 0;
      });
    }

    try {
      if (!send) {
        await _recorder.cancel();
        return;
      }

      final voice = await _recorder.stop();
      if (!mounted) return;
      if (voice == null) {
        _showMessage('Nothing was recorded.');
        return;
      }

      final error = await widget.controller.sendVoice(
        widget.threadId,
        path: voice.path,
        name: voice.name,
        mimeType: voice.mimeType,
        durationMs: voice.durationMs,
      );
      if (error != null && mounted) _showMessage(error);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (error) {
      if (mounted) _showMessage('Could not send the voice note: $error');
    } finally {
      _finishingRecording = false;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
                icon: Icon(
                  controller.encryptionEnabled
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                  color: controller.encryptionEnabled
                      ? MgsColors.mint
                      : MgsColors.amber,
                  size: 19,
                ),
                tooltip: controller.encryptionEnabled
                    ? 'Encrypted with the mesh passphrase'
                    : 'No mesh passphrase',
              ),
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
              if (!controller.encryptionEnabled) const _PlaintextBanner(),
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
              if (_recording)
                _RecordingBar(
                  seconds: _recordSeconds,
                  busy: _finishingRecording,
                  onCancel: () => _finishRecording(send: false),
                  onSend: () => _finishRecording(send: true),
                )
              else
                _Composer(
                  controller: _input,
                  focusNode: _focus,
                  hint: _isBroadcast
                      ? 'Message everyone nearby'
                      : 'Message $title',
                  busy: _pickingFile || _startingRecording,
                  onSend: _send,
                  onPickImage: () => _pickFile(imageOnly: true),
                  onAttach: () => _pickFile(imageOnly: false),
                  onRecord: _toggleRecording,
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
              'receives these messages. Relays only forward the encrypted '
              'bytes when a mesh passphrase is set; devices without the '
              'passphrase cannot read them.'
        : 'Messages are flooded through the mesh and addressed to this peer. '
              'Delivery is confirmed when the recipient is directly connected. '
              'When a mesh passphrase is set, message bodies, files, and voice '
              'notes are encrypted end to end (AES-256-GCM); relays cannot '
              'read them.';

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
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  controller.encryptionEnabled
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                  size: 15,
                  color: controller.encryptionEnabled
                      ? MgsColors.mint
                      : MgsColors.amber,
                ),
                const SizedBox(width: 6),
                Text(
                  controller.encryptionEnabled
                      ? 'Mesh passphrase is set'
                      : 'No mesh passphrase',
                  style: TextStyle(
                    color: controller.encryptionEnabled
                        ? MgsColors.mint
                        : MgsColors.amber,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
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
              'Anyone running MGS nearby can receive this channel.',
              style: TextStyle(color: MgsColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaintextBanner extends StatelessWidget {
  const _PlaintextBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: MgsColors.amber.withValues(alpha: 0.08),
      child: const Row(
        children: [
          Icon(Icons.lock_open_outlined, size: 13, color: MgsColors.amber),
          SizedBox(width: 7),
          Expanded(
            child: Text(
              'No mesh passphrase: relays can read messages, files, and voice '
              'notes. Set one in Settings → Mesh.',
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
    required this.busy,
    required this.onSend,
    required this.onPickImage,
    required this.onAttach,
    required this.onRecord,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool busy;
  final Future<void> Function() onSend;
  final VoidCallback onPickImage;
  final VoidCallback onAttach;
  final Future<void> Function() onRecord;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: MgsColors.ink,
        border: Border(top: BorderSide(color: MgsColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: busy ? null : onPickImage,
              tooltip: 'Send an image',
              icon: const Icon(Icons.photo_outlined, size: 21),
            ),
            IconButton(
              onPressed: busy ? null : onAttach,
              tooltip: 'Send a file',
              icon: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.attach_file, size: 21),
            ),
            const SizedBox(width: 2),
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
            const SizedBox(width: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return IconButton.filled(
                  onPressed: hasText ? () => onSend() : () => onRecord(),
                  tooltip: hasText ? 'Send' : 'Record a voice note',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(46, 46),
                    backgroundColor: hasText
                        ? MgsColors.lime
                        : MgsColors.panelHigh,
                    foregroundColor: hasText
                        ? const Color(0xFF101A00)
                        : MgsColors.text,
                    disabledBackgroundColor: MgsColors.panelHigh,
                    disabledForegroundColor: MgsColors.muted,
                  ),
                  icon: Icon(
                    hasText ? Icons.arrow_upward : Icons.mic_none,
                    size: 21,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.seconds,
    required this.busy,
    required this.onCancel,
    required this.onSend,
  });

  final int seconds;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: MgsColors.ink,
        border: Border(top: BorderSide(color: MgsColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: MgsColors.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Recording  ${durationLabel(seconds * 1000)}',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '/ ${durationLabel(maxVoiceSeconds * 1000)}',
              style: const TextStyle(color: MgsColors.muted, fontSize: 11),
            ),
            const Spacer(),
            TextButton(
              onPressed: busy ? null : onCancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: busy ? null : onSend,
              tooltip: 'Send voice note',
              style: IconButton.styleFrom(
                minimumSize: const Size(46, 46),
                backgroundColor: MgsColors.lime,
                foregroundColor: const Color(0xFF101A00),
              ),
              icon: const Icon(Icons.stop_rounded, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}
