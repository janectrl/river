import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:river/main.dart';
import 'package:river/player_skin.dart';
import 'package:river/player_skin_editor.dart';

Future<void> _waitForLibraryLoading(WidgetTester tester) async {
  final loading = find.byKey(const ValueKey('library-loading-screen'));
  for (
    var attempt = 0;
    attempt < 60 && loading.evaluate().isNotEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

const _windowManagerChannel = MethodChannel('window_manager');

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, (call) async {
          return call.method == 'isMaximized' ? false : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, null);
  });

  testWidgets('a new app opens the language welcome screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(RiverApp(preferences: preferences));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('river'), findsNothing);
    expect(find.byTooltip('Minimize window'), findsOneWidget);
    expect(find.byTooltip('Maximize window'), findsOneWidget);
    expect(find.byTooltip('Close window'), findsOneWidget);
    final background = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('welcome-background')),
    );
    expect(
      (background.decoration as BoxDecoration).color,
      const Color(0xFF0F0F0F),
    );

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('English'));
    await tester.pump();

    expect(preferences.getString('language_code'), 'en');
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('library loading screen replaces the startup greeting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'user_name': 'Mira',
      'language_code': 'en',
    });
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(RiverApp(preferences: preferences));
    final tickerMode = find.byKey(const ValueKey('startup-player-ticker-mode'));
    expect(tester.widget<TickerMode>(tickerMode).enabled, isFalse);
    expect(
      find.byKey(const ValueKey('library-loading-indicator')),
      findsOneWidget,
    );
    expect(find.textContaining('Good morning'), findsNothing);

    await _waitForLibraryLoading(tester);
    expect(tester.widget<TickerMode>(tickerMode).enabled, isTrue);
  });

  testWidgets('setup can add and remove multiple music folders', (
    tester,
  ) async {
    final selectedFolders = <String>[];
    final removedFolders = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          languageCode: 'en',
          initialMusicFolders: [r'C:\Music\One'],
          onPickFolder: () async => r'C:\Music\Two',
          onFolderSelected: (path) async {
            if (path != null) selectedFolders.add(path);
          },
          onFolderRemoved: (path) async => removedFolders.add(path),
          onContinue: () async {},
          onConnectLastFm: (_) async => null,
        ),
      ),
    );

    expect(find.text(r'C:\Music\One'), findsOneWidget);
    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect(find.text(r'C:\Music\Two'), findsOneWidget);
    expect(selectedFolders, [r'C:\Music\Two']);

    await tester.tap(find.byTooltip('Remove folder').first);
    await tester.pumpAndSettle();
    expect(find.text(r'C:\Music\One'), findsNothing);
    expect(find.text(r'C:\Music\Two'), findsOneWidget);
    expect(removedFolders, [r'C:\Music\One']);
  });

  testWidgets('player controls stay below the custom window buttons', (
    tester,
  ) async {
    if (!Platform.isWindows) return;

    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'user_name': 'Mira',
      'language_code': 'en',
    });
    final preferences = await SharedPreferences.getInstance();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in [const Size(1000, 760), const Size(720, 620)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(RiverApp(preferences: preferences));
      await _waitForLibraryLoading(tester);
      await tester.pumpAndSettle();

      final windowBar = tester.getRect(
        find.byKey(const ValueKey('river-window-bar')),
      );
      final playerSettings = tester.getRect(find.byTooltip('river settings'));
      expect(playerSettings.top, greaterThanOrEqualTo(windowBar.bottom));
      expect(playerSettings.bottom, lessThan(size.height));
      final windowControlsOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('window-controls-opacity')),
      );
      expect(windowControlsOpacity.opacity, 0);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: size.width.round(),
      );
      await mouse.addPointer(location: Offset(size.width - 24, 20));
      await mouse.moveTo(Offset(size.width - 24, 20));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('window-controls-opacity')),
            )
            .opacity,
        1,
      );
      await mouse.removePointer();
    }
  });

  testWidgets('left navigation stays clickable with lyrics open', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'user_name': 'Mira',
      'language_code': 'en',
    });
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(RiverApp(preferences: preferences));
    await _waitForLibraryLoading(tester);
    await tester.tap(find.byTooltip('Show lyrics'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();

    expect(find.text('river settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected system font survives restart and font-list fallback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'user_name': 'Mira',
      'language_code': 'en',
    });
    final preferences = await SharedPreferences.getInstance();
    const fontChannel = MethodChannel('river/system_fonts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var availableFonts = <String>['Inter', 'Arial'];
    messenger.setMockMethodCallHandler(fontChannel, (call) async {
      return availableFonts;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(fontChannel, null));

    await tester.pumpWidget(RiverApp(preferences: preferences));
    await _waitForLibraryLoading(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byType(DropdownButtonFormField<String>).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arial').last);
    await tester.pumpAndSettle();
    expect(preferences.getString('font_family'), 'Arial');

    await tester.ensureVisible(find.text('Done').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    availableFonts = ['Inter'];
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(RiverApp(preferences: preferences));
    await _waitForLibraryLoading(tester);
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme!.textTheme.bodyMedium!.fontFamily, 'Arial');
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final fontPicker = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last,
    );
    expect(fontPicker.initialValue, 'Arial');
  });

  testWidgets('custom player skins persist and reload with their name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'user_name': 'Mira',
      'language_code': 'en',
    });
    final preferences = await SharedPreferences.getInstance();
    const fontChannel = MethodChannel('river/system_fonts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      fontChannel,
      (call) async => ['Inter', 'Arial'],
    );
    addTearDown(() => messenger.setMockMethodCallHandler(fontChannel, null));

    await tester.pumpWidget(RiverApp(preferences: preferences));
    await _waitForLibraryLoading(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    final saveSkinButton = find.text('Save as a new skin');
    await tester.ensureVisible(saveSkinButton);
    await tester.tap(saveSkinButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Soft mix');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();

    final separateLyricsFont = find.widgetWithText(
      SwitchListTile,
      'Use a separate lyrics font',
    );
    await tester.ensureVisible(separateLyricsFont);
    await tester.tap(separateLyricsFont);
    await tester.pumpAndSettle();
    final lyricsFontPicker = find.byKey(const ValueKey('lyrics-font-null'));
    await tester.ensureVisible(lyricsFontPicker);
    final lyricsFontDropdown = tester.widget<DropdownButtonFormField<String>>(
      lyricsFontPicker,
    );
    lyricsFontDropdown.onChanged!('Arial');
    await tester.pumpAndSettle();
    final backgroundPicker = find.byType(
      DropdownButtonFormField<PlayerBackgroundStyle>,
    );
    await tester.ensureVisible(backgroundPicker);
    await tester.tap(backgroundPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album color tones').last);
    await tester.pumpAndSettle();

    final savedSkins = preferences.getString('player_skins_v1');
    expect(savedSkins, contains('Soft mix'));
    expect(savedSkins, contains('"backgroundStyle":"coverTones"'));
    expect(savedSkins, contains('"separateLyricsFont":true'));
    expect(savedSkins, contains('"lyricsFontFamily":"Arial"'));
    expect(preferences.getString('active_player_skin_v1'), isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(RiverApp(preferences: preferences));
    await _waitForLibraryLoading(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('river settings'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Use a separate lyrics font'),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>).last,
          )
          .initialValue,
      'Arial',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<PlayerBackgroundStyle>>(
            find.byType(DropdownButtonFormField<PlayerBackgroundStyle>),
          )
          .initialValue,
      PlayerBackgroundStyle.coverTones,
    );
    final activeSkinDropdown = find.descendant(
      of: find.byType(PlayerSkinEditor),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    await tester.ensureVisible(activeSkinDropdown);
    await tester.tap(activeSkinDropdown);
    await tester.pumpAndSettle();
    expect(find.text('Soft mix'), findsNWidgets(2));
  });

  testWidgets('cycling welcome greeting keeps one stable semantics node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(onLanguageSelected: (_) {}, onContinue: (_) {}),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1700));

    final initialGreeting = tester.getSemantics(find.bySemanticsLabel('Hello'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 800));

    final nextGreeting = tester.getSemantics(find.bySemanticsLabel('Hola'));
    expect(nextGreeting.id, initialGreeting.id);
    semantics.dispose();
  });

  testWidgets('river theme uses white accents and exact charcoal surfaces', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(RiverApp(preferences: preferences));
    final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;

    expect(theme.scaffoldBackgroundColor, const Color(0xFF0F0F0F));
    expect(theme.colorScheme.primary, Colors.white);
    expect(theme.colorScheme.secondary, Colors.white);
    expect(theme.colorScheme.tertiary, Colors.white);
    expect(theme.colorScheme.surface, const Color(0xFF0F0F0F));
    expect(theme.colorScheme.surfaceContainerHighest, const Color(0xFF0F0F0F));
    expect(theme.dialogTheme.backgroundColor, const Color(0xFF0F0F0F));
    expect(theme.progressIndicatorTheme.color, Colors.white);
  });

  testWidgets('a previously completed setup still shows missing name screens', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'onboarding_step': 2,
      'language_code': 'ru',
    });
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(RiverApp(preferences: preferences));
    expect(find.text('Как тебя зовут, пользователь?'), findsNothing);
    await tester.pump(const Duration(milliseconds: 112));
    final initialTyping = tester
        .widget<Text>(find.byKey(const ValueKey('typewriter-text')))
        .data!;
    expect(initialTyping, isNotEmpty);
    expect(initialTyping, isNot('Как тебя зовут, пользователь?'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('typewriter-text'))).data,
      isNot('Как тебя зовут, пользователь?'),
    );

    await tester.enterText(find.byType(TextField), 'Катя');
    await tester.pump();
    expect(find.text('Как тебя зовут, Катя?'), findsOneWidget);
    await tester.tap(find.text('Продолжить'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Добро пожаловать в river, Катя!'), findsOneWidget);

    await tester.tap(find.text('Начать слушать'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(preferences.getBool('onboarding_complete'), isTrue);
    expect(preferences.getString('user_name'), 'Катя');
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('language choice reveals a localized continue button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? selectedLanguage;
    String? continuedLanguage;
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(
          onLanguageSelected: (code) => selectedLanguage = code,
          onContinue: (code) => continuedLanguage = code,
        ),
      ),
    );

    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('Choose your language'), findsOneWidget);

    await tester.tap(find.text('Русский'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(selectedLanguage, 'ru');
    expect(find.text('Выберите язык'), findsOneWidget);
    expect(find.text('Продолжить'), findsOneWidget);

    await tester.tap(find.text('Продолжить'));
    expect(continuedLanguage, 'ru');
  });

  testWidgets('welcome greeting cycles through supported languages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(onLanguageSelected: (_) {}, onContinue: (_) {}),
      ),
    );
    expect(find.text('Hello'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Hola'), findsOneWidget);
  });

  testWidgets('welcome greeting and language choices fade in sequentially', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeScreen(onLanguageSelected: (_) {}, onContinue: (_) {}),
      ),
    );

    var greetingFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('welcome-greeting-fade')),
    );
    var languageFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('welcome-language-picker-fade')),
    );
    expect(greetingFade.opacity.value, 0);
    expect(languageFade.opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 400));
    greetingFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('welcome-greeting-fade')),
    );
    languageFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('welcome-language-picker-fade')),
    );
    expect(greetingFade.opacity.value, greaterThan(0));
    expect(greetingFade.opacity.value, lessThan(1));
    expect(languageFade.opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 400));
    languageFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('welcome-language-picker-fade')),
    );
    expect(languageFade.opacity.value, greaterThan(0));
    expect(languageFade.opacity.value, lessThan(1));
  });

  testWidgets(
    'name screen localizes the question and animates the typed name',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? continuedName;
      await tester.pumpWidget(
        MaterialApp(
          home: NameScreen(
            languageCode: 'ru',
            onContinue: (name) async => continuedName = name,
          ),
        ),
      );
      final background = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('name-background')),
      );
      expect(
        (background.decoration as BoxDecoration).color,
        const Color(0xFF0F0F0F),
      );
      expect(find.text('Как тебя зовут, пользователь?'), findsNothing);
      await tester.pump(const Duration(milliseconds: 112));
      final initialTyping = tester
          .widget<Text>(find.byKey(const ValueKey('typewriter-text')))
          .data!;
      expect(initialTyping, isNotEmpty);
      expect(initialTyping, isNot('Как тебя зовут, пользователь?'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('typewriter-text'))).data,
        isNot('Как тебя зовут, пользователь?'),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Как тебя зовут, пользователь?'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      await tester.enterText(find.byType(TextField), 'Лена');
      await tester.pump();
      expect(find.text('Как тебя зовут, Лена?'), findsOneWidget);

      await tester.tap(find.text('Продолжить'));
      await tester.pump();
      expect(continuedName, 'Лена');
    },
  );

  testWidgets('celebration screen shows the localized personal welcome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var continued = false;
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomeCelebrationScreen(
          languageCode: 'ru',
          name: 'Лена',
          onContinue: () async => continued = true,
        ),
      ),
    );
    final background = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('celebration-background')),
    );
    expect(
      (background.decoration as BoxDecoration).color,
      const Color(0xFF0F0F0F),
    );
    expect(find.text('Добро пожаловать в river, Лена!'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    final initialTyping = tester
        .widget<Text>(find.byKey(const ValueKey('typewriter-text')))
        .data!;
    expect(initialTyping, isNotEmpty);
    expect(initialTyping, isNot('Добро пожаловать в river, Лена!'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('typewriter-text'))).data,
      isNot('Добро пожаловать в river, Лена!'),
    );

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Добро пожаловать в river, Лена!'), findsOneWidget);
    var overlay = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('welcome-exit-overlay')),
    );
    expect((overlay.decoration as BoxDecoration).color!.a, 0);

    await tester.tap(find.text('Начать слушать'));
    await tester.pump();
    expect(continued, isFalse);

    await tester.pump(const Duration(milliseconds: 300));
    overlay = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('welcome-exit-overlay')),
    );
    expect((overlay.decoration as BoxDecoration).color!.a, greaterThan(0));
    expect((overlay.decoration as BoxDecoration).color!.a, lessThan(1));

    await tester.pump(const Duration(milliseconds: 400));
    expect(continued, isTrue);
  });

  testWidgets('setup saves a chosen folder before continuing', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? savedFolder;
    var continued = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          languageCode: 'en',
          onPickFolder: () async => r'C:\Music',
          onFolderSelected: (path) async {
            savedFolder = path;
          },
          onConnectLastFm: (_) async => null,
          onContinue: () async {
            continued = true;
          },
        ),
      ),
    );
    final background = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('setup-background')),
    );
    expect(
      (background.decoration as BoxDecoration).color,
      const Color(0xFF0F0F0F),
    );

    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect(savedFolder, r'C:\Music');
    expect(find.text(r'C:\Music'), findsOneWidget);

    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(continued, isTrue);
  });

  testWidgets('welcome screen fits minimum and fullscreen window sizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in [const Size(720, 620), const Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: WelcomeScreen(onLanguageSelected: (_) {}, onContinue: (_) {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: NameScreen(languageCode: 'en', onContinue: (_) async {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: WelcomeCelebrationScreen(
            languageCode: 'en',
            name: 'River listener',
            onContinue: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull);
    }
  });
}
