import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lyrics.dart';

class LyricsService {
  LyricsService({http.Client? client}) : _client = client ?? http.Client();

  static const _endpoint = 'https://lrclib.net/api';
  final http.Client _client;

  Future<List<LyricLine>> lookup({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final query = <String, String>{
      'track_name': title.trim(),
      'artist_name': artist.trim(),
      if (album?.trim().isNotEmpty ?? false) 'album_name': album!.trim(),
      if (duration != null && duration.inSeconds > 0)
        'duration': duration.inSeconds.toString(),
    };
    final exactResponse = await _get('get', query);
    var exactLyrics = const <LyricLine>[];
    if (exactResponse.statusCode == 200) {
      exactLyrics = _lyricsFromJson(exactResponse.body);
      if (_hasSyncedLyrics(exactLyrics)) return exactLyrics;
    } else if (exactResponse.statusCode != 404) {
      throw LyricsLookupException(
        'LRCLIB вернул ошибку ${exactResponse.statusCode}.',
      );
    }

    final searchResponse = await _get('search', {
      'track_name': title.trim(),
      'artist_name': artist.trim(),
    });
    if (searchResponse.statusCode != 200) {
      throw LyricsLookupException(
        'LRCLIB вернул ошибку ${searchResponse.statusCode}.',
      );
    }

    final decoded = jsonDecode(searchResponse.body);
    if (decoded is! List) {
      throw const LyricsLookupException(
        'LRCLIB вернул ответ в неожиданном формате.',
      );
    }

    final candidates = decoded
        .whereType<Map<String, dynamic>>()
        .where(
          (item) =>
              _normalize(item['trackName']) == _normalize(title) &&
              _normalize(item['artistName']) == _normalize(artist),
        )
        .toList();
    candidates.sort((a, b) {
      final aSynced =
          (a['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
      final bSynced =
          (b['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
      if (aSynced != bSynced) return aSynced ? -1 : 1;

      if (duration == null || duration.inSeconds <= 0) return 0;
      final targetSeconds = duration.inSeconds;
      final aDistance =
          ((a['duration'] as num?)?.round() ?? targetSeconds) - targetSeconds;
      final bDistance =
          ((b['duration'] as num?)?.round() ?? targetSeconds) - targetSeconds;
      return aDistance.abs().compareTo(bDistance.abs());
    });

    for (final candidate in candidates) {
      final lyrics = _lyricsFromMap(candidate);
      if (_hasSyncedLyrics(lyrics)) return lyrics;
    }
    for (final candidate in candidates) {
      final lyrics = _lyricsFromMap(candidate);
      if (lyrics.isNotEmpty) return lyrics;
    }
    return exactLyrics;
  }

  Future<http.Response> _get(String path, Map<String, String> query) {
    return _client
        .get(
          Uri.parse('$_endpoint/$path').replace(queryParameters: query),
          headers: const {'User-Agent': 'river Flutter music player'},
        )
        .timeout(const Duration(seconds: 12));
  }

  List<LyricLine> _lyricsFromJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const LyricsLookupException(
        'LRCLIB вернул ответ в неожиданном формате.',
      );
    }
    return _lyricsFromMap(decoded);
  }

  List<LyricLine> _lyricsFromMap(Map<String, dynamic> item) {
    final syncedLyrics = item['syncedLyrics'];
    if (syncedLyrics is String && syncedLyrics.trim().isNotEmpty) {
      final lines = parseLrc(syncedLyrics);
      if (lines.isNotEmpty) return lines;
    }

    final plainLyrics = item['plainLyrics'];
    if (plainLyrics is! String || plainLyrics.trim().isEmpty) {
      return const [];
    }
    return List.unmodifiable(
      plainLyrics
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map((line) => LyricLine(timestamp: Duration.zero, text: line)),
    );
  }

  String _normalize(Object? value) =>
      value?.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim() ??
      '';

  bool _hasSyncedLyrics(List<LyricLine> lyrics) =>
      lyrics.length > 1 && lyrics.last.timestamp > lyrics.first.timestamp;

  void dispose() => _client.close();
}

class LyricsLookupException implements Exception {
  const LyricsLookupException(this.message);

  final String message;

  @override
  String toString() => message;
}
