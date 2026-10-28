import 'dart:convert';

typedef TrackMetadataOverrides = Map<String, Map<String, String>>;

const trackMetadataOverrideFields = {
  'title',
  'artist',
  'album',
  'albumArtist',
  'trackNumber',
  'trackTotal',
  'discNumber',
  'discTotal',
  'year',
  'genre',
  'composer',
  'performers',
  'publisher',
  'copyright',
  'comment',
  'isrc',
  'bpm',
  'language',
  'lyrics',
  'mbid',
  'coverFile',
  'backdropFile',
  'palettePrimary',
  'paletteAccent',
  'removeArtwork',
};

TrackMetadataOverrides decodeTrackMetadataOverrides(String? encoded) {
  if (encoded == null) return {};
  final decoded = jsonDecode(encoded);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Track details must be a JSON object.');
  }

  final overrides = <String, Map<String, String>>{};
  for (final entry in decoded.entries) {
    if (entry.value is! Map) {
      throw const FormatException('Track details must be JSON objects.');
    }
    final values = <String, String>{};
    final fields = entry.value as Map;
    for (final field in trackMetadataOverrideFields) {
      final value = fields[field];
      if (value != null && value is! String) {
        throw const FormatException('Track detail values must be text.');
      }
      if (value is String) values[field] = value;
    }
    overrides[entry.key] = values;
  }
  return overrides;
}

String encodeTrackMetadataOverrides(TrackMetadataOverrides overrides) =>
    jsonEncode(overrides);
