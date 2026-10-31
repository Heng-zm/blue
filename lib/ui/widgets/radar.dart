import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

class RadarBlip {
  const RadarBlip({
    required this.keyLabel,
    required this.rssi,
    required this.online,
  });

  final String keyLabel;
  final int rssi;
  final bool online;
}

class MgsRadar extends StatefulWidget {
  const MgsRadar({super.key, required this.blips, this.size = 240});

  final List<RadarBlip> blips;
  final double size;

  @override
  State<MgsRadar> createState() => _MgsRadarState();
}

class _MgsRadarState extends State<MgsRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _RadarPainter(
              progress: _controller.value,
              blips: widget.blips,
            ),
          );
        },
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress, required this.blips});

  final double progress;
  final List<RadarBlip> blips;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = MgsColors.line.withValues(alpha: 0.9);
    for (var ringIndex = 1; ringIndex <= 3; ringIndex++) {
      canvas.drawCircle(center, radius * ringIndex / 3, ring);
    }

    final cross = Paint()
      ..strokeWidth = 1
      ..color = MgsColors.line.withValues(alpha: 0.55);
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      cross,
    );

    final angle = progress * 2 * math.pi - math.pi / 2;
    final sweepRect = Rect.fromCircle(center: center, radius: radius);
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: angle - 0.85,
        endAngle: angle,
        colors: [
          MgsColors.lime.withValues(alpha: 0),
          MgsColors.lime.withValues(alpha: 0.16),
        ],
        stops: const [0.0, 1.0],
      ).createShader(sweepRect);
    canvas.drawCircle(center, radius, sweepPaint);

    final beamPaint = Paint()
      ..color = MgsColors.lime.withValues(alpha: 0.55)
      ..strokeWidth = 1.4;
    canvas.drawLine(
      center,
      center + Offset(math.cos(angle), math.sin(angle)) * radius,
      beamPaint,
    );

    for (final blip in blips) {
      final hash = blip.keyLabel.hashCode.abs();
      final blipAngle = (hash % 360) * math.pi / 180;
      final normalized = ((-blip.rssi - 35) / 55).clamp(0.0, 1.0).toDouble();
      final distance = radius * (0.22 + normalized * 0.7);
      final point =
          center + Offset(math.cos(blipAngle), math.sin(blipAngle)) * distance;
      final color = blip.online
          ? MgsColors.lime
          : MgsColors.muted.withValues(alpha: 0.8);

      canvas.drawCircle(
        point,
        9,
        Paint()..color = color.withValues(alpha: 0.12),
      );
      canvas.drawCircle(point, 3.4, Paint()..color = color);
      if (blip.online) {
        canvas.drawCircle(
          point,
          6.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.45),
        );
      }
    }

    canvas.drawCircle(
      center,
      4,
      Paint()..color = MgsColors.lime.withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = MgsColors.lime.withValues(alpha: 0.25),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.blips != blips;
}
