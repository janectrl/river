import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/lyrics_service.dart';

void main() {
  test('loads synchronized lyrics from the exact LRCLIB match', () async {
    final service = LyricsService(
      client: MockClient((request) async {
        expect(request.url.path, '/api/get');
        expect(request.url.queryParameters['track_name'], 'Song');
        expect(request.url.queryParameters['artist_name'], 'Artist');
        expect(request.url.queryParameters['duration'], '200');
        return http.Response(
          jsonEncode({
            'syncedLyrics': '[00:01.20]First line\n[00:03.50]Second line',
            'plainLyrics': 'Ignored plain lyrics',
          }),
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    final lyrics = await service.lookup(
      title: 'Song',
      artist: 'Artist',
      duration: const Duration(seconds: 200),
    );

    expect(lyrics, hasLength(2));
    expect(lyrics.first.text, 'First line');
    expect(lyrics.first.timestamp, const Duration(milliseconds: 1200));
    expect(lyrics.last.text, 'Second line');
  });

  test('search fallback selects an exact artist and title match', () async {
    final service = LyricsService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/get')) {
          return http.Response('', 404);
        }
        return http.Response(
          jsonEncode([
            {
              'trackName': 'Song',
              'artistName': 'Different artist',
              'syncedLyrics': '[00:01.00]Wrong result',
            },
            {
              'trackName': 'Song',
              'artistName': 'Artist',
              'syncedLyrics': '[00:01.00]Exact result',
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    final lyrics = await service.lookup(title: 'Song', artist: 'Artist');

    expect(lyrics, hasLength(1));
    expect(lyrics.single.text, 'Exact result');
  });

  test(
    'searches for synced lyrics before falling back to exact plain text',
    () async {
      final service = LyricsService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/get')) {
            return http.Response(
              jsonEncode({'plainLyrics': 'Plain result'}),
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {
                'trackName': 'Song',
                'artistName': 'Artist',
                'syncedLyrics': '[00:01.00]Synchronized result',
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final lyrics = await service.lookup(title: 'Song', artist: 'Artist');

      expect(lyrics.single.text, 'Synchronized result');
    },
  );

  test(
    'returns plain lyrics without pretending they are synchronized',
    () async {
      final service = LyricsService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/get')) {
            return http.Response(
              jsonEncode({'plainLyrics': 'First line\n\nSecond line'}),
              200,
            );
          }
          return http.Response('[]', 200);
        }),
      );
      addTearDown(service.dispose);

      final lyrics = await service.lookup(title: 'Song', artist: 'Artist');

      expect(lyrics.map((line) => line.text), ['First line', 'Second line']);
      expect(lyrics.every((line) => line.timestamp == Duration.zero), isTrue);
    },
  );

  test(
    'returns an empty result when LRCLIB has no exact or search match',
    () async {
      final service = LyricsService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/get')) {
            return http.Response('', 404);
          }
          return http.Response('[]', 200);
        }),
      );
      addTearDown(service.dispose);

      expect(
        await service.lookup(title: 'Missing', artist: 'Unknown'),
        isEmpty,
      );
    },
  );
}
