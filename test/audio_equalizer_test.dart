import 'package:flutter_test/flutter_test.dart';
import 'package:river/audio_equalizer.dart';

void main() {
  test('builds a named mpv lavfi chain with one filter per band', () {
    final filter = buildEqualizerFilter([0, 1.5, -2, 3, -4, 5, -6, 7, -8, 9]);

    expect(filter, startsWith('@river_equalizer:lavfi=['));
    expect('equalizer='.allMatches(filter).length, 10);
    expect(filter, contains('f=31.25:width_type=o:width=1:gain=0.0'));
    expect(filter, contains('f=62.5:width_type=o:width=1:gain=1.5'));
    expect(filter, contains('f=16000.0:width_type=o:width=1:gain=9.0'));
  });

  test('rejects malformed or out-of-range bands', () {
    expect(() => buildEqualizerFilter([0]), throwsArgumentError);
    expect(
      () => buildEqualizerFilter(List<double>.filled(10, 13)),
      throwsArgumentError,
    );
    expect(
      () => buildEqualizerFilter([0, 0, 0, 0, 0, 0, 0, 0, 0, double.nan]),
      throwsArgumentError,
    );
  });
}
