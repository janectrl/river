import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/audio_visualizer.dart';

void main() {
  testWidgets('system loopback mode is disclosed and stopped on dispose', (
    tester,
  ) async {
    const channel = MethodChannel('river/audio_visualizer');
    final calls = <String>[];
    var noticeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'start' => 'system',
            'getLevels' => List<double>.filled(10, 0.4),
            'stop' => null,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AudioVisualizer(
          isPlaying: true,
          semanticsLabel: 'Live audio spectrum',
          systemCaptureLabel: 'Listening to all system audio',
          exitFullScreenLabel: 'Exit full screen',
          fullScreen: false,
          barCount: 32,
          onSystemCaptureNoticeShown: () => noticeCount++,
          onToggleFullScreen: _unexpectedToggle,
          onError: _unexpectedError,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Listening to all system audio'), findsOneWidget);
    expect(noticeCount, 1);
    expect(calls, contains('start'));
    expect(calls, contains('getLevels'));

    await tester.pump(const Duration(milliseconds: 2800));
    expect(find.text('Listening to all system audio'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls, contains('stop'));
  }, skip: !Platform.isWindows);

  testWidgets('suppressed system capture notice stays hidden', (tester) async {
    const channel = MethodChannel('river/audio_visualizer');
    final calls = <String>[];
    var noticeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'start' => 'system',
            'getLevels' => List<double>.filled(10, 0.4),
            'stop' => null,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AudioVisualizer(
          isPlaying: true,
          semanticsLabel: 'Live audio spectrum',
          systemCaptureLabel: 'Listening to all system audio',
          exitFullScreenLabel: 'Exit full screen',
          fullScreen: false,
          barCount: 32,
          showSystemCaptureNotice: false,
          onSystemCaptureNoticeShown: () => noticeCount++,
          onToggleFullScreen: _unexpectedToggle,
          onError: _unexpectedError,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(calls, contains('start'));
    expect(find.text('Listening to all system audio'), findsNothing);
    expect(noticeCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, skip: !Platform.isWindows);

  testWidgets('full-screen visualizer exits with Escape or its button', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AudioVisualizer(
          isPlaying: false,
          semanticsLabel: 'Live audio spectrum',
          systemCaptureLabel: 'Listening to all system audio',
          exitFullScreenLabel: 'Exit full screen',
          fullScreen: true,
          barCount: 32,
          onToggleFullScreen: () => toggles++,
          onError: _unexpectedError,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('full-screen-audio-visualizer')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(toggles, 1);
    await tester.tap(find.byTooltip('Exit full screen'));
    expect(toggles, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capture stays active while the visualizer changes layouts', (
    tester,
  ) async {
    const channel = MethodChannel('river/audio_visualizer');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'start' => 'system',
            'getLevels' => List<double>.filled(10, 0.6),
            'stop' => null,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final key = GlobalKey();
    var fullScreen = false;
    Widget visualizer(StateSetter setState) => AudioVisualizer(
      key: key,
      isPlaying: true,
      semanticsLabel: 'Live audio spectrum',
      systemCaptureLabel: 'Listening to all system audio',
      exitFullScreenLabel: 'Exit full screen',
      fullScreen: fullScreen,
      barCount: 32,
      onToggleFullScreen: () => setState(() => fullScreen = !fullScreen),
      onError: _unexpectedError,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Stack(
              children: [
                if (!fullScreen)
                  Positioned(left: 30, top: 30, child: visualizer(setState)),
                if (fullScreen) Positioned.fill(child: visualizer(setState)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(calls.where((method) => method == 'start'), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('audio-visualizer')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('full-screen-audio-visualizer')),
      findsOneWidget,
    );
    expect(calls.where((method) => method == 'start'), hasLength(1));
    expect(calls.where((method) => method == 'stop'), isEmpty);

    await tester.tap(find.byTooltip('Exit full screen'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('audio-visualizer')), findsOneWidget);
    expect(calls.where((method) => method == 'start'), hasLength(1));
    expect(calls.where((method) => method == 'stop'), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.where((method) => method == 'stop'), hasLength(1));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}

void _unexpectedError(PlatformException error) {
  fail('Unexpected visualizer error: ${error.message}');
}

void _unexpectedToggle() {
  fail('Unexpected visualizer mode change');
}
