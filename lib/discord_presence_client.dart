import 'package:flutter_discord/dart_discord_presence.dart';

const riverDiscordApplicationId = '1564981299352043570';

class DiscordPresenceClient {
  DiscordRPC? _rpc;
  String? _applicationId;

  Future<void> setNowPlaying({
    required String title,
    required String artist,
    required Duration position,
    required Duration duration,
  }) async {
    await _connect(riverDiscordApplicationId);
    final start = DateTime.now().subtract(position);
    final timestamps = duration > position
        ? DiscordTimestamps.range(start, start.add(duration))
        : DiscordTimestamps.started(start);
    await _rpc!.setPresence(
      DiscordPresence(
        type: DiscordActivityType.listening,
        details: _limitText(title),
        state: _limitText(artist),
        timestamps: timestamps,
      ),
    );
  }

  Future<void> clear() async {
    final rpc = _rpc;
    if (rpc?.isConnected ?? false) {
      await rpc!.clearPresence();
    }
  }

  Future<void> disconnect() async {
    final rpc = _rpc;
    _rpc = null;
    _applicationId = null;
    if (rpc == null) return;
    try {
      if (rpc.isConnected) await rpc.clearPresence();
    } finally {
      await rpc.dispose();
    }
  }

  Future<void> dispose() => disconnect();

  Future<void> _connect(String applicationId) async {
    if (!DiscordRPC.isAvailable) {
      throw UnsupportedError('Discord Rich Presence requires a desktop app.');
    }
    final rpc = _rpc;
    if (rpc != null && rpc.isConnected && _applicationId == applicationId) {
      return;
    }
    await disconnect();
    final client = DiscordRPC();
    _rpc = client;
    _applicationId = applicationId;
    await client.initialize(applicationId);
  }

  String _limitText(String value) =>
      String.fromCharCodes(value.runes.take(128));
}
