import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum PlaybackShortcutAction {
  playPause,
  previousTrack,
  nextTrack,
  seekBackward,
  seekForward,
  volumeDown,
  volumeUp,
  toggleRepeat,
}

enum PlaybackControlLayout { modern, classic }

class PlaybackShortcut {
  const PlaybackShortcut({
    required this.logicalKeyId,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final int logicalKeyId;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  LogicalKeyboardKey get key =>
      LogicalKeyboardKey.findKeyByKeyId(logicalKeyId) ??
      LogicalKeyboardKey.space;

  ShortcutActivator get activator => SingleActivator(
    key,
    control: control,
    alt: alt,
    shift: shift,
    meta: meta,
  );

  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Win',
    key.keyLabel,
  ].join(' + ');

  Map<String, Object> toJson() => {
    'key': logicalKeyId,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };

  factory PlaybackShortcut.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['key'] is! int ||
        value['control'] is! bool ||
        value['alt'] is! bool ||
        value['shift'] is! bool ||
        value['meta'] is! bool) {
      throw const FormatException('Invalid playback shortcut.');
    }
    final keyId = value['key']! as int;
    if (LogicalKeyboardKey.findKeyByKeyId(keyId) == null) {
      throw const FormatException('Unknown playback shortcut key.');
    }
    return PlaybackShortcut(
      logicalKeyId: keyId,
      control: value['control']! as bool,
      alt: value['alt']! as bool,
      shift: value['shift']! as bool,
      meta: value['meta']! as bool,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackShortcut &&
      logicalKeyId == other.logicalKeyId &&
      control == other.control &&
      alt == other.alt &&
      shift == other.shift &&
      meta == other.meta;

  @override
  int get hashCode => Object.hash(logicalKeyId, control, alt, shift, meta);
}

Map<PlaybackShortcutAction, PlaybackShortcut> defaultPlaybackShortcuts() => {
  PlaybackShortcutAction.playPause: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.space.keyId,
  ),
  PlaybackShortcutAction.previousTrack: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowLeft.keyId,
    control: true,
  ),
  PlaybackShortcutAction.nextTrack: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowRight.keyId,
    control: true,
  ),
  PlaybackShortcutAction.seekBackward: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowLeft.keyId,
  ),
  PlaybackShortcutAction.seekForward: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowRight.keyId,
  ),
  PlaybackShortcutAction.volumeDown: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowDown.keyId,
  ),
  PlaybackShortcutAction.volumeUp: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.arrowUp.keyId,
  ),
  PlaybackShortcutAction.toggleRepeat: PlaybackShortcut(
    logicalKeyId: LogicalKeyboardKey.keyR.keyId,
  ),
};
