import 'package:flutter_test/flutter_test.dart';
import 'package:river/library_search.dart';

void main() {
  test('library search matches title, artist, album, and playlist', () {
    const title = 'Midnight City';
    const artist = 'M83';
    const album = 'Hurry Up, We’re Dreaming';
    const playlists = ['Night Drive'];

    for (final query in ['midnight', 'M83', 'dreaming', 'night drive']) {
      expect(
        matchesLibrarySearch(
          query: query,
          title: title,
          artist: artist,
          album: album,
          playlists: playlists,
        ),
        isTrue,
        reason: 'Expected "$query" to match a library field.',
      );
    }

    expect(
      matchesLibrarySearch(query: '  ', title: title, artist: artist),
      isTrue,
    );
    expect(
      matchesLibrarySearch(
        query: 'unrelated',
        title: title,
        artist: artist,
        album: album,
        playlists: playlists,
      ),
      isFalse,
    );
  });
}
