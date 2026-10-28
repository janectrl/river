import 'dart:math' as math;

import 'package:flutter/material.dart';

class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({
    required this.imageProvider,
    required this.trackKey,
    this.motionEnabled = true,
    this.motionDurationSeconds = 14,
    super.key,
  });

  final ImageProvider imageProvider;
  final Object trackKey;
  final bool motionEnabled;
  final double motionDurationSeconds;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 32),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.duration = _motionDuration;
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant PlayerBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motionDurationSeconds != widget.motionDurationSeconds) {
      _motion.duration = _motionDuration;
    }
    if (oldWidget.motionEnabled != widget.motionEnabled ||
        oldWidget.motionDurationSeconds != widget.motionDurationSeconds) {
      _updateMotion();
    }
  }

  Duration get _motionDuration => Duration(
    seconds: widget.motionDurationSeconds.round().clamp(1, 40).toInt() * 2,
  );

  void _updateMotion() {
    if (!widget.motionEnabled || MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          child: AnimatedBuilder(
            animation: _motion,
            key: const ValueKey('player-backdrop-motion'),
            child: RepaintBoundary(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.center,
                  fit: StackFit.expand,
                  children: [...previousChildren, ?currentChild],
                ),
                child: SizedBox.expand(
                  key: ValueKey(widget.trackKey),
                  child: Image(
                    image: widget.imageProvider,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
            builder: (context, child) {
              final phase = _motion.value * math.pi * 2;
              final horizontalDrift = math.sin(phase);
              final verticalDrift = math.cos(phase * 2);
              final scale = 1.14 + math.sin(phase) * 0.012;
              return Transform.translate(
                offset: Offset(
                  horizontalDrift * constraints.maxWidth * 0.045,
                  verticalDrift * constraints.maxHeight * 0.03,
                ),
                child: Transform.rotate(
                  angle: horizontalDrift * 0.012,
                  child: Transform.scale(scale: scale, child: child),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
