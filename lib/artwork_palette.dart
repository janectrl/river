import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

typedef PreparedArtwork = ({
  Uint8List cover,
  Uint8List backdrop,
  int palettePrimary,
  int paletteAccent,
});

PreparedArtwork? prepareArtwork(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final coverScale = math.min(
    1.0,
    1024 / math.max(decoded.width, decoded.height),
  );
  final cover = img.copyResize(
    decoded,
    width: (decoded.width * coverScale).round(),
    height: (decoded.height * coverScale).round(),
    interpolation: img.Interpolation.average,
  );
  final backdropScale = math.min(
    1.0,
    192 / math.max(cover.width, cover.height),
  );
  final paletteImage = img.copyResize(
    cover,
    width: 16,
    height: 16,
    interpolation: img.Interpolation.average,
  );
  final buckets = <int, _PaletteBucket>{};
  for (final pixel in paletteImage) {
    final red = pixel.r.toInt();
    final green = pixel.g.toInt();
    final blue = pixel.b.toInt();
    final key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4);
    final bucket = buckets.putIfAbsent(key, () => _PaletteBucket(key));
    bucket.count++;
    bucket.red += red;
    bucket.green += green;
    bucket.blue += blue;
  }
  final allBuckets = buckets.values.toList();
  final colorfulBuckets = allBuckets
      .where(
        (bucket) =>
            bucket.saturation >= 0.15 &&
            bucket.maximum >= 40 &&
            bucket.minimum <= 238,
      )
      .toList();
  final primaryCandidates = colorfulBuckets.isEmpty
      ? allBuckets
      : colorfulBuckets;
  primaryCandidates.sort((first, second) {
    final byCoverage = second.count.compareTo(first.count);
    return byCoverage != 0 ? byCoverage : first.key.compareTo(second.key);
  });
  final primary = primaryCandidates.first;
  final accentCandidates =
      colorfulBuckets.where((bucket) => bucket.key != primary.key).toList()
        ..sort((first, second) {
          final byScore = second.accentScore.compareTo(first.accentScore);
          return byScore != 0 ? byScore : first.key.compareTo(second.key);
        });
  final palettePrimary = primary.argb;
  final paletteAccent = accentCandidates.isEmpty
      ? palettePrimary
      : accentCandidates.first.argb;

  final backdrop = img.copyResize(
    cover,
    width: (cover.width * backdropScale).round(),
    height: (cover.height * backdropScale).round(),
    interpolation: img.Interpolation.average,
  );
  final blurredBackdrop = img.gaussianBlur(backdrop, radius: 14);

  return (
    cover: Uint8List.fromList(img.encodeJpg(cover, quality: 92)),
    backdrop: Uint8List.fromList(img.encodeJpg(blurredBackdrop, quality: 68)),
    palettePrimary: palettePrimary,
    paletteAccent: paletteAccent,
  );
}

class _PaletteBucket {
  _PaletteBucket(this.key);

  final int key;
  int count = 0;
  int red = 0;
  int green = 0;
  int blue = 0;

  double get averageRed => red / count;
  double get averageGreen => green / count;
  double get averageBlue => blue / count;
  double get maximum =>
      math.max(averageRed, math.max(averageGreen, averageBlue));
  double get minimum =>
      math.min(averageRed, math.min(averageGreen, averageBlue));
  double get saturation => maximum == 0 ? 0 : (maximum - minimum) / maximum;
  double get accentScore => count * (0.25 + saturation);

  int get argb =>
      0xFF000000 |
      averageRed.round() << 16 |
      averageGreen.round() << 8 |
      averageBlue.round();
}
