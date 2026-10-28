import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:river/lyrics.dart';
import 'package:river/main.dart';
import 'package:river/playback_shortcuts.dart';

void main() {
  testWidgets('mouse wheel does not scroll the player surface', (tester) async {
    tester.view.physicalSize = const Size(720, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    expect(
      tester.widget<Scrollable>(scrollable).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(
          find.byKey(const ValueKey('player-background')),
        ),
        scrollDelta: const Offset(0, 240),
      ),
    );
    await tester.pump();

    expect(tester.state<ScrollableState>(scrollable).position.pixels, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty player explains how to add music', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    final background = tester.widget<Container>(
      find.byKey(const ValueKey('player-background')),
    );
    final backgroundDecoration = background.decoration! as BoxDecoration;
    expect(
      backgroundDecoration.color,
      ThemeData.light().scaffoldBackgroundColor,
    );
    expect(backgroundDecoration.gradient, isNull);
    expect(find.text('river'), findsOneWidget);
    expect(find.text('Drop an audio file here'), findsOneWidget);
    expect(find.text('0:00'), findsNWidgets(2));
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Previous track'), findsOneWidget);
    expect(find.byTooltip('Next track'), findsOneWidget);

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(find.text('Add an audio file to river first.'), findsOneWidget);

    await tester.tap(find.byTooltip('Repeat track'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Turn repeat off'), findsOneWidget);
  });

  testWidgets('queue panel opens from the player controls', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    expect(
      find.descendant(
        of: find.byTooltip('Queue'),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Next in queue'), findsOneWidget);
    expect(
      find.text(
        'Your queue is clear. Add tracks from the library to line them up.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discord listening activity settings are saved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );

    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final setupButton = find.widgetWithText(OutlinedButton, 'Set up');
    await tester.ensureVisible(setupButton);
    await tester.pumpAndSettle();
    await tester.tap(setupButton);
    await tester.pumpAndSettle();

    expect(find.text('Share what I’m listening to'), findsOneWidget);
    expect(find.textContaining('shared Discord app ID'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Share what I’m listening to'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(preferences.getBool('discord_presence_enabled_v1'), isTrue);
    expect(preferences.containsKey('discord_application_id_v1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player no longer shows a library track position counter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d+\s*/\s*\d+$').hasMatch(widget.data ?? ''),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback position exposes a single accessible slider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    final seekNode = tester.getSemantics(
      find.bySemanticsLabel('Playback position'),
    );
    expect(seekNode.getSemanticsData().flagsCollection.isSlider, isTrue);
    expect(seekNode.getSemanticsData().label, 'Playback position');
    semantics.dispose();
  });

  testWidgets('volume slider is accessible and can set a playback level', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );

    final volumeSlider = find.byKey(const ValueKey('player-volume-slider'));
    final volumeNode = tester.getSemantics(find.bySemanticsLabel('Volume'));
    expect(volumeNode.getSemanticsData().flagsCollection.isSlider, isTrue);
    expect(tester.widget<Slider>(volumeSlider).value, 100);
    await tester.drag(volumeSlider, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(volumeSlider).value, lessThan(100));
    expect(preferences.getDouble('playback_volume_v1'), lessThan(100));
    expect(tester.takeException(), isNull);
    final savedVolume = preferences.getDouble('playback_volume_v1')!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(volumeSlider).value, savedVolume);
    semantics.dispose();
  });

  testWidgets('playback control settings persist layouts and shortcuts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'playback_volume_v1': 50.0});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> openPlayer() => tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );

    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    expect(find.text('Modern'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('control-layout-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Classic').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Container>(
            find.byKey(const ValueKey('player-transport-controls')),
          )
          .decoration,
      isA<BoxDecoration>(),
    );

    await tester.tap(find.byKey(const ValueKey('seek-step-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 s').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('volume-step-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10%').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shortcut-change-playPause')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final nextShortcutButton = find.byKey(
      const ValueKey('shortcut-change-nextTrack'),
    );
    await tester.ensureVisible(nextShortcutButton);
    await tester.tap(nextShortcutButton);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('That shortcut is already assigned.'), findsOneWidget);

    final savedControls = jsonDecode(
      preferences.getString('playback_controls_v1')!,
    ) as Map<String, dynamic>;
    expect(savedControls['layout'], 'classic');
    expect(savedControls['seekStep'], 15);
    expect(savedControls['volumeStep'], 10);
    expect(
      PlaybackShortcut.fromJson(
        (savedControls['shortcuts'] as Map<String, dynamic>)['playPause'],
      ).key,
      LogicalKeyboardKey.keyB,
    );
    expect(
      PlaybackShortcut.fromJson(
        (savedControls['shortcuts'] as Map<String, dynamic>)['nextTrack'],
      ),
      defaultPlaybackShortcuts()[PlaybackShortcutAction.nextTrack],
    );
    expect(find.text('Ctrl + B'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Add an audio file to river first.'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Add an audio file to river first.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(preferences.getDouble('playback_volume_v1'), 60);

    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    expect(find.text('Classic'), findsOneWidget);
    expect(find.text('Seek step · 15 sec'), findsOneWidget);
    expect(find.text('Keyboard volume step · 10%'), findsOneWidget);
    expect(find.text('Ctrl + B'), findsOneWidget);

    final resetButton = find.byKey(const ValueKey('reset-playback-controls'));
    await tester.ensureVisible(resetButton);
    await tester.tap(resetButton);
    await tester.pumpAndSettle();
    final resetControls = jsonDecode(
      preferences.getString('playback_controls_v1')!,
    ) as Map<String, dynamic>;
    expect(resetControls['layout'], 'modern');
    expect(resetControls['seekStep'], 5);
    expect(find.text('Modern'), findsOneWidget);
  });

  testWidgets('album artwork exposes one stable image semantics node', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    expect(find.bySemanticsLabel('Cover artwork placeholder'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'player exposes library, year review, and settings without greeting',
    (tester) async {
      final year = DateTime.now().year.toString();
      SharedPreferences.setMockInitialValues({
        'user_name': 'Mira',
        'listening_stats_v1': jsonEncode({
          year: {
            'totalMs': 60000,
            'artists': {'Arctic Monkeys': 60000},
            'songs': {
              r'C:\Music\Do I Wanna Know.mp3': {
                'title': 'Do I Wanna Know?',
                'artist': 'Arctic Monkeys',
                'milliseconds': 60000,
                'plays': 2,
              },
            },
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            enableDropTarget: false,
            enableLastFm: false,
            preferences: preferences,
          ),
        ),
      );

      expect(find.byTooltip('Music library'), findsOneWidget);
      expect(find.byTooltip('Year in music'), findsOneWidget);
      expect(find.byTooltip('river settings'), findsOneWidget);
      expect(find.textContaining(', Mira'), findsNothing);
      expect(
        tester.getSize(find.byTooltip('Music library')),
        const Size.square(56),
      );
      expect(
        tester.getSize(find.byTooltip('river settings')),
        const Size.square(56),
      );

      await tester.tap(find.byTooltip('river settings'));
      await tester.pumpAndSettle();
      expect(find.text('river settings'), findsOneWidget);
      expect(find.text('Installed Windows font'), findsOneWidget);
      expect(find.text('Music folders'), findsOneWidget);
      expect(find.text('Year in music'), findsWidgets);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Year in music'));
      await tester.pumpAndSettle();
      expect(find.text('Arctic Monkeys · 1 min'), findsOneWidget);
      expect(
        find.textContaining('Do I Wanna Know? — Arctic Monkeys'),
        findsOneWidget,
      );
      expect(find.textContaining('2 plays'), findsOneWidget);
    },
  );

  testWidgets('settings credits show jane and open the project links', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final openedUrls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncherChannel, (call) async {
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          openedUrls.add(arguments['url']! as String);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(urlLauncherChannel, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final openCreditsButton = find.byKey(const ValueKey('open-credits'));
    await tester.ensureVisible(openCreditsButton);
    await tester.tap(openCreditsButton);
    await tester.pumpAndSettle();

    expect(find.text('jane(not remover)'), findsOneWidget);
    expect(find.text('creator of river'), findsOneWidget);
    expect(find.text('River 1.0.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('credits-avatar')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('credits-avatar')),
        matching: find.byType(ClipOval),
      ),
      findsOneWidget,
    );
    expect(find.text('Discord: janectrl'), findsOneWidget);
    expect(find.byKey(const ValueKey('credits-discord-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('credits-lastfm')), findsOneWidget);
    expect(find.byKey(const ValueKey('credits-github')), findsOneWidget);
    expect(find.byKey(const ValueKey('credits-kofi')), findsOneWidget);

    final lastFmButton = find.byKey(const ValueKey('credits-lastfm'));
    await tester.ensureVisible(lastFmButton);
    await tester.tap(lastFmButton);
    await tester.pumpAndSettle();
    final githubButton = find.byKey(const ValueKey('credits-github'));
    await tester.ensureVisible(githubButton);
    await tester.tap(githubButton);
    await tester.pumpAndSettle();
    final kofiButton = find.byKey(const ValueKey('credits-kofi'));
    await tester.ensureVisible(kofiButton);
    await tester.tap(kofiButton);
    await tester.pumpAndSettle();
    expect(openedUrls, [
      'https://www.last.fm/user/janectrl',
      'https://github.com/janectrl',
      'https://ko-fi.com/rivermusicplayer',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics button opens the lyrics panel', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );

    await tester.tap(find.byTooltip('Show lyrics'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Lyrics not found in LRCLIB.\n'
        'You can add a matching local .lrc file.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Hide lyrics'), findsOneWidget);
  });

  testWidgets('compact visualizer setting defaults on and persists off', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    Future<void> openPlayer() => tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );

    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Show compact visualizer',
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(preferences.getBool('compact_visualizer_enabled'), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final restoredToggle = find.widgetWithText(
      SwitchListTile,
      'Show compact visualizer',
    );
    expect(tester.widget<SwitchListTile>(restoredToggle).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('economy mode disables visualizers and uses a solid background', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> openPlayer() => tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          preferences: preferences,
        ),
      ),
    );

    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final economyToggle = find.byKey(const ValueKey('economy-mode-toggle'));
    await tester.ensureVisible(economyToggle);
    expect(tester.widget<SwitchListTile>(economyToggle).value, isFalse);
    await tester.tap(economyToggle);
    await tester.pumpAndSettle();

    expect(preferences.getBool('economy_mode_enabled_v1'), isTrue);
    expect(tester.widget<SwitchListTile>(economyToggle).value, isTrue);
    final compactVisualizerToggle = find.widgetWithText(
      SwitchListTile,
      'Show compact visualizer',
    );
    expect(
      tester.widget<SwitchListTile>(compactVisualizerToggle).value,
      isFalse,
    );
    expect(
      tester.widget<SwitchListTile>(compactVisualizerToggle).onChanged,
      isNull,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Done').last);
    await tester.pumpAndSettle();
    final background = tester.widget<Container>(
      find.byKey(const ValueKey('player-background')),
    );
    expect(
      (background.decoration! as BoxDecoration).color,
      const Color(0xFF0F0F0F),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await openPlayer();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('economy-mode-toggle')),
          )
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long lyric lines wrap and expose concise lyric semantics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const longLine =
        "I've never been to London, London, but I have a feeling that I might "
        "stay out all night";
    const secondLine = "And that's the truth, that's the truth";
    final controller = ScrollController();
    final activeLine = ValueNotifier(0);
    addTearDown(controller.dispose);
    addTearDown(activeLine.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 800,
            child: LyricsListView(
              lyrics: const [
                LyricLine(timestamp: Duration.zero, text: longLine),
                LyricLine(timestamp: Duration(seconds: 3), text: secondLine),
              ],
              controller: controller,
              activeLyricIndex: activeLine,
              semanticsLabel: 'Lyrics',
              synced: true,
              largeWindow: false,
              fontFamily: 'Georgia',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lyricsPanel = find.byType(LyricsListView);
    expect(
      (tester.getCenter(find.text(longLine)).dy -
              tester.getRect(lyricsPanel).center.dy)
          .abs(),
      lessThan(1),
    );
    final lyricText = tester.widget<Text>(find.text(longLine));
    final paragraph = tester.renderObject<RenderParagraph>(find.text(longLine));
    expect(paragraph.text.style?.fontFamily, 'Georgia');
    expect(lyricText.textAlign, TextAlign.center);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(lyricText.softWrap, isTrue);
    expect(lyricText.maxLines, isNull);
    expect(paragraph.size.height, greaterThan(34));
    expect(lyricText.data, longLine);
    expect(paragraph.size.height, greaterThan(86));
    expect(paragraph.size.height, lessThan(800));
    final lyricsSemantics = tester.getSemantics(
      find.bySemanticsLabel('Lyrics'),
    );
    expect(lyricsSemantics.getSemanticsData().value, longLine);
    activeLine.value = 1;
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.text(secondLine)).dy -
              tester.getRect(lyricsPanel).center.dy)
          .abs(),
      lessThan(1),
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Lyrics'))
          .getSemanticsData()
          .value,
      secondLine,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('synced lyric stays centered in small and large panels', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final (size, largeWindow) in [
      (const Size(360, 200), false),
      (const Size(1200, 720), true),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final controller = ScrollController();
      final activeLine = ValueNotifier(3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              height: size.height,
              child: LyricsListView(
                lyrics: [
                  for (var index = 0; index < 6; index++)
                    LyricLine(
                      timestamp: Duration(seconds: index * 3),
                      text: 'Sung line $index',
                    ),
                ],
                controller: controller,
                activeLyricIndex: activeLine,
                semanticsLabel: 'Lyrics',
                synced: true,
                largeWindow: largeWindow,
                fontFamily: 'Georgia',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final panel = find.byType(LyricsListView);
      final activeText = find.text('Sung line 3');
      expect(
        (tester.getCenter(activeText).dy - tester.getRect(panel).center.dy)
            .abs(),
        lessThan(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      activeLine.dispose();
    }
  });

  testWidgets('F11 toggles window fullscreen and Escape exits it', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.idle();
    expect(calls, contains('setFullScreen'));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.idle();
    expect(calls.where((method) => method == 'setFullScreen'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('player controls use the selected language', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          languageCode: 'es',
        ),
      ),
    );

    expect(find.text('river'), findsOneWidget);
    expect(find.byTooltip('Reproducir'), findsOneWidget);
    expect(find.byTooltip('Biblioteca musical'), findsOneWidget);
    expect(find.byTooltip('Ajustes de river'), findsOneWidget);
  });

  testWidgets('player and lyrics fit common desktop window sizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in [
      const Size(720, 620),
      const Size(1000, 760),
      const Size(1238, 950),
      const Size(1920, 1080),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        const MaterialApp(
          home: PlayerScreen(enableDropTarget: false, enableLastFm: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('empty-artwork')))
            .shortestSide,
        greaterThan(0),
      );
      final playButton = tester.getRect(find.byTooltip('Play'));
      expect(playButton.top, greaterThanOrEqualTo(0));
      expect(playButton.bottom, lessThanOrEqualTo(size.height));

      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final artworkRect = tester.getRect(
        find.byKey(const ValueKey('player-artwork')),
      );
      final toolbarRect = tester.getRect(
        find.byKey(const ValueKey('player-top-toolbar')),
      );
      expect(artworkRect.top, greaterThanOrEqualTo(toolbarRect.bottom));
      expect(
        artworkRect.width,
        greaterThanOrEqualTo(size.width < 800 ? 180 : 240),
      );
      final playerColumn = tester.getSize(
        find.byKey(const ValueKey('player-column')),
      );
      final lyricsPanel = tester.getSize(
        find.byKey(const ValueKey('lyrics-panel')),
      );
      if (size.width >= 1200) {
        expect(lyricsPanel.width, greaterThan(playerColumn.width));
      } else {
        expect((playerColumn.width - lyricsPanel.width).abs(), lessThan(1));
      }
      final lyricsRect = tester.getRect(
        find.byKey(const ValueKey('lyrics-panel')),
      );
      expect(lyricsRect.top, 0);
      expect(lyricsRect.bottom, size.height);
      expect(
        tester.getRect(find.byTooltip('Hide lyrics')).left,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('lyrics-panel'))).left,
        ),
      );
      if (size.width >= 1200) {
        final volumeRect = tester.getRect(
          find.byKey(const ValueKey('player-volume-slider')),
        );
        final transportRect = tester.getRect(
          find.byKey(const ValueKey('player-transport-controls')),
        );
        expect(
          transportRect.center.dx,
          closeTo(
            tester
                .getRect(find.byKey(const ValueKey('player-column')))
                .center
                .dx,
            2,
          ),
        );
        expect(volumeRect.overlaps(transportRect), isFalse);
        expect(volumeRect.bottom, lessThanOrEqualTo(size.height));
      }
    }
  });
}
