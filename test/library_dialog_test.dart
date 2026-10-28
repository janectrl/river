import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/main.dart';
import 'package:river/player_skin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('corrupt track cache is reported without crashing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'track_library_cache_v1': 'bad'});
    final preferences = await SharedPreferences.getInstance();
    final musicFolder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('river-library-cache-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => musicFolder.delete(recursive: true)),
    );
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          initialMusicFolders: [musicFolder.path],
          preferences: preferences,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not read the music library cache.'),
      findsOneWidget,
    );
    expect(find.text('Could not save the music library cache.'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'library can create a playlist without a dialog lifecycle error',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'playlists_v1': jsonEncode({
          'Legacy Mix': <String>['old.mp3'],
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      final musicFolder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('river-playlist-create-'),
      ))!;
      addTearDown(
        () => tester.runAsync(() => musicFolder.delete(recursive: true)),
      );
      tester.view.physicalSize = const Size(720, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            enableDropTarget: false,
            enableLastFm: false,
            initialMusicFolders: [musicFolder.path],
            preferences: preferences,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Music library'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Create playlist'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Test Mix',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Test Mix'), findsWidgets);
      expect(find.text('0 songs'), findsWidgets);
      expect(find.text('Legacy Mix'), findsOneWidget);
      expect(find.text('1 song'), findsOneWidget);
      await tester.tap(find.byTooltip('Playlist options'));
      await tester.pumpAndSettle();
      expect(find.text('Choose playlist cover'), findsOneWidget);
      expect(jsonDecode(preferences.getString('playlists_v1')!)['Legacy Mix'], [
        'old.mp3',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            enableDropTarget: false,
            enableLastFm: false,
            initialMusicFolders: [musicFolder.path],
            preferences: preferences,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Music library'));
      await tester.pumpAndSettle();
      expect(find.text('Test Mix'), findsOneWidget);
      expect(find.text('Legacy Mix'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library search finds playlists and shows clear empty results', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final musicFolder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('river-library-search-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => musicFolder.delete(recursive: true)),
    );
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await preferences.setString(
      'playlists_v1',
      jsonEncode({'Night Drive': <String>[]}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          initialMusicFolders: [musicFolder.path],
          preferences: preferences,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Music library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Night Drive'), findsOneWidget);
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText ==
              'Search songs, artists, albums, playlists…',
    );
    expect(search, findsOneWidget);

    await tester.enterText(search, 'night');
    await tester.pump();
    expect(find.text('Night Drive'), findsOneWidget);

    await tester.enterText(search, 'no match');
    await tester.pump();
    expect(find.text('Night Drive'), findsNothing);
    expect(find.text('No matches for “no match”.'), findsOneWidget);
    expect(find.byTooltip('Clear search'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Night Drive'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library exposes songs, albums, and artists sections', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final musicFolder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('river-library-catalog-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => musicFolder.delete(recursive: true)),
    );
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          initialMusicFolders: [musicFolder.path],
          preferences: preferences,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Music library'));
    await tester.pumpAndSettle();
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Add a music folder to see your songs.'), findsOneWidget);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Add a music folder to see your songs.'), findsOneWidget);

    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('solid background uses the saved skin color', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const backgroundColor = Color(0xFF405060);
    final musicFolder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('river-solid-background-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => musicFolder.delete(recursive: true)),
    );
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          initialMusicFolders: [musicFolder.path],
          preferences: preferences,
          skin: PlayerSkin.defaultSkin.copyWith(
            backgroundColor: backgroundColor,
            backgroundStyle: PlayerBackgroundStyle.solidColor,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    final background = tester.widget<Container>(
      find.byKey(const ValueKey('player-background')),
    );
    expect((background.decoration! as BoxDecoration).color, backgroundColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Last.fm management is available in river settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final musicFolder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('river-settings-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => musicFolder.delete(recursive: true)),
    );
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          enableDropTarget: false,
          enableLastFm: false,
          initialMusicFolders: [musicFolder.path],
          preferences: preferences,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Adding'), findsNothing);
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();

    expect(find.text('Last.fm settings'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    await tester.ensureVisible(find.text('Equalizer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Equalizer'));
    await tester.pumpAndSettle();
    final bands = find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == -12 && widget.max == 12,
    );
    expect(bands, findsAtLeastNWidgets(8));
    expect(find.text('Reset to flat'), findsOneWidget);
    await tester.drag(bands.first, const Offset(90, 0));
    await tester.pumpAndSettle();
    final savedBands =
        jsonDecode(preferences.getString('equalizer_bands_v1')!) as List;
    expect(savedBands.any((gain) => gain != 0), isTrue);
    await tester.drag(find.byType(ListView).last, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(find.text('16 kHz'), findsOneWidget);
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
