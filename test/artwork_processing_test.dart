import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:river/artwork_palette.dart';

void main() {
  test('artwork keeps high-resolution cover data and prepares palette and backdrop', () async {
    final source = await _createArtwork();
    final prepared = await Isolate.run(() => prepareArtwork(source));

    expect(prepared, isNotNull);
    final cover = img.decodeImage(prepared!.cover)!;
    final backdrop = img.decodeImage(prepared.backdrop)!;
    expect(mathMax(cover.width, cover.height), 1024);
    expect(mathMax(backdrop.width, backdrop.height), lessThanOrEqualTo(192));
    expect(prepared.cover.length, lessThan(1024 * 1024 * 4));
    expect(prepared.backdrop.length, lessThan(prepared.cover.length));
    expect(prepared.palettePrimary, isNot(0xFF000000));
    expect(prepared.paletteAccent, isNot(0xFF000000));
  });

  test('palette favors common cover colors over a single bright pixel', () {
    final image = img.Image(width: 64, height: 64);
    img.fillRect(
      image,
      x1: 0,
      y1: 0,
      x2: 27,
      y2: 63,
      color: img.ColorRgb8(220, 48, 42),
    );
    img.fillRect(
      image,
      x1: 28,
      y1: 0,
      x2: 55,
      y2: 63,
      color: img.ColorRgb8(48, 180, 78),
    );
    img.fillRect(
      image,
      x1: 56,
      y1: 0,
      x2: 63,
      y2: 63,
      color: img.ColorRgb8(12, 14, 18),
    );
    image.setPixel(60, 32, img.ColorRgb8(0, 100, 255));

    final prepared = prepareArtwork(Uint8List.fromList(img.encodePng(image)));

    expect(prepared, isNotNull);
    final colors = [prepared!.palettePrimary, prepared.paletteAccent];
    expect(colors.where(_isRedOrGreen), hasLength(2));
  });
}

int mathMax(int a, int b) => a > b ? a : b;

bool _isRedOrGreen(int color) {
  final red = (color >> 16) & 0xFF;
  final green = (color >> 8) & 0xFF;
  final blue = color & 0xFF;
  final isRed = red > green * 1.5 && red > blue * 1.5;
  final isGreen = green > red * 1.5 && green > blue * 1.5;
  return isRed || isGreen;
}

Future<Uint8List> _createArtwork() async {
  const size = 1600;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final stripeWidth = size / 3;
  const colors = [Color(0xFFE53935), Color(0xFF43A047), Color(0xFF1E88E5)];
  for (var index = 0; index < colors.length; index++) {
    canvas.drawRect(
      Rect.fromLTWH(index * stripeWidth, 0, stripeWidth, size.toDouble()),
      Paint()..color = colors[index],
    );
  }
  final image = await recorder.endRecording().toImage(size, size);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
