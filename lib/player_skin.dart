import 'package:flutter/material.dart';

enum PlayerBackgroundStyle { blurredCover, coverTones, solidColor }

class PlayerSkin {
  const PlayerSkin({
    required this.id,
    required this.name,
    required this.backgroundColor,
    required this.textColor,
    required this.accentColor,
    required this.cornerRadius,
    required this.backgroundMotion,
    required this.motionDurationSeconds,
    required this.visualizerBars,
    this.backgroundStyle = PlayerBackgroundStyle.blurredCover,
    this.separateLyricsFont = false,
    this.lyricsFontFamily,
    this.fontFamily,
    this.fontScale,
  });

  static const defaultSkin = PlayerSkin(
    id: 'river-default',
    name: 'River',
    backgroundColor: Color(0xFF0F0F0F),
    textColor: Color(0xFFF8F7F5),
    accentColor: Colors.white,
    cornerRadius: 16,
    backgroundMotion: true,
    motionDurationSeconds: 14,
    visualizerBars: 32,
  );

  static const presets = <PlayerSkin>[
    defaultSkin,
    PlayerSkin(
      id: 'deep-ocean',
      name: 'Deep ocean',
      backgroundColor: Color(0xFF101A22),
      textColor: Color(0xFFEAF4F6),
      accentColor: Color(0xFF83D7E8),
      cornerRadius: 22,
      backgroundMotion: true,
      motionDurationSeconds: 18,
      visualizerBars: 32,
    ),
    PlayerSkin(
      id: 'warm-earth',
      name: 'Warm earth',
      backgroundColor: Color(0xFF211511),
      textColor: Color(0xFFFFF1E8),
      accentColor: Color(0xFFE4A078),
      cornerRadius: 12,
      backgroundMotion: true,
      motionDurationSeconds: 12,
      visualizerBars: 32,
    ),
    PlayerSkin(
      id: 'quiet-forest',
      name: 'Quiet forest',
      backgroundColor: Color(0xFF111A13),
      textColor: Color(0xFFF1F6ED),
      accentColor: Color(0xFFB4D39C),
      cornerRadius: 8,
      backgroundMotion: true,
      motionDurationSeconds: 22,
      visualizerBars: 24,
    ),
  ];

  final String id;
  final String name;
  final Color backgroundColor;
  final Color textColor;
  final Color accentColor;
  final double cornerRadius;
  final bool backgroundMotion;
  final double motionDurationSeconds;
  final int visualizerBars;
  final PlayerBackgroundStyle backgroundStyle;
  final bool separateLyricsFont;
  final String? lyricsFontFamily;
  final String? fontFamily;
  final double? fontScale;

  PlayerSkin copyWith({
    String? id,
    String? name,
    Color? backgroundColor,
    Color? textColor,
    Color? accentColor,
    double? cornerRadius,
    bool? backgroundMotion,
    double? motionDurationSeconds,
    int? visualizerBars,
    PlayerBackgroundStyle? backgroundStyle,
    bool? separateLyricsFont,
    String? lyricsFontFamily,
    String? fontFamily,
    double? fontScale,
  }) {
    return PlayerSkin(
      id: id ?? this.id,
      name: name ?? this.name,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      accentColor: accentColor ?? this.accentColor,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      backgroundMotion: backgroundMotion ?? this.backgroundMotion,
      motionDurationSeconds:
          motionDurationSeconds ?? this.motionDurationSeconds,
      visualizerBars: visualizerBars ?? this.visualizerBars,
      backgroundStyle: backgroundStyle ?? this.backgroundStyle,
      separateLyricsFont: separateLyricsFont ?? this.separateLyricsFont,
      lyricsFontFamily: lyricsFontFamily ?? this.lyricsFontFamily,
      fontFamily: fontFamily ?? this.fontFamily,
      fontScale: fontScale ?? this.fontScale,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'background': backgroundColor.toARGB32(),
    'text': textColor.toARGB32(),
    'accent': accentColor.toARGB32(),
    'cornerRadius': cornerRadius,
    'backgroundMotion': backgroundMotion,
    'motionDurationSeconds': motionDurationSeconds,
    'visualizerBars': visualizerBars,
    'backgroundStyle': backgroundStyle.name,
    'separateLyricsFont': separateLyricsFont,
    'lyricsFontFamily': lyricsFontFamily,
    'fontFamily': fontFamily,
    'fontScale': fontScale,
  };

  factory PlayerSkin.fromJson(Map<String, Object?> json) {
    return PlayerSkin(
      id: json['id'] as String,
      name: json['name'] as String,
      backgroundColor: Color(json['background'] as int),
      textColor: Color(json['text'] as int),
      accentColor: Color(json['accent'] as int),
      cornerRadius: (json['cornerRadius'] as num).toDouble().clamp(0, 40),
      backgroundMotion: json['backgroundMotion'] as bool? ?? true,
      motionDurationSeconds:
          (json['motionDurationSeconds'] as num?)?.toDouble().clamp(1, 40) ??
          14,
      visualizerBars: (json['visualizerBars'] as int? ?? 32).clamp(16, 64),
      backgroundStyle: PlayerBackgroundStyle.values.firstWhere(
        (style) => style.name == json['backgroundStyle'],
        orElse: () => PlayerBackgroundStyle.blurredCover,
      ),
      separateLyricsFont: json['separateLyricsFont'] as bool? ?? false,
      lyricsFontFamily: json['lyricsFontFamily'] as String?,
      fontFamily: json['fontFamily'] as String?,
      fontScale: (json['fontScale'] as num?)?.toDouble().clamp(0.85, 1.4),
    );
  }
}
