import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_discord/dart_discord_presence.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'app_localizations.dart';
import 'artwork_palette.dart';
import 'audio_equalizer.dart';
import 'audio_visualizer.dart';
import 'discord_presence_client.dart';
import 'last_fm_service.dart';
import 'library_search.dart';
import 'lyrics.dart';
import 'lyrics_service.dart';
import 'music_folder_metadata.dart';
import 'player_backdrop.dart';
import 'playback_shortcuts.dart';
import 'player_skin.dart';
import 'player_skin_editor.dart';
import 'track_metadata_overrides.dart';

const _artworkProcessingVersion = 3;

Map<String, Object?> _readTrackMetadata(String path) {
  final file = File(path);
  final tags = readMetadata(file, getImage: true);
  final extendedTags = readAllMetadata(file, getImage: false);
  return {
    'title': tags.title,
    'artist': tags.artist,
    'album': tags.album,
    'albumArtist': tags.albumArtist,
    'trackNumber': tags.trackNumber,
    'trackTotal': tags.trackTotal,
    'discNumber': tags.discNumber,
    'discTotal': tags.totalDisc,
    'year': tags.year?.year,
    'genre': tags.genres.isEmpty ? null : tags.genres.first,
    'performers': tags.performers.isEmpty ? null : tags.performers.join('; '),
    'language': tags.language,
    'lyrics': tags.lyrics,
    'durationMs': tags.duration?.inMilliseconds,
    ..._additionalTrackMetadata(extendedTags),
    if (tags.pictures.isNotEmpty)
      'artwork': prepareArtwork(tags.pictures.first.bytes),
    'mbid': _musicBrainzIdFromTags(extendedTags),
  };
}

Map<String, dynamic> _decodeTrackLibraryCache(String encoded) {
  final json = utf8.decode(gzip.decode(base64Decode(encoded)));
  final decoded = jsonDecode(json);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid track library cache');
  }
  return decoded;
}

String _encodeTrackLibraryCache(Map<String, dynamic> cache) {
  return base64Encode(gzip.encode(utf8.encode(jsonEncode(cache))));
}

Color _contrastingForeground(Color color) =>
    color.computeLuminance() > 0.45 ? Colors.black : Colors.white;

Map<String, Object?> _additionalTrackMetadata(Object tags) => switch (tags) {
  Mp3Metadata metadata => {
    'composer': metadata.composer,
    'genre': metadata.genres.isEmpty
        ? metadata.contentType
        : metadata.genres.join('; '),
    'publisher': metadata.publisher,
    'copyright': metadata.copyrightMessage,
    'comment': metadata.comments.isEmpty
        ? null
        : metadata.comments.map((comment) => comment.text).join('\n'),
    'isrc': metadata.isrc,
    'bpm': metadata.bpm,
    'albumArtist': metadata.bandOrOrchestra,
    'discNumber': metadata.discNumber,
    'trackTotal': metadata.trackTotal,
  },
  VorbisMetadata metadata => {
    'composer': metadata.composer.join('; '),
    'genre': metadata.genres.join('; '),
    'publisher': metadata.unknowns['PUBLISHER'],
    'copyright': metadata.copyright.join('; '),
    'comment': metadata.comment.join('\n'),
    'isrc': metadata.isrc.join('; '),
  },
  ApeMetadata metadata => {
    'composer': metadata.composer,
    'genre': metadata.genres.join('; '),
    'comment': metadata.comment,
    'albumArtist': metadata.albumArtist,
    'discNumber': metadata.discNumber,
  },
  RiffMetadata metadata => {
    'genre': metadata.genre,
    'comment': metadata.comment,
    'publisher': metadata.publisher,
    'copyright': metadata.copyright,
  },
  Mp4Metadata metadata => {
    'genre': metadata.genre,
    'discNumber': metadata.discNumber,
    'trackTotal': metadata.totalTracks,
    'discTotal': metadata.totalDiscs,
  },
  _ => const {},
};

String? _musicBrainzIdFromTags(Object tags) {
  final fields = switch (tags) {
    Mp3Metadata metadata => metadata.customMetadata,
    VorbisMetadata metadata => metadata.unknowns,
    ApeMetadata metadata => metadata.unknowns,
    _ => null,
  };
  if (fields == null) return null;

  for (final entry in fields.entries) {
    final normalizedKey = entry.key.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (normalizedKey == 'musicbrainztrackid' &&
        entry.value.trim().isNotEmpty) {
      return entry.value.trim();
    }
  }
  return null;
}

EdgeInsets _windowBarSafeAreaMinimum() => EdgeInsets.only(
  top: Platform.isWindows && !_windowFullscreen.value
      ? _RiverWindowBar.height
      : 0,
);

final ValueNotifier<bool> _windowFullscreen = ValueNotifier(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 128;
  imageCache.maximumSizeBytes = 32 * 1024 * 1024;
  final preferences = await SharedPreferences.getInstance();
  await windowManager.ensureInitialized();

  const windowSize = Size(1000, 760);
  const minimumWindowSize = Size(720, 620);
  final windowOptions = WindowOptions(
    size: windowSize,
    center: true,
    title: 'river',
    titleBarStyle: Platform.isWindows ? TitleBarStyle.hidden : null,
    windowButtonVisibility: Platform.isWindows ? false : null,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setMinimumSize(minimumWindowSize);
    await windowManager.setSize(windowSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(RiverApp(preferences: preferences));
}

String _encodeListeningStats(Map<String, dynamic> stats) => jsonEncode(stats);

class RiverApp extends StatefulWidget {
  const RiverApp({required this.preferences, super.key});

  final SharedPreferences preferences;

  @override
  State<RiverApp> createState() => _RiverAppState();
}

class _RiverAppState extends State<RiverApp> {
  static const _systemFontsChannel = MethodChannel('river/system_fonts');

  bool _startupLibraryReady = false;
  late String? _languageCode = widget.preferences.getString('language_code');
  late int _onboardingStep =
      widget.preferences.getBool('onboarding_complete') ?? false
      ? (widget.preferences.getString('user_name')?.isNotEmpty ?? false ? 4 : 2)
      : widget.preferences.getInt('onboarding_step') ?? 0;
  late String? _musicFolder = widget.preferences.getString('music_folder');
  late String? _userName = widget.preferences.getString('user_name');
  late String _fontFamily =
      widget.preferences.getString('font_family') ?? 'Inter';
  late double _fontScale = widget.preferences.getDouble('font_scale') ?? 1;
  PlayerSkin _skin = PlayerSkin.defaultSkin;
  List<PlayerSkin> _customSkins = [];
  List<String> _systemFonts = const ['Inter'];
  String? _fontLoadError;

  @override
  void initState() {
    super.initState();
    _loadSavedSkins();
    _systemFonts = {'Inter', _fontFamily}.toList();
    unawaited(_loadSystemFonts());
  }

  List<PlayerSkin> get _skinProfiles => [
    ...PlayerSkin.presets,
    ..._customSkins,
  ];

  void _loadSavedSkins() {
    final encoded = widget.preferences.getString('player_skins_v1');
    if (encoded != null) {
      try {
        final value = jsonDecode(encoded);
        if (value is List) {
          _customSkins = [
            for (final item in value)
              if (item is Map)
                PlayerSkin.fromJson(Map<String, Object?>.from(item)),
          ];
        }
      } on FormatException {
        _customSkins = [];
      } on TypeError {
        _customSkins = [];
      }
    }

    final activeId = widget.preferences.getString('active_player_skin_v1');
    final storedSkin = _skinProfiles.where((skin) => skin.id == activeId);
    if (storedSkin.isNotEmpty) {
      _skin = storedSkin.first;
      _fontFamily = _skin.fontFamily ?? _fontFamily;
      _fontScale = _skin.fontScale ?? _fontScale;
    }
  }

  Future<void> _persistSkinSettings() async {
    final profilesSaved = await widget.preferences.setString(
      'player_skins_v1',
      jsonEncode(_customSkins.map((skin) => skin.toJson()).toList()),
    );
    final activeSaved = await widget.preferences.setString(
      'active_player_skin_v1',
      _skin.id,
    );
    final fontSaved = await widget.preferences.setString(
      'font_family',
      _fontFamily,
    );
    final scaleSaved = await widget.preferences.setDouble(
      'font_scale',
      _fontScale,
    );
    if (!profilesSaved || !activeSaved || !fontSaved || !scaleSaved) {
      throw Exception('Could not save your appearance settings.');
    }
  }

  Future<void> _selectSkin(PlayerSkin skin) async {
    setState(() {
      _skin = skin;
      _fontFamily = skin.fontFamily ?? _fontFamily;
      _fontScale = skin.fontScale ?? _fontScale;
    });
    await _persistSkinSettings();
  }

  void _updateSkin(PlayerSkin updated) {
    setState(() {
      final isBuiltIn = PlayerSkin.presets.any((skin) => skin.id == _skin.id);
      final next = isBuiltIn
          ? updated.copyWith(
              id: 'custom-current',
              name: RiverLocalizations(_languageCode ?? 'en')
                  .text('skinCustom'),
              fontFamily: _fontFamily,
              fontScale: _fontScale,
            )
          : updated;
      _skin = next;
      _customSkins.removeWhere((skin) => skin.id == next.id);
      _customSkins.add(next);
    });
  }

  Future<void> _saveSkinAs(String name) async {
    final skin = _skin.copyWith(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      fontFamily: _fontFamily,
      fontScale: _fontScale,
    );
    setState(() {
      _skin = skin;
      _customSkins.add(skin);
    });
    await _persistSkinSettings();
  }

  Future<void> _deleteCurrentSkin() async {
    setState(() {
      _customSkins.removeWhere((skin) => skin.id == _skin.id);
      _skin = PlayerSkin.defaultSkin;
      _fontFamily = 'Inter';
      _fontScale = 1;
    });
    await _persistSkinSettings();
  }

  Future<void> _commitSkinChanges() async {
    try {
      await _persistSkinSettings();
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _fontLoadError = RiverLocalizations(_languageCode ?? 'en')
                  .text('skinSaveError'),
        );
      }
    }
  }

  Future<void> _loadSystemFonts() async {
    try {
      final fonts = await _systemFontsChannel.invokeListMethod<String>(
        'listFonts',
      );
      if (!mounted || fonts == null) return;
      setState(() {
        _systemFonts = {
          'Inter',
          _fontFamily,
          ...fonts.where((font) => font.trim().isNotEmpty),
        }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _fontLoadError = null;
      });
    } on PlatformException {
      if (mounted) {
        setState(
          () =>
              _fontLoadError = RiverLocalizations(_languageCode ?? 'en')
                  .text('fontLoadError'),
        );
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () =>
              _fontLoadError = RiverLocalizations(_languageCode ?? 'en')
                  .text('fontLoadError'),
        );
      }
    }
  }

  Future<void> _saveFontFamily(String family) async {
    final saved = await widget.preferences.setString('font_family', family);
    if (!saved) throw Exception('Could not save the selected font.');
    if (mounted) {
      setState(() => _fontFamily = family);
      _updateSkin(_skin.copyWith(fontFamily: family, fontScale: _fontScale));
      await _persistSkinSettings();
    }
  }

  Future<void> _saveFontScale(double scale) async {
    final saved = await widget.preferences.setDouble('font_scale', scale);
    if (!saved) throw Exception('Could not save the text size.');
    if (mounted) {
      setState(() => _fontScale = scale);
      _updateSkin(_skin.copyWith(fontFamily: _fontFamily, fontScale: scale));
      await _persistSkinSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: RiverLocalizations(_languageCode ?? 'en').text('appTitle'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: _fontFamily,
        scaffoldBackgroundColor: _skin.backgroundColor,
        colorScheme:
            ColorScheme.dark(
              primary: _skin.accentColor,
              onPrimary: _contrastingForeground(_skin.accentColor),
              secondary: _skin.accentColor,
              onSecondary: _contrastingForeground(_skin.accentColor),
              surface: _skin.backgroundColor,
              onSurface: _skin.textColor,
              error: const Color(0xFFFFB4AB),
              onError: const Color(0xFF690005),
            ).copyWith(
              primaryContainer: _skin.accentColor,
              onPrimaryContainer: _contrastingForeground(_skin.accentColor),
              secondaryContainer: _skin.accentColor,
              onSecondaryContainer: _contrastingForeground(_skin.accentColor),
              tertiary: _skin.accentColor,
              onTertiary: _contrastingForeground(_skin.accentColor),
              tertiaryContainer: _skin.accentColor,
              onTertiaryContainer: _contrastingForeground(_skin.accentColor),
              outline: _skin.textColor.withValues(alpha: 0.48),
              outlineVariant: _skin.textColor.withValues(alpha: 0.28),
              surfaceDim: _skin.backgroundColor,
              surfaceBright: _skin.backgroundColor,
              surfaceContainerLowest: _skin.backgroundColor,
              surfaceContainerLow: _skin.backgroundColor,
              surfaceContainer: _skin.backgroundColor,
              surfaceContainerHigh: _skin.backgroundColor,
              surfaceContainerHighest: _skin.backgroundColor,
            ),
        iconTheme: IconThemeData(color: _skin.textColor),
        dialogTheme: DialogThemeData(
          backgroundColor: _skin.backgroundColor,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: _skin.textColor,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: TextStyle(
            color: _skin.textColor.withValues(alpha: 0.88),
            fontSize: 15,
            height: 1.5,
          ),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Colors.white,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: _skin.accentColor,
          inactiveTrackColor: _skin.textColor.withValues(alpha: 0.24),
          thumbColor: _skin.accentColor,
          overlayColor: _skin.accentColor.withValues(alpha: 0.12),
        ),
      ),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final scaledChild = MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              media.textScaler.scale(1) * _fontScale,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
        if (!Platform.isWindows) return scaledChild;
        return _RiverWindowFrame(
          languageCode: _languageCode ?? 'en',
          child: scaledChild,
        );
      },
      home: switch (_onboardingStep) {
        0 => WelcomeScreen(
          initialLanguageCode: _languageCode,
          onLanguageSelected: (code) {
            _languageCode = code;
            unawaited(widget.preferences.setString('language_code', code));
          },
          onContinue: (code) {
            _languageCode = code;
            unawaited(widget.preferences.setString('language_code', code));
            unawaited(widget.preferences.setInt('onboarding_step', 1));
            setState(() => _onboardingStep = 1);
          },
        ),
        1 => SetupScreen(
          languageCode: _languageCode ?? 'en',
          initialMusicFolder: _musicFolder,
          initialMusicFolders:
              widget.preferences.getStringList('music_folders') ?? const [],
          onFolderSelected: (path) async {
            if (path == null) return;
            final folders = {
              ...?widget.preferences.getStringList('music_folders'),
              ?_musicFolder,
              path,
            }.toList();
            final foldersSaved = await widget.preferences.setStringList(
              'music_folders',
              folders,
            );
            if (!foldersSaved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en')
                    .text('folderSaveError'),
              );
            }
            if (folders.isNotEmpty) {
              final preferredFolder = _musicFolder ?? folders.first;
              final legacySaved = await widget.preferences.setString(
                'music_folder',
                preferredFolder,
              );
              if (!legacySaved) {
                throw Exception(
                  RiverLocalizations(_languageCode ?? 'en')
                      .text('folderSaveError'),
                );
              }
              if (mounted && _musicFolder == null) {
                setState(() => _musicFolder = preferredFolder);
              }
            }
          },
          onFolderRemoved: (path) async {
            final folders = {
              ...?widget.preferences.getStringList('music_folders'),
              ?_musicFolder,
            }..remove(path);
            final saved = await widget.preferences.setStringList(
              'music_folders',
              folders.toList(),
            );
            if (!saved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en')
                    .text('folderSaveError'),
              );
            }
            if (_musicFolder == path) {
              if (folders.isEmpty) {
                final removed = await widget.preferences.remove('music_folder');
                if (!removed) {
                  throw Exception(
                    RiverLocalizations(_languageCode ?? 'en')
                        .text('folderSaveError'),
                  );
                }
                if (mounted) setState(() => _musicFolder = null);
              } else {
                final replacement = folders.first;
                final saved = await widget.preferences.setString(
                  'music_folder',
                  replacement,
                );
                if (!saved) {
                  throw Exception(
                    RiverLocalizations(_languageCode ?? 'en')
                        .text('folderSaveError'),
                  );
                }
                if (mounted) setState(() => _musicFolder = replacement);
              }
            }
          },
          onContinue: () async {
            final saved = await widget.preferences.setInt('onboarding_step', 2);
            if (!saved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en').text('saveError'),
              );
            }
            if (mounted) setState(() => _onboardingStep = 2);
          },
        ),
        2 => NameScreen(
          languageCode: _languageCode ?? 'en',
          initialName: _userName,
          onContinue: (name) async {
            final nameSaved = await widget.preferences.setString(
              'user_name',
              name,
            );
            if (!nameSaved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en').text('saveError'),
              );
            }
            final stepSaved = await widget.preferences.setInt(
              'onboarding_step',
              3,
            );
            if (!stepSaved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en').text('saveError'),
              );
            }
            _userName = name;
            if (mounted) setState(() => _onboardingStep = 3);
          },
        ),
        3 => WelcomeCelebrationScreen(
          languageCode: _languageCode ?? 'en',
          name: _userName ?? '',
          onContinue: () async {
            final stepSaved = await widget.preferences.setInt(
              'onboarding_step',
              4,
            );
            final completeSaved = await widget.preferences.setBool(
              'onboarding_complete',
              true,
            );
            if (!stepSaved || !completeSaved) {
              throw Exception(
                RiverLocalizations(_languageCode ?? 'en').text('saveError'),
              );
            }
            if (mounted) setState(() => _onboardingStep = 4);
          },
        ),
        _ => _LibraryLoadingOverlay(
          loadingLabel: RiverLocalizations(_languageCode ?? 'en')
              .text('libraryLoading'),
          libraryReady: _startupLibraryReady,
          child: PlayerScreen(
            languageCode: _languageCode ?? 'en',
            initialMusicFolder: _musicFolder,
            initialMusicFolders:
                widget.preferences.getStringList('music_folders') ?? const [],
            preferences: widget.preferences,
            onInitialLibraryLoaded: () {
              if (!mounted || _startupLibraryReady) return;
              setState(() => _startupLibraryReady = true);
            },
            systemFonts: _systemFonts,
            fontLoadError: _fontLoadError,
            fontFamily: _fontFamily,
            fontScale: _fontScale,
            skin: _skin,
            skinProfiles: _skinProfiles,
            onSkinSelected: _selectSkin,
            onSkinChanged: _updateSkin,
            onSkinCommit: _commitSkinChanges,
            onSkinSaveAs: _saveSkinAs,
            onSkinDelete: _deleteCurrentSkin,
            onFontFamilyChanged: _saveFontFamily,
            onFontScaleChanged: _saveFontScale,
          ),
        ),
      },
    );
  }
}

class _LibraryLoadingOverlay extends StatelessWidget {
  const _LibraryLoadingOverlay({
    required this.loadingLabel,
    required this.libraryReady,
    required this.child,
  });

  final String loadingLabel;
  final bool libraryReady;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        TickerMode(
          key: const ValueKey('startup-player-ticker-mode'),
          enabled: libraryReady,
          child: child,
        ),
        if (!libraryReady)
          ColoredBox(
            key: const ValueKey('library-loading-screen'),
            color: const Color(0xFF0F0F0F),
            child: Center(
              child: Semantics(
                container: true,
                liveRegion: true,
                label: loadingLabel,
                child: ExcludeSemantics(
                  child: SizedBox.square(
                    key: const ValueKey('library-loading-indicator'),
                    dimension: 72,
                    child: const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 6,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RiverWindowFrame extends StatefulWidget {
  const _RiverWindowFrame({required this.languageCode, required this.child});

  final String languageCode;
  final Widget child;

  @override
  State<_RiverWindowFrame> createState() => _RiverWindowFrameState();
}

class _RiverWindowFrameState extends State<_RiverWindowFrame> {
  late final OverlayEntry _entry = OverlayEntry(builder: _buildFrame);

  Widget _buildFrame(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: 6,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          ValueListenableBuilder<bool>(
            valueListenable: _windowFullscreen,
            builder: (context, fullScreen, _) => fullScreen
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.topCenter,
                    child: _RiverWindowBar(languageCode: widget.languageCode),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _RiverWindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child ||
        oldWidget.languageCode != widget.languageCode) {
      _entry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry]);
  }
}

class _RiverWindowBar extends StatefulWidget {
  static const height = 44.0;

  const _RiverWindowBar({required this.languageCode});

  final String languageCode;

  @override
  State<_RiverWindowBar> createState() => _RiverWindowBarState();
}

class _RiverWindowBarState extends State<_RiverWindowBar> with WindowListener {
  bool _isMaximized = false;
  bool _isHovered = false;

  RiverLocalizations get _localizations =>
      RiverLocalizations(widget.languageCode);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refreshMaximizedState());
  }

  @override
  void didUpdateWidget(covariant _RiverWindowBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.languageCode != widget.languageCode) setState(() {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximizedState() async {
    try {
      final isMaximized = await windowManager.isMaximized();
      if (mounted && isMaximized != _isMaximized) {
        setState(() => _isMaximized = isMaximized);
      }
    } on PlatformException catch (error) {
      debugPrint('Could not read the window maximized state: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Window manager is unavailable: $error');
    }
  }

  Future<void> _toggleMaximized() async {
    if (_isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _refreshMaximizedState();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        key: const ValueKey('river-window-bar'),
        width: 150,
        height: _RiverWindowBar.height,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                const Expanded(child: SizedBox.expand()),
                IgnorePointer(
                  ignoring: !_isHovered,
                  child: AnimatedOpacity(
                    key: const ValueKey('window-controls-opacity'),
                    opacity: _isHovered ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RiverWindowButton(
                          tooltip: _localizations.text('minimizeWindow'),
                          icon: Icons.remove_rounded,
                          onPressed: () => unawaited(windowManager.minimize()),
                        ),
                        _RiverWindowButton(
                          tooltip: _localizations.text(
                            _isMaximized ? 'restoreWindow' : 'maximizeWindow',
                          ),
                          icon: _isMaximized
                              ? Icons.filter_none_rounded
                              : Icons.crop_square_rounded,
                          onPressed: () => unawaited(_toggleMaximized()),
                        ),
                        _RiverWindowButton(
                          tooltip: _localizations.text('closeWindow'),
                          icon: Icons.close_rounded,
                          closeButton: true,
                          onPressed: () => unawaited(windowManager.close()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RiverWindowButton extends StatefulWidget {
  const _RiverWindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.closeButton = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool closeButton;

  @override
  State<_RiverWindowButton> createState() => _RiverWindowButtonState();
}

class _RiverWindowButtonState extends State<_RiverWindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.closeButton
        ? const Color(0xFFE5484D)
        : Colors.white.withValues(alpha: 0.11);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 48,
            height: 44,
            color: _hovered ? hoverColor : Colors.transparent,
            child: Icon(widget.icon, size: 18, color: const Color(0xFFF0F0F0)),
          ),
        ),
      ),
    );
  }
}

class _SetupCopy {
  const _SetupCopy({
    required this.title,
    required this.folderTitle,
    required this.folderDescription,
    required this.chooseFolder,
    required this.noFolder,
    required this.lastFmTitle,
    required this.lastFmDescription,
    required this.connect,
    required this.connected,
    required this.continueLabel,
    required this.later,
    required this.lastFmRequirements,
  });

  final String title;
  final String folderTitle;
  final String folderDescription;
  final String chooseFolder;
  final String noFolder;
  final String lastFmTitle;
  final String lastFmDescription;
  final String connect;
  final String connected;
  final String continueLabel;
  final String later;
  final String lastFmRequirements;
}

const _setupCopyByLanguage = <String, _SetupCopy>{
  'en': _SetupCopy(
    title: 'Make river yours',
    folderTitle: 'Your music folders',
    folderDescription: 'Add every folder where you keep your music.',
    chooseFolder: 'Add folder',
    noFolder: 'No folders added',
    lastFmTitle: 'Last.fm',
    lastFmDescription:
        'Connect your account to send now-playing and scrobbles.',
    connect: 'Connect Last.fm',
    connected: 'Connected',
    continueLabel: 'Continue',
    later: 'Set up later',
    lastFmRequirements: 'Connect your Last.fm account to enable scrobbling.',
  ),
  'es': _SetupCopy(
    title: 'Personaliza river',
    folderTitle: 'Tus carpetas de música',
    folderDescription: 'Añade todas las carpetas donde guardas música.',
    chooseFolder: 'Añadir carpeta',
    noFolder: 'No se han añadido carpetas',
    lastFmTitle: 'Last.fm',
    lastFmDescription:
        'Conecta tu cuenta para enviar reproducciones y scrobbles.',
    connect: 'Conectar Last.fm',
    connected: 'Conectado',
    continueLabel: 'Continuar',
    later: 'Configurar más tarde',
    lastFmRequirements:
        'Conecta tu cuenta de Last.fm para activar los scrobbles.',
  ),
  'ru': _SetupCopy(
    title: 'Настроим river',
    folderTitle: 'Папки с музыкой',
    folderDescription: 'Добавь все папки, где хранится твоя музыка.',
    chooseFolder: 'Добавить папку',
    noFolder: 'Папки не добавлены',
    lastFmTitle: 'Last.fm',
    lastFmDescription:
        'Подключи аккаунт для отправки текущего трека и скробблов.',
    connect: 'Подключить Last.fm',
    connected: 'Подключён',
    continueLabel: 'Продолжить',
    later: 'Настроить позже',
    lastFmRequirements: 'Подключи аккаунт Last.fm, чтобы включить скробблинг.',
  ),
  'uk': _SetupCopy(
    title: 'Налаштуймо river',
    folderTitle: 'Теки з музикою',
    folderDescription: 'Додай усі теки, де зберігається твоя музика.',
    chooseFolder: 'Додати теку',
    noFolder: 'Теки не додано',
    lastFmTitle: 'Last.fm',
    lastFmDescription:
        'Під’єднай акаунт, щоб надсилати поточний трек і скробли.',
    connect: 'Під’єднати Last.fm',
    connected: 'Під’єднано',
    continueLabel: 'Продовжити',
    later: 'Налаштувати пізніше',
    lastFmRequirements: 'Під’єднай акаунт Last.fm, щоб увімкнути скроблінг.',
  ),
  'zh': _SetupCopy(
    title: '设置你的 river',
    folderTitle: '音乐文件夹',
    folderDescription: '添加所有存放音乐的文件夹。',
    chooseFolder: '添加文件夹',
    noFolder: '尚未添加文件夹',
    lastFmTitle: 'Last.fm',
    lastFmDescription: '连接账号以发送正在播放信息和收听记录。',
    connect: '连接 Last.fm',
    connected: '已连接',
    continueLabel: '继续',
    later: '稍后设置',
    lastFmRequirements: '连接 Last.fm 账号以启用收听记录。',
  ),
};

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.languageCode,
    required this.onFolderSelected,
    required this.onContinue,
    this.initialMusicFolder,
    this.initialMusicFolders = const [],
    this.onFolderRemoved,
    this.onPickFolder,
    this.onConnectLastFm,
    super.key,
  });

  final String languageCode;
  final String? initialMusicFolder;
  final List<String> initialMusicFolders;
  final Future<void> Function(String? path) onFolderSelected;
  final Future<void> Function(String path)? onFolderRemoved;
  final Future<void> Function() onContinue;
  final Future<String?> Function()? onPickFolder;
  final Future<String?> Function(String? currentUsername)? onConnectLastFm;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final LastFmService? _lastFm = widget.onConnectLastFm == null
      ? LastFmService()
      : null;
  late final List<String> _musicFolders = {
    ...widget.initialMusicFolders,
    ?widget.initialMusicFolder,
  }.toList();
  String? _lastFmUsername;
  String? _error;
  bool _pickingFolder = false;
  bool _connectingLastFm = false;
  bool _finishing = false;

  _SetupCopy get _copy =>
      _setupCopyByLanguage[widget.languageCode] ?? _setupCopyByLanguage['en']!;

  @override
  void initState() {
    super.initState();
    _loadLastFmUsername();
  }

  @override
  void dispose() {
    _lastFm?.dispose();
    super.dispose();
  }

  Future<void> _loadLastFmUsername() async {
    final service = _lastFm;
    if (service == null) return;
    try {
      final username = await service.readConnectedUsername();
      if (mounted) setState(() => _lastFmUsername = username);
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _error = RiverLocalizations(widget.languageCode)
                  .text('lastFmUnavailable'),
        );
      }
    }
  }

  Future<void> _chooseMusicFolder() async {
    setState(() {
      _pickingFolder = true;
      _error = null;
    });
    try {
      final path =
          await (widget.onPickFolder?.call() ?? FilePicker.getDirectoryPath());
      if (!mounted || path == null) return;
      if (_musicFolders.any(
        (folder) => folder.toLowerCase() == path.toLowerCase(),
      )) {
        return;
      }
      await widget.onFolderSelected(path);
      if (!mounted) return;
      setState(() => _musicFolders.add(path));
    } on Exception catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = RiverLocalizations(widget.languageCode)
                  .text('folderReadError', {'error': error}),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingFolder = false);
    }
  }

  Future<void> _removeMusicFolder(String path) async {
    try {
      await widget.onFolderRemoved?.call(path);
      if (!mounted) return;
      setState(() => _musicFolders.remove(path));
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _error = RiverLocalizations(widget.languageCode)
                  .text('folderSaveError'),
        );
      }
    }
  }

  Future<void> _finishSetup() async {
    setState(() {
      _finishing = true;
      _error = null;
    });
    try {
      await widget.onContinue();
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Future<void> _connectLastFm() async {
    setState(() {
      _connectingLastFm = true;
      _error = null;
    });
    try {
      final username = widget.onConnectLastFm != null
          ? await widget.onConnectLastFm!(_lastFmUsername)
          : await showDialog<String>(
              context: context,
              builder: (context) => LastFmSettingsDialog(
                service: _lastFm!,
                initialUsername: _lastFmUsername,
                languageCode: widget.languageCode,
              ),
            );
      if (mounted && username != null) {
        setState(() => _lastFmUsername = username.isEmpty ? null : username);
      }
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _connectingLastFm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    final compact = MediaQuery.sizeOf(context).width < 720;
    final primaryText = const Color(0xFFF5F5F5);
    final secondaryText = const Color(0xFFD0D0D0);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            key: ValueKey('setup-background'),
            decoration: BoxDecoration(color: Color(0xFF0F0F0F)),
          ),
          SafeArea(
            minimum: _windowBarSafeAreaMinimum(),
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 22 : 40,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        copy.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: primaryText,
                          fontSize: compact ? 36 : 48,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1.5,
                        ),
                      ),
                      const SizedBox(height: 36),
                      _SetupSection(
                        title: copy.folderTitle,
                        description: copy.folderDescription,
                        content: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_musicFolders.isEmpty)
                              Text(
                                copy.noFolder,
                                style: TextStyle(
                                  color: secondaryText.withValues(alpha: 0.75),
                                  fontSize: 15,
                                ),
                              )
                            else
                              for (final folder in _musicFolders)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        CupertinoIcons.folder,
                                        color: Color(0xFFD0D0D0),
                                        size: 22,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Tooltip(
                                          message: folder,
                                          child: Text(
                                            folder,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: primaryText,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: RiverLocalizations(
                                          widget.languageCode,
                                        ).text('removeFolder'),
                                        onPressed: () =>
                                            _removeMusicFolder(folder),
                                        icon: const Icon(
                                          CupertinoIcons.minus_circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _pickingFolder
                                  ? null
                                  : _chooseMusicFolder,
                              icon: _pickingFolder
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(CupertinoIcons.folder_open),
                              label: Text(copy.chooseFolder),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: primaryText,
                                side: const BorderSide(
                                  color: Color(0xFF777777),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      _SetupSection(
                        title: copy.lastFmTitle,
                        description:
                            '${copy.lastFmDescription} ${copy.lastFmRequirements}',
                        content: LayoutBuilder(
                          builder: (context, constraints) {
                            final status = Row(
                              children: [
                                Icon(
                                  _lastFmUsername == null
                                      ? CupertinoIcons.cloud
                                      : CupertinoIcons.check_mark_circled,
                                  color: _lastFmUsername == null
                                      ? const Color(0xFFD0D0D0)
                                      : const Color(0xFFE0E0E0),
                                  size: 24,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _lastFmUsername ?? copy.connect,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: primaryText,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            );
                            final button = OutlinedButton(
                              onPressed: _connectingLastFm
                                  ? null
                                  : _connectLastFm,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: primaryText,
                                side: const BorderSide(
                                  color: Color(0xFF777777),
                                ),
                              ),
                              child: _connectingLastFm
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      _lastFmUsername == null
                                          ? copy.connect
                                          : copy.connected,
                                    ),
                            );
                            return constraints.maxWidth < 480
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      status,
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: button,
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      Expanded(child: status),
                                      const SizedBox(width: 12),
                                      button,
                                    ],
                                  );
                          },
                        ),
                      ),
                      if (_error case final error?) ...[
                        const SizedBox(height: 16),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFFFFC7C7),
                            fontSize: 14,
                          ),
                        ),
                      ],
                      const SizedBox(height: 32),
                      FilledButton(
                        onPressed: _finishing ? null : _finishSetup,
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.black,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          textStyle: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: _finishing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.black,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(copy.continueLabel),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _finishing ? null : _finishSetup,
                        style: TextButton.styleFrom(
                          foregroundColor: secondaryText,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(copy.later),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupSection extends StatelessWidget {
  const _SetupSection({
    required this.title,
    required this.description,
    required this.content,
  });

  final String title;
  final String description;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF555555)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFF5F5F5),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFFD0D0D0),
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          content,
        ],
      ),
    );
  }
}

class _WelcomeLanguage {
  const _WelcomeLanguage({
    required this.code,
    required this.label,
    required this.greeting,
    required this.choosePrompt,
    required this.continueLabel,
    required this.nameQuestionPrefix,
    required this.nameQuestionPlaceholder,
    required this.nameQuestionSuffix,
    required this.nameFieldHint,
    required this.nameSaveError,
    required this.welcomeMessage,
    required this.welcomeSaveError,
    required this.welcomeContinueLabel,
  });

  final String code;
  final String label;
  final String greeting;
  final String choosePrompt;
  final String continueLabel;
  final String nameQuestionPrefix;
  final String nameQuestionPlaceholder;
  final String nameQuestionSuffix;
  final String nameFieldHint;
  final String nameSaveError;
  final String welcomeMessage;
  final String welcomeSaveError;
  final String welcomeContinueLabel;
}

const _welcomeLanguages = [
  _WelcomeLanguage(
    code: 'en',
    label: 'English',
    greeting: 'Hello',
    choosePrompt: 'Choose your language',
    continueLabel: 'Continue',
    nameQuestionPrefix: "What's your name, ",
    nameQuestionPlaceholder: 'user',
    nameQuestionSuffix: '?',
    nameFieldHint: 'Type your name',
    nameSaveError: 'Could not save your name. Please try again.',
    welcomeMessage: 'Welcome to river, {name}!',
    welcomeSaveError: 'Could not save your setup. Please try again.',
    welcomeContinueLabel: 'Start listening',
  ),
  _WelcomeLanguage(
    code: 'es',
    label: 'Español',
    greeting: 'Hola',
    choosePrompt: 'Elige tu idioma',
    continueLabel: 'Continuar',
    nameQuestionPrefix: '¿Cómo te llamas, ',
    nameQuestionPlaceholder: 'usuario',
    nameQuestionSuffix: '?',
    nameFieldHint: 'Escribe tu nombre',
    nameSaveError: 'No se pudo guardar tu nombre. Inténtalo de nuevo.',
    welcomeMessage: 'Te damos la bienvenida a river, {name}.',
    welcomeSaveError:
        'No se pudo guardar la configuración. Inténtalo de nuevo.',
    welcomeContinueLabel: 'Empezar a escuchar',
  ),
  _WelcomeLanguage(
    code: 'ru',
    label: 'Русский',
    greeting: 'Привет',
    choosePrompt: 'Выберите язык',
    continueLabel: 'Продолжить',
    nameQuestionPrefix: 'Как тебя зовут, ',
    nameQuestionPlaceholder: 'пользователь',
    nameQuestionSuffix: '?',
    nameFieldHint: 'Напиши своё имя',
    nameSaveError: 'Не удалось сохранить имя. Попробуй ещё раз.',
    welcomeMessage: 'Добро пожаловать в river, {name}!',
    welcomeSaveError: 'Не удалось сохранить настройки. Попробуй ещё раз.',
    welcomeContinueLabel: 'Начать слушать',
  ),
  _WelcomeLanguage(
    code: 'uk',
    label: 'Українська',
    greeting: 'Привіт',
    choosePrompt: 'Оберіть мову',
    continueLabel: 'Продовжити',
    nameQuestionPrefix: 'Як тебе звати, ',
    nameQuestionPlaceholder: 'користувач',
    nameQuestionSuffix: '?',
    nameFieldHint: 'Введи своє ім’я',
    nameSaveError: 'Не вдалося зберегти ім’я. Спробуй ще раз.',
    welcomeMessage: 'Ласкаво просимо до river, {name}!',
    welcomeSaveError: 'Не вдалося зберегти налаштування. Спробуй ще раз.',
    welcomeContinueLabel: 'Почати слухати',
  ),
  _WelcomeLanguage(
    code: 'zh',
    label: '中文 · 普通话',
    greeting: '你好',
    choosePrompt: '选择你的语言',
    continueLabel: '继续',
    nameQuestionPrefix: '你叫什么名字，',
    nameQuestionPlaceholder: '朋友',
    nameQuestionSuffix: '？',
    nameFieldHint: '输入你的名字',
    nameSaveError: '无法保存名字，请重试。',
    welcomeMessage: '欢迎来到 river，{name}！',
    welcomeSaveError: '无法保存设置，请重试。',
    welcomeContinueLabel: '开始聆听',
  ),
];

class NameScreen extends StatefulWidget {
  const NameScreen({
    required this.languageCode,
    required this.onContinue,
    this.initialName,
    super.key,
  });

  final String languageCode;
  final String? initialName;
  final Future<void> Function(String name) onContinue;

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> with TickerProviderStateMixin {
  late final AnimationController _entranceMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final Animation<double> _contentOpacity = CurvedAnimation(
    parent: _entranceMotion,
    curve: Curves.easeOutCubic,
  );
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName ?? '',
  );
  String _name = '';
  String? _error;
  bool _saving = false;

  _WelcomeLanguage get _language => _welcomeLanguages.firstWhere(
    (language) => language.code == widget.languageCode,
    orElse: () => _welcomeLanguages.first,
  );

  @override
  void initState() {
    super.initState();
    _name = widget.initialName?.trim() ?? '';
    _entranceMotion.forward();
  }

  @override
  void dispose() {
    _entranceMotion.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onContinue(name);
    } on Exception {
      if (mounted) setState(() => _error = _language.nameSaveError);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = _language;
    final compact = MediaQuery.sizeOf(context).width < 680;
    final visibleName = _name.isEmpty
        ? language.nameQuestionPlaceholder
        : _name;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            key: ValueKey('name-background'),
            decoration: BoxDecoration(color: Color(0xFF0F0F0F)),
          ),
          SafeArea(
            minimum: _windowBarSafeAreaMinimum(),
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: constraints.maxWidth < 680 ? 24 : 48,
                    vertical: 32,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: FadeTransition(
                      opacity: _contentOpacity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            label:
                                '${language.nameQuestionPrefix}$visibleName'
                                '${language.nameQuestionSuffix}',
                            child: ExcludeSemantics(
                              child: _TypewriterText(
                                text:
                                    '${language.nameQuestionPrefix}$visibleName'
                                    '${language.nameQuestionSuffix}',
                                characterDelay: const Duration(
                                  milliseconds: 70,
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: const Color(0xFFF5F5F5),
                                  fontSize: compact ? 30 : 46,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                  letterSpacing: -1.1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 36),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: TextField(
                              controller: _nameController,
                              enabled: !_saving,
                              maxLength: 32,
                              textAlign: TextAlign.center,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.done,
                              onChanged: (value) => setState(() {
                                _name = value.trim();
                                _error = null;
                              }),
                              onSubmitted: (_) => _continue(),
                              style: const TextStyle(
                                color: Color(0xFFF5F5F5),
                                fontSize: 22,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                hintText: language.nameFieldHint,
                                hintStyle: const TextStyle(
                                  color: Color(0xFFBDBDBD),
                                ),
                                counterStyle: const TextStyle(
                                  color: Color(0xFFBDBDBD),
                                ),
                                filled: true,
                                fillColor: const Color(0xFF111111),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 20,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(
                                    color: const Color(0xFF666666),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_error case final error?) ...[
                            const SizedBox(height: 12),
                            Text(
                              error,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFFFD5D5),
                                fontSize: 14,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _name.trim().isEmpty || _saving
                                ? null
                                : _continue,
                            style: FilledButton.styleFrom(
                              foregroundColor: Colors.black,
                              backgroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFBDBDBD),
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 30 : 38,
                                vertical: 20,
                              ),
                              textStyle: TextStyle(
                                fontSize: compact ? 16 : 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(language.continueLabel),
                                const SizedBox(width: 12),
                                if (_saving)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      color: Colors.black,
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  const Icon(
                                    CupertinoIcons.arrow_right,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypewriterText extends StatefulWidget {
  const _TypewriterText({
    required this.text,
    required this.style,
    required this.textAlign,
    this.characterDelay = const Duration(milliseconds: 28),
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final Duration characterDelay;

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  Timer? _timer;
  late List<int> _runes;
  int _visibleRuneCount = 0;

  @override
  void initState() {
    super.initState();
    _runes = widget.text.runes.toList();
    _startTyping();
  }

  @override
  void didUpdateWidget(covariant _TypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _timer?.cancel();
    _timer = null;
    _runes = widget.text.runes.toList();
    _visibleRuneCount = _runes.length;
  }

  void _startTyping() {
    if (_runes.isEmpty) return;
    _timer = Timer.periodic(widget.characterDelay, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _visibleRuneCount++;
        if (_visibleRuneCount >= _runes.length) {
          timer.cancel();
          _timer = null;
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    String.fromCharCodes(_runes.take(_visibleRuneCount)),
    key: const ValueKey('typewriter-text'),
    textAlign: widget.textAlign,
    style: widget.style,
  );
}

class WelcomeCelebrationScreen extends StatefulWidget {
  const WelcomeCelebrationScreen({
    required this.languageCode,
    required this.name,
    required this.onContinue,
    super.key,
  });

  final String languageCode;
  final String name;
  final Future<void> Function() onContinue;

  @override
  State<WelcomeCelebrationScreen> createState() =>
      _WelcomeCelebrationScreenState();
}

class _WelcomeCelebrationScreenState extends State<WelcomeCelebrationScreen>
    with TickerProviderStateMixin {
  late final AnimationController _backgroundMotion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );
  late final AnimationController _entranceMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _exitMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );
  late final Animation<double> _contentOpacity = CurvedAnimation(
    parent: _entranceMotion,
    curve: const Interval(0, 0.78, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _buttonOpacity = CurvedAnimation(
    parent: _entranceMotion,
    curve: const Interval(0.5, 1, curve: Curves.easeOutCubic),
  );
  late final Animation<Offset> _contentOffset = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(_contentOpacity);
  bool _saving = false;
  String? _error;

  _WelcomeLanguage get _language => _welcomeLanguages.firstWhere(
    (language) => language.code == widget.languageCode,
    orElse: () => _welcomeLanguages.first,
  );

  @override
  void initState() {
    super.initState();
    _backgroundMotion.repeat();
    _entranceMotion.forward();
  }

  @override
  void dispose() {
    _backgroundMotion.dispose();
    _entranceMotion.dispose();
    _exitMotion.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    _backgroundMotion.stop();
    try {
      await _exitMotion.forward();
      await widget.onContinue();
    } on Exception {
      if (mounted) {
        await _exitMotion.reverse();
        _backgroundMotion.repeat();
        setState(() {
          _saving = false;
          _error = _language.welcomeSaveError;
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = _language;
    final compact = MediaQuery.sizeOf(context).width < 680;
    final name = widget.name.trim().isEmpty
        ? language.nameQuestionPlaceholder
        : widget.name.trim();
    final message = language.welcomeMessage.replaceFirst('{name}', name);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            key: ValueKey('celebration-background'),
            decoration: BoxDecoration(color: Color(0xFF0F0F0F)),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _WelcomeCelebrationPainter(_backgroundMotion),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _exitMotion,
                builder: (context, child) => DecoratedBox(
                  key: const ValueKey('welcome-exit-overlay'),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F0F).withValues(
                      alpha: Curves.easeInOut.transform(_exitMotion.value),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            minimum: _windowBarSafeAreaMinimum(),
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 24 : 48,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FadeTransition(
                        opacity: _contentOpacity,
                        child: SlideTransition(
                          position: _contentOffset,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.94,
                              end: 1,
                            ).animate(_contentOpacity),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Semantics(
                                  label: message,
                                  child: ExcludeSemantics(
                                    child: _TypewriterText(
                                      text: message,
                                      characterDelay: const Duration(
                                        milliseconds: 70,
                                      ),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: const Color(0xFFF5F5F5),
                                        fontFamily: 'Georgia',
                                        fontSize: compact ? 38 : 60,
                                        fontWeight: FontWeight.w600,
                                        height: 1.12,
                                        letterSpacing: compact ? -0.8 : -1.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 44),
                      AnimatedBuilder(
                        animation: _buttonOpacity,
                        builder: (context, child) => IgnorePointer(
                          ignoring: _buttonOpacity.value < 0.5 || _saving,
                          child: FadeTransition(
                            opacity: _buttonOpacity,
                            child: child,
                          ),
                        ),
                        child: Column(
                          children: [
                            if (_error case final error?) ...[
                              Text(
                                error,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFFFD5D5),
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            FilledButton(
                              onPressed: _saving ? null : _continue,
                              style: FilledButton.styleFrom(
                                foregroundColor: Colors.black,
                                backgroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(
                                  horizontal: compact ? 28 : 36,
                                  vertical: 20,
                                ),
                                textStyle: TextStyle(
                                  fontSize: compact ? 16 : 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(language.welcomeContinueLabel),
                                  const SizedBox(width: 12),
                                  if (_saving)
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.black,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    const Icon(
                                      CupertinoIcons.arrow_right,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeCelebrationPainter extends CustomPainter {
  _WelcomeCelebrationPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final phase = animation.value * math.pi * 2;
    for (var index = 0; index < 42; index++) {
      final x = ((index * 73) % 997) / 997 * size.width;
      final y = ((index * 193) % 991) / 991 * size.height;
      final pulse = (math.sin(phase + index * 1.73) + 1) / 2;
      final radius = 1.1 + pulse * (index % 5 == 0 ? 2.4 : 1.1);
      final paint = Paint()
        ..color = const Color(0xFFE0E0E0).withValues(alpha: 0.12 + pulse * 0.5);
      canvas.drawCircle(Offset(x, y), radius, paint);
      if (index % 7 == 0) {
        final ray = radius * 2.8;
        canvas.drawLine(
          Offset(x - ray, y),
          Offset(x + ray, y),
          paint..strokeWidth = 0.8,
        );
        canvas.drawLine(
          Offset(x, y - ray),
          Offset(x, y + ray),
          paint..strokeWidth = 0.8,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WelcomeCelebrationPainter oldDelegate) =>
      oldDelegate.animation != animation;
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    required this.onLanguageSelected,
    required this.onContinue,
    this.initialLanguageCode,
    super.key,
  });

  final String? initialLanguageCode;
  final ValueChanged<String> onLanguageSelected;
  final ValueChanged<String> onContinue;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entranceMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final Animation<double> _greetingOpacity = CurvedAnimation(
    parent: _entranceMotion,
    curve: const Interval(0, 0.64, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _pickerOpacity = CurvedAnimation(
    parent: _entranceMotion,
    curve: const Interval(0.34, 1, curve: Curves.easeOutCubic),
  );
  late final Animation<Offset> _pickerOffset = Tween<Offset>(
    begin: const Offset(0, 0.045),
    end: Offset.zero,
  ).animate(_pickerOpacity);
  Timer? _greetingTimer;
  String? _selectedLanguageCode;
  int _greetingIndex = 0;

  @override
  void initState() {
    super.initState();
    _entranceMotion.forward();
    _selectedLanguageCode = widget.initialLanguageCode;
    if (_selectedLanguageCode != null) {
      _greetingIndex = _welcomeLanguages.indexWhere(
        (language) => language.code == _selectedLanguageCode,
      );
      if (_greetingIndex < 0) _greetingIndex = 0;
    }
    _greetingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() {
        _greetingIndex = (_greetingIndex + 1) % _welcomeLanguages.length;
      });
    });
  }

  @override
  void dispose() {
    _greetingTimer?.cancel();
    _entranceMotion.dispose();
    super.dispose();
  }

  _WelcomeLanguage? get _selectedLanguage {
    for (final language in _welcomeLanguages) {
      if (language.code == _selectedLanguageCode) return language;
    }
    return null;
  }

  void _selectLanguage(String code) {
    setState(() => _selectedLanguageCode = code);
    widget.onLanguageSelected(code);
  }

  @override
  Widget build(BuildContext context) {
    final selectedLanguage = _selectedLanguage;
    final greeting = _welcomeLanguages[_greetingIndex].greeting;
    final prompt = selectedLanguage?.choosePrompt ?? 'Choose your language';
    final continueLabel = selectedLanguage?.continueLabel ?? 'Continue';

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            key: ValueKey('welcome-background'),
            decoration: BoxDecoration(color: Color(0xFF0F0F0F)),
          ),
          SafeArea(
            minimum: _windowBarSafeAreaMinimum(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 680;
                final horizontalPadding = compact ? 24.0 : 48.0;
                return Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: 32,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            container: true,
                            label: greeting,
                            child: SizedBox(
                              height: compact ? 112 : 150,
                              child: Center(
                                child: ExcludeSemantics(
                                  child: FadeTransition(
                                    key: const ValueKey(
                                      'welcome-greeting-fade',
                                    ),
                                    opacity: _greetingOpacity,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 720,
                                      ),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      transitionBuilder: (child, animation) =>
                                          FadeTransition(
                                            opacity: animation,
                                            child: child,
                                          ),
                                      child: Text(
                                        greeting,
                                        key: ValueKey(greeting),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: const Color(0xFFF5F5F5),
                                          fontSize: compact ? 64 : 92,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -3.5,
                                          height: 1,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _pickerOpacity,
                            builder: (context, child) => IgnorePointer(
                              ignoring: _pickerOpacity.value < 0.5,
                              child: ExcludeSemantics(
                                excluding: _pickerOpacity.value < 0.5,
                                child: child,
                              ),
                            ),
                            child: FadeTransition(
                              key: const ValueKey(
                                'welcome-language-picker-fade',
                              ),
                              opacity: _pickerOpacity,
                              child: SlideTransition(
                                position: _pickerOffset,
                                child: Column(
                                  children: [
                                    const SizedBox(height: 12),
                                    Text(
                                      prompt,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: const Color(0xFFD0D0D0),
                                        fontSize: compact ? 22 : 28,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        for (final language
                                            in _welcomeLanguages)
                                          _LanguageOption(
                                            language: language,
                                            selected:
                                                language.code ==
                                                _selectedLanguageCode,
                                            compact: compact,
                                            onTap: () =>
                                                _selectLanguage(language.code),
                                          ),
                                      ],
                                    ),
                                    AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      switchInCurve: Curves.easeOutCubic,
                                      transitionBuilder: (child, animation) =>
                                          FadeTransition(
                                            opacity: animation,
                                            child: SlideTransition(
                                              position: Tween<Offset>(
                                                begin: const Offset(0, 0.12),
                                                end: Offset.zero,
                                              ).animate(animation),
                                              child: child,
                                            ),
                                          ),
                                      child: selectedLanguage == null
                                          ? const SizedBox(
                                              key: ValueKey('no-language'),
                                              height: 72,
                                            )
                                          : Padding(
                                              key: ValueKey(
                                                'continue-${selectedLanguage.code}',
                                              ),
                                              padding: const EdgeInsets.only(
                                                top: 28,
                                              ),
                                              child: FilledButton(
                                                onPressed: () =>
                                                    widget.onContinue(
                                                      selectedLanguage.code,
                                                    ),
                                                style: FilledButton.styleFrom(
                                                  foregroundColor: Colors.black,
                                                  backgroundColor: Colors.white,
                                                  padding: EdgeInsets.symmetric(
                                                    horizontal: compact
                                                        ? 28
                                                        : 36,
                                                    vertical: 20,
                                                  ),
                                                  textStyle: TextStyle(
                                                    fontSize: compact ? 16 : 18,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(continueLabel),
                                                    const SizedBox(width: 12),
                                                    const Icon(
                                                      CupertinoIcons
                                                          .arrow_right,
                                                      size: 20,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.language,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final _WelcomeLanguage language;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: language.label,
      child: Material(
        color: selected ? Colors.white : const Color(0xFF111111),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            constraints: BoxConstraints(
              minWidth: compact ? 142 : 190,
              minHeight: 60,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? Colors.white : const Color(0xFF555555),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                    color: Colors.black,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  language.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? Colors.black : const Color(0xFFF0F0F0),
                    fontSize: compact ? 15 : 17,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef _LibraryTrackAction = ({
  bool editMetadata,
  bool addToQueue,
  String? playlist,
});

class _Track {
  const _Track({
    required this.path,
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.year,
    this.genre,
    this.composer,
    this.performers,
    this.publisher,
    this.copyright,
    this.comment,
    this.isrc,
    this.bpm,
    this.language,
    this.embeddedLyrics,
    this.mbid,
    this.taggedDuration,
    this.cover,
    this.backgroundArt,
    this.palettePrimary,
    this.paletteAccent,
    this.coverFile,
    this.backdropFile,
    this.lyrics = const [],
  });

  final String path;
  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final int? year;
  final String? genre;
  final String? composer;
  final String? performers;
  final String? publisher;
  final String? copyright;
  final String? comment;
  final String? isrc;
  final String? bpm;
  final String? language;
  final String? embeddedLyrics;
  final String? mbid;
  final Duration? taggedDuration;
  final Uint8List? cover;
  final Uint8List? backgroundArt;
  final int? palettePrimary;
  final int? paletteAccent;
  final String? coverFile;
  final String? backdropFile;
  final List<LyricLine> lyrics;

  ImageProvider? get coverImageProvider {
    if (cover case final bytes?) return MemoryImage(bytes);
    if (coverFile case final path?) return FileImage(File(path));
    return null;
  }

  ImageProvider? get backdropImageProvider {
    if (backgroundArt case final bytes?) return MemoryImage(bytes);
    if (backdropFile case final path?) return FileImage(File(path));
    return null;
  }

  Map<String, Object?> toCacheMap() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'trackNumber': trackNumber,
    'trackTotal': trackTotal,
    'discNumber': discNumber,
    'discTotal': discTotal,
    'year': year,
    'genre': genre,
    'composer': composer,
    'performers': performers,
    'publisher': publisher,
    'copyright': copyright,
    'comment': comment,
    'isrc': isrc,
    'bpm': bpm,
    'language': language,
    'embeddedLyrics': embeddedLyrics,
    'mbid': mbid,
    'taggedDurationMs': taggedDuration?.inMilliseconds,
    'palettePrimary': palettePrimary,
    'paletteAccent': paletteAccent,
  };

  factory _Track.fromCache(
    Map<String, dynamic> cache, {
    Uint8List? cover,
    Uint8List? backgroundArt,
    int? palettePrimary,
    int? paletteAccent,
    String? coverFile,
    String? backdropFile,
  }) => _Track(
    path: cache['path'] as String,
    title: cache['title'] as String,
    artist: cache['artist'] as String,
    album: cache['album'] as String?,
    albumArtist: cache['albumArtist'] as String?,
    trackNumber: cache['trackNumber'] as int?,
    trackTotal: cache['trackTotal'] as int?,
    discNumber: cache['discNumber'] as int?,
    discTotal: cache['discTotal'] as int?,
    year: cache['year'] as int?,
    genre: cache['genre'] as String?,
    composer: cache['composer'] as String?,
    performers: cache['performers'] as String?,
    publisher: cache['publisher'] as String?,
    copyright: cache['copyright'] as String?,
    comment: cache['comment'] as String?,
    isrc: cache['isrc'] as String?,
    bpm: cache['bpm'] as String?,
    language: cache['language'] as String?,
    embeddedLyrics: cache['embeddedLyrics'] as String?,
    mbid: cache['mbid'] as String?,
    taggedDuration: switch (cache['taggedDurationMs']) {
      final int milliseconds => Duration(milliseconds: milliseconds),
      _ => null,
    },
    cover: cover,
    backgroundArt: backgroundArt,
    palettePrimary: palettePrimary ?? cache['palettePrimary'] as int?,
    paletteAccent: paletteAccent ?? cache['paletteAccent'] as int?,
    coverFile: coverFile,
    backdropFile: backdropFile,
  );

  _Track copyWith({String? title, String? artist, String? album}) => _Track(
    path: path,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    albumArtist: albumArtist,
    trackNumber: trackNumber,
    trackTotal: trackTotal,
    discNumber: discNumber,
    discTotal: discTotal,
    year: year,
    genre: genre,
    composer: composer,
    performers: performers,
    publisher: publisher,
    copyright: copyright,
    comment: comment,
    isrc: isrc,
    bpm: bpm,
    language: language,
    embeddedLyrics: embeddedLyrics,
    mbid: mbid,
    taggedDuration: taggedDuration,
    cover: cover,
    backgroundArt: backgroundArt,
    palettePrimary: palettePrimary,
    paletteAccent: paletteAccent,
    coverFile: coverFile,
    backdropFile: backdropFile,
    lyrics: lyrics,
  );

  _Track copyWithLyrics(List<LyricLine> lyrics) => _Track(
    path: path,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    trackNumber: trackNumber,
    trackTotal: trackTotal,
    discNumber: discNumber,
    discTotal: discTotal,
    year: year,
    genre: genre,
    composer: composer,
    performers: performers,
    publisher: publisher,
    copyright: copyright,
    comment: comment,
    isrc: isrc,
    bpm: bpm,
    language: language,
    embeddedLyrics: embeddedLyrics,
    mbid: mbid,
    taggedDuration: taggedDuration,
    cover: cover,
    backgroundArt: backgroundArt,
    palettePrimary: palettePrimary,
    paletteAccent: paletteAccent,
    coverFile: coverFile,
    backdropFile: backdropFile,
    lyrics: lyrics,
  );

  _Track copyWithMetadata(
    Map<String, String> values, {
    Uint8List? cover,
    Uint8List? backgroundArt,
    int? palettePrimary,
    int? paletteAccent,
    bool clearArtwork = false,
    bool clearArtworkBytes = false,
    String? coverFile,
    String? backdropFile,
  }) => _Track(
    path: path,
    title: values['title'] ?? title,
    artist: values['artist'] ?? artist,
    album: _metadataOptionalString(values, 'album', album),
    albumArtist: _metadataOptionalString(values, 'albumArtist', albumArtist),
    trackNumber: _metadataInt(values, 'trackNumber', trackNumber),
    trackTotal: _metadataInt(values, 'trackTotal', trackTotal),
    discNumber: _metadataInt(values, 'discNumber', discNumber),
    discTotal: _metadataInt(values, 'discTotal', discTotal),
    year: _metadataInt(values, 'year', year),
    genre: _metadataOptionalString(values, 'genre', genre),
    composer: _metadataOptionalString(values, 'composer', composer),
    performers: _metadataOptionalString(values, 'performers', performers),
    publisher: _metadataOptionalString(values, 'publisher', publisher),
    copyright: _metadataOptionalString(values, 'copyright', copyright),
    comment: _metadataOptionalString(values, 'comment', comment),
    isrc: _metadataOptionalString(values, 'isrc', isrc),
    bpm: _metadataOptionalString(values, 'bpm', bpm),
    language: _metadataOptionalString(values, 'language', language),
    embeddedLyrics: _metadataOptionalString(values, 'lyrics', embeddedLyrics),
    mbid: _metadataOptionalString(values, 'mbid', mbid),
    taggedDuration: taggedDuration,
    cover: clearArtwork || clearArtworkBytes ? null : cover ?? this.cover,
    backgroundArt: clearArtwork || clearArtworkBytes
        ? null
        : backgroundArt ?? this.backgroundArt,
    palettePrimary: clearArtwork
        ? null
        : _metadataInt(
            values,
            'palettePrimary',
            palettePrimary ?? this.palettePrimary,
          ),
    paletteAccent: clearArtwork
        ? null
        : _metadataInt(
            values,
            'paletteAccent',
            paletteAccent ?? this.paletteAccent,
          ),
    coverFile: clearArtwork ? null : coverFile ?? this.coverFile,
    backdropFile: clearArtwork ? null : backdropFile ?? this.backdropFile,
    lyrics: lyrics,
  );

  LastFmTrack toLastFmTrack(Duration playbackDuration) => LastFmTrack(
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    trackNumber: trackNumber,
    mbid: mbid,
    duration: playbackDuration > Duration.zero
        ? playbackDuration
        : taggedDuration ?? Duration.zero,
  );
}

int? _metadataInt(Map<String, String> values, String key, int? fallback) {
  if (!values.containsKey(key)) return fallback;
  final value = values[key]!.trim();
  return value.isEmpty ? null : int.tryParse(value);
}

String? _metadataOptionalString(
  Map<String, String> values,
  String key,
  String? fallback,
) {
  if (!values.containsKey(key)) return fallback;
  final value = values[key]!.trim();
  return value.isEmpty ? null : value;
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.label,
    required this.cancelLabel,
    required this.createLabel,
  });

  final String title;
  final String label;
  final String cancelLabel;
  final String createLabel;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.createLabel)),
      ],
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    this.enableDropTarget = true,
    this.enableLastFm = true,
    this.languageCode = 'en',
    this.initialMusicFolder,
    this.initialMusicFolders = const [],
    this.preferences,
    this.onInitialLibraryLoaded,
    this.systemFonts = const ['Inter'],
    this.fontLoadError,
    this.fontFamily = 'Inter',
    this.fontScale = 1,
    this.skin = PlayerSkin.defaultSkin,
    this.skinProfiles = PlayerSkin.presets,
    this.onSkinSelected,
    this.onSkinChanged,
    this.onSkinCommit,
    this.onSkinSaveAs,
    this.onSkinDelete,
    this.onFontFamilyChanged,
    this.onFontScaleChanged,
  });

  final bool enableDropTarget;
  final bool enableLastFm;
  final String languageCode;
  final String? initialMusicFolder;
  final List<String> initialMusicFolders;
  final SharedPreferences? preferences;
  final VoidCallback? onInitialLibraryLoaded;
  final List<String> systemFonts;
  final String? fontLoadError;
  final String fontFamily;
  final double fontScale;
  final PlayerSkin skin;
  final List<PlayerSkin> skinProfiles;
  final Future<void> Function(PlayerSkin skin)? onSkinSelected;
  final ValueChanged<PlayerSkin>? onSkinChanged;
  final Future<void> Function()? onSkinCommit;
  final Future<void> Function(String name)? onSkinSaveAs;
  final Future<void> Function()? onSkinDelete;
  final Future<void> Function(String family)? onFontFamilyChanged;
  final Future<void> Function(double scale)? onFontScaleChanged;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin, WindowListener {
  Color get _defaultBackground => Theme.of(context).scaffoldBackgroundColor;
  Color get _foreground => Theme.of(context).colorScheme.onSurface;
  Color get _progressColor => Theme.of(context).colorScheme.primary;
  final List<_Track> _queue = [];
  final List<_Track> _libraryTracks = [];
  final List<String> _recentlyPlayedPaths = [];
  final Set<String> _loadedFolders = {};
  final Map<String, List<String>> _playlists = {};
  final Map<String, String> _playlistCovers = {};
  final Map<String, int> _playlistCoverRevisions = {};
  final Map<String, Map<String, dynamic>> _trackLibraryCache = {};
  final Map<String, dynamic> _listeningStats = {};
  Future<void> _trackLibraryCacheSaveQueue = Future<void>.value();
  bool _trackLibraryCacheDirty = false;
  Future<void> _playlistSaveQueue = Future<void>.value();
  late final LastFmService? _lastFm;
  final DiscordPresenceClient _discordPresence = DiscordPresenceClient();
  Player? _player;
  bool _mediaKitInitialized = false;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Playlist>? _playlistSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<String>? _errorSubscription;
  final ScrollController _lyricsScrollController = ScrollController();

  int _currentIndex = -1;
  int _playerPlaylistLength = 0;
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<int> _activeLyricIndex = ValueNotifier(-1);
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _repeatEnabled = false;
  bool _isDragging = false;
  bool _isLoading = false;
  bool _showCompactVisualizer = true;
  bool _economyMode = false;
  int _systemCaptureNoticeCount = 0;
  static const _systemCaptureNoticeDisplayLimit = 3;
  bool _isSeeking = false;
  PlaybackControlLayout _controlLayout = PlaybackControlLayout.modern;
  int _seekStepSeconds = 5;
  int _volumeStepPercent = 5;
  Map<PlaybackShortcutAction, PlaybackShortcut> _playbackShortcuts =
      defaultPlaybackShortcuts();
  double _volume = 100;
  bool _isLastFmConnected = false;
  bool _lastFmEnabled = true;
  bool _discordPresenceEnabled = false;
  bool _discordConnectionErrorShown = false;
  bool _showLyrics = false;
  bool _showFullScreenVisualizer = false;
  bool _windowMinimized = false;
  bool _windowIsFullscreen = false;
  final List<double> _equalizerBands = List<double>.filled(10, 0);
  final List<double> _appliedEqualizerBands = [];
  bool _equalizerApplied = false;
  String? _selectedPlaylist;
  DateTime? _lastStatsSave;
  Timer? _statsSaveTimer;
  bool _statsSaveInProgress = false;
  bool _statsDirty = false;
  String? _libraryError;
  bool _isLoadingLyrics = false;
  bool _hasScrobbledCurrentTrack = false;
  Duration _listenedToCurrentTrack = Duration.zero;
  Duration _lastPlaybackPosition = Duration.zero;
  DateTime? _trackStartedAt;
  DateTime? _lastPositionUiRefresh;
  String? _message;
  String? _error;
  String? _lastFmUsername;
  String? _lyricsError;
  final LyricsService _lyricsService = LyricsService();
  final GlobalKey _audioVisualizerKey = GlobalKey();
  final Set<String> _lyricsRequestsInFlight = {};
  final Set<String> _localLyricsRequestsInFlight = {};
  final Map<String, List<LyricLine>> _onlineLyrics = {};
  final TrackMetadataOverrides _trackMetadataOverrides = {};
  late final Future<void> _trackOverridesLoaded;
  late final Future<void> _trackLibraryCacheLoaded;

  _Track? get _currentTrack =>
      _currentIndex >= 0 && _currentIndex < _queue.length
      ? _queue[_currentIndex]
      : null;

  bool get _hasTrack => _currentTrack != null;
  String _t(String key, [Map<String, Object?> values = const {}]) =>
      RiverLocalizations(widget.languageCode).text(key, values);

  void _loadEqualizerSettings() {
    final encoded = widget.preferences?.getString('equalizer_bands_v1');
    if (encoded == null) return;
    try {
      final values = jsonDecode(encoded);
      if (values is List &&
          values.length == _equalizerBands.length &&
          values.every((value) => value is num)) {
        for (var index = 0; index < values.length; index++) {
          _equalizerBands[index] = (values[index] as num)
              .toDouble()
              .clamp(-12, 12)
              .toDouble();
        }
      }
    } on FormatException {
      _setError(_t('equalizerApplyError'));
    }
  }

  void _loadPlaybackSettings() {
    final preferences = widget.preferences;
    if (preferences == null) return;
    final savedVolume = preferences.getDouble('playback_volume_v1');
    if (savedVolume != null && savedVolume.isFinite) {
      _volume = savedVolume.clamp(0, 100).toDouble();
    }
    final encoded = preferences.getString('playback_controls_v1');
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid playback control settings.');
      }
      final layout = decoded['layout'];
      final seekStep = decoded['seekStep'];
      final volumeStep = decoded['volumeStep'];
      final shortcuts = decoded['shortcuts'];
      if (layout is! String ||
          seekStep is! int ||
          volumeStep is! int ||
          shortcuts is! Map<String, dynamic> ||
          !{5, 10, 15, 30}.contains(seekStep) ||
          !{2, 5, 10, 20}.contains(volumeStep)) {
        throw const FormatException('Invalid playback control settings.');
      }
      final layouts = PlaybackControlLayout.values
          .where((value) => value.name == layout)
          .toList();
      if (layouts.isEmpty) {
        throw const FormatException('Unknown playback control layout.');
      }
      final parsedLayout = layouts.first;
      final parsedShortcuts = <PlaybackShortcutAction, PlaybackShortcut>{};
      for (final action in PlaybackShortcutAction.values) {
        final shortcut = PlaybackShortcut.fromJson(shortcuts[action.name]);
        if (parsedShortcuts.values.contains(shortcut)) {
          throw const FormatException('Duplicate playback shortcut.');
        }
        parsedShortcuts[action] = shortcut;
      }
      setState(() {
        _controlLayout = parsedLayout;
        _seekStepSeconds = seekStep;
        _volumeStepPercent = volumeStep;
        _playbackShortcuts = parsedShortcuts;
      });
    } on FormatException {
      _setError(_t('controlSettingsSaveError'));
    }
  }

  Future<bool> _savePlaybackSettings({
    PlaybackControlLayout? layout,
    int? seekStepSeconds,
    int? volumeStepPercent,
    Map<PlaybackShortcutAction, PlaybackShortcut>? shortcuts,
  }) async {
    final nextLayout = layout ?? _controlLayout;
    final nextSeekStep = seekStepSeconds ?? _seekStepSeconds;
    final nextVolumeStep = volumeStepPercent ?? _volumeStepPercent;
    final nextShortcuts = shortcuts ?? _playbackShortcuts;
    final preferences = widget.preferences;
    if (preferences != null) {
      try {
        final saved = await preferences.setString(
          'playback_controls_v1',
          jsonEncode({
            'layout': nextLayout.name,
            'seekStep': nextSeekStep,
            'volumeStep': nextVolumeStep,
            'shortcuts': {
              for (final entry in nextShortcuts.entries)
                entry.key.name: entry.value.toJson(),
            },
          }),
        );
        if (!saved) throw Exception('Preference write returned false.');
      } on Exception {
        if (mounted) {
          setState(() => _libraryError = _t('controlSettingsSaveError'));
        }
        return false;
      }
    }
    if (!mounted) return false;
    setState(() {
      _controlLayout = nextLayout;
      _seekStepSeconds = nextSeekStep;
      _volumeStepPercent = nextVolumeStep;
      _playbackShortcuts = Map.of(nextShortcuts);
    });
    return true;
  }

  Future<void> _savePlaybackVolume() async {
    final preferences = widget.preferences;
    if (preferences == null) return;
    try {
      final saved = await preferences.setDouble('playback_volume_v1', _volume);
      if (!saved) throw Exception('Preference write returned false.');
    } on Exception {
      if (mounted) _setError(_t('controlSettingsSaveError'));
    }
  }

  Future<PlaybackShortcut?> _capturePlaybackShortcut() {
    String? captureError;
    return showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_t('pressShortcut')),
            content: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.handled;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  Navigator.pop(dialogContext);
                  return KeyEventResult.handled;
                }
                final key = event.logicalKey;
                final reserved =
                    key == LogicalKeyboardKey.f11 ||
                    key == LogicalKeyboardKey.tab ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.controlLeft ||
                    key == LogicalKeyboardKey.controlRight ||
                    key == LogicalKeyboardKey.altLeft ||
                    key == LogicalKeyboardKey.altRight ||
                    key == LogicalKeyboardKey.shiftLeft ||
                    key == LogicalKeyboardKey.shiftRight ||
                    key == LogicalKeyboardKey.metaLeft ||
                    key == LogicalKeyboardKey.metaRight;
                if (reserved) {
                  setDialogState(
                    () => captureError = _t('shortcutKeyUnavailable'),
                  );
                  return KeyEventResult.handled;
                }
                Navigator.pop(
                  dialogContext,
                  PlaybackShortcut(
                    logicalKeyId: key.keyId,
                    control: HardwareKeyboard.instance.isControlPressed,
                    alt: HardwareKeyboard.instance.isAltPressed,
                    shift: HardwareKeyboard.instance.isShiftPressed,
                    meta: HardwareKeyboard.instance.isMetaPressed,
                  ),
                );
                return KeyEventResult.handled;
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_t('shortcutCaptureHint')),
                  if (captureError case final error?) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(_t('cancel')),
              ),
            ],
          );
        },
      ),
    );
  }

  bool get _isEditingText {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _hasSpacePlayPauseShortcut {
    final shortcut = _playbackShortcuts[PlaybackShortcutAction.playPause]!;
    return shortcut.logicalKeyId == LogicalKeyboardKey.space.keyId &&
        !shortcut.control &&
        !shortcut.alt &&
        !shortcut.shift &&
        !shortcut.meta;
  }

  void _runPlaybackShortcut(PlaybackShortcutAction action) {
    if (_isEditingText) return;
    switch (action) {
      case PlaybackShortcutAction.playPause:
        unawaited(_togglePlayback());
        break;
      case PlaybackShortcutAction.previousTrack:
        unawaited(_skip(-1));
        break;
      case PlaybackShortcutAction.nextTrack:
        unawaited(_skip(1));
        break;
      case PlaybackShortcutAction.seekBackward:
        _seekBy(-1);
        break;
      case PlaybackShortcutAction.seekForward:
        _seekBy(1);
        break;
      case PlaybackShortcutAction.volumeDown:
        unawaited(
          _setPlaybackVolume(_volume - _volumeStepPercent, persist: true),
        );
        break;
      case PlaybackShortcutAction.volumeUp:
        unawaited(
          _setPlaybackVolume(_volume + _volumeStepPercent, persist: true),
        );
        break;
      case PlaybackShortcutAction.toggleRepeat:
        unawaited(_toggleRepeat());
        break;
    }
  }

  void _seekBy(int direction) {
    if (!_hasTrack) return;
    final durationSeconds = math.max(_duration.inSeconds, 0);
    final targetSeconds =
        (_position.value.inSeconds + direction * _seekStepSeconds)
            .clamp(0, durationSeconds)
            .toDouble();
    unawaited(_seekTo(targetSeconds));
  }

  Future<void> _setCompactVisualizerEnabled(bool enabled) async {
    setState(() => _showCompactVisualizer = enabled);
    final preferences = widget.preferences;
    if (preferences == null) return;
    try {
      final saved = await preferences.setBool(
        'compact_visualizer_enabled',
        enabled,
      );
      if (!saved) throw Exception(_t('skinSaveError'));
    } on Exception {
      if (mounted) _setError(_t('skinSaveError'));
    }
  }

  Future<void> _setEconomyModeEnabled(
    bool enabled,
    StateSetter setDialogState,
  ) async {
    final previousValue = _economyMode;
    setState(() {
      _economyMode = enabled;
      if (enabled) _showFullScreenVisualizer = false;
    });
    setDialogState(() {});

    final preferences = widget.preferences;
    if (preferences == null) return;
    try {
      final saved = await preferences.setBool(
        'economy_mode_enabled_v1',
        enabled,
      );
      if (!saved) throw Exception(_t('skinSaveError'));
    } on Exception {
      if (!mounted) return;
      setState(() => _economyMode = previousValue);
      setDialogState(() {});
      _setError(_t('skinSaveError'));
    }
  }

  void _recordSystemCaptureNoticeShown() {
    if (_systemCaptureNoticeCount >= _systemCaptureNoticeDisplayLimit) return;
    final count = ++_systemCaptureNoticeCount;
    final preferences = widget.preferences;
    if (preferences == null) return;
    unawaited(_saveSystemCaptureNoticeCount(preferences, count));
  }

  Future<void> _saveSystemCaptureNoticeCount(
    SharedPreferences preferences,
    int count,
  ) async {
    try {
      final saved = await preferences.setInt(
        'audio_visualizer_system_notice_count_v1',
        count,
      );
      if (!saved) throw Exception(_t('skinSaveError'));
    } on Exception {
      if (mounted) _setError(_t('skinSaveError'));
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _lastFm = widget.enableLastFm ? LastFmService() : null;
    _economyMode =
        widget.preferences?.getBool('economy_mode_enabled_v1') ?? false;
    _showCompactVisualizer =
        widget.preferences?.getBool('compact_visualizer_enabled') ?? true;
    _systemCaptureNoticeCount =
        (widget.preferences?.getInt(
                  'audio_visualizer_system_notice_count_v1',
                ) ??
                0)
            .clamp(0, _systemCaptureNoticeDisplayLimit)
            .toInt();
    _loadPlaybackSettings();
    _loadEqualizerSettings();
    _loadLastFmState();
    _loadDiscordPresenceSettings();
    _trackOverridesLoaded = _loadTrackMetadataOverrides();
    _trackLibraryCacheLoaded = _loadTrackLibraryCache();
    unawaited(_loadInitialMusicFolders());
    unawaited(_loadPlaylists());
    unawaited(_loadListeningStats());
  }

  @override
  void onWindowMinimize() {
    if (mounted && !_windowMinimized) {
      setState(() => _windowMinimized = true);
    }
  }

  @override
  void onWindowRestore() {
    if (mounted && _windowMinimized) {
      setState(() => _windowMinimized = false);
    }
  }

  Future<void> _loadInitialMusicFolders() async {
    try {
      await Future.wait([_trackOverridesLoaded, _trackLibraryCacheLoaded]);
      final savedFolders = widget.preferences?.getStringList('music_folders');
      final storedFolders =
          savedFolders ??
          (widget.initialMusicFolder == null
              ? <String>[]
              : [widget.initialMusicFolder!]);
      final folders = {...widget.initialMusicFolders, ...storedFolders};
      for (final folder in folders) {
        await _loadMusicFolder(folder, showProgress: false);
      }
      if (_queue.isNotEmpty && _playerPlaylistLength == 0) {
        final lastPath = widget.preferences?.getString('last_played_track_v1');
        final restoredIndex = _queue.indexWhere(
          (track) => track.path == lastPath,
        );
        _selectTrackState(restoredIndex < 0 ? 0 : restoredIndex);
      }
      if (_trackLibraryCacheDirty) unawaited(_saveTrackLibraryCache());
    } on Exception catch (error) {
      _setError(_t('folderReadError', {'error': error}));
    } finally {
      if (mounted) widget.onInitialLibraryLoaded?.call();
    }
  }

  Future<void> _loadMusicFolder(String path, {bool showProgress = true}) async {
    if (!_loadedFolders.add(path)) return;
    try {
      final audioPaths = <String>[];
      await for (final entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File && _isSupportedAudio(entity.path)) {
          audioPaths.add(entity.path);
        }
      }
      audioPaths.sort(
        (first, second) => first.toLowerCase().compareTo(second.toLowerCase()),
      );
      final currentPaths = audioPaths.toSet();
      final normalizedFolder = Directory(path).absolute.path.toLowerCase();
      final folderPrefix = normalizedFolder.endsWith(Platform.pathSeparator)
          ? normalizedFolder
          : '$normalizedFolder${Platform.pathSeparator}';
      final stalePaths = _trackLibraryCache.keys
          .where(
            (cachedPath) =>
                cachedPath.toLowerCase().startsWith(folderPrefix) &&
                !currentPaths.contains(cachedPath),
          )
          .toList();
      if (stalePaths.isNotEmpty) {
        for (final stalePath in stalePaths) {
          _trackLibraryCache.remove(stalePath);
        }
        _trackLibraryCacheDirty = true;
      }
      if (audioPaths.isNotEmpty) {
        await _receivePaths(
          audioPaths,
          libraryRoot: path,
          autoplayFirst: false,
          showProgress: showProgress,
          showStatusMessages: showProgress,
          selectTrackWhenQueueWasEmpty: showProgress,
        );
      } else if (mounted && showProgress) {
        _setMessage(_t('folderMissingTracks'));
      }
      if (_trackLibraryCacheDirty) unawaited(_saveTrackLibraryCache());
    } on FileSystemException catch (error) {
      _loadedFolders.remove(path);
      _setError(_t('folderReadError', {'error': error}));
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _statsSaveTimer?.cancel();
    unawaited(_saveListeningStats(force: true));
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _playlistSubscription?.cancel();
    _completedSubscription?.cancel();
    _errorSubscription?.cancel();
    _position.dispose();
    _activeLyricIndex.dispose();
    _lyricsScrollController.dispose();
    _player?.dispose();
    _lastFm?.dispose();
    unawaited(_discordPresence.dispose());
    _lyricsService.dispose();
    super.dispose();
  }

  String _formatTime(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _titleFromPath(String path) {
    final filename = path.split(RegExp(r'[\\/]')).last;
    return filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
  }

  bool _isSupportedAudio(String path) {
    final lowerPath = path.toLowerCase();
    return supportedFileExtensions.any(lowerPath.endsWith);
  }

  Future<_Track> _readTrack(String path, {String? libraryRoot}) async {
    await _trackOverridesLoaded;
    final fallbackTitle = _titleFromPath(path);
    final folderMetadata = libraryRoot == null
        ? (artist: null, album: null)
        : musicFolderMetadataFromPath(path, libraryRoot);
    try {
      final fileStat = await File(path).stat();
      final cached = _trackLibraryCache[path];
      if (cached != null &&
          cached['artworkVersion'] == _artworkProcessingVersion &&
          cached['size'] == fileStat.size &&
          cached['modifiedUs'] == fileStat.modified.microsecondsSinceEpoch) {
        final trackData = cached['track'];
        final coverPath = cached['coverFile'];
        final backdropPath = cached['backdropFile'];
        String? cachedCoverFile;
        String? cachedBackdropFile;
        var artworkValid = coverPath == null && backdropPath == null;
        if (coverPath is String && backdropPath is String) {
          final coverFile = File(coverPath);
          final backdropFile = File(backdropPath);
          final artworkExists = await Future.wait([
            coverFile.exists(),
            backdropFile.exists(),
          ]);
          if (artworkExists.every((exists) => exists)) {
            cachedCoverFile = coverPath;
            cachedBackdropFile = backdropPath;
            artworkValid = true;
          }
        }
        if (artworkValid &&
            trackData is Map<String, dynamic> &&
            _isValidCachedTrack(trackData, path)) {
          return await _applyTrackMetadataOverride(
            _trackWithFolderMetadata(
              _Track.fromCache(
                trackData,
                coverFile: cachedCoverFile,
                backdropFile: cachedBackdropFile,
              ),
              folderMetadata,
            ),
          );
        }
      }
      final metadata = await compute(_readTrackMetadata, path);
      final artwork = metadata['artwork'] as PreparedArtwork?;
      final title = metadata['title'] as String?;
      final artist = metadata['artist'] as String?;
      final album = (metadata['album'] as String?)?.trim();
      var track = _Track(
        path: path,
        title: title?.trim().isNotEmpty == true ? title!.trim() : fallbackTitle,
        artist: artist?.trim().isNotEmpty == true
            ? artist!.trim()
            : folderMetadata.artist ?? _t('unknownArtist'),
        album: album?.isNotEmpty == true ? album : folderMetadata.album,
        albumArtist: metadata['albumArtist'] as String?,
        trackNumber: metadata['trackNumber'] as int?,
        trackTotal: metadata['trackTotal'] as int?,
        discNumber: metadata['discNumber'] as int?,
        discTotal: metadata['discTotal'] as int?,
        year: metadata['year'] as int?,
        genre: metadata['genre'] as String?,
        composer: metadata['composer'] as String?,
        performers: metadata['performers'] as String?,
        publisher: metadata['publisher'] as String?,
        copyright: metadata['copyright'] as String?,
        comment: metadata['comment'] as String?,
        isrc: metadata['isrc'] as String?,
        bpm: metadata['bpm']?.toString(),
        language: metadata['language'] as String?,
        embeddedLyrics: metadata['lyrics'] as String?,
        mbid: metadata['mbid'] as String?,
        taggedDuration: switch (metadata['durationMs']) {
          final int milliseconds => Duration(milliseconds: milliseconds),
          _ => null,
        },
        cover: artwork?.cover,
        backgroundArt: artwork?.backdrop,
        palettePrimary: artwork?.palettePrimary,
        paletteAccent: artwork?.paletteAccent,
        lyrics: const [],
      );
      String? coverFile;
      String? backdropFile;
      var cacheable = true;
      if (artwork != null) {
        try {
          final files = await _saveTrackArtwork(path, artwork);
          coverFile = files.coverFile;
          backdropFile = files.backdropFile;
          track = track.copyWithMetadata(
            const {},
            clearArtworkBytes: true,
            coverFile: coverFile,
            backdropFile: backdropFile,
          );
        } on Exception {
          cacheable = false;
          if (mounted) {
            setState(() => _libraryError = _t('libraryCacheSaveError'));
          }
        }
      }
      if (cacheable) {
        _trackLibraryCache[path] = {
          'artworkVersion': _artworkProcessingVersion,
          'size': fileStat.size,
          'modifiedUs': fileStat.modified.microsecondsSinceEpoch,
          'track': track.toCacheMap(),
          'coverFile': coverFile,
          'backdropFile': backdropFile,
        };
        _trackLibraryCacheDirty = true;
      }
      return await _applyTrackMetadataOverride(
        _trackWithFolderMetadata(track, folderMetadata),
      );
    } on Exception {
      return await _applyTrackMetadataOverride(
        _trackWithFolderMetadata(
          _Track(
            path: path,
            title: fallbackTitle,
            artist: _t('unknownArtist'),
            lyrics: const [],
          ),
          folderMetadata,
        ),
      );
    }
  }

  _Track _trackWithFolderMetadata(
    _Track track,
    ({String? artist, String? album}) folderMetadata,
  ) {
    final needsArtist =
        track.artist == _t('unknownArtist') &&
        folderMetadata.artist?.trim().isNotEmpty == true;
    final needsAlbum = track.album?.trim().isNotEmpty != true;
    if (!needsArtist && (!needsAlbum || folderMetadata.album == null)) {
      return track;
    }
    return track.copyWith(
      artist: needsArtist ? folderMetadata.artist : null,
      album: needsAlbum ? folderMetadata.album : null,
    );
  }

  bool _isValidCachedTrack(Map<String, dynamic> track, String path) {
    if (track['path'] != path ||
        track['title'] is! String ||
        track['artist'] is! String) {
      return false;
    }
    const stringFields = [
      'album',
      'albumArtist',
      'genre',
      'composer',
      'performers',
      'publisher',
      'copyright',
      'comment',
      'isrc',
      'bpm',
      'language',
      'embeddedLyrics',
      'mbid',
    ];
    if (stringFields.any(
      (field) => track[field] != null && track[field] is! String,
    )) {
      return false;
    }
    const integerFields = [
      'trackNumber',
      'trackTotal',
      'discNumber',
      'discTotal',
      'year',
      'taggedDurationMs',
    ];
    return !integerFields.any(
      (field) => track[field] != null && track[field] is! int,
    );
  }

  Future<void> _loadTrackLibraryCache() async {
    final encoded = widget.preferences?.getString('track_library_cache_v1');
    if (encoded == null) return;
    try {
      final decoded = await compute(_decodeTrackLibraryCache, encoded);
      var invalidEntries = false;
      for (final entry in decoded.entries) {
        final record = entry.value;
        if (record is! Map<String, dynamic> ||
            record['size'] is! int ||
            record['modifiedUs'] is! int ||
            record['track'] is! Map<String, dynamic> ||
            (record['coverFile'] != null && record['coverFile'] is! String) ||
            (record['backdropFile'] != null &&
                record['backdropFile'] is! String)) {
          invalidEntries = true;
          continue;
        }
        _trackLibraryCache[entry.key] = record;
      }
      if (invalidEntries && mounted) {
        setState(() => _libraryError = _t('libraryCacheReadError'));
      }
      if (invalidEntries) {
        _trackLibraryCacheDirty = true;
        unawaited(_saveTrackLibraryCache());
      }
    } on Object {
      _trackLibraryCache.clear();
      _trackLibraryCacheDirty = true;
      if (mounted) {
        setState(() => _libraryError = _t('libraryCacheReadError'));
      }
      unawaited(_saveTrackLibraryCache());
    }
  }

  Future<void> _saveTrackLibraryCache() {
    final save = _trackLibraryCacheSaveQueue.then((_) async {
      if (!_trackLibraryCacheDirty) return;
      final preferences = widget.preferences;
      if (preferences == null) return;
      final snapshot = <String, dynamic>{
        for (final entry in _trackLibraryCache.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };
      try {
        final encoded = await compute(_encodeTrackLibraryCache, snapshot);
        final saved = await preferences.setString(
          'track_library_cache_v1',
          encoded,
        );
        if (!saved) throw Exception(_t('libraryCacheSaveError'));
        _trackLibraryCacheDirty = false;
      } on Object {
        if (mounted) {
          setState(() => _libraryError = _t('libraryCacheSaveError'));
        }
      }
    });
    _trackLibraryCacheSaveQueue = save;
    return save;
  }

  Future<_Track> _applyTrackMetadataOverride(_Track track) async {
    final override = _trackMetadataOverrides[track.path];
    if (override == null) return track;
    final coverPath = override['coverFile'];
    final backdropPath = override['backdropFile'];
    final coverFile = coverPath == null ? null : File(coverPath);
    final backdropFile = backdropPath == null ? null : File(backdropPath);
    final hasCoverOverride =
        coverFile != null &&
        backdropFile != null &&
        await coverFile.exists() &&
        await backdropFile.exists();
    final clearArtwork = override['removeArtwork'] == 'true';
    return track.copyWithMetadata(
      override,
      clearArtwork: clearArtwork,
      clearArtworkBytes: hasCoverOverride || clearArtwork,
      coverFile: hasCoverOverride ? coverPath : null,
      backdropFile: hasCoverOverride ? backdropPath : null,
    );
  }

  Future<({String coverFile, String backdropFile})> _saveTrackArtwork(
    String trackPath,
    PreparedArtwork artwork,
  ) async {
    final supportDirectory = await getApplicationSupportDirectory();
    final artworkDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}track-artwork',
    );
    await artworkDirectory.create(recursive: true);
    final key = sha256.convert(utf8.encode(trackPath)).toString();
    final coverFile = File(
      '${artworkDirectory.path}${Platform.pathSeparator}$key-cover.jpg',
    );
    final backdropFile = File(
      '${artworkDirectory.path}${Platform.pathSeparator}$key-backdrop.jpg',
    );
    await coverFile.writeAsBytes(artwork.cover, flush: true);
    await backdropFile.writeAsBytes(artwork.backdrop, flush: true);
    return (coverFile: coverFile.path, backdropFile: backdropFile.path);
  }

  Future<List<LyricLine>> _readLyrics(String audioPath) async {
    final lyricPath = audioPath.replaceFirst(RegExp(r'\.[^.\\/]+$'), '.lrc');
    final file = File(lyricPath);
    if (!await file.exists()) return const [];
    try {
      final bytes = await file.readAsBytes();
      String contents;
      try {
        contents = utf8.decode(bytes);
      } on FormatException {
        contents = latin1.decode(bytes);
      }
      return parseLrc(contents);
    } on FileSystemException {
      return const [];
    }
  }

  Future<void> _receivePaths(
    Iterable<String> paths, {
    String? libraryRoot,
    bool autoplayFirst = true,
    bool showProgress = true,
    bool showStatusMessages = true,
    bool selectTrackWhenQueueWasEmpty = true,
  }) async {
    final existingPaths = _queue.map((track) => track.path).toSet();
    final uniquePaths = paths.toSet().difference(existingPaths).toList();
    final validPaths = uniquePaths.where(_isSupportedAudio).toList();

    if (validPaths.isEmpty) {
      if (showStatusMessages) {
        if (paths.isNotEmpty && uniquePaths.isEmpty) {
          _setMessage(_t('filesAlreadyAdded'));
        } else {
          _setMessage(_t('supportedFormats'));
        }
      }
      return;
    }

    if (showProgress) {
      setState(() {
        _isLoading = true;
        _error = null;
        _message = _t('addingTracks', {'count': validPaths.length});
      });
    }

    final tracks = <_Track>[];
    const batchSize = 4;
    for (var start = 0; start < validPaths.length; start += batchSize) {
      final batch = validPaths.skip(start).take(batchSize);
      final loadedTracks = await Future.wait(
        batch.map((path) async {
          if (!await File(path).exists()) return null;
          return _readTrack(path, libraryRoot: libraryRoot);
        }),
      );
      tracks.addAll(loadedTracks.whereType<_Track>());
    }
    if (_trackLibraryCacheDirty) unawaited(_saveTrackLibraryCache());

    if (!mounted) return;
    if (showProgress) {
      setState(() {
        _isLoading = false;
        _message = null;
      });
    }

    if (tracks.isEmpty) {
      if (showStatusMessages) _setMessage(_t('filesReadError'));
      return;
    }

    final previousQueueLength = _queue.length;
    final wasEmpty = previousQueueLength == 0;
    setState(() {
      _libraryTracks.addAll(tracks);
      _queue.addAll(tracks);
    });

    if (wasEmpty && selectTrackWhenQueueWasEmpty) {
      await _openTrack(0, autoplay: autoplayFirst);
    } else {
      final player = _player;
      if (player != null && _playerPlaylistLength > 0) {
        for (
          var index = _playerPlaylistLength;
          index < _queue.length;
          index++
        ) {
          await player.add(_mediaForTrack(_queue[index]));
        }
        _playerPlaylistLength = _queue.length;
      }
      if (showStatusMessages) {
        _setMessage(_t('queueAdded', {'count': tracks.length}));
      }
    }
  }

  Media _mediaForTrack(_Track track) => Media(File(track.path).uri.toString());

  Future<void> _openTrack(int index, {required bool autoplay}) async {
    if (index < 0 || index >= _queue.length) return;
    if (!_mediaKitInitialized) {
      MediaKit.ensureInitialized();
      _mediaKitInitialized = true;
    }
    final configureInitialVolume = _player == null && _volume < 100;
    final player = _player ??= Player();
    if (autoplay) _recordTrackPlay(_queue[index]);

    _positionSubscription ??= player.stream.position.listen((position) {
      if (!mounted || _isSeeking) return;
      _recordPlaybackPosition(position);
      _syncLyricsToPosition(position);
      final now = DateTime.now();
      if (_lastPositionUiRefresh == null ||
          now.difference(_lastPositionUiRefresh!) >=
              const Duration(milliseconds: 100)) {
        _lastPositionUiRefresh = now;
        _position.value = position;
      }
    });
    _durationSubscription ??= player.stream.duration.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
      if (_isPlaying) unawaited(_syncDiscordPresence());
      _maybeScrobble();
    });
    _playingSubscription ??= player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
      unawaited(_syncDiscordPresence());
      if (playing && _lastPlaybackPosition == Duration.zero) {
        _trackStartedAt ??= DateTime.now();
      }
    });
    _playlistSubscription ??= player.stream.playlist.listen((playlist) {
      final index = playlist.index;
      if (index < 0 || index >= _queue.length || index == _currentIndex) return;
      _selectTrackState(index);
      _recordTrackPlay(_queue[index]);
      unawaited(_sendNowPlaying(_queue[index]));
    });
    _completedSubscription ??= player.stream.completed.listen((completed) {
      if (completed) _handlePlaylistCompleted();
    });
    _errorSubscription ??= player.stream.error.listen((error) {
      if (error.isNotEmpty && !error.toLowerCase().contains('.lrc')) {
        _setError(error);
      }
    });

    _selectTrackState(index);

    try {
      if (configureInitialVolume) await player.setVolume(_volume);
      await player.setPlaylistMode(
        _repeatEnabled ? PlaylistMode.single : PlaylistMode.none,
      );
      if (_playerPlaylistLength == 0) {
        await player.open(
          Playlist(_queue.map(_mediaForTrack).toList(), index: index),
          play: autoplay,
        );
        _playerPlaylistLength = _queue.length;
      } else {
        await player.jump(index);
      }
      await _applyEqualizer();
      await player.setSubtitleTrack(SubtitleTrack.no());
      if (autoplay) await _sendNowPlaying(_queue[index]);
    } on Exception catch (error) {
      _setError(_t('playbackError', {'error': error}));
    }
  }

  Future<void> _saveEqualizerSettings() async {
    final preferences = widget.preferences;
    if (preferences == null) return;
    try {
      final saved = await preferences.setString(
        'equalizer_bands_v1',
        jsonEncode(_equalizerBands),
      );
      if (!saved && mounted) _setError(_t('equalizerApplyError'));
    } on Exception {
      if (mounted) _setError(_t('equalizerApplyError'));
    }
  }

  Future<void> _applyEqualizer() async {
    final player = _player;
    if (player == null) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final enabled = _equalizerBands.any((gain) => gain.abs() > 0.01);
    if (_equalizerApplied &&
        listEquals(_equalizerBands, _appliedEqualizerBands)) {
      return;
    }
    if (!enabled && !_equalizerApplied) return;
    try {
      if (enabled) {
        await platform.command([
          'af',
          'add',
          buildEqualizerFilter(_equalizerBands),
        ]);
      } else {
        await platform.command(['af', 'remove', '@river_equalizer']);
      }
      _equalizerApplied = enabled;
      _appliedEqualizerBands
        ..clear()
        ..addAll(enabled ? _equalizerBands : const []);
    } on Exception {
      _setError(_t('equalizerApplyError'));
    }
  }

  String _equalizerFrequencyLabel(int index) {
    const labels = [
      '31 Hz',
      '62 Hz',
      '125 Hz',
      '250 Hz',
      '500 Hz',
      '1 kHz',
      '2 kHz',
      '4 kHz',
      '8 kHz',
      '16 kHz',
    ];
    return labels[index];
  }

  Future<void> _openEqualizer() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('equalizer')),
          content: SizedBox(
            width: 520,
            height: 430,
            child: ListView.builder(
              itemCount: _equalizerBands.length,
              itemBuilder: (context, index) {
                final frequency = _equalizerFrequencyLabel(index);
                final gain = _equalizerBands[index];
                return Row(
                  children: [
                    SizedBox(
                      width: 54,
                      child: Text(
                        frequency,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Semantics(
                        label: _t('equalizerBand', {'frequency': frequency}),
                        child: Slider(
                          value: gain,
                          min: -12,
                          max: 12,
                          divisions: 24,
                          label: '${gain.toStringAsFixed(1)} dB',
                          onChanged: (value) {
                            _equalizerBands[index] = value;
                            setDialogState(() {});
                          },
                          onChangeEnd: (_) {
                            unawaited(_saveEqualizerSettings());
                            unawaited(_applyEqualizer());
                          },
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 54,
                      child: Text(
                        '${gain.toStringAsFixed(1)} dB',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (var index = 0; index < _equalizerBands.length; index++) {
                  _equalizerBands[index] = 0;
                }
                setDialogState(() {});
                unawaited(_saveEqualizerSettings());
                unawaited(_applyEqualizer());
              },
              child: Text(_t('equalizerReset')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('done')),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTrackState(int index) {
    final previousTrack = _currentTrack;
    final track = _queue[index];
    setState(() {
      if (previousTrack != null &&
          previousTrack.path != track.path &&
          previousTrack.lyrics.isNotEmpty) {
        _replaceTrackInCollections(previousTrack.copyWithLyrics(const []));
      }
      _currentIndex = index;
      _position.value = Duration.zero;
      _lastPositionUiRefresh = DateTime.now();
      _duration = Duration.zero;
      _error = null;
      _hasScrobbledCurrentTrack = false;
      _listenedToCurrentTrack = Duration.zero;
      _lastPlaybackPosition = Duration.zero;
      _trackStartedAt = DateTime.now();
      _activeLyricIndex.value = -1;
      _isLoadingLyrics =
          _showLyrics &&
          track.lyrics.isEmpty &&
          !_onlineLyrics.containsKey(track.path);
      _lyricsError = null;
    });
    final saved = widget.preferences?.setString(
      'last_played_track_v1',
      track.path,
    );
    if (saved != null) {
      unawaited(
        saved.then((didSave) {
          if (!didSave && mounted) _setError(_t('trackRememberError'));
        }),
      );
    }
    if (track.lyrics.isEmpty && _showLyrics) {
      unawaited(_loadLyricsForTrack(track));
    }
    unawaited(_syncDiscordPresence());
  }

  void _replaceTrackInCollections(_Track updatedTrack) {
    for (var index = 0; index < _queue.length; index++) {
      if (_queue[index].path == updatedTrack.path) {
        _queue[index] = updatedTrack;
      }
    }
    for (var index = 0; index < _libraryTracks.length; index++) {
      if (_libraryTracks[index].path == updatedTrack.path) {
        _libraryTracks[index] = updatedTrack;
      }
    }
  }

  void _handlePlaylistCompleted() {
    if (!mounted) return;
    setState(() {
      _position.value = _duration;
      _isPlaying = false;
    });
    unawaited(_syncDiscordPresence());
  }

  Future<void> _togglePlayback() async {
    if (!_hasTrack) {
      _setMessage(_t('noTrackToPlay'));
      return;
    }

    try {
      if (_player == null) {
        await _openTrack(_currentIndex, autoplay: true);
        return;
      }
      final player = _player!;
      if (_isPlaying) {
        await player.pause();
      } else {
        _trackStartedAt ??= DateTime.now();
        if (_position.value == Duration.zero) {
          final track = _currentTrack;
          if (track != null) _recordTrackPlay(track);
        }
        await player.play();
        final track = _currentTrack;
        if (track != null) await _sendNowPlaying(track);
      }
    } on Exception catch (error) {
      _setError(_t('playbackToggleError', {'error': error}));
    }
  }

  Future<void> _skip(int direction) async {
    if (_queue.isEmpty) return;

    if (direction < 0 && _position.value > const Duration(seconds: 3)) {
      await _player?.seek(Duration.zero);
      return;
    }

    final nextIndex = (_currentIndex + direction).clamp(0, _queue.length - 1);
    await _openTrack(nextIndex, autoplay: true);
  }

  Future<void> _addTrackToQueue(_Track track) async {
    final player = _player;
    if (player != null && _playerPlaylistLength > 0) {
      try {
        await player.add(_mediaForTrack(track));
      } on Exception catch (error) {
        _setError(_t('queueAddError', {'error': error}));
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _queue.add(track);
      if (player != null && _playerPlaylistLength > 0) {
        _playerPlaylistLength++;
      }
    });
    _setMessage(_t('queueAdded', {'count': 1}));
  }

  Future<void> _removeUpcomingTrack(int index) async {
    if (index <= _currentIndex || index >= _queue.length) return;
    final player = _player;
    if (player != null && index < _playerPlaylistLength) {
      try {
        await player.remove(index);
      } on Exception catch (error) {
        _setError(_t('queueRemoveError', {'error': error}));
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _queue.removeAt(index);
      if (player != null && index < _playerPlaylistLength) {
        _playerPlaylistLength--;
      }
    });
  }

  Future<void> _clearUpcomingQueue() async {
    final firstUpcoming = (_currentIndex + 1).clamp(0, _queue.length);
    if (firstUpcoming == _queue.length) return;
    final player = _player;
    if (player != null) {
      try {
        for (
          var index = _playerPlaylistLength - 1;
          index >= firstUpcoming;
          index--
        ) {
          await player.remove(index);
        }
      } on Exception catch (error) {
        _setError(_t('queueRemoveError', {'error': error}));
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _queue.removeRange(firstUpcoming, _queue.length);
      _playerPlaylistLength = math.min(_playerPlaylistLength, _queue.length);
    });
  }

  _Track? _trackForPath(String path) {
    for (final track in _queue) {
      if (track.path == path) return track;
    }
    for (final track in _libraryTracks) {
      if (track.path == path) return track;
    }
    return null;
  }

  Future<void> _openQueue() async {
    var selectedTab = 'queue';
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: _t('close'),
      barrierColor: Colors.black.withValues(alpha: 0.28),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setDialogState) {
              final current = _currentTrack;
              final upcomingStart = (_currentIndex + 1).clamp(0, _queue.length);
              final upcoming = _queue.skip(upcomingStart).toList();
              final recent = _recentlyPlayedPaths
                  .map(_trackForPath)
                  .whereType<_Track>()
                  .toList();
              Widget trackRow(
                _Track track, {
                required VoidCallback onTap,
                Widget? trailing,
                bool highlighted = false,
              }) {
                final image = track.coverImageProvider;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox.square(
                      dimension: 48,
                      child: image == null
                          ? const CustomPaint(painter: _AlbumArtworkPainter())
                          : Image(
                              image: ResizeImage(image, width: 96, height: 96),
                              fit: BoxFit.cover,
                              excludeFromSemantics: true,
                              errorBuilder: (context, error, stackTrace) =>
                                  const CustomPaint(
                                    painter: _AlbumArtworkPainter(),
                                  ),
                            ),
                    ),
                  ),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: highlighted ? _progressColor : _foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: trailing,
                  onTap: onTap,
                );
              }

              Future<void> playTrack(_Track track) async {
                final index = _queue.indexWhere(
                  (queuedTrack) => queuedTrack.path == track.path,
                );
                if (index >= 0) {
                  await _openTrack(index, autoplay: true);
                  if (context.mounted) Navigator.pop(dialogContext);
                }
              }

              return SafeArea(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      elevation: 18,
                      shadowColor: Colors.black.withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: _foreground.withValues(alpha: 0.1),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: math.min(
                          420,
                          MediaQuery.sizeOf(context).width - 28,
                        ),
                        height: MediaQuery.sizeOf(context).height * 0.9,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: SegmentedButton<String>(
                                      segments: [
                                        ButtonSegment(
                                          value: 'queue',
                                          label: Text(_t('queue')),
                                        ),
                                        ButtonSegment(
                                          value: 'recent',
                                          label: Text(_t('recentlyPlayed')),
                                        ),
                                      ],
                                      selected: {selectedTab},
                                      onSelectionChanged: (selection) =>
                                          setDialogState(() {
                                            selectedTab = selection.first;
                                          }),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: _t('close'),
                                    onPressed: () =>
                                        Navigator.pop(dialogContext),
                                    icon: const Icon(CupertinoIcons.xmark),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: selectedTab == 'queue'
                                  ? ListView(
                                      padding: const EdgeInsets.only(
                                        top: 14,
                                        bottom: 12,
                                      ),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 8,
                                          ),
                                          child: Text(
                                            _t('nowPlaying'),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                        if (current != null)
                                          trackRow(
                                            current,
                                            highlighted: true,
                                            onTap: () async {
                                              await _togglePlayback();
                                              setDialogState(() {});
                                            },
                                            trailing: Icon(
                                              _isPlaying
                                                  ? CupertinoIcons.waveform
                                                  : CupertinoIcons.play_fill,
                                              color: _progressColor,
                                            ),
                                          )
                                        else
                                          Padding(
                                            padding: const EdgeInsets.all(18),
                                            child: Text(_t('noTrackToPlay')),
                                          ),
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            18,
                                            20,
                                            16,
                                            8,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _t('nextInQueue'),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                ),
                                              ),
                                              TextButton(
                                                onPressed: upcoming.isEmpty
                                                    ? null
                                                    : () async {
                                                        await _clearUpcomingQueue();
                                                        setDialogState(() {});
                                                      },
                                                child: Text(_t('clearQueue')),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (upcoming.isEmpty)
                                          Padding(
                                            padding: const EdgeInsets.all(18),
                                            child: Text(_t('queueEmpty')),
                                          )
                                        else
                                          for (
                                            var offset = 0;
                                            offset < upcoming.length;
                                            offset++
                                          )
                                            trackRow(
                                              upcoming[offset],
                                              onTap: () =>
                                                  playTrack(upcoming[offset]),
                                              trailing: IconButton(
                                                tooltip: _t('removeFromQueue'),
                                                onPressed: () async {
                                                  await _removeUpcomingTrack(
                                                    upcomingStart + offset,
                                                  );
                                                  setDialogState(() {});
                                                },
                                                icon: const Icon(
                                                  CupertinoIcons.xmark,
                                                  size: 18,
                                                ),
                                              ),
                                            ),
                                      ],
                                    )
                                  : recent.isEmpty
                                  ? Center(child: Text(_t('recentlyEmpty')))
                                  : ListView(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      children: [
                                        for (final track in recent)
                                          trackRow(
                                            track,
                                            onTap: () => playTrack(track),
                                          ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final slide = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.08, 0),
            end: Offset.zero,
          ).animate(slide),
          child: child,
        );
      },
    );
  }

  Future<void> _toggleRepeat() async {
    final enabled = !_repeatEnabled;
    setState(() => _repeatEnabled = enabled);
    try {
      await _player?.setPlaylistMode(
        enabled ? PlaylistMode.single : PlaylistMode.none,
      );
    } on Exception catch (error) {
      _setError(_t('repeatError', {'error': error}));
    }
  }

  Future<void> _seekTo(double seconds) async {
    final position = Duration(seconds: seconds.round());
    _lastPlaybackPosition = position;
    _position.value = position;
    try {
      await _player?.seek(position);
      await _syncDiscordPresence();
    } on Exception catch (error) {
      _setError(_t('seekError', {'error': error}));
    }
    if (mounted) setState(() => _isSeeking = false);
  }

  Future<void> _setPlaybackVolume(double volume, {bool persist = false}) async {
    final normalizedVolume = volume.clamp(0, 100).toDouble();
    setState(() => _volume = normalizedVolume);
    final player = _player;
    if (player != null) {
      try {
        await player.setVolume(normalizedVolume);
      } on Exception catch (error) {
        _setError(_t('volumeError', {'error': error}));
      }
    }
    if (persist) await _savePlaybackVolume();
  }

  Widget _buildVolumeControl() {
    final nextVolume = math.min(_volume.round() + _volumeStepPercent, 100);
    final previousVolume = math.max(_volume.round() - _volumeStepPercent, 0);
    return Semantics(
      container: true,
      slider: true,
      label: _t('volume'),
      value: '${_volume.round()}%',
      increasedValue: '$nextVolume%',
      decreasedValue: '$previousVolume%',
      onIncrease: () =>
          unawaited(_setPlaybackVolume(nextVolume.toDouble(), persist: true)),
      onDecrease: () => unawaited(
        _setPlaybackVolume(previousVolume.toDouble(), persist: true),
      ),
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(
              _volume == 0
                  ? CupertinoIcons.speaker_slash_fill
                  : CupertinoIcons.speaker_2_fill,
              color: _foreground.withValues(alpha: 0.86),
              size: 20,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: _progressColor,
                  inactiveTrackColor: _foreground.withValues(alpha: 0.22),
                  thumbColor: _foreground,
                  overlayColor: _foreground.withValues(alpha: 0.12),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                    elevation: 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('player-volume-slider'),
                  min: 0,
                  max: 100,
                  value: _volume,
                  onChanged: (value) => unawaited(_setPlaybackVolume(value)),
                  onChangeEnd: (_) => unawaited(_savePlaybackVolume()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<LyricLine> _lyricsFor(_Track? track) {
    if (track == null) return const [];
    if (track.lyrics.isNotEmpty) return track.lyrics;
    return _onlineLyrics[track.path] ?? const [];
  }

  bool _hasSyncedLyrics(List<LyricLine> lyrics) =>
      lyrics.length > 1 && lyrics.last.timestamp > lyrics.first.timestamp;

  Future<void> _loadLyricsForTrack(_Track track) async {
    if (track.lyrics.isNotEmpty || _onlineLyrics.containsKey(track.path)) {
      return;
    }
    if (!_localLyricsRequestsInFlight.add(track.path)) return;

    if (_currentTrack?.path == track.path && mounted) {
      setState(() {
        _isLoadingLyrics = true;
        _lyricsError = null;
      });
    }

    List<LyricLine> localLyrics;
    try {
      localLyrics = await _readLyrics(track.path);
    } on Exception {
      if (_currentTrack?.path == track.path && mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyricsError = _t('lyricsUnavailable');
        });
      }
      return;
    } finally {
      _localLyricsRequestsInFlight.remove(track.path);
    }

    if (!mounted || _currentTrack?.path != track.path) return;
    if (localLyrics.isNotEmpty) {
      final updatedTrack = track.copyWithLyrics(localLyrics);
      final activeIndex = _lyricIndexAtForLyrics(localLyrics, _position.value);
      setState(() {
        _replaceTrackInCollections(updatedTrack);
        _isLoadingLyrics = false;
        _activeLyricIndex.value = activeIndex;
      });
      return;
    }

    await _loadOnlineLyrics(track);
  }

  Future<void> _loadOnlineLyrics(_Track track) async {
    if (track.lyrics.isNotEmpty ||
        _onlineLyrics.containsKey(track.path) ||
        !_lyricsRequestsInFlight.add(track.path)) {
      return;
    }

    if (_currentTrack?.path == track.path && mounted) {
      setState(() {
        _isLoadingLyrics = true;
        _lyricsError = null;
      });
    }

    try {
      final lyrics = await _lyricsService.lookup(
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.taggedDuration,
      );
      _onlineLyrics[track.path] = lyrics;
      if (_currentTrack?.path == track.path && mounted) {
        final activeIndex = _lyricIndexAt(_position.value);
        setState(() {
          _isLoadingLyrics = false;
          _activeLyricIndex.value = activeIndex;
        });
      }
    } on Exception {
      if (_currentTrack?.path == track.path && mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyricsError = _t('lyricsUnavailable');
        });
      }
    } finally {
      _lyricsRequestsInFlight.remove(track.path);
    }
  }

  int _lyricIndexAt(Duration position) {
    final lyrics = _lyricsFor(_currentTrack);
    return _lyricIndexAtForLyrics(lyrics, position);
  }

  int _lyricIndexAtForLyrics(List<LyricLine> lyrics, Duration position) {
    if (!_hasSyncedLyrics(lyrics)) return -1;
    var low = 0;
    var high = lyrics.length - 1;
    var result = -1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (lyrics[middle].timestamp <= position) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result;
  }

  void _syncLyricsToPosition(Duration position) {
    if (!_showLyrics) return;
    final index = _lyricIndexAt(position);
    if (index == _activeLyricIndex.value) return;
    _activeLyricIndex.value = index;
  }

  Widget _buildLyricsPanel(double height, {required bool largeWindow}) {
    final lyrics = _lyricsFor(_currentTrack);
    if (lyrics.isEmpty) {
      return SizedBox(
        key: const ValueKey('lyrics-panel'),
        height: height,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingLyrics)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Text(
                  _isLoadingLyrics
                      ? _t('lyricsLoading')
                      : _lyricsError != null
                      ? _t('lyricsUnavailable')
                      : _t('lyricsMissing'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _foreground.withValues(alpha: 0.76),
                    fontSize: 18,
                    height: 1.55,
                  ),
                ),
                if (_lyricsError != null && !_isLoadingLyrics) ...[
                  const SizedBox(height: 8),
                  Text(
                    _lyricsError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _foreground.withValues(alpha: 0.62),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _currentTrack == null
                        ? null
                        : _retryOnlineLyrics,
                    icon: const Icon(CupertinoIcons.refresh),
                    label: Text(_t('retry')),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      key: const ValueKey('lyrics-panel'),
      height: height,
      child: LyricsListView(
        lyrics: lyrics,
        controller: _lyricsScrollController,
        activeLyricIndex: _activeLyricIndex,
        semanticsLabel: _t('lyrics'),
        synced: _hasSyncedLyrics(lyrics),
        largeWindow: largeWindow,
        fontFamily: widget.skin.separateLyricsFont
            ? widget.skin.lyricsFontFamily ?? widget.fontFamily
            : widget.fontFamily,
      ),
    );
  }

  void _toggleLyrics() {
    setState(() => _showLyrics = !_showLyrics);
    final track = _currentTrack;
    if (_showLyrics && track != null) {
      final index = _lyricIndexAt(_position.value);
      _activeLyricIndex.value = index;
      unawaited(_loadLyricsForTrack(track));
    }
  }

  void _retryOnlineLyrics() {
    final track = _currentTrack;
    if (track == null) return;
    _onlineLyrics.remove(track.path);
    unawaited(_loadLyricsForTrack(track));
  }

  Future<void> _loadLastFmState() async {
    final service = _lastFm;
    if (service == null) return;
    try {
      final username = await service.readConnectedUsername();
      if (!mounted) return;
      setState(() {
        _lastFmUsername = username;
        _isLastFmConnected = username != null;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _lastFmEnabled = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _lastFmEnabled = false;
      });
    }
  }

  void _loadDiscordPresenceSettings() {
    _discordPresenceEnabled =
        widget.preferences?.getBool('discord_presence_enabled_v1') ?? false;
  }

  void _recordPlaybackPosition(Duration position) {
    if (_repeatEnabled &&
        _lastPlaybackPosition - position > const Duration(seconds: 3)) {
      _listenedToCurrentTrack = Duration.zero;
      _hasScrobbledCurrentTrack = false;
      _trackStartedAt = DateTime.now();
    }
    if (_isPlaying) {
      final elapsed = position - _lastPlaybackPosition;
      if (elapsed > Duration.zero && elapsed <= const Duration(seconds: 3)) {
        _listenedToCurrentTrack += elapsed;
        final track = _currentTrack;
        if (track != null) _recordListeningTime(elapsed, track);
      }
    }
    _lastPlaybackPosition = position;
    _maybeScrobble();
  }

  Future<void> _loadListeningStats() async {
    final encoded = widget.preferences?.getString('listening_stats_v1');
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map<String, dynamic> && mounted) {
        setState(() => _listeningStats.addAll(decoded));
      }
    } on FormatException {
      if (mounted) {
        setState(() => _libraryError = _t('statsReadError'));
      }
    }
  }

  void _recordListeningTime(Duration elapsed, _Track track) {
    final year = DateTime.now().year.toString();
    final yearData = _mutableStringMap(_listeningStats[year]);
    final artists = _mutableStringMap(yearData['artists']);
    final songs = _mutableStringMap(yearData['songs']);
    final milliseconds = elapsed.inMilliseconds;
    final artist = track.artist.trim().isEmpty
        ? _t('unknownArtist')
        : track.artist;
    final song = _mutableStringMap(songs[track.path]);
    song['title'] ??= track.title;
    song['artist'] ??= artist;
    song['milliseconds'] =
        ((song['milliseconds'] as num?)?.toInt() ?? 0) + milliseconds;
    song['plays'] ??= 0;
    artists[artist] = ((artists[artist] as num?)?.toInt() ?? 0) + milliseconds;
    yearData['totalMs'] =
        ((yearData['totalMs'] as num?)?.toInt() ?? 0) + milliseconds;
    yearData['artists'] = artists;
    yearData['songs'] = songs..[track.path] = song;
    _listeningStats[year] = yearData;

    _scheduleListeningStatsSave();
  }

  void _recordTrackPlay(_Track track) {
    _recentlyPlayedPaths
      ..remove(track.path)
      ..insert(0, track.path);
    if (_recentlyPlayedPaths.length > 50) {
      _recentlyPlayedPaths.removeLast();
    }
    final year = DateTime.now().year.toString();
    final yearData = _mutableStringMap(_listeningStats[year]);
    final songs = _mutableStringMap(yearData['songs']);
    final song = _mutableStringMap(songs[track.path]);
    song['title'] ??= track.title;
    song['artist'] ??= track.artist;
    song['milliseconds'] ??= 0;
    song['plays'] = ((song['plays'] as num?)?.toInt() ?? 0) + 1;
    yearData['songs'] = songs..[track.path] = song;
    _listeningStats[year] = yearData;
    _scheduleListeningStatsSave();
  }

  Map<String, dynamic> _mutableStringMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  void _scheduleListeningStatsSave() {
    _statsDirty = true;
    if (_statsSaveInProgress || _statsSaveTimer?.isActive == true) return;

    final lastSaved = _lastStatsSave;
    final remaining = lastSaved == null
        ? Duration.zero
        : lastSaved.add(const Duration(seconds: 12)).difference(DateTime.now());
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _statsSaveTimer = Timer(delay, () {
      _statsSaveTimer = null;
      unawaited(_saveListeningStats());
    });
  }

  Future<void> _saveListeningStats({bool force = false}) async {
    _statsSaveTimer?.cancel();
    _statsSaveTimer = null;
    final preferences = widget.preferences;
    if (preferences == null) return;
    if (_statsSaveInProgress) {
      _statsDirty = true;
      return;
    }
    if (!_statsDirty && !force) return;

    _statsSaveInProgress = true;
    _statsDirty = false;
    try {
      final snapshot = Map<String, dynamic>.from(_listeningStats);
      final encoded = await compute(_encodeListeningStats, snapshot);
      final saved = await preferences.setString('listening_stats_v1', encoded);
      _lastStatsSave = DateTime.now();
      if (!saved) {
        _statsDirty = true;
        if (mounted) setState(() => _libraryError = _t('statsSaveError'));
      }
    } on Object {
      _lastStatsSave = DateTime.now();
      _statsDirty = true;
      if (mounted) setState(() => _libraryError = _t('statsSaveError'));
    } finally {
      _statsSaveInProgress = false;
      if (_statsDirty && mounted) _scheduleListeningStatsSave();
    }
  }

  Future<void> _loadTrackMetadataOverrides() async {
    final encoded = widget.preferences?.getString(
      'track_metadata_overrides_v1',
    );
    if (encoded == null) return;
    try {
      _trackMetadataOverrides.addAll(decodeTrackMetadataOverrides(encoded));
    } on FormatException {
      if (mounted) setState(() => _libraryError = _t('trackInfoReadError'));
    }
  }

  Future<void> _saveTrackMetadataOverrides(
    Map<String, Map<String, String>> overrides,
  ) async {
    final preferences = widget.preferences;
    if (preferences != null) {
      final saved = await preferences.setString(
        'track_metadata_overrides_v1',
        encodeTrackMetadataOverrides(overrides),
      );
      if (!saved) throw Exception(_t('trackInfoSaveError'));
    }
    _trackMetadataOverrides
      ..clear()
      ..addAll(overrides);
  }

  Future<void> _loadPlaylists() async {
    final preferences = widget.preferences;
    final encoded = preferences?.getString('playlists_v1');
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid playlist data');
      }
      final playlists = <String, List<String>>{};
      for (final entry in decoded.entries) {
        if (entry.value is! List ||
            !(entry.value as List).every((path) => path is String)) {
          throw const FormatException('Invalid playlist tracks');
        }
        playlists[entry.key] = (entry.value as List).cast<String>();
      }
      final covers = <String, String>{};
      var coversInvalid = false;
      final savedCovers = preferences?.getString('playlist_covers_v1');
      if (savedCovers != null) {
        try {
          final decodedCovers = jsonDecode(savedCovers);
          if (decodedCovers is! Map<String, dynamic>) {
            throw const FormatException('Invalid playlist cover data');
          }
          for (final entry in decodedCovers.entries) {
            if (entry.value is String) {
              covers[entry.key] = entry.value as String;
            } else {
              coversInvalid = true;
            }
          }
        } on FormatException {
          coversInvalid = true;
        }
      }
      if (!mounted) return;
      setState(() {
        _playlists
          ..clear()
          ..addAll(playlists);
        _playlistCovers
          ..clear()
          ..addAll(covers);
      });
      if (coversInvalid) {
        setState(() => _libraryError = _t('playlistSaveError'));
      }
    } on FormatException {
      if (mounted) {
        setState(() => _libraryError = _t('playlistSaveError'));
      }
    }
  }

  Future<void> _savePlaylists() {
    final preferences = widget.preferences;
    if (preferences == null) return Future<void>.value();
    final playlistsSnapshot = jsonEncode(_playlists);
    final coversSnapshot = jsonEncode(_playlistCovers);
    final save = _playlistSaveQueue.then((_) async {
      try {
        final saved = await preferences.setString(
          'playlists_v1',
          playlistsSnapshot,
        );
        final coversSaved = await preferences.setString(
          'playlist_covers_v1',
          coversSnapshot,
        );
        if ((!saved || !coversSaved) && mounted) {
          _setError(_t('playlistSaveError'));
        }
      } on Exception {
        if (mounted) _setError(_t('playlistSaveError'));
      }
    });
    _playlistSaveQueue = save;
    return save;
  }

  Future<File> _playlistCoverFile(String playlist) async {
    final supportDirectory = await getApplicationSupportDirectory();
    final artworkDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}playlist-artwork',
    );
    final key = sha256.convert(utf8.encode(playlist)).toString();
    return File(
      '${artworkDirectory.path}${Platform.pathSeparator}$key-cover.jpg',
    );
  }

  Future<void> _editTrackMetadata(_Track track) async {
    const fields = [
      ('title', 'trackTitle'),
      ('artist', 'trackArtist'),
      ('album', 'trackAlbum'),
      ('albumArtist', 'trackAlbumArtist'),
      ('trackNumber', 'trackNumber'),
      ('trackTotal', 'trackTotal'),
      ('discNumber', 'discNumber'),
      ('discTotal', 'discTotal'),
      ('year', 'trackYear'),
      ('genre', 'trackGenre'),
      ('composer', 'trackComposer'),
      ('performers', 'trackPerformers'),
      ('publisher', 'trackPublisher'),
      ('copyright', 'trackCopyright'),
      ('comment', 'trackComment'),
      ('isrc', 'trackIsrc'),
      ('bpm', 'trackBpm'),
      ('language', 'trackLanguage'),
      ('lyrics', 'trackLyrics'),
      ('mbid', 'trackMbid'),
    ];
    final initialValues = <String, String>{
      'title': track.title,
      'artist': track.artist,
      'album': track.album ?? '',
      'albumArtist': track.albumArtist ?? '',
      'trackNumber': track.trackNumber?.toString() ?? '',
      'trackTotal': track.trackTotal?.toString() ?? '',
      'discNumber': track.discNumber?.toString() ?? '',
      'discTotal': track.discTotal?.toString() ?? '',
      'year': track.year?.toString() ?? '',
      'genre': track.genre ?? '',
      'composer': track.composer ?? '',
      'performers': track.performers ?? '',
      'publisher': track.publisher ?? '',
      'copyright': track.copyright ?? '',
      'comment': track.comment ?? '',
      'isrc': track.isrc ?? '',
      'bpm': track.bpm ?? '',
      'language': track.language ?? '',
      'lyrics': track.embeddedLyrics ?? '',
      'mbid': track.mbid ?? '',
    };
    final controllers = {
      for (final (key, _) in fields)
        key: TextEditingController(text: initialValues[key]),
    };
    PreparedArtwork? selectedArtwork = track.cover != null
        ? (
            cover: track.cover!,
            backdrop: track.backgroundArt ?? track.cover!,
            palettePrimary: track.palettePrimary ?? 0xFF0F0F0F,
            paletteAccent: track.paletteAccent ?? 0xFF333333,
          )
        : null;
    var artworkChanged = false;
    var removeArtwork = false;
    String? validationError;

    try {
      if (selectedArtwork == null && track.coverFile != null) {
        final coverBytes = await File(track.coverFile!).readAsBytes();
        final backdropBytes = track.backdropFile == null
            ? coverBytes
            : await File(track.backdropFile!).readAsBytes();
        selectedArtwork = (
          cover: coverBytes,
          backdrop: backdropBytes,
          palettePrimary: track.palettePrimary ?? 0xFF0F0F0F,
          paletteAccent: track.paletteAccent ?? 0xFF333333,
        );
      }
      if (!mounted) return;
      final editedValues = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(_t('editTrackInfo')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selectedArtwork case final artwork?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            artwork.cover,
                            width: 104,
                            height: 104,
                            fit: BoxFit.cover,
                            cacheWidth: 208,
                            cacheHeight: 208,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_t('trackCover')),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              final file = await FilePicker.pickFile(
                                type: FileType.image,
                              );
                              if (file == null) return;
                              final bytes = await file.readAsBytes();
                              final prepared = await compute(
                                prepareArtwork,
                                bytes,
                              );
                              if (prepared == null) {
                                setDialogState(
                                  () =>
                                      validationError = _t('trackCoverInvalid'),
                                );
                                return;
                              }
                              setDialogState(() {
                                selectedArtwork = prepared;
                                artworkChanged = true;
                                removeArtwork = false;
                                validationError = null;
                              });
                            } on Exception {
                              setDialogState(
                                () => validationError = _t('trackCoverInvalid'),
                              );
                            }
                          },
                          icon: const Icon(CupertinoIcons.photo),
                          label: Text(_t('chooseCover')),
                        ),
                        if (selectedArtwork != null)
                          TextButton.icon(
                            onPressed: () => setDialogState(() {
                              selectedArtwork = null;
                              artworkChanged = true;
                              removeArtwork = true;
                            }),
                            icon: const Icon(CupertinoIcons.trash),
                            label: Text(_t('removeCover')),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final (key, label) in fields)
                      TextField(
                        controller: controllers[key],
                        autofocus: key == 'title',
                        maxLength: key == 'lyrics' ? 10000 : 1000,
                        maxLines: key == 'lyrics' || key == 'comment' ? 4 : 1,
                        minLines: 1,
                        keyboardType:
                            const {
                              'trackNumber',
                              'trackTotal',
                              'discNumber',
                              'discTotal',
                              'year',
                              'bpm',
                            }.contains(key)
                            ? TextInputType.number
                            : TextInputType.text,
                        textInputAction: key == 'mbid'
                            ? TextInputAction.done
                            : TextInputAction.next,
                        decoration: InputDecoration(labelText: _t(label)),
                      ),
                    if (validationError case final error?) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_t('cancel')),
              ),
              FilledButton(
                onPressed: () {
                  final values = {
                    for (final (key, _) in fields)
                      key: controllers[key]!.text.trim(),
                  };
                  if (values['title']!.isEmpty) {
                    setDialogState(
                      () => validationError = _t('trackTitleRequired'),
                    );
                    return;
                  }
                  const numericFields = {
                    'trackNumber',
                    'trackTotal',
                    'discNumber',
                    'discTotal',
                    'year',
                    'bpm',
                  };
                  for (final key in numericFields) {
                    final value = values[key]!;
                    final parsed = int.tryParse(value);
                    if (value.isNotEmpty &&
                        (parsed == null ||
                            parsed < 1 ||
                            (key == 'year' && parsed > 9999) ||
                            (key == 'bpm' && parsed > 1000))) {
                      setDialogState(
                        () => validationError = _t('trackNumbersInvalid'),
                      );
                      return;
                    }
                  }
                  Navigator.pop(context, values);
                },
                child: Text(_t('save')),
              ),
            ],
          ),
        ),
      );
      if (editedValues == null || !mounted) return;
      final overrides = {
        for (final entry in _trackMetadataOverrides.entries)
          entry.key: Map<String, String>.from(entry.value),
      };
      final values = Map<String, String>.from(editedValues);
      if (artworkChanged && selectedArtwork != null) {
        final artworkFiles = await _saveTrackArtwork(
          track.path,
          selectedArtwork!,
        );
        values.addAll({
          'coverFile': artworkFiles.coverFile,
          'backdropFile': artworkFiles.backdropFile,
          'palettePrimary': selectedArtwork!.palettePrimary.toString(),
          'paletteAccent': selectedArtwork!.paletteAccent.toString(),
        });
      }
      if (removeArtwork) {
        values
          ..remove('coverFile')
          ..remove('backdropFile')
          ..remove('palettePrimary')
          ..remove('paletteAccent')
          ..['removeArtwork'] = 'true';
      } else {
        values.remove('removeArtwork');
      }
      overrides[track.path] = values;
      await _saveTrackMetadataOverrides(overrides);
      if (!mounted) return;
      final updatedTrack = track.copyWithMetadata(
        values,
        cover: artworkChanged ? selectedArtwork?.cover : null,
        backgroundArt: artworkChanged ? selectedArtwork?.backdrop : null,
        palettePrimary: artworkChanged ? selectedArtwork?.palettePrimary : null,
        paletteAccent: artworkChanged ? selectedArtwork?.paletteAccent : null,
        clearArtwork: removeArtwork,
        clearArtworkBytes: artworkChanged,
        coverFile: artworkChanged ? values['coverFile'] : null,
        backdropFile: artworkChanged ? values['backdropFile'] : null,
      );
      setState(() {
        for (var index = 0; index < _libraryTracks.length; index++) {
          if (_libraryTracks[index].path == track.path) {
            _libraryTracks[index] = updatedTrack;
          }
        }
        for (var index = 0; index < _queue.length; index++) {
          if (_queue[index].path == track.path) {
            _queue[index] = updatedTrack;
          }
        }
      });
      _setMessage(_t('trackInfoSaved'));
    } on Exception {
      _setError(_t('trackInfoSaveError'));
    } finally {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
  }

  Future<void> _addMusicFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path == null || !mounted) return;
      if (_loadedFolders.contains(path)) {
        _setMessage(_t('folderAlreadyAdded'));
        return;
      }
      final folders = {
        ...?widget.preferences?.getStringList('music_folders'),
        ..._loadedFolders,
        path,
      }.toList();
      final saved = await widget.preferences?.setStringList(
        'music_folders',
        folders,
      );
      if (saved == false) throw Exception(_t('folderSaveError'));
      setState(() {
        _libraryError = null;
      });
      await _loadMusicFolder(path);
      if (mounted) setState(() {});
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _libraryError = _t('folderReadError', {'error': error}));
      }
    }
  }

  Future<void> _removeMusicFolder(String path) async {
    final folders = _loadedFolders.where((folder) => folder != path).toList();
    final saved = await widget.preferences?.setStringList(
      'music_folders',
      folders,
    );
    if (saved == false) {
      setState(() => _libraryError = _t('folderSaveError'));
      return;
    }
    final normalizedFolder = path.toLowerCase().replaceAll('/', '\\');
    final folderPrefix = normalizedFolder.endsWith('\\')
        ? normalizedFolder
        : '$normalizedFolder\\';
    final removedCachePaths = _trackLibraryCache.keys
        .where(
          (cachedPath) => cachedPath.toLowerCase().startsWith(folderPrefix),
        )
        .toList();
    for (final cachedPath in removedCachePaths) {
      _trackLibraryCache.remove(cachedPath);
    }
    if (removedCachePaths.isNotEmpty) {
      _trackLibraryCacheDirty = true;
      unawaited(_saveTrackLibraryCache());
    }
    setState(() {
      _loadedFolders.remove(path);
      _libraryTracks.removeWhere(
        (track) => track.path.toLowerCase().startsWith(folderPrefix),
      );
    });
  }

  Future<void> _createPlaylist() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _PlaylistNameDialog(
        title: _t('newPlaylist'),
        label: _t('playlistName'),
        cancelLabel: _t('cancel'),
        createLabel: _t('create'),
      ),
    );
    final normalized = name?.trim();
    if (normalized == null || normalized.isEmpty || !mounted) return;
    if (_playlists.keys.any(
      (existing) => existing.toLowerCase() == normalized.toLowerCase(),
    )) {
      _setMessage(_t('duplicatePlaylist'));
      return;
    }
    _playlists[normalized] = [];
    _selectedPlaylist = normalized;
    unawaited(_savePlaylists());
  }

  void _addToPlaylist(_Track track, String playlist) {
    final entries = _playlists[playlist];
    if (entries == null || entries.contains(track.path)) return;
    entries.add(track.path);
    unawaited(_savePlaylists());
  }

  Future<void> _choosePlaylistCover(String playlist) async {
    try {
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null) return;
      final artwork = await compute(prepareArtwork, await file.readAsBytes());
      if (artwork == null) {
        _setError(_t('trackCoverInvalid'));
        return;
      }
      final coverFile = await _playlistCoverFile(playlist);
      await coverFile.parent.create(recursive: true);
      await coverFile.writeAsBytes(artwork.cover, flush: true);
      await FileImage(coverFile).evict();
      if (!mounted) return;
      _playlistCovers[playlist] = coverFile.path;
      _playlistCoverRevisions.update(
        playlist,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
      unawaited(_savePlaylists());
    } on Exception {
      if (mounted) _setError(_t('trackCoverInvalid'));
    }
  }

  Future<void> _removePlaylistCover(String playlist) async {
    try {
      final coverFile = await _playlistCoverFile(playlist);
      if (_playlistCovers[playlist] == coverFile.path &&
          await coverFile.exists()) {
        await FileImage(coverFile).evict();
        await coverFile.delete();
      }
      if (!mounted) return;
      _playlistCovers.remove(playlist);
      _playlistCoverRevisions.update(
        playlist,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
      unawaited(_savePlaylists());
    } on Exception {
      if (mounted) _setError(_t('playlistSaveError'));
    }
  }

  Future<void> _deletePlaylist(String name) async {
    _playlists.remove(name);
    _playlistCovers.remove(name);
    if (_selectedPlaylist == name) _selectedPlaylist = null;
    unawaited(_savePlaylists());
  }

  Future<void> _playLibraryTracks(List<_Track> tracks, _Track selected) async {
    if (tracks.isEmpty) return;
    final index = tracks.indexWhere((track) => track.path == selected.path);
    if (index < 0) return;
    setState(() {
      _queue
        ..clear()
        ..addAll(tracks);
      _currentIndex = -1;
      _playerPlaylistLength = 0;
    });
    await _openTrack(index, autoplay: true);
  }

  Widget _playlistArtwork(String playlist, double size) {
    final path = _playlistCovers[playlist];
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: size,
        height: size,
        child: path == null
            ? const CustomPaint(painter: _AlbumArtworkPainter())
            : Image.file(
                File(path),
                key: ValueKey(
                  '$path:${_playlistCoverRevisions[playlist] ?? 0}',
                ),
                fit: BoxFit.cover,
                cacheWidth: (size * 2).round(),
                cacheHeight: (size * 2).round(),
                excludeFromSemantics: true,
                errorBuilder: (context, error, stackTrace) =>
                    const CustomPaint(painter: _AlbumArtworkPainter()),
              ),
      ),
    );
  }

  Widget _catalogArtwork(
    _Track track, {
    required bool circular,
    required String fallbackLabel,
  }) {
    const size = 56.0;
    final borderRadius = BorderRadius.circular(circular ? size / 2 : 8);
    final imageProvider = track.coverImageProvider;
    final image = imageProvider == null
        ? circular
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: Center(
                    child: Text(
                      fallbackLabel.runes.isEmpty
                          ? '?'
                          : String.fromCharCode(fallbackLabel.runes.first)
                                .toUpperCase(),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              : const CustomPaint(painter: _AlbumArtworkPainter())
        : Image(
            image: ResizeImage(
              imageProvider,
              width: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              height: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            ),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (context, error, stackTrace) => circular
                ? ColoredBox(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: Center(
                      child: Text(
                        fallbackLabel.runes.isEmpty
                            ? '?'
                            : String.fromCharCode(fallbackLabel.runes.first)
                                  .toUpperCase(),
                      ),
                    ),
                  )
                : const CustomPaint(painter: _AlbumArtworkPainter()),
          );
    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox.square(dimension: size, child: image),
    );
  }

  String _playlistCount(int count) => _t(
    count == 1 ? 'playlistSongSingular' : 'playlistSongs',
    {'count': count},
  );

  Widget _playlistSelectorCard({
    required String title,
    required String subtitle,
    required Widget artwork,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: subtitle.isEmpty ? title : '$title, $subtitle',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 220,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected
                  ? _progressColor.withValues(alpha: 0.16)
                  : foreground.withValues(alpha: 0.045),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? _progressColor.withValues(alpha: 0.8)
                    : foreground.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                artwork,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLibrary() async {
    if (_libraryTracks.isEmpty && _loadedFolders.isEmpty) {
      await _addMusicFolder();
      if (!mounted || _libraryTracks.isEmpty) return;
    }
    if (!mounted) return;
    var selectedPlaylist = _selectedPlaylist;
    var selectedSection = 'songs';
    String? selectedArtist;
    (String, String)? selectedAlbum;
    final searchController = TextEditingController();
    var searchQuery = '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final playlistPaths = selectedPlaylist == null
              ? null
              : _playlists[selectedPlaylist] ?? const <String>[];
          final visiblePlaylists = _playlists.keys.where((playlist) {
            if (matchesLibrarySearch(
              query: searchQuery,
              title: playlist,
              artist: '',
            )) {
              return true;
            }
            final paths = _playlists[playlist] ?? const <String>[];
            return _libraryTracks.any(
              (track) =>
                  paths.contains(track.path) &&
                  matchesLibrarySearch(
                    query: searchQuery,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                  ),
            );
          }).toList();
          final candidateTracks = _libraryTracks
              .where(
                (track) =>
                    (playlistPaths == null ||
                        playlistPaths.contains(track.path)) &&
                    matchesLibrarySearch(
                      query: searchQuery,
                      title: track.title,
                      artist: track.artist,
                      album: track.album,
                      playlists: _playlists.entries
                          .where((entry) => entry.value.contains(track.path))
                          .map((entry) => entry.key),
                    ),
              )
              .toList();
          final tracks = candidateTracks.where((track) {
            if (selectedArtist != null && track.artist != selectedArtist) {
              return false;
            }
            if (selectedAlbum case final album?) {
              final name = track.album?.trim().isNotEmpty == true
                  ? track.album!.trim()
                  : File(track.path).parent.uri.pathSegments
                        .where((part) => part.isNotEmpty)
                        .last;
              final artist = track.albumArtist?.trim().isNotEmpty == true
                  ? track.albumArtist!.trim()
                  : track.artist;
              if ((name, artist) != album) return false;
            }
            return true;
          }).toList();
          final albums = <(String, String), List<_Track>>{};
          final artists = <String, List<_Track>>{};
          for (final track in candidateTracks) {
            final albumName = track.album?.trim().isNotEmpty == true
                ? track.album!.trim()
                : File(track.path).parent.uri.pathSegments
                      .where((part) => part.isNotEmpty)
                      .last;
            final albumArtist = track.albumArtist?.trim().isNotEmpty == true
                ? track.albumArtist!.trim()
                : track.artist;
            albums.putIfAbsent((albumName, albumArtist), () => []).add(track);
            artists.putIfAbsent(track.artist, () => []).add(track);
          }
          final albumEntries = albums.entries.toList()
            ..sort((first, second) {
              final byName = first.key.$1.toLowerCase().compareTo(
                second.key.$1.toLowerCase(),
              );
              return byName != 0
                  ? byName
                  : first.key.$2.toLowerCase().compareTo(
                      second.key.$2.toLowerCase(),
                    );
            });
          final artistEntries = artists.entries.toList()
            ..sort(
              (first, second) =>
                  first.key.toLowerCase().compareTo(second.key.toLowerCase()),
            );
          final sectionItemCount = switch (selectedSection) {
            'albums' => albumEntries.length,
            'artists' => artistEntries.length,
            _ => tracks.length,
          };
          return Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 900,
                maxHeight: 720,
                minWidth: 560,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(CupertinoIcons.music_note_list, size: 26),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _t('library'),
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _t('addMusicFolder'),
                          onPressed: () async {
                            await _addMusicFolder();
                            setDialogState(() {});
                          },
                          icon: const Icon(CupertinoIcons.folder_badge_plus),
                        ),
                        IconButton(
                          tooltip: _t('createPlaylist'),
                          onPressed: () async {
                            await _createPlaylist();
                            selectedPlaylist = _selectedPlaylist;
                            setDialogState(() {});
                          },
                          icon: const Icon(CupertinoIcons.music_note_list),
                        ),
                        IconButton(
                          tooltip: _t('close'),
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(CupertinoIcons.xmark),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: searchController,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) =>
                          setDialogState(() => searchQuery = value.trim()),
                      decoration: InputDecoration(
                        hintText: _t('searchLibrary'),
                        prefixIcon: const Icon(CupertinoIcons.search),
                        suffixIcon: searchQuery.isEmpty
                            ? null
                            : IconButton(
                                tooltip: _t('clearSearch'),
                                onPressed: () {
                                  searchController.clear();
                                  setDialogState(() => searchQuery = '');
                                },
                                icon: const Icon(CupertinoIcons.xmark_circle),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _t('playlistsHeading'),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 92,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _playlistSelectorCard(
                            title: _t('allSongs', {
                              'count': _libraryTracks.length,
                            }),
                            subtitle: '',
                            artwork: Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                color: _foreground.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(CupertinoIcons.music_note_list),
                            ),
                            selected: selectedPlaylist == null,
                            onTap: () => setDialogState(() {
                              selectedPlaylist = null;
                              selectedArtist = null;
                              selectedAlbum = null;
                            }),
                          ),
                          const SizedBox(width: 8),
                          for (final playlist in visiblePlaylists) ...[
                            _playlistSelectorCard(
                              title: playlist,
                              subtitle: _playlistCount(
                                _playlists[playlist]!.length,
                              ),
                              artwork: _playlistArtwork(playlist, 68),
                              selected: selectedPlaylist == playlist,
                              onTap: () => setDialogState(() {
                                selectedPlaylist = playlist;
                                selectedArtist = null;
                                selectedAlbum = null;
                                selectedSection = 'songs';
                              }),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'songs',
                          label: Text(_t('songs')),
                          icon: const Icon(CupertinoIcons.music_note),
                        ),
                        ButtonSegment(
                          value: 'albums',
                          label: Text(_t('albums')),
                          icon: const Icon(CupertinoIcons.square_stack),
                        ),
                        ButtonSegment(
                          value: 'artists',
                          label: Text(_t('artists')),
                          icon: const Icon(CupertinoIcons.person_2),
                        ),
                      ],
                      selected: {selectedSection},
                      onSelectionChanged: (selection) => setDialogState(() {
                        selectedSection = selection.first;
                      }),
                    ),
                    if (selectedPlaylist != null) ...[
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: _foreground.withValues(alpha: 0.045),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              _playlistArtwork(selectedPlaylist!, 72),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      selectedPlaylist!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _playlistCount(
                                        _playlists[selectedPlaylist]!.length,
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: tracks.isEmpty
                                    ? null
                                    : () => _playLibraryTracks(
                                        tracks,
                                        tracks.first,
                                      ),
                                icon: const Icon(
                                  CupertinoIcons.play_fill,
                                  size: 17,
                                ),
                                label: Text(_t('playPlaylist')),
                              ),
                              PopupMenuButton<String>(
                                tooltip: _t('playlistActions'),
                                onSelected: (action) async {
                                  final playlist = selectedPlaylist!;
                                  if (action == 'cover') {
                                    await _choosePlaylistCover(playlist);
                                  } else if (action == 'remove-cover') {
                                    await _removePlaylistCover(playlist);
                                  } else {
                                    await _deletePlaylist(playlist);
                                    selectedPlaylist = null;
                                  }
                                  setDialogState(() {});
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'cover',
                                    child: Text(_t('setPlaylistCover')),
                                  ),
                                  if (_playlistCovers.containsKey(
                                    selectedPlaylist,
                                  ))
                                    PopupMenuItem(
                                      value: 'remove-cover',
                                      child: Text(_t('removePlaylistCover')),
                                    ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(_t('deletePlaylist')),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (_error case final error?) ...[
                      const SizedBox(height: 8),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (_message case final message?) ...[
                      const SizedBox(height: 8),
                      Text(
                        message,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                    const Divider(height: 20),
                    if (sectionItemCount == 0)
                      Expanded(
                        child: Center(
                          child: Text(
                            searchQuery.isNotEmpty
                                ? _t('searchNoResults', {'query': searchQuery})
                                : _libraryTracks.isEmpty
                                ? _t('emptyLibrary')
                                : _t('emptyPlaylist'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          itemCount: sectionItemCount,
                          itemBuilder: (context, index) {
                            if (selectedSection == 'albums') {
                              final entry = albumEntries[index];
                              final album = entry.key;
                              final albumTracks = entry.value;
                              return ListTile(
                                leading: _catalogArtwork(
                                  albumTracks.first,
                                  circular: false,
                                  fallbackLabel: album.$1,
                                ),
                                title: Text(
                                  album.$1,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${album.$2} · ${_playlistCount(albumTracks.length)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => setDialogState(() {
                                  selectedPlaylist = null;
                                  selectedArtist = null;
                                  selectedAlbum = album;
                                  selectedSection = 'songs';
                                }),
                              );
                            }
                            if (selectedSection == 'artists') {
                              final entry = artistEntries[index];
                              return ListTile(
                                leading: _catalogArtwork(
                                  entry.value.first,
                                  circular: true,
                                  fallbackLabel: entry.key,
                                ),
                                title: Text(
                                  entry.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  _playlistCount(entry.value.length),
                                ),
                                onTap: () => setDialogState(() {
                                  selectedPlaylist = null;
                                  selectedArtist = entry.key;
                                  selectedAlbum = null;
                                  selectedSection = 'songs';
                                }),
                              );
                            }
                            final track = tracks[index];
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: track.coverImageProvider == null
                                      ? const CustomPaint(
                                          painter: _AlbumArtworkPainter(),
                                        )
                                      : Image(
                                          image: ResizeImage(
                                            track.coverImageProvider!,
                                            width:
                                                (44 *
                                                        MediaQuery.devicePixelRatioOf(
                                                          context,
                                                        ))
                                                    .round(),
                                            height:
                                                (44 *
                                                        MediaQuery.devicePixelRatioOf(
                                                          context,
                                                        ))
                                                    .round(),
                                          ),
                                          fit: BoxFit.cover,
                                          excludeFromSemantics: true,
                                          errorBuilder:
                                              (context, error, stack) =>
                                                  const CustomPaint(
                                                    painter:
                                                        _AlbumArtworkPainter(),
                                                  ),
                                        ),
                                ),
                              ),
                              title: Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${track.artist} · ${track.album ?? File(track.path).parent.path}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _playLibraryTracks(tracks, track),
                              trailing: Semantics(
                                label: _t('trackOptions'),
                                button: true,
                                child: PopupMenuButton<_LibraryTrackAction>(
                                  tooltip: _t('trackOptions'),
                                  icon: const Icon(CupertinoIcons.ellipsis),
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: (
                                        editMetadata: true,
                                        addToQueue: false,
                                        playlist: null,
                                      ),
                                      child: Text(_t('editTrackInfo')),
                                    ),
                                    PopupMenuItem(
                                      value: (
                                        editMetadata: false,
                                        addToQueue: true,
                                        playlist: null,
                                      ),
                                      child: Text(_t('addToQueue')),
                                    ),
                                    const PopupMenuDivider(),
                                    for (final playlist in _playlists.keys)
                                      PopupMenuItem(
                                        value: (
                                          editMetadata: false,
                                          addToQueue: false,
                                          playlist: playlist,
                                        ),
                                        child: Text(
                                          _t('addPlaylist', {'name': playlist}),
                                        ),
                                      ),
                                    if (_playlists.isEmpty)
                                      PopupMenuItem<_LibraryTrackAction>(
                                        enabled: false,
                                        child: Text(_t('createPlaylistFirst')),
                                      ),
                                  ],
                                  onSelected: (action) async {
                                    if (action.editMetadata) {
                                      await _editTrackMetadata(track);
                                    } else if (action.addToQueue) {
                                      await _addTrackToQueue(track);
                                    } else if (action.playlist
                                        case final playlist?) {
                                      _addToPlaylist(track, playlist);
                                    }
                                    setDialogState(() {});
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _t('folderSongCount', {
                          'folders': _loadedFolders.length,
                          'songs': _libraryTracks.length,
                        }),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    searchController.dispose();
  }

  Future<void> _showYearSummary() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final years = _listeningStats.keys.toList()
          ..sort((a, b) => b.compareTo(a));
        return AlertDialog(
          title: Text(_t('yearReview')),
          content: SizedBox(
            width: 480,
            child: years.isEmpty
                ? Text(_t('yearReviewEmpty'))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final year in years)
                        _YearSummary(
                          year: year,
                          languageCode: widget.languageCode,
                          data: Map<String, dynamic>.from(
                            _listeningStats[year] as Map,
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('close')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openCreditsDialog() async {
    var linkError = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> openLink(Uri uri) async {
            try {
              final opened = await launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
              );
              if (!opened && dialogContext.mounted) {
                setDialogState(() => linkError = true);
              }
            } on Exception {
              if (dialogContext.mounted) {
                setDialogState(() => linkError = true);
              }
            }
          }

          return AlertDialog(
            title: Text(_t('credits'), textAlign: TextAlign.center),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      image: true,
                      label: _t('creditsAvatar'),
                      child: ClipOval(
                        child: Image.asset(
                          'devbio/jane1.jpg',
                          key: const ValueKey('credits-avatar'),
                          width: 156,
                          height: 156,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox(
                                width: 156,
                                height: 156,
                                child: Icon(CupertinoIcons.person, size: 72),
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _t('creditsName'),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _t('creditsTagline'),
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'River 1.0.0',
                      key: const ValueKey('credits-app-version'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_t('discordContact')),
                        IconButton(
                          key: const ValueKey('credits-discord-copy'),
                          tooltip: _t('copyDiscord'),
                          onPressed: () async {
                            try {
                              await Clipboard.setData(
                                const ClipboardData(text: 'janectrl'),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(_t('discordCopied'))),
                                );
                              }
                            } on Exception {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(_t('discordCopyError')),
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(CupertinoIcons.doc_on_doc),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey('credits-lastfm'),
                        onPressed: () => openLink(
                          Uri.https('www.last.fm', '/user/janectrl'),
                        ),
                        icon: const Icon(CupertinoIcons.music_note),
                        label: Text(_t('lastFmProfile')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey('credits-github'),
                        onPressed: () =>
                            openLink(Uri.https('github.com', '/janectrl')),
                        icon: const Icon(
                          CupertinoIcons.chevron_left_slash_chevron_right,
                        ),
                        label: Text(_t('githubProfile')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('credits-kofi'),
                        onPressed: () => openLink(
                          Uri.https('ko-fi.com', '/rivermusicplayer'),
                        ),
                        icon: const Icon(CupertinoIcons.heart_fill),
                        label: Text(_t('supportOnKofi')),
                      ),
                    ),
                    if (linkError) ...[
                      const SizedBox(height: 12),
                      Text(
                        _t('creditsLinkError'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_t('close')),
              ),
            ],
          );
        },
      ),
    );
  }

  String _shortcutActionLabel(PlaybackShortcutAction action) =>
      switch (action) {
        PlaybackShortcutAction.playPause => _t('shortcutPlayPause'),
        PlaybackShortcutAction.previousTrack => _t('shortcutPreviousTrack'),
        PlaybackShortcutAction.nextTrack => _t('shortcutNextTrack'),
        PlaybackShortcutAction.seekBackward => _t('shortcutSeekBackward'),
        PlaybackShortcutAction.seekForward => _t('shortcutSeekForward'),
        PlaybackShortcutAction.volumeDown => _t('shortcutVolumeDown'),
        PlaybackShortcutAction.volumeUp => _t('shortcutVolumeUp'),
        PlaybackShortcutAction.toggleRepeat => _t('shortcutToggleRepeat'),
      };

  Future<void> _changePlaybackShortcut(
    PlaybackShortcutAction action,
    StateSetter setDialogState,
  ) async {
    final shortcut = await _capturePlaybackShortcut();
    if (shortcut == null) return;
    final conflictsWithSpace =
        action != PlaybackShortcutAction.playPause &&
        shortcut.logicalKeyId == LogicalKeyboardKey.space.keyId &&
        !shortcut.control &&
        !shortcut.alt &&
        !shortcut.shift &&
        !shortcut.meta;
    if (conflictsWithSpace ||
        _playbackShortcuts.entries.any(
          (entry) => entry.key != action && entry.value == shortcut,
        )) {
      setState(() => _libraryError = _t('shortcutConflict'));
      setDialogState(() {});
      return;
    }
    final nextShortcuts = Map<PlaybackShortcutAction, PlaybackShortcut>.of(
      _playbackShortcuts,
    )..[action] = shortcut;
    if (await _savePlaybackSettings(shortcuts: nextShortcuts)) {
      setDialogState(() {});
    }
  }

  Future<void> _resetPlaybackSettings(StateSetter setDialogState) async {
    if (await _savePlaybackSettings(
      layout: PlaybackControlLayout.modern,
      seekStepSeconds: 5,
      volumeStepPercent: 5,
      shortcuts: defaultPlaybackShortcuts(),
    )) {
      setDialogState(() {});
    }
  }

  Future<void> _openCustomizationSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('librarySettings')),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _t('controlLayout'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<PlaybackControlLayout>(
                    key: const ValueKey('control-layout-setting'),
                    initialValue: _controlLayout,
                    items: [
                      DropdownMenuItem(
                        value: PlaybackControlLayout.modern,
                        child: Text(_t('controlLayoutModern')),
                      ),
                      DropdownMenuItem(
                        value: PlaybackControlLayout.classic,
                        child: Text(_t('controlLayoutClassic')),
                      ),
                    ],
                    onChanged: (layout) async {
                      if (layout == null) return;
                      await _savePlaybackSettings(layout: layout);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: ValueKey('seek-step-$_seekStepSeconds'),
                    initialValue: _seekStepSeconds,
                    decoration: InputDecoration(
                      labelText: _t('seekStep', {'seconds': _seekStepSeconds}),
                    ),
                    items: [
                      for (final seconds in [5, 10, 15, 30])
                        DropdownMenuItem(
                          value: seconds,
                          child: Text('$seconds s'),
                        ),
                    ],
                    onChanged: (seconds) async {
                      if (seconds == null) return;
                      await _savePlaybackSettings(seekStepSeconds: seconds);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    key: ValueKey('volume-step-$_volumeStepPercent'),
                    initialValue: _volumeStepPercent,
                    decoration: InputDecoration(
                      labelText: _t('volumeStep', {
                        'percent': _volumeStepPercent,
                      }),
                    ),
                    items: [
                      for (final percent in [2, 5, 10, 20])
                        DropdownMenuItem(
                          value: percent,
                          child: Text('$percent%'),
                        ),
                    ],
                    onChanged: (percent) async {
                      if (percent == null) return;
                      await _savePlaybackSettings(volumeStepPercent: percent);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _t('keyboardShortcuts'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _t('spaceAlwaysPlayback'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  for (final action in PlaybackShortcutAction.values)
                    ListTile(
                      key: ValueKey('shortcut-row-${action.name}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        _shortcutActionLabel(action),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: OutlinedButton(
                        key: ValueKey('shortcut-change-${action.name}'),
                        onPressed: () =>
                            _changePlaybackShortcut(action, setDialogState),
                        child: Text(_playbackShortcuts[action]!.label),
                      ),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('reset-playback-controls'),
                    onPressed: () => _resetPlaybackSettings(setDialogState),
                    icon: const Icon(CupertinoIcons.arrow_counterclockwise),
                    label: Text(_t('resetControls')),
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    key: const ValueKey('economy-mode-toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(_t('economyMode')),
                    subtitle: Text(_t('economyModeDescription')),
                    value: _economyMode,
                    onChanged: (enabled) => unawaited(
                      _setEconomyModeEnabled(enabled, setDialogState),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PlayerSkinEditor(
                    languageCode: widget.languageCode,
                    skin: widget.skin,
                    skins: widget.skinProfiles,
                    onSelect: (skin) async {
                      try {
                        await widget.onSkinSelected?.call(skin);
                        setDialogState(() {});
                      } on Exception {
                        if (mounted) {
                          setState(() => _libraryError = _t('skinSaveError'));
                        }
                      }
                    },
                    onChange: (skin) {
                      widget.onSkinChanged?.call(skin);
                      setDialogState(() {});
                    },
                    onCommit: widget.onSkinCommit ?? () async {},
                    onSaveAs: (name) async {
                      try {
                        await widget.onSkinSaveAs?.call(name);
                      } on Exception {
                        if (mounted) {
                          setState(() => _libraryError = _t('skinSaveError'));
                        }
                      }
                    },
                    onDelete: () async {
                      try {
                        await widget.onSkinDelete?.call();
                      } on Exception {
                        if (mounted) {
                          setState(() => _libraryError = _t('skinSaveError'));
                        }
                      }
                    },
                    showCompactVisualizer: _showCompactVisualizer,
                    economyMode: _economyMode,
                    onCompactVisualizerChanged: (enabled) {
                      unawaited(_setCompactVisualizerEnabled(enabled));
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _t('font'),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: ValueKey(widget.fontFamily),
                    initialValue: widget.systemFonts.contains(widget.fontFamily)
                        ? widget.fontFamily
                        : 'Inter',
                    items: [
                      for (final font in widget.systemFonts)
                        DropdownMenuItem(value: font, child: Text(font)),
                    ],
                    onChanged: (font) async {
                      if (font == null) return;
                      try {
                        await widget.onFontFamilyChanged?.call(font);
                        if (mounted) setDialogState(() {});
                      } on Exception {
                        setState(() => _libraryError = _t('fontLoadError'));
                      }
                    },
                    decoration: InputDecoration(labelText: _t('systemFont')),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_t('lyricsSeparateFont')),
                    value: widget.skin.separateLyricsFont,
                    onChanged: (enabled) async {
                      widget.onSkinChanged?.call(
                        widget.skin.copyWith(separateLyricsFont: enabled),
                      );
                      setDialogState(() {});
                      try {
                        await widget.onSkinCommit?.call();
                      } on Exception {
                        if (mounted) {
                          setState(() => _libraryError = _t('skinSaveError'));
                        }
                      }
                    },
                  ),
                  if (widget.skin.separateLyricsFont)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'lyrics-font-${widget.skin.lyricsFontFamily}',
                        ),
                        initialValue:
                            widget.systemFonts.contains(
                              widget.skin.lyricsFontFamily,
                            )
                            ? widget.skin.lyricsFontFamily
                            : widget.fontFamily,
                        items: [
                          for (final font in widget.systemFonts)
                            DropdownMenuItem(value: font, child: Text(font)),
                        ],
                        decoration: InputDecoration(
                          labelText: _t('lyricsFont'),
                        ),
                        onChanged: (font) async {
                          if (font == null) return;
                          widget.onSkinChanged?.call(
                            widget.skin.copyWith(lyricsFontFamily: font),
                          );
                          setDialogState(() {});
                          try {
                            await widget.onSkinCommit?.call();
                          } on Exception {
                            if (mounted) {
                              setState(
                                () => _libraryError = _t('skinSaveError'),
                              );
                            }
                          }
                        },
                      ),
                    ),
                  if (widget.fontLoadError case final fontError?) ...[
                    const SizedBox(height: 8),
                    Text(
                      fontError,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      inactiveTrackColor: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.18),
                      thumbColor: Theme.of(context).colorScheme.onSurface,
                      overlayColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.14),
                      trackShape: const RoundedRectSliderTrackShape(),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                        elevation: 0,
                        pressedElevation: 0,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                      tickMarkShape: const RoundSliderTickMarkShape(
                        tickMarkRadius: 1.5,
                      ),
                      activeTickMarkColor: Theme.of(context)
                          .colorScheme
                          .primary,
                      inactiveTickMarkColor: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _t('textSize', {
                            'size': (widget.fontScale * 100).round(),
                          }),
                        ),
                        Slider(
                          value: widget.fontScale.clamp(0.85, 1.4),
                          min: 0.85,
                          max: 1.4,
                          divisions: 11,
                          label: '${(widget.fontScale * 100).round()}%',
                          onChanged: (scale) async {
                            await widget.onFontScaleChanged?.call(scale);
                            if (mounted) setDialogState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _openEqualizer,
                    icon: const Icon(CupertinoIcons.slider_horizontal_3),
                    label: Text(_t('equalizer')),
                  ),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const Icon(CupertinoIcons.cloud, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _t('lastFmSettings'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isLastFmConnected
                                      ? _t('lastFmAccount', {
                                          'name': _lastFmUsername ?? '',
                                        })
                                      : _t('lastFmNotConnected'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () async {
                              await _openLastFmSettings();
                              if (mounted) setDialogState(() {});
                            },
                            child: Text(_t('manageLastFm')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const Icon(CupertinoIcons.chat_bubble, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _t('discordRichPresence'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _discordPresenceEnabled
                                      ? _t('discordPresenceStatusOn')
                                      : _t('discordPresenceStatusOff'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () async {
                              await _openDiscordPresenceSettings();
                              if (mounted) setDialogState(() {});
                            },
                            child: Text(_t('manageDiscord')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _t('musicFolders'),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  for (final folder in _loadedFolders)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(CupertinoIcons.folder),
                      title: Text(
                        folder,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: _t('removeFolder'),
                        onPressed: () async {
                          await _removeMusicFolder(folder);
                          setDialogState(() {});
                        },
                        icon: const Icon(CupertinoIcons.minus_circle),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _addMusicFolder();
                      setDialogState(() {});
                    },
                    icon: const Icon(CupertinoIcons.folder_badge_plus),
                    label: Text(_t('addFolder')),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _showYearSummary,
                    icon: const Icon(CupertinoIcons.chart_bar),
                    label: Text(_t('yearReview')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('open-credits'),
                    onPressed: _openCreditsDialog,
                    icon: const Icon(CupertinoIcons.heart),
                    label: Text(_t('credits')),
                  ),
                  if (_libraryError case final error?) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('done')),
            ),
          ],
        ),
      ),
    );
  }

  void _maybeScrobble() {
    final track = _currentTrack;
    final duration = _duration > Duration.zero
        ? _duration
        : track?.taggedDuration ?? Duration.zero;
    if (!_lastFmEnabled ||
        !_isLastFmConnected ||
        track == null ||
        !_isPlaying ||
        _hasScrobbledCurrentTrack ||
        duration <= const Duration(seconds: 30)) {
      return;
    }

    final threshold = duration ~/ 2 < const Duration(minutes: 4)
        ? duration ~/ 2
        : const Duration(minutes: 4);
    if (_listenedToCurrentTrack < threshold) return;

    _hasScrobbledCurrentTrack = true;
    final startedAt = _trackStartedAt ?? DateTime.now();
    unawaited(_sendScrobble(track, duration, startedAt));
  }

  Future<void> _sendNowPlaying(_Track track) async {
    if (!_lastFmEnabled || !_isLastFmConnected) return;
    final service = _lastFm;
    if (service == null) return;
    try {
      await service.updateNowPlaying(track.toLastFmTrack(_duration));
    } on Exception {
      _setError(_t('lastFmUnavailable'));
    }
  }

  Future<void> _sendScrobble(
    _Track track,
    Duration duration,
    DateTime startedAt,
  ) async {
    final service = _lastFm;
    if (service == null) return;
    try {
      await service.scrobble(
        track: track.toLastFmTrack(duration),
        startedAt: startedAt,
      );
    } on Exception {
      _setError(_t('lastFmUnavailable'));
    }
  }

  Future<void> _openLastFmSettings() async {
    final service = _lastFm;
    if (service == null || !_lastFmEnabled) {
      _setMessage(_t('lastFmUnavailable'));
      return;
    }
    final username = await showDialog<String>(
      context: context,
      builder: (context) => LastFmSettingsDialog(
        service: service,
        initialUsername: _lastFmUsername,
        languageCode: widget.languageCode,
      ),
    );
    if (!mounted || username == null) return;
    setState(() {
      _lastFmUsername = username;
      _isLastFmConnected = username.isNotEmpty;
    });
    if (username.isNotEmpty && _isPlaying && _currentTrack != null) {
      await _sendNowPlaying(_currentTrack!);
    }
  }

  Future<void> _openDiscordPresenceSettings() async {
    final enabled = await showDialog<bool>(
      context: context,
      builder: (context) => DiscordPresenceSettingsDialog(
        languageCode: widget.languageCode,
        initialEnabled: _discordPresenceEnabled,
      ),
    );
    if (!mounted || enabled == null) return;

    final preferences = widget.preferences;
    if (preferences != null) {
      try {
        final savedEnabled = await preferences.setBool(
          'discord_presence_enabled_v1',
          enabled,
        );
        final removedLegacyId = await preferences.remove(
          'discord_application_id_v1',
        );
        if (!savedEnabled || !removedLegacyId) {
          _setError(_t('controlSettingsSaveError'));
          return;
        }
      } on Exception {
        _setError(_t('controlSettingsSaveError'));
        return;
      }
    }
    setState(() {
      _discordPresenceEnabled = enabled;
    });
    if (!enabled) {
      await _disconnectDiscordPresence();
    }
    if (enabled && _isPlaying) {
      await _syncDiscordPresence();
    } else if (!enabled) {
      _discordConnectionErrorShown = false;
    }
  }

  Future<void> _disconnectDiscordPresence() async {
    try {
      await _discordPresence.disconnect();
    } on DiscordRPCException {
      _notifyDiscordUnavailable('discordConnectionUnavailable');
    } on Exception {
      _notifyDiscordUnavailable('discordConnectionUnavailable');
    }
  }

  Future<void> _syncDiscordPresence() async {
    try {
      if (!_discordPresenceEnabled) {
        await _discordPresence.disconnect();
        return;
      }
      final track = _currentTrack;
      if (!_isPlaying || track == null) {
        await _discordPresence.clear();
        return;
      }
      await _discordPresence.setNowPlaying(
        title: track.title,
        artist: track.artist,
        position: _position.value,
        duration: _duration,
      );
      _discordConnectionErrorShown = false;
    } on UnsupportedError {
      _notifyDiscordUnavailable('discordConnectionUnavailable');
    } on DiscordRPCException {
      _notifyDiscordUnavailable('discordConnectionUnavailable');
    } on Exception {
      _notifyDiscordUnavailable('discordConnectionUnavailable');
    }
  }

  void _notifyDiscordUnavailable(String key) {
    if (_discordConnectionErrorShown) return;
    _discordConnectionErrorShown = true;
    _setMessage(_t(key));
  }

  void _setMessage(String message) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _error = null;
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _message = null;
    });
  }

  Widget _wrapDropTarget(Widget child) {
    if (!widget.enableDropTarget) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) async {
        setState(() => _isDragging = false);
        final files = details.files.whereType<DropItemFile>().toList();
        final paths = files.map((file) => file.path).toList();
        if (paths.isEmpty && files.isNotEmpty) {
          _setMessage(_t('dropPathError'));
          return;
        }
        await _receivePaths(paths);
      },
      child: child,
    );
  }

  Widget _buildAudioVisualizer({required bool fullScreen}) => AudioVisualizer(
    key: _audioVisualizerKey,
    isPlaying: _isPlaying && !_windowMinimized,
    semanticsLabel: _t('audioVisualizer'),
    systemCaptureLabel: _t('audioVisualizerSystemCapture'),
    exitFullScreenLabel: _t('exitFullScreenVisualizer'),
    fullScreen: fullScreen,
    barCount: fullScreen ? 64 : widget.skin.visualizerBars,
    showSystemCaptureNotice:
        _systemCaptureNoticeCount < _systemCaptureNoticeDisplayLimit,
    onSystemCaptureNoticeShown: _recordSystemCaptureNoticeShown,
    onToggleFullScreen: () {
      setState(() => _showFullScreenVisualizer = !fullScreen);
    },
    onError: (error) => _setError(
      _t('audioVisualizerError', {'error': error.message ?? error.code}),
    ),
  );

  Future<void> _toggleWindowFullscreen([bool? fullScreen]) async {
    final nextState = fullScreen ?? !_windowIsFullscreen;
    try {
      await windowManager.setFullScreen(nextState);
      if (!mounted) return;
      _windowIsFullscreen = nextState;
      _windowFullscreen.value = nextState;
      setState(() {});
    } on Exception catch (error) {
      _setError(_t('fullScreenError', {'error': error}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final backdropImage = _currentTrack?.backdropImageProvider;
    final backgroundStyle = _economyMode
        ? PlayerBackgroundStyle.solidColor
        : widget.skin.backgroundStyle;
    final albumPrimary = Color(
      _currentTrack?.palettePrimary ?? widget.skin.backgroundColor.toARGB32(),
    );
    final albumAccent = Color(
      _currentTrack?.paletteAccent ?? widget.skin.accentColor.toARGB32(),
    );
    return CallbackShortcuts(
      bindings: {
        for (final entry in _playbackShortcuts.entries)
          entry.value.activator: () => _runPlaybackShortcut(entry.key),
        if (!_hasSpacePlayPauseShortcut)
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _runPlaybackShortcut(PlaybackShortcutAction.playPause),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_toggleWindowFullscreen()),
        if (_windowIsFullscreen)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_toggleWindowFullscreen(false)),
      },
      child: Focus(
        autofocus: true,
        child: _wrapDropTarget(
          Scaffold(
            backgroundColor: Colors.transparent,
            body: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: Container(
                key: const ValueKey('player-background'),
                decoration: BoxDecoration(
                  color: backgroundStyle == PlayerBackgroundStyle.solidColor
                      ? widget.skin.backgroundColor
                      : _defaultBackground,
                ),
                child: Stack(
                  children: [
                    if (backdropImage != null)
                      if (backgroundStyle == PlayerBackgroundStyle.blurredCover)
                        Positioned.fill(
                          child: PlayerBackdrop(
                            imageProvider: backdropImage,
                            trackKey: _currentTrack!.path,
                            motionEnabled:
                                widget.skin.backgroundMotion &&
                                _isPlaying &&
                                !_showFullScreenVisualizer &&
                                !_windowMinimized,
                            motionDurationSeconds:
                                widget.skin.motionDurationSeconds,
                          ),
                        ),
                    if (backgroundStyle == PlayerBackgroundStyle.coverTones)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.lerp(albumPrimary, Colors.black, 0.38)!,
                                Color.lerp(albumAccent, Colors.black, 0.5)!,
                                Color.lerp(albumPrimary, Colors.black, 0.68)!,
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (backdropImage != null &&
                        backgroundStyle == PlayerBackgroundStyle.blurredCover)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0x40000000),
                                  Color(0x55000000),
                                  Color(0x66000000),
                                ],
                                stops: [0, 0.58, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                    SafeArea(
                      minimum: _showLyrics
                          ? EdgeInsets.zero
                          : _windowBarSafeAreaMinimum(),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 760;
                          final narrow = constraints.maxWidth < 480;
                          final contentWidth = math
                              .min(
                                constraints.maxWidth - (narrow ? 28.0 : 56.0),
                                _showLyrics ? 1680.0 : 1480.0,
                              )
                              .toDouble();
                          final lyricsGutter = contentWidth * 0.04;
                          final panelWidth = contentWidth - lyricsGutter;
                          final wideLyricsLayout = constraints.maxWidth >= 1200;
                          final compactLyricsLayout =
                              _showLyrics && constraints.maxHeight < 660;
                          final verticalPadding = _showLyrics
                              ? 0.0
                              : compact
                              ? 12.0
                              : 20.0;
                          final playerTopInset = _showLyrics
                              ? compactLyricsLayout
                                    ? 56.0
                                    : 64.0
                              : 0.0;
                          final playerAvailableHeight = math.max(
                            0.0,
                            constraints.maxHeight -
                                playerTopInset -
                                verticalPadding * 2,
                          );
                          final playerWidth = _showLyrics
                              ? panelWidth * (wideLyricsLayout ? 0.38 : 0.5)
                              : contentWidth;
                          final lyricsPanelWidth = _showLyrics
                              ? panelWidth - playerWidth
                              : 0.0;
                          final artworkWidthFactor = _showLyrics
                              ? (compactLyricsLayout
                                    ? 0.64
                                    : compact
                                    ? 0.68
                                    : 0.82)
                              : (compact ? 0.62 : 0.60);
                          final largeWindow = constraints.maxWidth >= 1400;
                          final largeLyricsPanel = lyricsPanelWidth >= 680;
                          final showCompactVisualizer =
                              _hasTrack &&
                              _showCompactVisualizer &&
                              !_economyMode &&
                              !_showFullScreenVisualizer;
                          final artworkHeightFactor = _showLyrics
                              ? (largeWindow ? 0.50 : 0.58)
                              : largeWindow
                              ? 0.48
                              : (0.38 + constraints.maxHeight / 1000 * 0.14)
                                    .clamp(0.43, 0.54)
                                    .toDouble();
                          final artworkVisualizerReserve = showCompactVisualizer
                              ? 112.0
                              : 0.0;
                          final artworkHeightLimit = math.max(
                            140.0,
                            (_showLyrics
                                        ? playerAvailableHeight
                                        : constraints.maxHeight) *
                                    artworkHeightFactor -
                                artworkVisualizerReserve,
                          );
                          final artworkSize = math.max(
                            140.0,
                            math.min(
                                  math.min(
                                    playerWidth * artworkWidthFactor,
                                    artworkHeightLimit,
                                  ),
                                  compact
                                      ? 360.0
                                      : (_showLyrics ? 620.0 : 560.0),
                                ) -
                                (_showLyrics
                                    ? compactLyricsLayout
                                          ? 20.0
                                          : 12.0
                                    : 0.0),
                          );
                          final title =
                              _currentTrack?.title ?? _t('emptyTitle');
                          final artist =
                              _currentTrack?.artist ?? _t('emptyHint');
                          final durationSeconds = _duration.inSeconds
                              .toDouble();
                          final sliderMaximum = math
                              .max(durationSeconds, 1)
                              .toDouble();
                          final coverImage = _currentTrack?.coverImageProvider;
                          final trackColor = _foreground.withValues(
                            alpha: 0.22,
                          );
                          final controlsWidth = math
                              .min(playerWidth, 680)
                              .toDouble();
                          final inlineVolumeControl =
                              !narrow && controlsWidth >= 500;
                          final inlineVolumeWidth = math
                              .min(132.0, controlsWidth / 2 - 164)
                              .toDouble();

                          return Stack(
                            children: [
                              SingleChildScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: narrow ? 14 : 28,
                                      vertical: verticalPadding,
                                    ),
                                    child: Center(
                                      child: SizedBox(
                                        width: contentWidth,
                                        child: Row(
                                          mainAxisAlignment: _showLyrics
                                              ? MainAxisAlignment.start
                                              : MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Flexible(
                                              fit: FlexFit.loose,
                                              child: SizedBox(
                                                height: _showLyrics
                                                    ? constraints.maxHeight
                                                    : null,
                                                child: Padding(
                                                  padding: EdgeInsets.only(
                                                    top: playerTopInset,
                                                  ),
                                                  child: Center(
                                                    child: AnimatedContainer(
                                                      duration: const Duration(
                                                        milliseconds: 360,
                                                      ),
                                                      curve:
                                                          Curves.easeInOutCubic,
                                                      key: const ValueKey(
                                                        'player-column',
                                                      ),
                                                      width: playerWidth,
                                                      child: Column(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: [
                                                          Semantics(
                                                            image: true,
                                                            label:
                                                                _currentTrack ==
                                                                    null
                                                                ? _t(
                                                                    'coverPlaceholder',
                                                                  )
                                                                : _t(
                                                                    'albumCover',
                                                                  ),
                                                            child: RepaintBoundary(
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      widget
                                                                          .skin
                                                                          .cornerRadius,
                                                                    ),
                                                                child: AnimatedContainer(
                                                                  key:
                                                                      const ValueKey(
                                                                        'player-artwork',
                                                                      ),
                                                                  duration:
                                                                      const Duration(
                                                                        milliseconds:
                                                                            360,
                                                                      ),
                                                                  curve: Curves
                                                                      .easeInOutCubic,
                                                                  width:
                                                                      artworkSize,
                                                                  height:
                                                                      artworkSize,
                                                                  child: ExcludeSemantics(
                                                                    child: AnimatedSwitcher(
                                                                      duration: const Duration(
                                                                        milliseconds:
                                                                            360,
                                                                      ),
                                                                      switchInCurve:
                                                                          Curves
                                                                              .easeOutCubic,
                                                                      switchOutCurve:
                                                                          Curves
                                                                              .easeInCubic,
                                                                      transitionBuilder: (child, animation) => FadeTransition(
                                                                        opacity:
                                                                            animation,
                                                                        child: ScaleTransition(
                                                                          scale: Tween<double>(
                                                                            begin:
                                                                                0.97,
                                                                            end:
                                                                                1,
                                                                          ).animate(animation),
                                                                          child:
                                                                              child,
                                                                        ),
                                                                      ),
                                                                      child: SizedBox.expand(
                                                                        child:
                                                                            coverImage ==
                                                                                null
                                                                            ? const CustomPaint(
                                                                                key: ValueKey(
                                                                                  'empty-artwork',
                                                                                ),
                                                                                painter: _AlbumArtworkPainter(),
                                                                              )
                                                                            : Image(
                                                                                image: ResizeImage(
                                                                                  coverImage,
                                                                                  width: (artworkSize * MediaQuery.devicePixelRatioOf(context)).round(),
                                                                                  height: (artworkSize * MediaQuery.devicePixelRatioOf(context)).round(),
                                                                                ),
                                                                                key: ValueKey(_currentTrack?.path),
                                                                                fit: BoxFit.cover,
                                                                                excludeFromSemantics: true,
                                                                                errorBuilder: (_, _, _) => const CustomPaint(painter: _AlbumArtworkPainter()),
                                                                              ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            height:
                                                                compactLyricsLayout
                                                                ? 8
                                                                : compact
                                                                ? 12
                                                                : 18,
                                                          ),
                                                          Text(
                                                            title,
                                                            textAlign: TextAlign
                                                                .center,
                                                            maxLines: 2,
                                                            softWrap: true,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color:
                                                                  _foreground,
                                                              fontSize: math
                                                                  .min(
                                                                    largeWindow
                                                                        ? playerWidth *
                                                                              0.065
                                                                        : artworkSize *
                                                                              0.14,
                                                                    largeWindow
                                                                        ? 76
                                                                        : 64,
                                                                  )
                                                                  .toDouble(),
                                                              height: 1.02,
                                                              letterSpacing:
                                                                  -1.8,
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            artist,
                                                            textAlign: TextAlign
                                                                .center,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color:
                                                                  _foreground,
                                                              fontSize: compact
                                                                  ? 21
                                                                  : (largeWindow
                                                                        ? 32
                                                                        : 24),
                                                              height: 1.15,
                                                            ),
                                                          ),
                                                          if (showCompactVisualizer) ...[
                                                            const SizedBox(
                                                              height: 10,
                                                            ),
                                                            SizedBox(
                                                              height: 48,
                                                              child: Center(
                                                                child:
                                                                    _buildAudioVisualizer(
                                                                      fullScreen:
                                                                          false,
                                                                    ),
                                                              ),
                                                            ),
                                                            SizedBox(
                                                              height: compact
                                                                  ? 12
                                                                  : 18,
                                                            ),
                                                          ],
                                                          SizedBox(
                                                            height:
                                                                compactLyricsLayout
                                                                ? 8
                                                                : compact
                                                                ? 16
                                                                : 24,
                                                          ),
                                                          ValueListenableBuilder<
                                                            Duration
                                                          >(
                                                            valueListenable:
                                                                _position,
                                                            builder: (context, position, _) {
                                                              final sliderValue = position
                                                                  .inSeconds
                                                                  .clamp(
                                                                    0,
                                                                    sliderMaximum
                                                                        .toInt(),
                                                                  )
                                                                  .toDouble();
                                                              final increasedPosition = math
                                                                  .min(
                                                                    position.inSeconds +
                                                                        _seekStepSeconds,
                                                                    sliderMaximum,
                                                                  )
                                                                  .toInt();
                                                              final decreasedPosition = math
                                                                  .max(
                                                                    position.inSeconds -
                                                                        _seekStepSeconds,
                                                                    0,
                                                                  )
                                                                  .toInt();
                                                              return Semantics(
                                                                container: true,
                                                                slider: true,
                                                                label: _t(
                                                                  'seekPosition',
                                                                ),
                                                                value:
                                                                    '${_formatTime(position)} / ${_formatTime(_duration)}',
                                                                increasedValue:
                                                                    _hasTrack
                                                                    ? _formatTime(
                                                                        Duration(
                                                                          seconds:
                                                                              increasedPosition,
                                                                        ),
                                                                      )
                                                                    : null,
                                                                decreasedValue:
                                                                    _hasTrack
                                                                    ? _formatTime(
                                                                        Duration(
                                                                          seconds:
                                                                              decreasedPosition,
                                                                        ),
                                                                      )
                                                                    : null,
                                                                onIncrease:
                                                                    _hasTrack
                                                                    ? () => unawaited(
                                                                        _seekTo(
                                                                          increasedPosition
                                                                              .toDouble(),
                                                                        ),
                                                                      )
                                                                    : null,
                                                                onDecrease:
                                                                    _hasTrack
                                                                    ? () => unawaited(
                                                                        _seekTo(
                                                                          decreasedPosition
                                                                              .toDouble(),
                                                                        ),
                                                                      )
                                                                    : null,
                                                                child: ExcludeSemantics(
                                                                  child: Row(
                                                                    children: [
                                                                      SizedBox(
                                                                        width:
                                                                            48,
                                                                        child: Text(
                                                                          _formatTime(
                                                                            position,
                                                                          ),
                                                                          style: TextStyle(
                                                                            color:
                                                                                _foreground,
                                                                            fontSize:
                                                                                compact
                                                                                ? 14
                                                                                : 16,
                                                                            fontFeatures: const [
                                                                              FontFeature.tabularFigures(),
                                                                            ],
                                                                          ),
                                                                        ),
                                                                      ),
                                                                      Expanded(
                                                                        child: SliderTheme(
                                                                          data: SliderTheme.of(context).copyWith(
                                                                            trackHeight:
                                                                                4,
                                                                            trackShape:
                                                                                const RoundedRectSliderTrackShape(),
                                                                            activeTrackColor:
                                                                                _progressColor,
                                                                            inactiveTrackColor:
                                                                                trackColor,
                                                                            thumbColor:
                                                                                _foreground,
                                                                            overlayColor: _foreground.withValues(
                                                                              alpha: 0.12,
                                                                            ),
                                                                            thumbShape: const RoundSliderThumbShape(
                                                                              enabledThumbRadius: 5,
                                                                              elevation: 0,
                                                                              pressedElevation: 0,
                                                                            ),
                                                                            overlayShape: const RoundSliderOverlayShape(
                                                                              overlayRadius: 16,
                                                                            ),
                                                                          ),
                                                                          child: Slider(
                                                                            min:
                                                                                0,
                                                                            max:
                                                                                sliderMaximum,
                                                                            value:
                                                                                sliderValue,
                                                                            onChangeStart:
                                                                                _hasTrack
                                                                                ? (_) => setState(() => _isSeeking = true)
                                                                                : null,
                                                                            onChanged:
                                                                                _hasTrack
                                                                                ? (value) => _position.value = Duration(seconds: value.round())
                                                                                : null,
                                                                            onChangeEnd:
                                                                                _hasTrack
                                                                                ? _seekTo
                                                                                : null,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                      SizedBox(
                                                                        width:
                                                                            48,
                                                                        child: Text(
                                                                          _formatTime(
                                                                            _duration,
                                                                          ),
                                                                          textAlign:
                                                                              TextAlign.right,
                                                                          style: TextStyle(
                                                                            color:
                                                                                _foreground,
                                                                            fontSize:
                                                                                compact
                                                                                ? 14
                                                                                : 16,
                                                                            fontFeatures: const [
                                                                              FontFeature.tabularFigures(),
                                                                            ],
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                          SizedBox(
                                                            height:
                                                                compactLyricsLayout
                                                                ? 8
                                                                : compact
                                                                ? 16
                                                                : 22,
                                                          ),
                                                          SizedBox(
                                                            width:
                                                                controlsWidth,
                                                            child: Column(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                SizedBox(
                                                                  width:
                                                                      controlsWidth,
                                                                  height:
                                                                      compactLyricsLayout
                                                                      ? 76
                                                                      : compact
                                                                      ? 84
                                                                      : 96,
                                                                  child: Stack(
                                                                    alignment:
                                                                        Alignment
                                                                            .center,
                                                                    children: [
                                                                      Container(
                                                                        key:
                                                                            const ValueKey(
                                                                              'player-transport-controls',
                                                                            ),
                                                                        padding:
                                                                            _controlLayout ==
                                                                                PlaybackControlLayout.classic
                                                                            ? const EdgeInsets.symmetric(
                                                                                horizontal: 12,
                                                                                vertical: 6,
                                                                              )
                                                                            : EdgeInsets.zero,
                                                                        decoration:
                                                                            _controlLayout ==
                                                                                PlaybackControlLayout.classic
                                                                            ? BoxDecoration(
                                                                                color: Colors.white.withValues(alpha: 0.06),
                                                                                borderRadius: BorderRadius.circular(64),
                                                                                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                                                                              )
                                                                            : null,
                                                                        child: Row(
                                                                          mainAxisSize:
                                                                              MainAxisSize.min,
                                                                          children: [
                                                                            IconButton(
                                                                              tooltip: _t(
                                                                                'previous',
                                                                              ),
                                                                              onPressed: _hasTrack ? () => _skip(-1) : null,
                                                                              style: IconButton.styleFrom(
                                                                                foregroundColor: _foreground,
                                                                                fixedSize: const Size.square(48),
                                                                                shape: const CircleBorder(),
                                                                              ),
                                                                              icon: Icon(
                                                                                CupertinoIcons.backward_end_fill,
                                                                                size: compact ? 22 : 24,
                                                                              ),
                                                                            ),
                                                                            const SizedBox(
                                                                              width: 8,
                                                                            ),
                                                                            IconButton.filled(
                                                                              tooltip: _isPlaying ? _t('pause') : _t('play'),
                                                                              onPressed: _isLoading ? null : _togglePlayback,
                                                                              style: IconButton.styleFrom(
                                                                                backgroundColor: _foreground,
                                                                                foregroundColor: Colors.black,
                                                                                disabledBackgroundColor: _foreground.withValues(alpha: 0.65),
                                                                                fixedSize: Size.square(
                                                                                  compact
                                                                                      ? 68
                                                                                      : largeWindow
                                                                                      ? 84
                                                                                      : 76,
                                                                                ),
                                                                              ),
                                                                              iconSize: compact
                                                                                  ? 32
                                                                                  : largeWindow
                                                                                  ? 40
                                                                                  : 36,
                                                                              icon: _isLoading
                                                                                  ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                                                                                  : Icon(_isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill),
                                                                            ),
                                                                            const SizedBox(
                                                                              width: 8,
                                                                            ),
                                                                            IconButton(
                                                                              tooltip: _t(
                                                                                'next',
                                                                              ),
                                                                              onPressed: _hasTrack ? () => _skip(1) : null,
                                                                              style: IconButton.styleFrom(
                                                                                foregroundColor: _foreground,
                                                                                fixedSize: const Size.square(48),
                                                                                shape: const CircleBorder(),
                                                                              ),
                                                                              icon: Icon(
                                                                                CupertinoIcons.forward_end_fill,
                                                                                size: compact ? 22 : 24,
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      if (inlineVolumeControl)
                                                                        Positioned(
                                                                          right:
                                                                              56,
                                                                          child: SizedBox(
                                                                            width:
                                                                                inlineVolumeWidth,
                                                                            child:
                                                                                _buildVolumeControl(),
                                                                          ),
                                                                        ),
                                                                      Positioned(
                                                                        right:
                                                                            0,
                                                                        child: IconButton(
                                                                          tooltip:
                                                                              _repeatEnabled
                                                                              ? _t(
                                                                                  'repeatOff',
                                                                                )
                                                                              : _t(
                                                                                  'repeat',
                                                                                ),
                                                                          onPressed:
                                                                              _toggleRepeat,
                                                                          style: IconButton.styleFrom(
                                                                            backgroundColor:
                                                                                _repeatEnabled
                                                                                ? _foreground
                                                                                : Colors.transparent,
                                                                            foregroundColor:
                                                                                _repeatEnabled
                                                                                ? Colors.black
                                                                                : _foreground.withValues(alpha: 0.72),
                                                                            fixedSize: const Size.square(
                                                                              44,
                                                                            ),
                                                                            shape:
                                                                                const CircleBorder(),
                                                                          ),
                                                                          icon: Icon(
                                                                            CupertinoIcons.repeat,
                                                                            size:
                                                                                compact
                                                                                ? 22
                                                                                : 24,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                                if (!inlineVolumeControl)
                                                                  SizedBox(
                                                                    width: 196,
                                                                    height: 44,
                                                                    child:
                                                                        _buildVolumeControl(),
                                                                  ),
                                                              ],
                                                            ),
                                                          ),
                                                          if (_message
                                                              case final message?) ...[
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              message,
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              style: TextStyle(
                                                                color:
                                                                    _foreground,
                                                                fontSize: 13,
                                                              ),
                                                            ),
                                                          ],
                                                          if (_error
                                                              case final error?) ...[
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              error,
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              style:
                                                                  const TextStyle(
                                                                    color: Color(
                                                                      0xFFFFE3DF,
                                                                    ),
                                                                    fontSize:
                                                                        13,
                                                                  ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (_showLyrics)
                                              SizedBox(width: lyricsGutter),
                                            if (_showLyrics)
                                              Expanded(
                                                child: Padding(
                                                  padding: _showLyrics
                                                      ? EdgeInsets.zero
                                                      : const EdgeInsets.only(
                                                          top: 56,
                                                          bottom: 16,
                                                        ),
                                                  child: _buildLyricsPanel(
                                                    _showLyrics
                                                        ? constraints.maxHeight
                                                        : math.max(
                                                            0,
                                                            constraints
                                                                    .maxHeight -
                                                                72,
                                                          ),
                                                    largeWindow:
                                                        largeLyricsPanel,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                left: 0,
                                child: Row(
                                  key: const ValueKey('player-top-toolbar'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_hasTrack && !_economyMode)
                                      IconButton(
                                        tooltip: _t('fullScreenVisualizer'),
                                        onPressed: () => setState(
                                          () =>
                                              _showFullScreenVisualizer = true,
                                        ),
                                        style: IconButton.styleFrom(
                                          fixedSize: const Size.square(56),
                                        ),
                                        icon: Icon(
                                          CupertinoIcons.waveform,
                                          color: _foreground,
                                          size: 28,
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: _t('library'),
                                      onPressed: _openLibrary,
                                      style: IconButton.styleFrom(
                                        fixedSize: const Size.square(56),
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.music_note_list,
                                        color: _foreground,
                                        size: 28,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _t('queue'),
                                      onPressed: _openQueue,
                                      style: IconButton.styleFrom(
                                        fixedSize: const Size.square(56),
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.list_bullet,
                                        color: _foreground,
                                        size: 28,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _t('yearReview'),
                                      onPressed: _showYearSummary,
                                      style: IconButton.styleFrom(
                                        fixedSize: const Size.square(56),
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.chart_bar,
                                        color: _foreground,
                                        size: 28,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _t('librarySettings'),
                                      onPressed: _openCustomizationSettings,
                                      style: IconButton.styleFrom(
                                        fixedSize: const Size.square(56),
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.slider_horizontal_3,
                                        color: _foreground,
                                        size: 28,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _showLyrics
                                          ? _t('hideLyrics')
                                          : _t('showLyrics'),
                                      onPressed: _toggleLyrics,
                                      style: IconButton.styleFrom(
                                        fixedSize: const Size.square(56),
                                        backgroundColor: _showLyrics
                                            ? _foreground.withValues(
                                                alpha: 0.16,
                                              )
                                            : Colors.transparent,
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.text_quote,
                                        color: _foreground,
                                        size: 28,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_showFullScreenVisualizer && _hasTrack)
                                Positioned.fill(
                                  child: _buildAudioVisualizer(
                                    fullScreen: true,
                                  ),
                                ),
                              if (_isDragging)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: const Color(0xCC555D62),
                                        border: Border.all(
                                          color: _foreground,
                                          width: 3,
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          _t('dropFilesHint'),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: _foreground,
                                            fontSize: 28,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LyricsListView extends StatelessWidget {
  const LyricsListView({
    required this.lyrics,
    required this.controller,
    required this.activeLyricIndex,
    required this.semanticsLabel,
    required this.synced,
    required this.largeWindow,
    required this.fontFamily,
    super.key,
  });

  final List<LyricLine> lyrics;
  final ScrollController controller;
  final ValueListenable<int> activeLyricIndex;
  final String semanticsLabel;
  final bool synced;
  final bool largeWindow;
  final String fontFamily;

  static const _foreground = Color(0xFFF8F7F5);

  void _scrollBy(double direction) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final target =
        (position.pixels + position.viewportDimension * 0.8 * direction)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    unawaited(
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (lyrics.isEmpty) return const SizedBox.shrink();
    final fontSize = largeWindow ? 62.0 : 36.0;
    final baseItemExtent = largeWindow ? 164.0 : 104.0;
    final edgeBlurExtent = largeWindow ? 144.0 : 96.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemExtents = [
          for (final lyric in lyrics)
            _itemExtentFor(
              lyric.text,
              maxWidth: constraints.maxWidth,
              fontSize: fontSize,
              baseItemExtent: baseItemExtent,
              direction: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            ),
        ];
        final prefixExtents = <double>[0];
        for (final extent in itemExtents) {
          prefixExtents.add(prefixExtents.last + extent);
        }
        final topPadding = math.max(
          0.0,
          (constraints.maxHeight - itemExtents.first) / 2,
        );
        final bottomPadding = math.max(
          0.0,
          (constraints.maxHeight - itemExtents.last) / 2,
        );
        return ValueListenableBuilder<int>(
          valueListenable: activeLyricIndex,
          builder: (context, activeIndex, _) {
            if (synced) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!controller.hasClients ||
                    activeLyricIndex.value != activeIndex) {
                  return;
                }
                final scrollPosition = controller.position;
                final targetIndex = (activeIndex < 0 ? 0 : activeIndex).clamp(
                  0,
                  itemExtents.length - 1,
                );
                final target =
                    (topPadding +
                            prefixExtents[targetIndex] +
                            itemExtents[targetIndex] / 2 -
                            constraints.maxHeight / 2)
                        .clamp(0.0, scrollPosition.maxScrollExtent)
                        .toDouble();
                if ((scrollPosition.pixels - target).abs() < 0.5) return;
                controller.animateTo(
                  target,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                );
              });
            }
            return Semantics(
              container: true,
              label: semanticsLabel,
              value: activeIndex >= 0 && activeIndex < lyrics.length
                  ? lyrics[activeIndex].text
                  : null,
              onScrollUp: synced ? null : () => _scrollBy(-1),
              onScrollDown: synced ? null : () => _scrollBy(1),
              child: ExcludeSemantics(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ListView.builder(
                        controller: controller,
                        physics: synced
                            ? const NeverScrollableScrollPhysics()
                            : const ClampingScrollPhysics(),
                        padding: EdgeInsets.only(
                          top: topPadding,
                          bottom: bottomPadding,
                        ),
                        itemExtentBuilder: (index, _) => itemExtents[index],
                        itemCount: lyrics.length,
                        itemBuilder: (context, index) {
                          final distance = (index - activeIndex).abs();
                          final active = synced && index == activeIndex;
                          final baseOpacity = !synced
                              ? 0.86
                              : active
                              ? 1.0
                              : (0.82 - distance * 0.08)
                                    .clamp(0.72, 0.82)
                                    .toDouble();
                          return AnimatedBuilder(
                            animation: controller,
                            builder: (context, child) {
                              final scrollOffset = controller.hasClients
                                  ? controller.offset
                                  : 0.0;
                              final lineCenter =
                                  topPadding +
                                  prefixExtents[index] +
                                  itemExtents[index] / 2 -
                                  scrollOffset;
                              final edgeDistance = math.min(
                                lineCenter,
                                constraints.maxHeight - lineCenter,
                              );
                              final edgeProgress =
                                  (edgeDistance / edgeBlurExtent)
                                      .clamp(0.0, 1.0)
                                      .toDouble();
                              final blurSigma =
                                  (1 - edgeProgress) *
                                  (largeWindow ? 3.2 : 2.6);
                              final opacity =
                                  baseOpacity * (0.68 + edgeProgress * 0.32);
                              final styledText = AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                                style: TextStyle(
                                  color: _foreground.withValues(alpha: opacity),
                                  fontFamily: fontFamily,
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.w500,
                                  height: 1.2,
                                ),
                                child: Text(
                                  lyrics[index].text,
                                  textAlign: TextAlign.center,
                                  softWrap: true,
                                ),
                              );
                              return SizedBox(
                                width: constraints.maxWidth,
                                child: Align(
                                  alignment: Alignment.center,
                                  child: blurSigma > 0.05
                                      ? ImageFiltered(
                                          imageFilter: ImageFilter.blur(
                                            sigmaX: blurSigma,
                                            sigmaY: blurSigma,
                                          ),
                                          child: styledText,
                                        )
                                      : styledText,
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  double _itemExtentFor(
    String text, {
    required double maxWidth,
    required double fontSize,
    required double baseItemExtent,
    required TextDirection direction,
    required TextScaler textScaler,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
      textDirection: direction,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    return math.max(baseItemExtent, painter.height + 24);
  }
}

class _YearSummary extends StatelessWidget {
  const _YearSummary({
    required this.year,
    required this.data,
    required this.languageCode,
  });

  final String year;
  final Map<String, dynamic> data;
  final String languageCode;

  String _t(String key, [Map<String, Object?> values = const {}]) =>
      RiverLocalizations(languageCode).text(key, values);

  String _formatMinutes(num milliseconds) {
    final minutes = milliseconds ~/ Duration.millisecondsPerMinute;
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    if (hours == 0) {
      return '$minutes ${_t('minuteShort')}';
    }
    return '$hours ${_t('hourShort')} $remainingMinutes ${_t('minuteShort')}';
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = data['totalMs'] as num? ?? 0;
    final artists = (data['artists'] as Map? ?? const {}).entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));
    final songs = (data['songs'] as Map? ?? const {}).entries.toList()
      ..sort(
        (a, b) => ((b.value as Map)['milliseconds'] as num).compareTo(
          ((a.value as Map)['milliseconds'] as num),
        ),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(year, style: Theme.of(context).textTheme.titleLarge),
        Text(_t('totalListening', {'time': _formatMinutes(totalMs)})),
        const SizedBox(height: 12),
        Text(_t('topArtists'), style: TextStyle(fontWeight: FontWeight.w600)),
        if (artists.isEmpty) Text(_t('noStats')),
        for (final entry in artists.take(5))
          Text(
            '${entry.key} · ${_formatMinutes(entry.value as num)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 12),
        Text(_t('songs'), style: const TextStyle(fontWeight: FontWeight.w600)),
        if (songs.isEmpty) Text(_t('noStats')),
        for (final entry in songs.take(5))
          Builder(
            builder: (context) {
              final song = Map<String, dynamic>.from(entry.value as Map);
              return Text(
                '${song['title']} — ${song['artist']}'
                ' · ${_formatMinutes(song['milliseconds'] as num)}'
                ' · ${_t('plays', {'count': song['plays']})}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
        const Divider(height: 24),
      ],
    );
  }
}

class DiscordPresenceSettingsDialog extends StatefulWidget {
  const DiscordPresenceSettingsDialog({
    required this.languageCode,
    required this.initialEnabled,
    super.key,
  });

  final String languageCode;
  final bool initialEnabled;

  @override
  State<DiscordPresenceSettingsDialog> createState() =>
      _DiscordPresenceSettingsDialogState();
}

class _DiscordPresenceSettingsDialogState
    extends State<DiscordPresenceSettingsDialog> {
  late bool _enabled;

  String _t(String key) => RiverLocalizations(widget.languageCode).text(key);

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialEnabled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_t('discordRichPresence')),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_t('discordPresenceDescription')),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_t('discordEnablePresence')),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            Text(
              _t('discordSharedApplication'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_t('cancel')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _enabled),
        child: Text(_t('save')),
      ),
    ],
  );
}

class LastFmSettingsDialog extends StatefulWidget {
  const LastFmSettingsDialog({
    required this.service,
    this.initialUsername,
    this.languageCode = 'en',
    super.key,
  });

  final LastFmService service;
  final String? initialUsername;
  final String languageCode;

  @override
  State<LastFmSettingsDialog> createState() => _LastFmSettingsDialogState();
}

class _LastFmSettingsDialogState extends State<LastFmSettingsDialog> {
  String? _pendingToken;
  String? _error;
  bool _busy = false;
  bool _waitingForApproval = false;
  late String? _username = widget.initialUsername;

  String _t(String key, [Map<String, Object?> values = const {}]) =>
      RiverLocalizations(widget.languageCode).text(key, values);

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _requestAuthorization() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await widget.service.requestAuthorizationToken();
      _pendingToken = token;
      await _openAuthorizationPage(token);
      if (!mounted) return;
      setState(() => _waitingForApproval = true);
    } on Exception {
      if (mounted) setState(() => _error = _t('lastFmAuthError'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAuthorizationPage(String token) async {
    final opened = await launchUrl(
      await widget.service.authorizationUri(token),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw const LastFmException('Browser unavailable.');
    }
  }

  Future<void> _reopenAuthorizationPage() async {
    final token = _pendingToken;
    if (token == null) return;
    try {
      await _openAuthorizationPage(token);
    } on Exception {
      if (mounted) setState(() => _error = _t('lastFmBrowserError'));
    }
  }

  Future<void> _finishAuthorization() async {
    final token = _pendingToken;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final username = await widget.service.completeAuthorization(token);
      if (!mounted) return;
      setState(() => _username = username);
      Navigator.of(context).pop(username);
    } on Exception {
      if (mounted) setState(() => _error = _t('lastFmAuthError'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.disconnect();
      if (mounted) Navigator.of(context).pop('');
    } on Exception {
      if (mounted) setState(() => _error = _t('lastFmUnavailable'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_t('lastFmTitle')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_username case final username?) ...[
                Text(_t('lastFmUsername', {'name': username})),
                const SizedBox(height: 12),
              ],
              Text(_t('lastFmDescription')),
              if (_waitingForApproval) ...[
                const SizedBox(height: 16),
                Text(
                  _t('lastFmAuthorize'),
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                TextButton(
                  onPressed: _busy || _pendingToken == null
                      ? null
                      : _reopenAuthorizationPage,
                  child: Text(_t('lastFmOpenAgain')),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: colors.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_username != null)
          TextButton(
            onPressed: _busy ? null : _disconnect,
            child: Text(_t('disconnect')),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_t('close')),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : _waitingForApproval
              ? _finishAuthorization
              : _requestAuthorization,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _waitingForApproval
                      ? _t('authorized')
                      : _username == null
                      ? _t('connect')
                      : _t('connectAnother'),
                ),
        ),
      ],
    );
  }
}

class _AlbumArtworkPainter extends CustomPainter {
  const _AlbumArtworkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF68747A), Color(0xFF303C40)],
        ).createShader(bounds),
    );

    canvas.drawCircle(
      Offset(size.width * 0.72, size.height * 0.29),
      size.width * 0.105,
      Paint()..color = const Color(0xFFD4C2A5),
    );

    final farHills = Path()
      ..moveTo(0, size.height * 0.57)
      ..cubicTo(
        size.width * 0.22,
        size.height * 0.39,
        size.width * 0.34,
        size.height * 0.61,
        size.width * 0.55,
        size.height * 0.49,
      )
      ..cubicTo(
        size.width * 0.75,
        size.height * 0.37,
        size.width * 0.85,
        size.height * 0.58,
        size.width,
        size.height * 0.43,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(farHills, Paint()..color = const Color(0xFF667064));

    final nearHills = Path()
      ..moveTo(0, size.height * 0.72)
      ..cubicTo(
        size.width * 0.28,
        size.height * 0.56,
        size.width * 0.45,
        size.height * 0.83,
        size.width * 0.68,
        size.height * 0.65,
      )
      ..cubicTo(
        size.width * 0.81,
        size.height * 0.56,
        size.width * 0.9,
        size.height * 0.72,
        size.width,
        size.height * 0.63,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(nearHills, Paint()..color = const Color(0xFF394640));

    final water = Paint()
      ..color = const Color(0xFF9CA39A).withValues(alpha: 0.45)
      ..strokeWidth = math.max(1, size.width * 0.004)
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < 5; index++) {
      final y = size.height * (0.79 + index * 0.035);
      canvas.drawLine(
        Offset(size.width * 0.28, y),
        Offset(size.width * (0.47 + index * 0.035), y),
        water,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
