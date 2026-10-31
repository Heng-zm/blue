import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

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
    final encrypted = summary.lastMessage?.encrypted == true;
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
                        if (encrypted) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.lock,
                            size: 12,
                            color: MgsColors.mint,
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
    final subtle = mine
        ? const Color(0xFF0E1800).withValues(alpha: 0.58)
        : MgsColors.muted;

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
                  _content(
                    context,
                    mine: mine,
                    foreground: foreground,
                    subtle: subtle,
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.encrypted) ...[
                        Icon(Icons.lock, size: 10, color: subtle),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        clockTime(message.timestamp),
                        style: TextStyle(
                          color: subtle,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (mine) ...[
                        const SizedBox(width: 5),
                        _StatusIcon(status: message.status, color: subtle),
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

  Widget _content(
    BuildContext context, {
    required bool mine,
    required Color foreground,
    required Color subtle,
  }) {
    if (message.decryptionFailed) {
      return _LockedBody(kind: message.kind, color: foreground, subtle: subtle);
    }

    final attachment = message.attachment;
    if (message.kind == MessageKind.voice) {
      if (attachment == null) {
        return _MissingBody(color: foreground, subtle: subtle);
      }
      return _VoiceBody(message: message, attachment: attachment, mine: mine);
    }
    if (message.kind == MessageKind.file) {
      if (attachment == null) {
        return _MissingBody(color: foreground, subtle: subtle);
      }
      return _FileBody(
        message: message,
        attachment: attachment,
        foreground: foreground,
        subtle: subtle,
      );
    }

    return Text(
      message.text,
      style: TextStyle(color: foreground, fontSize: 15, height: 1.36),
    );
  }
}

class _LockedBody extends StatelessWidget {
  const _LockedBody({
    required this.kind,
    required this.color,
    required this.subtle,
  });

  final MessageKind kind;
  final Color color;
  final Color subtle;

  @override
  Widget build(BuildContext context) {
    final label = switch (kind) {
      MessageKind.text => 'Encrypted message',
      MessageKind.file => 'Encrypted file',
      MessageKind.voice => 'Encrypted voice note',
    };
    return SizedBox(
      width: 214,
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 22, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Set the same mesh passphrase, then ask for a resend.',
                  style: TextStyle(color: subtle, fontSize: 10.5, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingBody extends StatelessWidget {
  const _MissingBody({required this.color, required this.subtle});

  final Color color;
  final Color subtle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.attachment_outlined, size: 18, color: subtle),
        const SizedBox(width: 6),
        Text('Attachment unavailable', style: TextStyle(color: color)),
      ],
    );
  }
}

class _FileBody extends StatelessWidget {
  const _FileBody({
    required this.message,
    required this.attachment,
    required this.foreground,
    required this.subtle,
  });

  final Message message;
  final MessageAttachment attachment;
  final Color foreground;
  final Color subtle;

  @override
  Widget build(BuildContext context) {
    final available = attachment.available;
    if (attachment.isImage && available && attachment.path != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _open(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 240,
                  maxHeight: 260,
                  minWidth: 120,
                  minHeight: 80,
                ),
                child: Image.file(
                  File(attachment.path!),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _buildFileRow(context, available),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          GestureDetector(
            onTap: () => _open(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  formatBytes(attachment.size),
                  style: TextStyle(color: subtle, fontSize: 10.5),
                ),
              ],
            ),
          ),
          _TransferState(
            message: message,
            subtle: subtle,
            foreground: foreground,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: available ? () => _open(context) : null,
          child: _buildFileRow(context, available),
        ),
        _TransferState(
          message: message,
          subtle: subtle,
          foreground: foreground,
        ),
      ],
    );
  }

  Widget _buildFileRow(BuildContext context, bool available) {
    return SizedBox(
      width: 226,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: subtle.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              attachment.isImage
                  ? Icons.image_outlined
                  : _fileIcon(attachment.name),
              size: 21,
              color: foreground,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  available
                      ? '${formatBytes(attachment.size)} · tap to open'
                      : formatBytes(attachment.size),
                  style: TextStyle(color: subtle, fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (available) ...[
            const SizedBox(width: 4),
            Icon(Icons.open_in_new, size: 15, color: subtle),
          ],
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final path = attachment.path;
    if (path == null) return;
    final result = await OpenFilex.open(path);
    if (!context.mounted || result.type == ResultType.done) return;
    final message = switch (result.type) {
      ResultType.fileNotFound => 'The file is no longer on this device.',
      ResultType.noAppToOpen => 'No app can open this file type.',
      ResultType.permissionDenied =>
        'Permission denied while opening the file.',
      ResultType.error || ResultType.done => 'Could not open the file.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _VoiceBody extends StatelessWidget {
  const _VoiceBody({
    required this.message,
    required this.attachment,
    required this.mine,
  });

  final Message message;
  final MessageAttachment attachment;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final foreground = mine ? const Color(0xFF0E1800) : MgsColors.text;
    final subtle = mine
        ? const Color(0xFF0E1800).withValues(alpha: 0.58)
        : MgsColors.muted;
    final path = attachment.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path != null)
          _VoicePlayback(
            path: path,
            durationMs: attachment.durationMs,
            foreground: foreground,
            subtle: subtle,
          )
        else
          SizedBox(
            width: 214,
            child: Row(
              children: [
                Icon(Icons.mic_none, size: 20, color: foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Voice note · ${durationLabel(attachment.durationMs)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        _TransferState(
          message: message,
          subtle: subtle,
          foreground: foreground,
        ),
      ],
    );
  }
}

class _VoicePlayback extends StatefulWidget {
  const _VoicePlayback({
    required this.path,
    required this.durationMs,
    required this.foreground,
    required this.subtle,
  });

  final String path;
  final int durationMs;
  final Color foreground;
  final Color subtle;

  @override
  State<_VoicePlayback> createState() => _VoicePlaybackState();
}

class _VoicePlaybackState extends State<_VoicePlayback> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<PlayerState>? _stateSubscription;
  Duration _position = Duration.zero;
  Duration _duration = Duration(milliseconds: 0);
  PlayerState _state = PlayerState.stopped;

  bool get _playing => _state == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    _duration = Duration(milliseconds: widget.durationMs);
    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      if (!mounted || duration <= Duration.zero) return;
      setState(() => _duration = duration);
    });
    _completeSubscription = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _state = PlayerState.completed;
        _position = _duration;
      });
    });
    _stateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completeSubscription?.cancel();
    _stateSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
        return;
      }
      if (_state == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.stop();
        await _player.play(DeviceFileSource(widget.path));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play this voice note.')),
      );
    }
  }

  Future<void> _seek(double value) async {
    if (_duration <= Duration.zero) return;
    final target = Duration(
      milliseconds: (value * _duration.inMilliseconds).round(),
    );
    await _player.seek(target);
    if (mounted) setState(() => _position = target);
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : widget.durationMs;
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final shown = _playing || _position > Duration.zero
        ? _position
        : Duration(milliseconds: widget.durationMs);

    return SizedBox(
      width: 216,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: widget.subtle.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _playing ? Icons.pause : Icons.play_arrow_rounded,
                size: 22,
                color: widget.foreground,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    activeTrackColor: widget.foreground,
                    inactiveTrackColor: widget.subtle.withValues(alpha: 0.32),
                    thumbColor: widget.foreground,
                    overlayColor: widget.foreground.withValues(alpha: 0.12),
                  ),
                  child: Slider(value: progress.toDouble(), onChanged: _seek),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '${durationLabel(shown.inMilliseconds)} · voice',
                    style: TextStyle(
                      color: widget.subtle,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferState extends StatelessWidget {
  const _TransferState({
    required this.message,
    required this.subtle,
    required this.foreground,
  });

  final Message message;
  final Color subtle;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final attachment = message.attachment;
    if (attachment == null) {
      return const SizedBox.shrink();
    }
    final pendingOutgoing = message.outgoing && message.transferProgress < 1;
    if (attachment.available && !pendingOutgoing) {
      return const SizedBox.shrink();
    }

    final error = message.transferError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 13, color: subtle),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                error,
                style: TextStyle(color: subtle, fontSize: 10.5),
              ),
            ),
          ],
        ),
      );
    }

    final progress = message.transferProgress;
    final waiting = progress <= 0;
    final speed = message.transferSpeed;
    final eta = message.transferEtaSeconds;

    final String progressText;
    if (waiting) {
      progressText = 'Waiting for transfer…';
    } else {
      final pct = '${(progress * 100).round()}%';
      final parts = <String>[pct];
      final currentBytes = (progress * attachment.size).round();
      if (attachment.size > 0) {
        parts.add(
          '${formatBytes(currentBytes)} / ${formatBytes(attachment.size)}',
        );
      }
      if (speed > 50) {
        parts.add(formatSpeed(speed));
      }
      if (eta != null && eta > 0) {
        parts.add(formatEta(eta));
      }
      progressText = parts.join(' · ');
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: waiting ? null : progress,
              minHeight: 4,
              backgroundColor: subtle.withValues(alpha: 0.22),
              color: foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(progressText, style: TextStyle(color: subtle, fontSize: 10)),
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

IconData _fileIcon(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'heic' => Icons.image_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'mp3' || 'm4a' || 'wav' || 'ogg' || 'flac' => Icons.audio_file_outlined,
    'mp4' || 'mov' || 'mkv' || 'webm' => Icons.video_file_outlined,
    'apk' || 'exe' || 'msi' => Icons.install_mobile_outlined,
    'txt' || 'md' || 'csv' || 'json' || 'log' => Icons.description_outlined,
    'doc' || 'docx' || 'odt' => Icons.article_outlined,
    'xls' || 'xlsx' || 'ods' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
