import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'event_design_constants.dart';
import 'events_feature_api.dart';
import 'runpod_service.dart';

/// AI event theme design (RunPod img2img). Returns `theme_design` map on save via [Navigator.pop].
class EventThemeDesignScreen extends StatefulWidget {
  const EventThemeDesignScreen({
    super.key,
    required this.apiBase,
    required this.userEmail,
    this.orderId,
    this.orderKind = 'event',
    this.initialEventType = 'Birthday',
    this.initialThemeDesign,
    this.cashierEmail,
    this.cashierPassword,
    this.persistToOrder = false,
  });

  final String apiBase;
  final String userEmail;
  final String? orderId;
  final String orderKind;
  final String initialEventType;
  final Map<String, dynamic>? initialThemeDesign;
  final String? cashierEmail;
  final String? cashierPassword;
  final bool persistToOrder;

  @override
  State<EventThemeDesignScreen> createState() => _EventThemeDesignScreenState();
}

class _EventThemeDesignScreenState extends State<EventThemeDesignScreen> {
  late String _eventType;
  String? _style;
  String? _mood;
  final Set<String> _palettes = {};
  final Set<String> _decor = {};
  final _styleOther = TextEditingController();
  final _moodOther = TextEditingController();
  final _paletteOther = TextEditingController();
  final _decorOther = TextEditingController();
  final _notes = TextEditingController();
  String? _venueB64;
  String? _generatedUrl;
  final List<String> _otherImageUrls = [];
  bool _generating = false;
  bool _saving = false;
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    RunPodService.configure(widget.apiBase);
    _eventType = widget.initialEventType;
    final td = widget.initialThemeDesign ?? {};
    _style = '${td['style'] ?? ''}'.trim().isEmpty ? null : '${td['style']}';
    _mood = '${td['mood'] ?? ''}'.trim().isEmpty ? null : '${td['mood']}';
    for (final p in (td['colorPalette'] is List ? td['colorPalette'] as List : const [])) {
      _palettes.add('$p');
    }
    for (final d in (td['decorElements'] is List ? td['decorElements'] as List : const [])) {
      _decor.add('$d');
    }
    _notes.text = '${td['customInstructions'] ?? td['note'] ?? ''}';
    _venueB64 = '${td['venuePhotoBase64'] ?? ''}'.trim().isEmpty ? null : '${td['venuePhotoBase64']}';
    _generatedUrl = '${td['generatedImageUrl'] ?? ''}'.trim().isEmpty ? null : '${td['generatedImageUrl']}';
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
  }

  @override
  void dispose() {
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
      final rows = await api.listAiGenerations(widget.userEmail);
      if (!mounted) return;
      setState(() {
        _history = rows;
        _otherImageUrls
          ..clear()
          ..addAll(
            rows
                .map((r) => '${r['image_url'] ?? ''}'.trim())
                .where((u) => u.isNotEmpty && u != _generatedUrl)
                .take(8),
          );
      });
    } catch (_) {}
  }

  /// Resize venue reference to max 768px width PNG base64 (handoff `inquire_page.dart`).
  Future<String?> _encodeVenueForRunpod() async {
    if (_venueB64 == null || _venueB64!.isEmpty) return null;
    try {
      final raw = base64Decode(_venueB64!);
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 768);
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png == null) return _venueB64;
      return base64Encode(png.buffer.asUint8List());
    } catch (_) {
      return _venueB64;
    }
  }

  Future<void> _pickVenue({bool replace = false}) async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo must be 5 MB or smaller.')),
        );
      }
      return;
    }
    setState(() => _venueB64 = base64Encode(bytes));
  }

  String _composePrompt() {
    final parts = <String>[
      'Professional event venue decoration concept',
      'event type: $_eventType',
      if (_style != null) 'style: $_style',
      if (_styleOther.text.trim().isNotEmpty) 'style detail: ${_styleOther.text.trim()}',
      if (_mood != null) 'mood: $_mood',
      if (_moodOther.text.trim().isNotEmpty) 'mood detail: ${_moodOther.text.trim()}',
      if (_palettes.isNotEmpty) 'color palette: ${_palettes.join(', ')}',
      if (_paletteOther.text.trim().isNotEmpty) 'palette detail: ${_paletteOther.text.trim()}',
      if (_decor.isNotEmpty) 'decor: ${_decor.join(', ')}',
      if (_decorOther.text.trim().isNotEmpty) 'decor detail: ${_decorOther.text.trim()}',
      if (_notes.text.trim().isNotEmpty) _notes.text.trim(),
    ];
    return parts.join('. ');
  }

  bool get _hasPreferences =>
      _style != null ||
      _mood != null ||
      _palettes.isNotEmpty ||
      _decor.isNotEmpty ||
      _notes.text.trim().isNotEmpty ||
      _styleOther.text.trim().isNotEmpty;

  Future<void> _generate() async {
    if (_venueB64 == null || _venueB64!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload a venue reference photo first.')),
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
      final venue = await _encodeVenueForRunpod();
      final url = await RunPodService.generateImageWithPolling(
        _composePrompt(),
        user_id: widget.userEmail,
        initImageBase64: venue,
        strength: 0.52,
        numInferenceSteps: 18,
        designMeta: {
          'event_type': _eventType,
          if (_style != null) 'style': _style,
          if (_mood != null) 'mood': _mood,
        },
      );
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Generation finished but no image URL was returned.')),
        );
        return;
      }
      setState(() => _generatedUrl = url);
      await _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your custom event design is ready!')),
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
    return {
      'serviceType': 'catering+event',
      'menuChoice': 'custom_menu',
      'eventDesignSource': 'customer_ai',
      'eventDesignEventType': _eventType,
      if (_style != null) 'style': _style,
      if (_mood != null) 'mood': _mood,
      'colorPalette': _palettes.toList(),
      'decorElements': _decor.toList(),
      'customInstructions': _notes.text.trim(),
      if (_venueB64 != null) 'venuePhotoBase64': _venueB64,
      if (_generatedUrl != null) 'generatedImageUrl': _generatedUrl,
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
        content: const Text('This will store your AI concept and selections.'),
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
    TextEditingController? otherCtrl,
    String otherLabel = 'Other',
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
                selected: selected.contains(o),
                onSelected: (_) => setState(() => onToggle(o)),
              ),
            FilterChip(
              label: Text(otherLabel),
              selected: otherCtrl != null && otherCtrl.text.trim().isNotEmpty,
              onSelected: (_) => setState(() {}),
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
          title: const Text('Event theme design (AI)'),
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
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DropdownButtonFormField<String>(
                    value: kEventTypeOptions.contains(_eventType) ? _eventType : 'Other',
                    decoration: const InputDecoration(labelText: 'Event type', border: OutlineInputBorder()),
                    items: [for (final t in kEventTypeOptions) DropdownMenuItem(value: t, child: Text(t))],
                    onChanged: (v) => setState(() => _eventType = v ?? _eventType),
                  ),
                  const SizedBox(height: 12),
                  _chipSection(
                    title: 'Style',
                    options: kEventDesignStyles,
                    selected: _style != null ? {_style!} : {},
                    onToggle: (v) => setState(() => _style = _style == v ? null : v),
                    otherCtrl: _styleOther,
                  ),
                  _chipSection(
                    title: 'Mood / lighting',
                    options: kEventDesignMoods,
                    selected: _mood != null ? {_mood!} : {},
                    onToggle: (v) => setState(() => _mood = _mood == v ? null : v),
                    otherCtrl: _moodOther,
                  ),
                  _chipSection(
                    title: 'Color palette',
                    options: kEventDesignPalettes,
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
                    options: kEventDesignDecor,
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
                  const SizedBox(height: 12),
                  Text('Venue photo', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (_venueB64 != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(base64Decode(_venueB64!), height: 140, width: double.infinity, fit: BoxFit.cover),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _pickVenue(replace: _venueB64 != null),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: Text(_venueB64 == null ? 'Upload venue photo' : 'Change venue reference photo'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_generatedUrl != null) ...[
                    Text('Design preview', style: Theme.of(context).textTheme.titleMedium),
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
                      child: const Text('Your AI concept will appear here after you generate.'),
                    ),
                  if (_otherImageUrls.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Other generated designs', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 88,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _otherImageUrls.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => GestureDetector(
                          onTap: () => setState(() => _generatedUrl = _otherImageUrls[i]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(_otherImageUrls[i], width: 88, height: 88, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () async {
                          if (await _confirmCancel()) {
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(widget.persistToOrder ? 'Save' : 'Use this design'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
