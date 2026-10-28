import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:river/music_folder_metadata.dart';

void main() {
  test('uses artist and album folders above disc folders', () {
    final libraryRoot = ['music'].join(Platform.pathSeparator);
    final trackPath = [
      'music',
      'Artist One',
      'Shared Album',
      'Disc 1',
      '01 - Track.mp3',
    ].join(Platform.pathSeparator);
    final metadata = musicFolderMetadataFromPath(trackPath, libraryRoot);

    expect(metadata.artist, 'Artist One');
    expect(metadata.album, 'Shared Album');
  });

  test('keeps albums with the same name separated by their artists', () {
    final first = musicFolderMetadataFromPath(
      [
        'music',
        'Artist One',
        'Shared Album',
        'track.mp3',
      ].join(Platform.pathSeparator),
      ['music'].join(Platform.pathSeparator),
    );
    final second = musicFolderMetadataFromPath(
      [
        'music',
        'Artist Two',
        'Shared Album',
        'track.mp3',
      ].join(Platform.pathSeparator),
      ['music'].join(Platform.pathSeparator),
    );

    expect((first.album, first.artist), ('Shared Album', 'Artist One'));
    expect((second.album, second.artist), ('Shared Album', 'Artist Two'));
    expect((first.album, first.artist), isNot((second.album, second.artist)));
  });

  test(
    'uses a selected album folder when the track sits directly inside it',
    () {
      final metadata = musicFolderMetadataFromPath(
        ['music', 'Shared Album', 'track.mp3'].join(Platform.pathSeparator),
        ['music'].join(Platform.pathSeparator),
      );

      expect(metadata.artist, isNull);
      expect(metadata.album, 'Shared Album');
    },
  );

  test('uses the selected root folder for tracks directly inside it', () {
    final libraryRoot = ['Shared Album'].join(Platform.pathSeparator);
    final metadata = musicFolderMetadataFromPath(
      ['Shared Album', 'track.mp3'].join(Platform.pathSeparator),
      libraryRoot,
    );

    expect(metadata.album, 'Shared Album');
    expect(metadata.artist, isNull);
  });
}
