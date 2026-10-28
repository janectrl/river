import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class LastFmTrack {
  const LastFmTrack({
    required this.title,
    required this.artist,
    required this.duration,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.mbid,
  });

  final String title;
  final String artist;
  final Duration duration;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final String? mbid;
}

class LastFmService {
  LastFmService({
    http.Client? client,
    FlutterSecureStorage? storage,
    Uri? workerEndpoint,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage(),
       _workerEndpoint = workerEndpoint ?? Uri.parse(_defaultWorkerEndpoint);

  static const _defaultWorkerEndpoint =
      'https://river-lastfm.janeharper-co.workers.dev/api';
  static const _legacyStorageSecret = 'lastfm.sharedSecret';
  static const _storageSessionKey = 'lastfm.sessionKey';
  static const _storageUsername = 'lastfm.username';

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final Uri _workerEndpoint;

  Future<String?> readConnectedUsername() async {
    await _clearLegacySecret();
    return _storage.read(key: _storageUsername);
  }

  Future<bool> get isConnected async {
    await _clearLegacySecret();
    return (await _storage.read(key: _storageSessionKey))?.isNotEmpty ?? false;
  }

  Future<String> requestAuthorizationToken() async {
    await _clearLegacySecret();
    final response = await _send(method: 'auth.getToken', parameters: const {});
    final token = response['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const LastFmException('Last.fm не вернул токен авторизации.');
    }
    return token;
  }

  Future<Uri> authorizationUri(String token) async {
    final response = await _client.post(
      _workerEndpoint.replace(path: '/authorize'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode != 200) {
      throw const LastFmException(
        'Не удалось подготовить авторизацию Last.fm.',
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['url'] is! String) {
      throw const LastFmException('Worker вернул неправильную ссылку Last.fm.');
    }
    final uri = Uri.tryParse(decoded['url'] as String);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.last.fm' ||
        uri.path != '/api/auth' ||
        uri.queryParameters['token'] != token) {
      throw const LastFmException('Worker вернул неправильную ссылку Last.fm.');
    }
    return uri;
  }

  Future<String> completeAuthorization(String token) async {
    await _clearLegacySecret();
    final response = await _send(
      method: 'auth.getSession',
      parameters: {'token': token},
    );
    final session = response['session'];
    if (session is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm не вернул сессию пользователя.');
    }
    final sessionKey = session['key'] as String?;
    final username = session['name'] as String?;
    if (sessionKey == null || username == null) {
      throw const LastFmException('В ответе Last.fm не хватает данных сессии.');
    }
    await _storage.write(key: _storageSessionKey, value: sessionKey);
    await _storage.write(key: _storageUsername, value: username);
    return username;
  }

  Future<void> updateNowPlaying(LastFmTrack track) async {
    final parameters = _trackParameters(track);
    await _authenticatedRequest('track.updateNowPlaying', parameters);
  }

  Future<void> scrobble({
    required LastFmTrack track,
    required DateTime startedAt,
  }) async {
    final parameters = _trackParameters(track, indexed: true);
    parameters['timestamp[0]'] =
        (startedAt.toUtc().millisecondsSinceEpoch ~/ 1000).toString();
    final response = await _authenticatedRequest('track.scrobble', parameters);
    final scrobbles = response['scrobbles'];
    if (scrobbles is! Map<String, dynamic> ||
        scrobbles['@attr'] is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm не подтвердил приём скроббла.');
    }
    final accepted = (scrobbles['@attr'] as Map<String, dynamic>)['accepted'];
    if (accepted != '1' && accepted != 1) {
      throw const LastFmException('Last.fm не принял этот скроббл.');
    }
  }

  Future<void> disconnect() async {
    await _clearLegacySecret();
    await _storage.delete(key: _storageSessionKey);
    await _storage.delete(key: _storageUsername);
  }

  void dispose() {
    _client.close();
  }

  Map<String, String> _trackParameters(
    LastFmTrack track, {
    bool indexed = false,
  }) {
    final suffix = indexed ? '[0]' : '';
    final parameters = <String, String>{
      'artist$suffix': track.artist,
      'track$suffix': track.title,
    };
    _addOptional(parameters, 'album$suffix', track.album);
    _addOptional(parameters, 'albumArtist$suffix', track.albumArtist);
    _addOptional(parameters, 'mbid$suffix', track.mbid);
    if (track.trackNumber case final number? when number > 0) {
      parameters['trackNumber$suffix'] = number.toString();
    }
    if (track.duration.inSeconds > 0) {
      parameters['duration$suffix'] = track.duration.inSeconds.toString();
    }
    if (indexed) parameters['chosenByUser[0]'] = '1';
    return parameters;
  }

  void _addOptional(
    Map<String, String> parameters,
    String name,
    String? value,
  ) {
    if (value != null && value.trim().isNotEmpty) {
      parameters[name] = value.trim();
    }
  }

  Future<Map<String, dynamic>> _authenticatedRequest(
    String method,
    Map<String, String> parameters,
  ) async {
    final sessionKey = await _storage.read(key: _storageSessionKey);
    if (sessionKey == null || sessionKey.isEmpty) {
      throw const LastFmException('Сначала подключи аккаунт Last.fm.');
    }
    await _clearLegacySecret();
    parameters['sk'] = sessionKey;
    return _send(method: method, parameters: parameters);
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required Map<String, String> parameters,
  }) async {
    final response = await _client.post(
      _workerEndpoint,
      headers: const {
        'Content-Type': 'application/json',
        'User-Agent': 'river Music Player',
      },
      body: jsonEncode({'method': method, 'parameters': parameters}),
    );

    if (response.statusCode != 200) {
      throw LastFmException(
        'Last.fm relay ответил с ошибкой HTTP ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm вернул ответ неизвестного формата.');
    }
    if (decoded['error'] != null) {
      final code = decoded['error'];
      final message = decoded['message'] ?? 'Неизвестная ошибка Last.fm.';
      throw LastFmException('Ошибка Last.fm $code: $message');
    }
    return decoded;
  }

  Future<void> _clearLegacySecret() async {
    await _storage.delete(key: _legacyStorageSecret);
  }
}

class LastFmException implements Exception {
  const LastFmException(this.message);

  final String message;

  @override
  String toString() => message;
}
