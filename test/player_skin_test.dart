import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/player_skin.dart';
import 'package:river/player_skin_editor.dart';

void main() {
  test('saved appearance round-trips all skin properties', () {
    final skin = PlayerSkin.defaultSkin.copyWith(
      id: 'my-skin',
      name: 'Evening',
      backgroundColor: const Color(0xFF15202A),
      textColor: const Color(0xFFF0E8DD),
      accentColor: const Color(0xFFD8A889),
      cornerRadius: 28,
      backgroundMotion: false,
      motionDurationSeconds: 30,
      visualizerBars: 48,
      backgroundStyle: PlayerBackgroundStyle.coverTones,
      separateLyricsFont: true,
      lyricsFontFamily: 'Georgia',
      fontFamily: 'Arial',
      fontScale: 1.2,
    );

    final restored = PlayerSkin.fromJson(skin.toJson());

    expect(restored.id, skin.id);
    expect(restored.name, skin.name);
    expect(restored.backgroundColor, skin.backgroundColor);
    expect(restored.textColor, skin.textColor);
    expect(restored.accentColor, skin.accentColor);
    expect(restored.cornerRadius, skin.cornerRadius);
    expect(restored.backgroundMotion, skin.backgroundMotion);
    expect(restored.motionDurationSeconds, skin.motionDurationSeconds);
    expect(restored.visualizerBars, skin.visualizerBars);
    expect(restored.backgroundStyle, skin.backgroundStyle);
    expect(restored.separateLyricsFont, isTrue);
    expect(restored.lyricsFontFamily, 'Georgia');
    expect(restored.fontFamily, skin.fontFamily);
    expect(restored.fontScale, skin.fontScale);
  });

  test('loaded skin settings stay within supported control ranges', () {
    final skin = PlayerSkin.fromJson({
      'id': 'bounded',
      'name': 'Bounded',
      'background': 0xFF000000,
      'text': 0xFFFFFFFF,
      'accent': 0xFFFFFFFF,
      'cornerRadius': 100,
      'backgroundMotion': true,
      'motionDurationSeconds': 1,
      'visualizerBars': 200,
      'fontScale': 3,
    });

    expect(skin.cornerRadius, 40);
    expect(skin.motionDurationSeconds, 1);
    expect(skin.visualizerBars, 64);
    expect(skin.fontScale, 1.4);
  });

  testWidgets('background motion speed can be set below six seconds', (
    tester,
  ) async {
    var changedSkin = PlayerSkin.defaultSkin;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: PlayerSkinEditor(
                languageCode: 'en',
                skin: changedSkin,
                skins: PlayerSkin.presets,
                onSelect: (_) {},
                onChange: (skin) => changedSkin = skin,
                onCommit: () async {},
                onSaveAs: (_) async {},
                onDelete: () async {},
                showCompactVisualizer: true,
                onCompactVisualizerChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final speedSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('background-motion-speed')),
    );
    expect(speedSlider.min, 1);
    expect(speedSlider.max, 40);
    expect(speedSlider.divisions, 39);
    speedSlider.onChanged!(1);
    expect(changedSkin.motionDurationSeconds, 1);
  });

  testWidgets('solid background color can be edited in the style settings', (
    tester,
  ) async {
    var changedSkin = PlayerSkin.defaultSkin;

    Future<void> buildEditor() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: PlayerSkinEditor(
                languageCode: 'en',
                skin: changedSkin,
                skins: PlayerSkin.presets,
                onSelect: (_) {},
                onChange: (skin) => changedSkin = skin,
                onCommit: () async {},
                onSaveAs: (_) async {},
                onDelete: () async {},
                showCompactVisualizer: true,
                onCompactVisualizerChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await buildEditor();
    final styleField = tester
        .widget<DropdownButtonFormField<PlayerBackgroundStyle>>(
          find.byType(DropdownButtonFormField<PlayerBackgroundStyle>),
        );
    styleField.onChanged!(PlayerBackgroundStyle.solidColor);
    await tester.pumpAndSettle();
    await buildEditor();

    final backgroundColorButton = find.byKey(
      const ValueKey('skin-background-color'),
    );
    expect(backgroundColorButton, findsOneWidget);
    expect(
      tester.getTopLeft(backgroundColorButton).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byType(DropdownButtonFormField<PlayerBackgroundStyle>),
            )
            .dy,
      ),
    );

    final initialColor = changedSkin.backgroundColor;
    await tester.tap(backgroundColorButton);
    await tester.pumpAndSettle();
    final brightnessSlider = tester.widget<Slider>(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Slider),
          )
          .last,
    );
    brightnessSlider.onChanged!(0.4);
    await tester.pump();
    expect(changedSkin.backgroundColor, isNot(initialColor));
  });

  testWidgets('background motion toggle enables the speed control', (
    tester,
  ) async {
    var changedSkin = PlayerSkin.defaultSkin;

    Future<void> buildEditor() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: PlayerSkinEditor(
                languageCode: 'en',
                skin: changedSkin,
                skins: PlayerSkin.presets,
                onSelect: (_) {},
                onChange: (skin) => changedSkin = skin,
                onCommit: () async {},
                onSaveAs: (_) async {},
                onDelete: () async {},
                showCompactVisualizer: true,
                onCompactVisualizerChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await buildEditor();
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Moving album background',
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(
      find.byKey(const ValueKey('background-motion-speed')),
      findsOneWidget,
    );

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(changedSkin.backgroundMotion, isFalse);

    await buildEditor();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Moving album background'),
          )
          .value,
      isFalse,
    );
    expect(find.byKey(const ValueKey('background-motion-speed')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'older skins retain blurred cover and inherited lyrics font defaults',
    () {
      final skin = PlayerSkin.fromJson({
        'id': 'legacy',
        'name': 'Legacy',
        'background': 0xFF0F0F0F,
        'text': 0xFFF8F7F5,
        'accent': 0xFFFFFFFF,
        'cornerRadius': 16,
        'backgroundMotion': true,
        'motionDurationSeconds': 14,
        'visualizerBars': 32,
      });

      expect(skin.backgroundStyle, PlayerBackgroundStyle.blurredCover);
      expect(skin.separateLyricsFont, isFalse);
      expect(skin.lyricsFontFamily, isNull);
    },
  );
}
