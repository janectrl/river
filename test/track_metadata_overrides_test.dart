import 'package:flutter_test/flutter_test.dart';
import 'package:river/track_metadata_overrides.dart';

void main() {
  test('track detail overrides round-trip through local JSON storage', () {
    final overrides = <String, Map<String, String>>{
      r'C:\Music\song.mp3': {
        'title': 'Corrected title',
        'artist': 'Local artist',
        'album': 'Local album',
        'albumArtist': 'Album artist',
        'trackNumber': '2',
        'trackTotal': '12',
        'discNumber': '1',
        'discTotal': '2',
        'year': '2026',
        'genre': 'Dream pop',
        'composer': 'Composer',
        'performers': 'Guest performer',
        'publisher': 'Publisher',
        'copyright': 'Copyright',
        'comment': 'Notes',
        'isrc': 'USABC1234567',
        'bpm': '120',
        'language': 'en',
        'lyrics': 'Track lyrics',
        'mbid': 'musicbrainz-id',
        'coverFile': r'C:\AppData\river\cover.jpg',
        'backdropFile': r'C:\AppData\river\backdrop.jpg',
        'removeArtwork': 'true',
      },
    };

    expect(
      decodeTrackMetadataOverrides(encodeTrackMetadataOverrides(overrides)),
      overrides,
    );
    expect(decodeTrackMetadataOverrides(null), isEmpty);
  });

  test('malformed track detail overrides are rejected', () {
    expect(() => decodeTrackMetadataOverrides('[]'), throwsFormatException);
    expect(
      () => decodeTrackMetadataOverrides('{"track": {"title": 12}}'),
      throwsFormatException,
    );
  });
}
