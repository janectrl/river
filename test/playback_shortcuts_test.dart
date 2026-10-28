import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:river/playback_shortcuts.dart';

void main() {
  test('default playback shortcuts are unique and platform-independent', () {
    final shortcuts = defaultPlaybackShortcuts();

    expect(shortcuts.length, PlaybackShortcutAction.values.length);
    expect(shortcuts.values.toSet().length, shortcuts.length);
    expect(
      shortcuts[PlaybackShortcutAction.playPause]!.key,
      LogicalKeyboardKey.space,
    );
    expect(
      shortcuts[PlaybackShortcutAction.seekBackward]!.key,
      LogicalKeyboardKey.arrowLeft,
    );
    expect(shortcuts[PlaybackShortcutAction.previousTrack]!.control, isTrue);
  });

  test('playback shortcut modifier and key survive JSON round trip', () {
    final shortcut = PlaybackShortcut(
      logicalKeyId: LogicalKeyboardKey.keyB.keyId,
      control: true,
      shift: true,
    );

    final restored = PlaybackShortcut.fromJson(shortcut.toJson());
    expect(restored, shortcut);
    expect(shortcut.label, 'Ctrl + Shift + B');
    expect(restored.key, LogicalKeyboardKey.keyB);
  });

  test('invalid and unknown playback shortcuts are rejected', () {
    expect(() => PlaybackShortcut.fromJson({'key': 1}), throwsFormatException);
    expect(
      () => PlaybackShortcut.fromJson({
        'key': 0x7ffffffff,
        'control': false,
        'alt': false,
        'shift': false,
        'meta': false,
      }),
      throwsFormatException,
    );
  });
}
