import 'package:flutter_test/flutter_test.dart';
import 'package:river/app_localizations.dart';

void main() {
  const languages = ['en', 'es', 'ru', 'uk', 'zh'];

  test('app identity and player controls are translated in every language', () {
    const expectedLibraryLabels = {
      'en': 'Music library',
      'es': 'Biblioteca musical',
      'ru': 'Музыкальная библиотека',
      'uk': 'Музична бібліотека',
      'zh': '音乐库',
    };
    const expectedPlayLabels = {
      'en': 'Play',
      'es': 'Reproducir',
      'ru': 'Играть',
      'uk': 'Відтворити',
      'zh': '播放',
    };
    const expectedSettingsLabels = {
      'en': 'river settings',
      'es': 'Ajustes de river',
      'ru': 'Настройки river',
      'uk': 'Налаштування river',
      'zh': 'river 设置',
    };
    for (final language in languages) {
      final localizations = RiverLocalizations(language);
      expect(localizations.text('appTitle'), 'river');
      expect(localizations.text('library'), expectedLibraryLabels[language]);
      expect(localizations.text('play'), expectedPlayLabels[language]);
      expect(
        localizations.text('librarySettings'),
        expectedSettingsLabels[language],
      );
    }
  });

  test('localized labels interpolate their values', () {
    expect(
      const RiverLocalizations('es').text('allSongs', {'count': 12}),
      'Todas las canciones · 12',
    );
    expect(
      const RiverLocalizations('zh').text('playlistAdded', {'name': 'Mix'}),
      '已添加到“Mix”。',
    );
    expect(
      const RiverLocalizations('en').text('playlistSongs', {'count': 12}),
      '12 songs',
    );
    expect(
      const RiverLocalizations('ru').text('playlistSongSingular'),
      '1 песня',
    );
  });

  test('playback position accessibility label is localized', () {
    for (final language in languages) {
      expect(
        RiverLocalizations(language).text('seekPosition'),
        isNot('seekPosition'),
        reason: language,
      );
      expect(
        RiverLocalizations(language).text('volume'),
        isNot('volume'),
        reason: language,
      );
    }
  });

  test('library search and track editor are localized in every language', () {
    for (final language in languages) {
      final localizations = RiverLocalizations(language);
      for (final key in [
        'searchLibrary',
        'clearSearch',
        'searchNoResults',
        'credits',
        'creditsName',
        'creditsTagline',
        'creditsAvatar',
        'githubProfile',
        'lastFmProfile',
        'discordContact',
        'copyDiscord',
        'discordCopied',
        'discordCopyError',
        'supportOnKofi',
        'creditsLinkError',
        'volumeError',
        'economyMode',
        'economyModeDescription',
        'controlLayout',
        'controlLayoutModern',
        'controlLayoutClassic',
        'seekStep',
        'volumeStep',
        'keyboardShortcuts',
        'shortcutPlayPause',
        'shortcutPreviousTrack',
        'shortcutNextTrack',
        'shortcutSeekBackward',
        'shortcutSeekForward',
        'shortcutVolumeDown',
        'shortcutVolumeUp',
        'shortcutToggleRepeat',
        'spaceAlwaysPlayback',
        'changeShortcut',
        'pressShortcut',
        'shortcutCaptureHint',
        'shortcutKeyUnavailable',
        'shortcutConflict',
        'resetControls',
        'controlSettingsSaveError',
        'minimizeWindow',
        'maximizeWindow',
        'restoreWindow',
        'closeWindow',
        'lyrics',
        'editTrackInfo',
        'trackOptions',
        'equalizer',
        'equalizerReset',
        'equalizerBand',
        'equalizerApplyError',
        'audioVisualizer',
        'audioVisualizerError',
        'audioVisualizerSystemCapture',
        'skinBackgroundStyle',
        'backgroundBlurredCover',
        'backgroundCoverTones',
        'backgroundSolidColor',
        'lyricsSeparateFont',
        'lyricsFont',
        'libraryLoading',
        'fullScreenError',
        'trackTitle',
        'trackArtist',
        'trackAlbum',
        'trackAlbumArtist',
        'trackNumber',
        'trackTotal',
        'discNumber',
        'discTotal',
        'trackYear',
        'trackGenre',
        'trackComposer',
        'trackPerformers',
        'trackPublisher',
        'trackCopyright',
        'trackComment',
        'trackIsrc',
        'trackBpm',
        'trackLanguage',
        'trackLyrics',
        'trackMbid',
        'trackCover',
        'chooseCover',
        'removeCover',
        'trackTitleRequired',
        'trackNumbersInvalid',
        'trackCoverInvalid',
        'save',
        'trackInfoSaved',
        'trackInfoSaveError',
        'trackInfoReadError',
        'libraryCacheSaveError',
        'libraryCacheReadError',
        'playlistsHeading',
        'playlistActions',
        'setPlaylistCover',
        'removePlaylistCover',
        'playlistSongs',
        'playlistSongSingular',
        'lastFmNotConnected',
        'lastFmAccount',
        'manageLastFm',
        'discordRichPresence',
        'discordPresenceStatusOn',
        'discordPresenceStatusOff',
        'manageDiscord',
        'discordPresenceDescription',
        'discordEnablePresence',
        'discordSharedApplication',
        'discordConnectionUnavailable',
      ]) {
        expect(localizations.text(key), isNot(key), reason: '$language:$key');
      }
      expect(
        localizations.text('searchNoResults', {'query': 'Moon'}),
        contains('Moon'),
      );
      expect(
        localizations.text('audioVisualizerError', {'error': 'E_FAIL'}),
        contains('E_FAIL'),
      );
      expect(localizations.text('audioVisualizerSystemCapture'), isNotEmpty);
    }
  });

  test('queue controls are translated in every language', () {
    for (final language in languages) {
      final localizations = RiverLocalizations(language);
      for (final key in [
        'queue',
        'recentlyPlayed',
        'nowPlaying',
        'nextInQueue',
        'clearQueue',
        'queueEmpty',
        'recentlyEmpty',
        'addToQueue',
        'removeFromQueue',
        'queueAddError',
        'queueRemoveError',
      ]) {
        expect(localizations.text(key), isNot(key), reason: '$language: $key');
      }
    }
  });
}
