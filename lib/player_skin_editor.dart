import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'player_skin.dart';

class PlayerSkinEditor extends StatelessWidget {
  const PlayerSkinEditor({
    required this.languageCode,
    required this.skin,
    required this.skins,
    required this.onSelect,
    required this.onChange,
    required this.onCommit,
    required this.onSaveAs,
    required this.onDelete,
    required this.showCompactVisualizer,
    required this.onCompactVisualizerChanged,
    this.economyMode = false,
    super.key,
  });

  final String languageCode;
  final PlayerSkin skin;
  final List<PlayerSkin> skins;
  final ValueChanged<PlayerSkin> onSelect;
  final ValueChanged<PlayerSkin> onChange;
  final Future<void> Function() onCommit;
  final Future<void> Function(String name) onSaveAs;
  final Future<void> Function() onDelete;
  final bool showCompactVisualizer;
  final ValueChanged<bool> onCompactVisualizerChanged;
  final bool economyMode;

  String _t(String key, [Map<String, Object?> values = const {}]) =>
      RiverLocalizations(languageCode).text(key, values);

  Future<void> _editColor(
    BuildContext context, {
    required String label,
    required Color color,
    required ValueChanged<Color> onChanged,
  }) async {
    var hsv = HSVColor.fromColor(color);
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(label),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: hsv.toColor(),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(height: 12),
                _ColorSlider(
                  label: _t('skinHue'),
                  value: hsv.hue,
                  max: 360,
                  divisions: 360,
                  displayValue: '${hsv.hue.round()}°',
                  onChanged: (value) => setDialogState(() {
                    hsv = hsv.withHue(value);
                    onChanged(hsv.toColor());
                  }),
                ),
                _ColorSlider(
                  label: _t('skinSaturation'),
                  value: hsv.saturation,
                  max: 1,
                  divisions: 100,
                  displayValue: '${(hsv.saturation * 100).round()}%',
                  onChanged: (value) => setDialogState(() {
                    hsv = hsv.withSaturation(value);
                    onChanged(hsv.toColor());
                  }),
                ),
                _ColorSlider(
                  label: _t('skinBrightness'),
                  value: hsv.value,
                  max: 1,
                  divisions: 100,
                  displayValue: '${(hsv.value * 100).round()}%',
                  onChanged: (value) => setDialogState(() {
                    hsv = hsv.withValue(value);
                    onChanged(hsv.toColor());
                  }),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await onCommit();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(_t('done')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSkin(BuildContext context) async {
    var skinName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('skinSave')),
        content: TextField(
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(labelText: _t('skinName')),
          onChanged: (value) => skinName = value,
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, skinName.trim()),
            child: Text(_t('save')),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await onSaveAs(name.trim());
  }

  Widget _colorRow(
    BuildContext context, {
    required String label,
    required Color color,
    required ValueChanged<Color> onChanged,
    Key? key,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: IconButton(
        key: key,
        tooltip: label,
        onPressed: () => _editColor(
          context,
          label: label,
          color: color,
          onChanged: onChanged,
        ),
        icon: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: const SizedBox.square(dimension: 28),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = RiverLocalizations(languageCode);
    final isCustom = !PlayerSkin.presets.any((preset) => preset.id == skin.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('skins'), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey(skin.id),
          initialValue: skin.id,
          decoration: InputDecoration(labelText: _t('activeSkin')),
          items: [
            for (final profile in skins)
              DropdownMenuItem(value: profile.id, child: Text(profile.name)),
          ],
          onChanged: (id) {
            if (id == null) return;
            onSelect(skins.firstWhere((profile) => profile.id == id));
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _saveSkin(context),
                icon: const Icon(Icons.save_outlined),
                label: Text(_t('skinSaveAs')),
              ),
            ),
            if (isCustom) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: localizations.text('skinDelete'),
                onPressed: onDelete,
                icon: const Icon(CupertinoIcons.trash),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        _colorRow(
          context,
          label: _t('skinText'),
          color: skin.textColor,
          onChanged: (color) => onChange(skin.copyWith(textColor: color)),
        ),
        _colorRow(
          context,
          label: _t('skinAccent'),
          color: skin.accentColor,
          onChanged: (color) => onChange(skin.copyWith(accentColor: color)),
        ),
        DropdownButtonFormField<PlayerBackgroundStyle>(
          key: ValueKey(skin.backgroundStyle),
          initialValue: skin.backgroundStyle,
          decoration: InputDecoration(labelText: _t('skinBackgroundStyle')),
          items: [
            DropdownMenuItem(
              value: PlayerBackgroundStyle.blurredCover,
              child: Text(_t('backgroundBlurredCover')),
            ),
            DropdownMenuItem(
              value: PlayerBackgroundStyle.coverTones,
              child: Text(_t('backgroundCoverTones')),
            ),
            DropdownMenuItem(
              value: PlayerBackgroundStyle.solidColor,
              child: Text(_t('backgroundSolidColor')),
            ),
          ],
          onChanged: (style) async {
            if (style == null) return;
            onChange(skin.copyWith(backgroundStyle: style));
            await onCommit();
          },
        ),
        _colorRow(
          context,
          key: const ValueKey('skin-background-color'),
          label: _t('skinBackground'),
          color: skin.backgroundColor,
          onChanged: (color) => onChange(skin.copyWith(backgroundColor: color)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_t('compactVisualizer')),
          value: !economyMode && showCompactVisualizer,
          onChanged: economyMode ? null : onCompactVisualizerChanged,
        ),
        Text(_t('skinCorners', {'size': skin.cornerRadius.round()})),
        Slider(
          value: skin.cornerRadius.clamp(0, 40),
          min: 0,
          max: 40,
          divisions: 20,
          label: '${skin.cornerRadius.round()}',
          onChanged: (value) => onChange(skin.copyWith(cornerRadius: value)),
          onChangeEnd: (_) => onCommit(),
        ),
        if (skin.backgroundStyle == PlayerBackgroundStyle.blurredCover) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_t('skinBackgroundMotion')),
            value: skin.backgroundMotion,
            onChanged: (enabled) async {
              onChange(skin.copyWith(backgroundMotion: enabled));
              await onCommit();
            },
          ),
          if (skin.backgroundMotion) ...[
            Text(
              _t('skinMotionSpeed', {
                'seconds': skin.motionDurationSeconds.round(),
              }),
            ),
            Slider(
              key: const ValueKey('background-motion-speed'),
              value: skin.motionDurationSeconds.clamp(1, 40),
              min: 1,
              max: 40,
              divisions: 39,
              label: '${skin.motionDurationSeconds.round()} s',
              onChanged: (value) =>
                  onChange(skin.copyWith(motionDurationSeconds: value)),
              onChangeEnd: (_) => onCommit(),
            ),
          ],
        ],
        DropdownButtonFormField<int>(
          key: ValueKey(skin.visualizerBars),
          initialValue: skin.visualizerBars,
          decoration: InputDecoration(labelText: _t('skinVisualizerStyle')),
          items: [
            for (final count in [16, 24, 32, 48, 64])
              DropdownMenuItem(value: count, child: Text('$count')),
          ],
          onChanged: (count) {
            if (count == null) return;
            onChange(skin.copyWith(visualizerBars: count));
            onCommit();
          },
        ),
      ],
    );
  }
}

class _ColorSlider extends StatelessWidget {
  const _ColorSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(displayValue),
        ],
      ),
      Slider(
        value: value.clamp(0, max),
        min: 0,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );
}
