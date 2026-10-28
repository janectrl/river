import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:river/player_backdrop.dart';

void main() {
  testWidgets('backdrop fills the window and drifts across both axes', (
    tester,
  ) async {
    final imageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                Positioned.fill(
                  child: PlayerBackdrop(
                    imageProvider: MemoryImage(imageBytes),
                    trackKey: 'track',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Image)), const Size(800, 600));
    final initialTranslation = tester.widget<Transform>(
      find.byType(Transform).first,
    );
    final initialX = initialTranslation.transform.storage[12];
    final initialY = initialTranslation.transform.storage[13];
    final initialScale = tester
        .widget<Transform>(find.byType(Transform).last)
        .transform
        .storage[0];
    final initialRotation = tester
        .widget<Transform>(find.byType(Transform).at(1))
        .transform
        .storage[1];

    await tester.pump(const Duration(seconds: 7));

    final translation = tester.widget<Transform>(find.byType(Transform).first);
    final scale = tester
        .widget<Transform>(find.byType(Transform).last)
        .transform
        .storage[0];
    final rotation = tester
        .widget<Transform>(find.byType(Transform).at(1))
        .transform
        .storage[1];
    expect(
      (translation.transform.storage[12] - initialX).abs(),
      greaterThan(8),
    );
    expect(
      (translation.transform.storage[13] - initialY).abs(),
      greaterThan(4),
    );
    expect(translation.transform.storage[12].abs(), lessThanOrEqualTo(36));
    expect(translation.transform.storage[13].abs(), lessThanOrEqualTo(18));
    expect(scale, isNot(initialScale));
    expect(scale, inInclusiveRange(1.12, 1.16));
    expect(rotation, isNot(initialRotation));
    expect(rotation.abs(), lessThanOrEqualTo(0.012));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-second motion setting completes its cycle in two seconds', (
    tester,
  ) async {
    final imageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlayerBackdrop(
              imageProvider: MemoryImage(imageBytes),
              trackKey: 'track',
              motionDurationSeconds: 1,
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));

    final translation = tester.widget<Transform>(find.byType(Transform).first);
    expect(translation.transform.storage[12], closeTo(36, 0.1));
    expect(translation.transform.storage[13], closeTo(-18, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop motion respects the skin motion setting', (
    tester,
  ) async {
    final imageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlayerBackdrop(
              imageProvider: MemoryImage(imageBytes),
              trackKey: 'track',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 10));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlayerBackdrop(
              imageProvider: MemoryImage(imageBytes),
              trackKey: 'track',
              motionEnabled: false,
            ),
          ),
        ),
      ),
    );
    final initialTranslation = tester.widget<Transform>(
      find.byType(Transform).first,
    );
    final initialX = initialTranslation.transform.storage[12];
    final initialY = initialTranslation.transform.storage[13];
    final initialScale = tester
        .widget<Transform>(find.byType(Transform).last)
        .transform
        .storage[0];
    final initialRotation = tester
        .widget<Transform>(find.byType(Transform).at(1))
        .transform
        .storage[1];
    await tester.pump(const Duration(seconds: 30));
    final translation = tester.widget<Transform>(find.byType(Transform).first);
    expect(translation.transform.storage[12], initialX);
    expect(translation.transform.storage[13], initialY);
    expect(
      tester
          .widget<Transform>(find.byType(Transform).last)
          .transform
          .storage[0],
      initialScale,
    );
    expect(
      tester
          .widget<Transform>(find.byType(Transform).at(1))
          .transform
          .storage[1],
      initialRotation,
    );
    expect(tester.takeException(), isNull);
  });
}
