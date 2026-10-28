class LyricLine {
  const LyricLine({required this.timestamp, required this.text});

  final Duration timestamp;
  final String text;
}

final _timestampPattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
final _offsetPattern = RegExp(r'^\[offset:([+-]?\d+)\]$', caseSensitive: false);

List<LyricLine> parseLrc(String contents) {
  final lines = <LyricLine>[];
  var offset = Duration.zero;

  for (final rawLine
      in contents.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final offsetMatch = _offsetPattern.firstMatch(line);
    if (offsetMatch != null) {
      offset = Duration(milliseconds: int.parse(offsetMatch.group(1)!));
      continue;
    }

    final matches = _timestampPattern.allMatches(line).toList();
    if (matches.isEmpty) continue;

    final text = line.substring(matches.last.end).trim();
    if (text.isEmpty) continue;

    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3) ?? '';
      final milliseconds = switch (fraction.length) {
        1 => int.parse(fraction) * 100,
        2 => int.parse(fraction) * 10,
        3 => int.parse(fraction),
        _ => 0,
      };
      final timestamp =
          Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: milliseconds,
          ) +
          offset;
      lines.add(
        LyricLine(
          timestamp: timestamp < Duration.zero ? Duration.zero : timestamp,
          text: text,
        ),
      );
    }
  }

  lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return List.unmodifiable(lines);
}
