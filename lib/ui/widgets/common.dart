import 'package:flutter/material.dart';

import '../theme.dart';

class MgsMark extends StatelessWidget {
  const MgsMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MgsColors.lime, MgsColors.mint],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: [
          BoxShadow(
            color: MgsColors.lime.withValues(alpha: 0.25),
            blurRadius: size * 0.45,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Icon(
        Icons.bluetooth_searching,
        color: const Color(0xFF0A1200),
        size: size * 0.56,
      ),
    );
  }
}

class MgsWordmark extends StatelessWidget {
  const MgsWordmark({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MgsMark(size: compact ? 34 : 42),
        SizedBox(width: compact ? 10 : 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MGS',
              style: TextStyle(
                fontSize: compact ? 19 : 23,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.4,
                height: 1,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'OFFLINE MESH',
              style: TextStyle(
                fontSize: compact ? 8.5 : 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8,
                color: MgsColors.muted,
                height: 1,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class MgsCard extends StatelessWidget {
  const MgsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color = MgsColors.panel,
    this.borderColor = MgsColors.line,
    this.radius = 22,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.color = MgsColors.lime,
    this.pulsing = false,
  });

  final String label;
  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulseDot(color: color, active: pulsing),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class PulseDot extends StatefulWidget {
  const PulseDot({
    super.key,
    required this.color,
    this.active = true,
    this.size = 7,
  });

  final Color color;
  final bool active;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = widget.active ? _controller.value : 0.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.22 + 0.35 * (1 - t)),
                blurRadius: widget.size + 7 * t,
                spreadRadius: 1.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.rssi,
    this.color = MgsColors.lime,
  });

  final int rssi;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final level = rssi >= -55
        ? 4
        : rssi >= -70
        ? 3
        : rssi >= -85
        ? 2
        : 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final active = index < level;
        return Container(
          width: 3.5,
          height: 5 + index * 3.5,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: active ? color : MgsColors.line,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    required this.label,
    this.size = 46,
    this.online = false,
    this.isBroadcast = false,
  });

  final String label;
  final double size;
  final bool online;
  final bool isBroadcast;

  @override
  Widget build(BuildContext context) {
    final initial = label.trim().isEmpty ? '?' : label.trim().characters.first;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isBroadcast
                  ? MgsColors.lime.withValues(alpha: 0.12)
                  : MgsColors.panelHigh,
              shape: BoxShape.circle,
              border: Border.all(
                color: isBroadcast
                    ? MgsColors.lime.withValues(alpha: 0.45)
                    : MgsColors.line,
              ),
            ),
            child: isBroadcast
                ? Icon(
                    Icons.cell_tower,
                    size: size * 0.46,
                    color: MgsColors.lime,
                  )
                : Text(
                    initial.toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: size * 0.36,
                      color: MgsColors.text,
                    ),
                  ),
          ),
          if (online)
            Positioned(
              right: 1,
              bottom: 1,
              child: Container(
                width: size * 0.24,
                height: size * 0.24,
                decoration: BoxDecoration(
                  color: MgsColors.lime,
                  shape: BoxShape.circle,
                  border: Border.all(color: MgsColors.ink, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
