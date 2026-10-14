part of 'settings_page.dart';

/// Display name of a preset id.
///
/// Lives outside the widget so the appearance page can summarise the current
/// choice without duplicating this table.
String colorSchemePresetLabel(String? id) => switch (id) {
  kPresetSystem => "System".tl,
  kPresetCustom => "Custom".tl,
  'blue' => "Blue".tl,
  'purple' => "Purple".tl,
  'tokyo' => "Tokyo".tl,
  'teal' => "Teal".tl,
  'pink' => "Pink".tl,
  'amber' => "Amber".tl,
  'green' => "Green".tl,
  'red' => "Red".tl,
  'violet' => "Violet".tl,
  'graphite' => "Graphite".tl,
  'sepia' => "Sepia".tl,
  // The old `color` key fell back to blue; keep that for anything unreadable.
  _ => "Blue".tl,
};

/// The theme colour gallery: 11 seeded presets plus `system` and `custom`.
///
/// Everything here writes the same two settings the theme builder reads
/// (`colorSchemePreset`, `customSeedColor`), so there is no separate
/// "apply" step — a tap repaints the whole app immediately.
class AppColorSchemeSettings extends StatefulWidget {
  const AppColorSchemeSettings({super.key});

  @override
  State<AppColorSchemeSettings> createState() => _AppColorSchemeSettingsState();
}

class _AppColorSchemeSettingsState extends State<AppColorSchemeSettings> {
  late String _preset;
  late Color _seed;
  late HSLColor _hsl;
  late TextEditingController _hexController;
  bool _hexInvalid = false;

  /// Seeds at the extremes (pure black/white/grey) can't be expanded into a
  /// Material 3 tonal palette, so both sliders keep their seed inside a range
  /// `SeedColorScheme.fromSeeds` can actually work with.
  static const double _minSaturation = 0.05;
  static const double _minLightness = 0.15;
  static const double _maxLightness = 0.85;

  @override
  void initState() {
    super.initState();
    final preset = appdata.settings['colorSchemePreset'] as String?;
    _preset = isValidColorSchemePreset(preset) ? preset! : kPresetSystem;
    _seed = parseHexColor(appdata.settings['customSeedColor'] as String?) ??
        kDefaultSeedColor;
    _hsl = HSLColor.fromColor(_seed);
    _hexController = TextEditingController(text: _hexText);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String get _hexText => formatHexColor(_seed).substring(1);

  /// The seed currently being previewed.
  ///
  /// `system` has no seed of its own — it is whatever the platform is feeding
  /// the running app right now, which is exactly the ambient primary colour.
  Color _previewSeed() {
    if (_preset == kPresetSystem) return Theme.of(context).colorScheme.primary;
    if (_preset == kPresetCustom) return _seed;
    return seedColorForPreset(_preset) ?? kDefaultSeedColor;
  }

  void _selectPreset(String id) {
    setState(() => _preset = id);
    appdata.settings['colorSchemePreset'] = id;
    appdata.saveData();
    App.forceRebuild();
  }

  void _updateSeed(Color color) {
    setState(() {
      _seed = color;
      _hsl = HSLColor.fromColor(color);
      _hexController.text = _hexText;
    });
  }

  /// Persisting on every drag frame would queue a save (and a WebDAV upload)
  /// per pixel, so the drag only repaints and [onChangeEnd] commits.
  void _commitSeed() {
    appdata.settings['customSeedColor'] = formatHexColor(_seed);
    appdata.saveData();
    App.forceRebuild();
  }

  void _onHueChanged(double hue) =>
      _updateSeed(_hsl.withHue(hue.clamp(0.0, 360.0)).toColor());

  void _onSaturationChanged(double saturation) => _updateSeed(
    _hsl.withSaturation(saturation.clamp(_minSaturation, 1.0)).toColor(),
  );

  void _onLightnessChanged(double lightness) => _updateSeed(
    _hsl
        .withLightness(lightness.clamp(_minLightness, _maxLightness))
        .toColor(),
  );

  void _onHexSubmitted(String value) {
    final color = parseHexColor('#${value.trim()}');
    if (color == null) {
      setState(() => _hexInvalid = true);
      return;
    }
    // Force opaque: a translucent seed would derive a palette from a colour
    // the user never sees.
    _updateSeed(Color(color.toARGB32() | 0xFF000000));
    setState(() => _hexInvalid = false);
    _commitSeed();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Theme Color".tl)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text("Preview".tl, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _preview(Brightness.light),
          const SizedBox(height: 12),
          _preview(Brightness.dark),
          const SizedBox(height: 24),
          Text("Presets".tl, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _presetGrid(),
          if (_preset == kPresetCustom) ...[
            const SizedBox(height: 24),
            Text(
              "Custom seed".tl,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _customEditor(),
          ],
        ],
      ),
    );
  }

  Widget _preview(Brightness brightness) {
    final seed = _previewSeed();
    // Same derivation the running app uses (see [buildAppTheme]), so the
    // preview cannot drift from what a tap will actually apply.
    final theme = buildAppTheme(primary: seed, brightness: brightness);
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;
          return Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 28,
                  color: colorScheme.primaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    brightness == Brightness.light ? "Light".tl : "Dark".tl,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              height: 8,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              height: 8,
                              width: 120,
                              decoration: BoxDecoration(
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () {},
                        child: Text("Button".tl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _presetGrid() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final id in kColorSchemePresetIds) _presetTile(id),
      ],
    );
  }

  Widget _presetTile(String id) {
    final selected = _preset == id;
    final colorScheme = Theme.of(context).colorScheme;
    final swatch = switch (id) {
      kPresetSystem => colorScheme.primary,
      kPresetCustom => _seed,
      _ => seedColorForPreset(id) ?? kDefaultSeedColor,
    };
    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _selectPreset(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 20, color: colorScheme.onPrimary)
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                colorSchemePresetLabel(id),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _customEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _seed,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _hexController,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: InputDecoration(
                  prefixText: '#',
                  labelText: "HEX".tl,
                  errorText: _hexInvalid ? "Invalid colour code".tl : null,
                  isDense: true,
                ),
                onSubmitted: _onHexSubmitted,
                onChanged: (_) {
                  if (_hexInvalid) setState(() => _hexInvalid = false);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _slider("Hue".tl, _hsl.hue, 0, 360, 360, _onHueChanged),
        _slider(
          "Saturation".tl,
          _hsl.saturation.clamp(_minSaturation, 1.0),
          _minSaturation,
          1,
          95,
          _onSaturationChanged,
        ),
        _slider(
          "Lightness".tl,
          _hsl.lightness.clamp(_minLightness, _maxLightness),
          _minLightness,
          _maxLightness,
          70,
          _onLightnessChanged,
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          // The track is painted from the colour being edited, so dragging
          // reads as "mixing" rather than "typing a number".
          activeColor: _seed,
          onChanged: onChanged,
          onChangeEnd: (_) => _commitSeed(),
        ),
      ],
    );
  }
}
