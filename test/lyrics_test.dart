import 'package:flutter_test/flutter_test.dart';
import 'package:river/lyrics.dart';

void main() {
  test('parses timed lines and ignores metadata tags', () {
    final lyrics = parseLrc(
      '[ar:Artist]\n[ti:Song]\n[00:01.20]First line\n[00:03.5]Second line',
    );

    expect(lyrics, hasLength(2));
    expect(lyrics[0].timestamp, const Duration(milliseconds: 1200));
    expect(lyrics[0].text, 'First line');
    expect(lyrics[1].timestamp, const Duration(milliseconds: 3500));
    expect(lyrics[1].text, 'Second line');
  });

  test('supports multiple timestamps, offsets, and sorted output', () {
    final lyrics = parseLrc(
      '[offset:-500]\n[00:04.00][00:02.00]Repeated line\n[00:03.00]Next',
    );

    expect(lyrics, hasLength(3));
    expect(lyrics[0].timestamp, const Duration(milliseconds: 1500));
    expect(lyrics[0].text, 'Repeated line');
    expect(lyrics[1].timestamp, const Duration(milliseconds: 2500));
    expect(lyrics[1].text, 'Next');
    expect(lyrics[2].timestamp, const Duration(milliseconds: 3500));
    expect(lyrics[2].text, 'Repeated line');
  });
}
