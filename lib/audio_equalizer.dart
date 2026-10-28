const equalizerBandFrequencies = <double>[
  31.25,
  62.5,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

String buildEqualizerFilter(List<double> gains) {
  if (gains.length != equalizerBandFrequencies.length) {
    throw ArgumentError.value(gains.length, 'gains', 'Expected 10 bands.');
  }

  final filters = <String>[];
  for (var index = 0; index < gains.length; index++) {
    final gain = gains[index];
    if (!gain.isFinite || gain < -12 || gain > 12) {
      throw ArgumentError.value(
        gain,
        'gains[$index]',
        'Expected -12 to 12 dB.',
      );
    }
    filters.add(
      'equalizer=f=${equalizerBandFrequencies[index]}:'
      'width_type=o:width=1:gain=${gain.toStringAsFixed(1)}',
    );
  }

  return '@river_equalizer:lavfi=[${filters.join(',')}]';
}
