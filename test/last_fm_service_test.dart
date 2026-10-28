import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:river/last_fm_service.dart';

void main() {
  test(
    'authorization token is sent to Worker in POST body, not its URL',
    () async {
      final client = _StubClient(
        responseBody: jsonEncode({
          'url': 'https://www.last.fm/api/auth?api_key=public-key&token=temporary-token',
        }),
      );
      final service = LastFmService(
        client: client,
        workerEndpoint: Uri.parse('https://river.example.workers.dev/api'),
      );

      final uri = await service.authorizationUri('temporary-token');

      expect(uri.host, 'www.last.fm');
      expect(uri.path, '/api/auth');
      expect(uri.queryParameters['token'], 'temporary-token');
      expect(client.request!.method, 'POST');
      expect(client.request!.url.path, '/authorize');
      expect(client.request!.url.query, isEmpty);
      final body = jsonDecode(client.request!.body) as Map<String, dynamic>;
      expect(body, {'token': 'temporary-token'});
    },
  );

  test(
    'rejects authorization URLs outside the trusted Last.fm origin',
    () async {
      final client = _StubClient(
        responseBody: jsonEncode({
          'url': 'https://attacker.example/api/auth?token=temporary-token',
        }),
      );
      final service = LastFmService(
        client: client,
        workerEndpoint: Uri.parse('https://river.example.workers.dev/api'),
      );

      await expectLater(
        service.authorizationUri('temporary-token'),
        throwsA(isA<LastFmException>()),
      );
    },
  );
}

class _StubClient extends http.BaseClient {
  _StubClient({required this.responseBody});

  final String responseBody;
  http.Request? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    return http.StreamedResponse(
      Stream.value(utf8.encode(responseBody)),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}
