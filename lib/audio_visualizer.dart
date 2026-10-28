import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AudioVisualizer extends StatefulWidget {
  const AudioVisualizer({
    required this.isPlaying,
    required this.semanticsLabel,
    required this.systemCaptureLabel,
    required this.exitFullScreenLabel,
    required this.fullScreen,
    required this.barCount,
    required this.onToggleFullScreen,
    required this.onError,
    this.showSystemCaptureNotice = true,
    this.onSystemCaptureNoticeShown,
    super.key,
  });

  final bool isPlaying;
  final String semanticsLabel;
  final String systemCaptureLabel;
  final String exitFullScreenLabel;
  final bool fullScreen;
  final int barCount;
  final VoidCallback onToggleFullScreen;
  final ValueChanged<PlatformException> onError;
  final bool showSystemCaptureNotice;
  final VoidCallback? onSystemCaptureNoticeShown;

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer> {
  static const _channel = MethodChannel('river/audio_visualizer');
  static const _bandCount = 10;

  final List<double> _levels = List<double>.filled(_bandCount, 0);
  Timer? _timer;
  Timer? _noticeTimer;
  bool _active = false;
  bool _polling = false;
  bool _systemCapture = false;
  bool _showSystemCaptureNotice = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncCaptureState();
  }

  @override
  void didUpdateWidget(covariant AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncCaptureState();
  }

  void _syncCaptureState() {
    final shouldCapture =
        Platform.isWindows &&
        widget.isPlaying &&
        !MediaQuery.disableAnimationsOf(context);
    if (_active == shouldCapture) return;
    _active = shouldCapture;
    final generation = ++_generation;
    if (shouldCapture) {
      unawaited(_startCapture(generation));
    } else {
      _stopCapture();
    }
  }

  Future<void> _startCapture(int generation) async {
    try {
      final mode = await _channel.invokeMethod<String>('start');
      if (mode != 'system' && mode != 'process') {
        throw PlatformException(
          code: 'invalid_capture_mode',
          message: 'Windows returned an invalid audio capture mode.',
        );
      }
      if (!mounted || !_active || generation != _generation) return;
      final systemCapture = mode == 'system';
      final showNotice = systemCapture && widget.showSystemCaptureNotice;
      setState(() {
        _systemCapture = systemCapture;
        _showSystemCaptureNotice = showNotice;
      });
      _noticeTimer?.cancel();
      if (showNotice) {
        widget.onSystemCaptureNoticeShown?.call();
        _noticeTimer = Timer(const Duration(milliseconds: 2800), () {
          if (mounted) setState(() => _showSystemCaptureNotice = false);
        });
      }
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(milliseconds: 45),
        (_) => unawaited(_readLevels(generation)),
      );
      await _readLevels(generation);
    } on PlatformException catch (error) {
      _handleCaptureError(generation, error);
    }
  }

  Future<void> _readLevels(int generation) async {
    if (_polling || !mounted || !_active || generation != _generation) return;
    _polling = true;
    try {
      final values = await _channel.invokeListMethod<num>('getLevels');
      if (values == null || values.length != _bandCount) {
        throw PlatformException(
          code: 'invalid_audio_levels',
          message: 'Windows returned an invalid audio spectrum.',
        );
      }
      if (!mounted || !_active || generation != _generation) return;
      final normalized = values
          .map((value) => value.toDouble().clamp(0, 1).toDouble())
          .toList(growable: false);
      if (normalized.asMap().entries.any(
        (entry) => (entry.value - _levels[entry.key]).abs() > 0.015,
      )) {
        setState(() {
          for (var index = 0; index < _bandCount; index++) {
            _levels[index] = normalized[index];
          }
        });
      }
    } on PlatformException catch (error) {
      _handleCaptureError(generation, error);
    } finally {
      _polling = false;
    }
  }

  void _handleCaptureError(int generation, PlatformException error) {
    if (!mounted || generation != _generation) return;
    _timer?.cancel();
    _timer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _active = false;
    _generation++;
    _systemCapture = false;
    _showSystemCaptureNotice = false;
    for (var index = 0; index < _bandCount; index++) {
      _levels[index] = 0;
    }
    setState(() {});
    widget.onError(error);
    unawaited(_channel.invokeMethod<void>('stop'));
  }

  void _stopCapture() {
    _timer?.cancel();
    _timer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _systemCapture = false;
    _showSystemCaptureNotice = false;
    for (var index = 0; index < _bandCount; index++) {
      _levels[index] = 0;
    }
    if (Platform.isWindows) {
      unawaited(_channel.invokeMethod<void>('stop'));
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _noticeTimer?.cancel();
    if (_active) unawaited(_channel.invokeMethod<void>('stop'));
    super.dispose();
  }

  Widget _buildCompactVisualizer(BuildContext context) => SizedBox(
    key: const ValueKey('audio-visualizer'),
    width: 260,
    child: GestureDetector(
      onTap: widget.onToggleFullScreen,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 32,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SpectrumPainter(
                  List.of(_levels),
                  barCount: widget.barCount,
                  color: Theme.of(context).colorScheme.primary,
                ),
                size: const Size(double.infinity, 32),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _showSystemCaptureNotice
                ? Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.systemCaptureLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.68),
                        fontSize: 10,
                      ),
                    ),
                  )
                : const SizedBox(height: 0),
          ),
        ],
      ),
    ),
  );

  Widget _buildFullScreenVisualizer(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape):
          widget.onToggleFullScreen,
    },
    child: Focus(
      autofocus: true,
      child: GestureDetector(
        key: const ValueKey('full-screen-audio-visualizer'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggleFullScreen,
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: _SpectrumPainter(
                    List.of(_levels),
                    barCount: widget.barCount,
                    color: Theme.of(context).colorScheme.primary,
                    centered: true,
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  tooltip: widget.exitFullScreenLabel,
                  onPressed: widget.onToggleFullScreen,
                  icon: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ),
              if (_showSystemCaptureNotice)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Text(
                      widget.systemCaptureLabel,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.68),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Semantics(
    label: _systemCapture
        ? '${widget.semanticsLabel}. ${widget.systemCaptureLabel}'
        : widget.semanticsLabel,
    image: true,
    child: ExcludeSemantics(
      child: widget.fullScreen
          ? _buildFullScreenVisualizer(context)
          : _buildCompactVisualizer(context),
    ),
  );
}

class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter(
    this.levels, {
    required this.barCount,
    required this.color,
    this.centered = false,
  });

  final List<double> levels;
  final int barCount;
  final Color color;
  final bool centered;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.isEmpty) return;
    final count = barCount.clamp(1, 128);
    final gap = count > 40 ? 2.0 : 3.0;
    final barWidth = math.max(1.0, (size.width - gap * (count - 1)) / count);
    for (var index = 0; index < count; index++) {
      final bandPosition = index / (count - 1) * (levels.length - 1);
      final lowerBand = bandPosition.floor();
      final upperBand = math.min(lowerBand + 1, levels.length - 1);
      final mix = bandPosition - lowerBand;
      final level = levels[lowerBand] * (1 - mix) + levels[upperBand] * mix;
      final height = math.max(
        centered ? 4.0 : 2.0,
        size.height * (centered ? 0.035 + level * 0.86 : level),
      );
      final left = index * (barWidth + gap);
      final top = centered ? (size.height - height) / 2 : size.height - height;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, barWidth, height),
          const Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: 0.34 + level * 0.66),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) =>
      barCount != oldDelegate.barCount ||
      color != oldDelegate.color ||
      centered != oldDelegate.centered ||
      !listEquals(levels, oldDelegate.levels);
}
