import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/image_pick_limits.dart';
import 'event_design_categories.dart';
import 'events_feature_api.dart';
import 'runpod_service.dart';

/// Event theme design (RunPod img2img). Returns `theme_design` map on save via [Navigator.pop].
class EventThemeDesignScreen extends StatefulWidget {
  const EventThemeDesignScreen({
    super.key,
    required this.apiBase,
    required this.userEmail,
    this.orderId,
    this.orderKind = 'event',
    this.designSessionId,
    required this.initialEventType,
    this.initialThemeDesign,
    this.eventTitle,
    this.formalityLevel,
    this.eventSetting,
    this.cashierEmail,
    this.cashierPassword,
    this.persistToOrder = false,
  });

  final String apiBase;
  final String userEmail;
  final String? orderId;
  final String orderKind;
  final String? designSessionId;
  final String initialEventType;
  final Map<String, dynamic>? initialThemeDesign;
  final String? eventTitle;
  final String? formalityLevel;
  final String? eventSetting;
  final String? cashierEmail;
  final String? cashierPassword;
  final bool persistToOrder;

  @override
  State<EventThemeDesignScreen> createState() => _EventThemeDesignScreenState();
}

class _EventThemeDesignScreenState extends State<EventThemeDesignScreen> {
  late final String _eventType;
  String? _style;
  String? _mood;
  final Set<String> _palettes = {};
  final Set<String> _decor = {};
  final _styleOther = TextEditingController();
  final _moodOther = TextEditingController();
  final _paletteOther = TextEditingController();
  final _decorOther = TextEditingController();
  final _notes = TextEditingController();
  final List<String> _venuePhotosB64 = [];
  String? _generatedUrl;
  final List<String> _previousUrls = [];
  bool _generating = false;
  bool _saving = false;
  List<Map<String, dynamic>> _history = [];
  EventDesignCategories _categories = EventDesignCategories.defaults;
  final PageController _pageController = PageController();
  int _pageIndex = 0;

  static const _pageTitles = ['Style & mood', 'Colors & decor', 'Venue photos', 'Generate & save'];

  @override
  void initState() {
    super.initState();
    RunPodService.configure(widget.apiBase);
    _eventType = widget.initialEventType.trim().isEmpty ? 'Birthday' : widget.initialEventType.trim();
    final td = widget.initialThemeDesign ?? {};
    _style = '${td['style'] ?? ''}'.trim().isEmpty ? null : '${td['style']}';
    _mood = '${td['mood'] ?? ''}'.trim().isEmpty ? null : '${td['mood']}';
    _styleOther.text = '${td['styleOther'] ?? td['style_other'] ?? ''}'.trim();
    _moodOther.text = '${td['moodOther'] ?? td['mood_other'] ?? ''}'.trim();
    _paletteOther.text = '${td['paletteOther'] ?? td['palette_other'] ?? ''}'.trim();
    _decorOther.text = '${td['decorOther'] ?? td['decor_other'] ?? ''}'.trim();
    for (final p in (td['colorPalette'] is List ? td['colorPalette'] as List : const [])) {
      _palettes.add('$p');
    }
    for (final d in (td['decorElements'] is List ? td['decorElements'] as List : const [])) {
      _decor.add('$d');
    }
    _notes.text = '${td['customInstructions'] ?? td['note'] ?? ''}';
    final singleVenue = '${td['venuePhotoBase64'] ?? ''}'.trim();
    if (singleVenue.isNotEmpty) _venuePhotosB64.add(singleVenue);
    for (final v in (td['venuePhotos'] is List ? td['venuePhotos'] as List : const [])) {
      final s = '$v'.trim();
      if (s.isNotEmpty && !_venuePhotosB64.contains(s)) _venuePhotosB64.add(s);
    }
    for (final v in (td['reference_images'] is List ? td['reference_images'] as List : const [])) {
      final s = '$v'.trim();
      if (s.isNotEmpty && !_venuePhotosB64.contains(s)) _venuePhotosB64.add(s);
    }
    _generatedUrl = '${td['generatedImageUrl'] ?? ''}'.trim().isEmpty ? null : '${td['generatedImageUrl']}';
    for (final u in (td['previousGeneratedImageUrls'] is List ? td['previousGeneratedImageUrls'] as List : const [])) {
      final s = '$u'.trim();
      if (s.isNotEmpty && s != _generatedUrl) _previousUrls.add(s);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistory();
      _loadCategories();
    });
  }

  Future<void> _loadCategories() async {
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      final c = await api.getEventDesignCategories();
      if (mounted) setState(() => _categories = c);
    } catch (_) {}
  }

  @override
  void dispose() {
    _pageController.dispose();
    _styleOther.dispose();
    _moodOther.dispose();
    _paletteOther.dispose();
    _decorOther.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      final rows = await api.listAiGenerations(
        widget.userEmail,
        orderId: widget.orderId,
        designSessionId: widget.orderId == null ? widget.designSessionId : null,
      );
      if (!mounted) return;
      final urls = <String>[];
      for (final r in rows) {
        final u = '${r['image_url'] ?? ''}'.trim();
        if (u.isNotEmpty) urls.add(u);
      }
      setState(() {
        _history = rows;
        for (final u in urls) {
          if (!_previousUrls.contains(u)) _previousUrls.add(u);
        }
        if (_generatedUrl != null && _generatedUrl!.isNotEmpty && !_previousUrls.contains(_generatedUrl)) {
          _previousUrls.insert(0, _generatedUrl!);
        }
      });
    } catch (_) {}
  }

  List<String> get _galleryUrls {
    final seen = <String>{};
    final out = <String>[];
    void add(String? u) {
      final s = u?.trim() ?? '';
      if (s.isEmpty || seen.contains(s)) return;
      seen.add(s);
      out.add(s);
    }

    if (_generatedUrl != null) add(_generatedUrl);
    for (final u in _previousUrls) {
      add(u);
    }
    for (final r in _history) {
      add('${r['image_url'] ?? ''}');
    }
    return out;
  }

  String? get _primaryVenueB64 => _venuePhotosB64.isEmpty ? null : _venuePhotosB64.first;

  Future<String?> _encodeVenueForRunpod(String b64) async {
    if (b64.isEmpty) return null;
    try {
      final raw = base64Decode(b64);
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 768);
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png == null) return b64;
      return base64Encode(png.buffer.asUint8List());
    } catch (_) {
      return b64;
    }
  }

  Future<void> _pickVenuePhotos() async {
    final added = await pickImagesBase64(context: context, allowMultiple: true, maxWidth: 1600);
    if (!mounted || added.isEmpty) return;
    setState(() {
      for (final b in added) {
        if (!_venuePhotosB64.contains(b)) _venuePhotosB64.add(b);
      }
    });
  }

  String _detail(String? chip, TextEditingController other) {
    final parts = <String>[];
    if (chip != null && chip.trim().isNotEmpty) parts.add(chip.trim());
    if (other.text.trim().isNotEmpty) parts.add(other.text.trim());
    return parts.join(' — ');
  }

  String _composePrompt() {
    final lines = <String>[
      'Create one photorealistic event venue decoration concept image.',
      'Incorporate ALL of the following requirements together in a single cohesive scene (do not omit any item):',
      'Event type: $_eventType',
    ];
    final title = widget.eventTitle?.trim() ?? '';
    if (title.isNotEmpty) lines.add('Event title / theme: $title');
    final formality = widget.formalityLevel?.trim() ?? '';
    if (formality.isNotEmpty) lines.add('Formality: $formality');
    final setting = widget.eventSetting?.trim() ?? '';
    if (setting.isNotEmpty) lines.add('Venue setting: $setting');

    final styleLine = _detail(_style, _styleOther);
    if (styleLine.isNotEmpty) lines.add('Style: $styleLine');
    final moodLine = _detail(_mood, _moodOther);
    if (moodLine.isNotEmpty) lines.add('Mood and lighting: $moodLine');
    if (_palettes.isNotEmpty) {
      lines.add('Color palette (use all listed colors harmoniously): ${_palettes.join(', ')}');
    }
    if (_paletteOther.text.trim().isNotEmpty) {
      lines.add('Additional palette notes: ${_paletteOther.text.trim()}');
    }
    if (_decor.isNotEmpty) {
      lines.add('Decor elements (include every item): ${_decor.join(', ')}');
    }
    if (_decorOther.text.trim().isNotEmpty) {
      lines.add('Additional decor notes: ${_decorOther.text.trim()}');
    }
    if (_notes.text.trim().isNotEmpty) {
      lines.add('Customer notes: ${_notes.text.trim()}');
    }
    lines.add(
      'Use the uploaded venue photo as the spatial reference; keep realistic architecture and perspective while applying the full decoration scheme.',
    );
    return lines.join('\n');
  }

  Map<String, dynamic> _runpodDesignMeta() {
    return {
      'user_id': widget.userEmail,
      if (widget.orderId != null) 'order_id': widget.orderId,
      if (widget.designSessionId != null) 'design_session_id': widget.designSessionId,
      'event_type': _eventType,
      if (_style != null) 'style': _style,
      if (_mood != null) 'mood': _mood,
      if (_palettes.isNotEmpty) 'color_palette': _palettes.toList(),
      if (_decor.isNotEmpty) 'decor_elements': _decor.toList(),
      if (_styleOther.text.trim().isNotEmpty) 'style_other': _styleOther.text.trim(),
      if (_moodOther.text.trim().isNotEmpty) 'mood_other': _moodOther.text.trim(),
      if (_paletteOther.text.trim().isNotEmpty) 'palette_other': _paletteOther.text.trim(),
      if (_decorOther.text.trim().isNotEmpty) 'decor_other': _decorOther.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'custom_instructions': _notes.text.trim(),
      if (widget.eventTitle != null && widget.eventTitle!.trim().isNotEmpty) 'event_title': widget.eventTitle!.trim(),
      if (widget.formalityLevel != null && widget.formalityLevel!.trim().isNotEmpty)
        'formality_level': widget.formalityLevel!.trim(),
      if (widget.eventSetting != null && widget.eventSetting!.trim().isNotEmpty)
        'event_setting': widget.eventSetting!.trim(),
    };
  }

  bool get _hasPreferences =>
      _style != null ||
      _mood != null ||
      _palettes.isNotEmpty ||
      _decor.isNotEmpty ||
      _notes.text.trim().isNotEmpty ||
      _styleOther.text.trim().isNotEmpty ||
      _moodOther.text.trim().isNotEmpty ||
      _paletteOther.text.trim().isNotEmpty ||
      _decorOther.text.trim().isNotEmpty;

  Future<void> _generate() async {
    final primary = _primaryVenueB64;
    if (primary == null || primary.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload at least one venue reference photo first.')),
      );
      return;
    }
    if (!_hasPreferences) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one style, mood, color, decor, or add notes.')),
      );
      return;
    }
    setState(() => _generating = true);
    try {
      final venue = await _encodeVenueForRunpod(primary);
      final url = await RunPodService.generateImageWithPolling(
        _composePrompt(),
        user_id: widget.userEmail,
        initImageBase64: venue,
        strength: 0.58,
        numInferenceSteps: 22,
        designMeta: _runpodDesignMeta(),
      );
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Generation finished but no image URL was returned.')),
        );
        return;
      }
      setState(() {
        if (_generatedUrl != null && _generatedUrl!.isNotEmpty && _generatedUrl != url) {
          if (!_previousUrls.contains(_generatedUrl)) {
            _previousUrls.insert(0, _generatedUrl!);
          }
        }
        _generatedUrl = url;
        if (!_previousUrls.contains(url)) _previousUrls.insert(0, url);
      });
      await _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your event design is ready!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Map<String, dynamic> _buildThemeDesignForApi() {
    final prev = <String>{
      for (final u in _previousUrls) u.trim(),
      if (_generatedUrl != null) _generatedUrl!.trim(),
    }..removeWhere((u) => u.isEmpty);

    return {
      'serviceType': 'catering+event',
      'menuChoice': 'custom_menu',
      'eventDesignSource': 'customer_ai',
      'eventDesignEventType': _eventType,
      if (_style != null) 'style': _style,
      if (_mood != null) 'mood': _mood,
      if (_styleOther.text.trim().isNotEmpty) 'styleOther': _styleOther.text.trim(),
      if (_moodOther.text.trim().isNotEmpty) 'moodOther': _moodOther.text.trim(),
      if (_paletteOther.text.trim().isNotEmpty) 'paletteOther': _paletteOther.text.trim(),
      if (_decorOther.text.trim().isNotEmpty) 'decorOther': _decorOther.text.trim(),
      'colorPalette': _palettes.toList(),
      'decorElements': _decor.toList(),
      'customInstructions': _notes.text.trim(),
      if (_venuePhotosB64.isNotEmpty) 'venuePhotoBase64': _venuePhotosB64.first,
      if (_venuePhotosB64.isNotEmpty) 'venuePhotos': List<String>.from(_venuePhotosB64),
      if (_venuePhotosB64.isNotEmpty) 'reference_images': List<String>.from(_venuePhotosB64),
      if (_generatedUrl != null) 'generatedImageUrl': _generatedUrl,
      'previousGeneratedImageUrls': prev.toList(),
      'wantsCustomDesign': true,
    };
  }

  Future<bool> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Unsaved theme design changes will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save() async {
    if (_generatedUrl == null || _generatedUrl!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generate a design before saving.')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save theme design?'),
        content: const Text('This will store your design concept and selections.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      final payload = _buildThemeDesignForApi();
      if (widget.persistToOrder && widget.orderId != null) {
        final api = EventsFeatureApi(apiBase: widget.apiBase);
        await api.saveThemeDesign(
          orderId: widget.orderId!,
          orderKind: widget.orderKind,
          themeDesign: payload,
          userEmail: widget.userEmail,
          cashierEmail: widget.cashierEmail,
          cashierPassword: widget.cashierPassword,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, payload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _downloadUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _chipSection({
    required String title,
    required List<String> options,
    required Set<String> selected,
    required void Function(String) onToggle,
    bool singleSelect = false,
    TextEditingController? otherCtrl,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in options)
              FilterChip(
                label: Text(o),
                selected: singleSelect ? selected.contains(o) : selected.contains(o),
                onSelected: (_) => setState(() => onToggle(o)),
              ),
          ],
        ),
        if (otherCtrl != null) ...[
          const SizedBox(height: 8),
          TextField(
            controller: otherCtrl,
            decoration: InputDecoration(
              labelText: '$title — other',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _previousDesignsGallery() {
    final urls = _galleryUrls;
    if (urls.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          widget.orderId != null ? 'Designs for this inquiry' : 'Designs for this session',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a thumbnail to use it as your selected design.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final url = urls[i];
              final selected = url == _generatedUrl;
              return GestureDetector(
                onTap: () => setState(() => _generatedUrl = url),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(url, width: 96, height: 96, fit: BoxFit.cover),
                    ),
                    if (selected)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _goNext() {
    if (_pageIndex < _pageTitles.length - 1) {
      _pageController.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  void _goBack() {
    if (_pageIndex > 0) {
      _pageController.previousPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  Widget _pageIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: List.generate(_pageTitles.length, (i) {
          final active = i == _pageIndex;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFFE8B923) : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _pageTitles[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? Colors.black87 : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmCancel()) {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Event theme design'),
          actions: [
            if (_saving || _generating)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ],
        ),
        body: _generating
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Generating your event design…'),
                    Text('This may take a few minutes.', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : Column(
                children: [
                  _pageIndicator(),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (i) => setState(() => _pageIndex = i),
                      children: [
                        ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _lockedEventTypeField(),
                            _chipSection(
                              title: 'Style',
                              options: _categories.styles,
                              selected: _style != null ? {_style!} : {},
                              singleSelect: true,
                              onToggle: (v) => setState(() => _style = _style == v ? null : v),
                              otherCtrl: _styleOther,
                            ),
                            _chipSection(
                              title: 'Mood / lighting',
                              options: _categories.moods,
                              selected: _mood != null ? {_mood!} : {},
                              singleSelect: true,
                              onToggle: (v) => setState(() => _mood = _mood == v ? null : v),
                              otherCtrl: _moodOther,
                            ),
                          ],
                        ),
                        ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _chipSection(
                              title: 'Color palette',
                              options: _categories.palettes,
                              selected: _palettes,
                              onToggle: (v) => setState(() {
                                if (_palettes.contains(v)) {
                                  _palettes.remove(v);
                                } else {
                                  _palettes.add(v);
                                }
                              }),
                              otherCtrl: _paletteOther,
                            ),
                            _chipSection(
                              title: 'Decor elements',
                              options: _categories.decor,
                              selected: _decor,
                              onToggle: (v) => setState(() {
                                if (_decor.contains(v)) {
                                  _decor.remove(v);
                                } else {
                                  _decor.add(v);
                                }
                              }),
                              otherCtrl: _decorOther,
                            ),
                            TextField(
                              controller: _notes,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                labelText: 'Notes',
                                hintText: 'e.g. simple wedding setup with garden theme',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ],
                        ),
                        ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Text('Venue reference photos', style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            Text(
                              'Upload one or more photos of your venue (max ${kMaxImageAttachmentBytes ~/ (1024 * 1024)} MB each). '
                              'The first photo is used for AI generation; all photos are available for seating layout.',
                              style: TextStyle(fontSize: 12, height: 1.35, color: Colors.grey.shade700),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _pickVenuePhotos,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Add venue photos'),
                            ),
                            if (_venuePhotosB64.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 100,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _venuePhotosB64.length,
                                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                                  itemBuilder: (context, i) => Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.memory(
                                          base64Decode(_venuePhotosB64[i]),
                                          width: 100,
                                          height: 100,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      if (i == 0)
                                        Positioned(
                                          left: 4,
                                          bottom: 4,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            color: Colors.black54,
                                            child: const Text('Primary', style: TextStyle(color: Colors.white, fontSize: 10)),
                                          ),
                                        ),
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        child: InkWell(
                                          onTap: () => setState(() => _venuePhotosB64.removeAt(i)),
                                          child: Container(
                                            color: Colors.black54,
                                            padding: const EdgeInsets.all(2),
                                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (_generatedUrl != null) ...[
                              Text('Selected design', style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              GestureDetector(
                                onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (ctx) => Dialog(
                                    child: InteractiveViewer(
                                      child: Image.network(_generatedUrl!, fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(_generatedUrl!, height: 220, width: double.infinity, fit: BoxFit.cover),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => _downloadUrl(_generatedUrl!),
                                    icon: const Icon(Icons.download_outlined),
                                    label: const Text('Open / download'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: _generatedUrl!));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Image URL copied')),
                                      );
                                    },
                                    icon: const Icon(Icons.link),
                                    label: const Text('Copy link'),
                                  ),
                                ],
                              ),
                            ] else
                              Container(
                                height: 160,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('Your design preview will appear here after you generate.'),
                              ),
                            _previousDesignsGallery(),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _generating ? null : _generate,
                              icon: const Icon(Icons.auto_awesome),
                              label: const Text('GENERATE EVENT DESIGN'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                backgroundColor: const Color(0xFFE8B923),
                                foregroundColor: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Row(
                        children: [
                          if (_pageIndex > 0)
                            TextButton(onPressed: _goBack, child: const Text('Back'))
                          else
                            TextButton(
                              onPressed: () async {
                                if (await _confirmCancel()) {
                                  if (context.mounted) Navigator.pop(context);
                                }
                              },
                              child: const Text('Cancel'),
                            ),
                          const Spacer(),
                          if (_pageIndex < _pageTitles.length - 1)
                            FilledButton(onPressed: _goNext, child: const Text('Next'))
                          else
                            FilledButton(
                              onPressed: _saving ? null : _save,
                              child: Text(widget.persistToOrder ? 'Save' : 'Use this design'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _lockedEventTypeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Event type',
            border: OutlineInputBorder(),
            filled: true,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _eventType,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              Icon(Icons.lock_outline, size: 18, color: Colors.grey.shade600),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 12),
          child: Text(
            'From your inquiry form — change it there if needed.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }
}
