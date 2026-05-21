import 'package:flutter/material.dart';

import 'event_design_categories.dart';
import 'events_feature_api.dart';

/// Manager settings: edit event theme design category chips shown to customers.
class EventDesignAdminScreen extends StatefulWidget {
  const EventDesignAdminScreen({
    super.key,
    required this.apiBase,
    required this.staffEmail,
    required this.staffPassword,
  });

  final String apiBase;
  final String staffEmail;
  final String staffPassword;

  @override
  State<EventDesignAdminScreen> createState() => _EventDesignAdminScreenState();
}

class _EventDesignAdminScreenState extends State<EventDesignAdminScreen> {
  EventDesignCategories _cats = EventDesignCategories.defaults;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      final c = await api.getEventDesignCategories();
      if (!mounted) return;
      setState(() {
        _cats = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      await api.saveEventDesignCategories(
        categories: _cats,
        staffEmail: widget.staffEmail,
        staffPassword: widget.staffPassword,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event design categories saved.')),
      );
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

  void _addOption(String field, String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    setState(() {
      switch (field) {
        case 'styles':
          if (!_cats.styles.contains(v)) _cats = EventDesignCategories(styles: [..._cats.styles, v], moods: _cats.moods, palettes: _cats.palettes, decor: _cats.decor);
        case 'moods':
          if (!_cats.moods.contains(v)) _cats = EventDesignCategories(styles: _cats.styles, moods: [..._cats.moods, v], palettes: _cats.palettes, decor: _cats.decor);
        case 'palettes':
          if (!_cats.palettes.contains(v)) _cats = EventDesignCategories(styles: _cats.styles, moods: _cats.moods, palettes: [..._cats.palettes, v], decor: _cats.decor);
        case 'decor':
          if (!_cats.decor.contains(v)) _cats = EventDesignCategories(styles: _cats.styles, moods: _cats.moods, palettes: _cats.palettes, decor: [..._cats.decor, v]);
      }
    });
  }

  void _removeOption(String field, String value) {
    setState(() {
      switch (field) {
        case 'styles':
          _cats = EventDesignCategories(styles: _cats.styles.where((e) => e != value).toList(), moods: _cats.moods, palettes: _cats.palettes, decor: _cats.decor);
        case 'moods':
          _cats = EventDesignCategories(styles: _cats.styles, moods: _cats.moods.where((e) => e != value).toList(), palettes: _cats.palettes, decor: _cats.decor);
        case 'palettes':
          _cats = EventDesignCategories(styles: _cats.styles, moods: _cats.moods, palettes: _cats.palettes.where((e) => e != value).toList(), decor: _cats.decor);
        case 'decor':
          _cats = EventDesignCategories(styles: _cats.styles, moods: _cats.moods, palettes: _cats.palettes, decor: _cats.decor.where((e) => e != value).toList());
      }
    });
  }

  Future<void> _promptAdd(String field, String title) async {
    final ctl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add $title'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(hintText: 'New option'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    ctl.dispose();
    if (v != null && v.isNotEmpty) _addOption(field, v);
  }

  Widget _categoryEditor(String field, String title, List<String> options) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800))),
                TextButton.icon(
                  onPressed: () => _promptAdd(field, title),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in options)
                  InputChip(
                    label: Text(o),
                    onDeleted: () => _removeOption(field, o),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Event theme design options'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(onPressed: _save, icon: const Icon(Icons.save_outlined), tooltip: 'Save'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Text(
                        'These options appear in the customer Event Theme Design flow (style, mood, colors, decor).',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.35),
                      ),
                      const SizedBox(height: 12),
                      _categoryEditor('styles', 'Style', _cats.styles),
                      _categoryEditor('moods', 'Mood / lighting', _cats.moods),
                      _categoryEditor('palettes', 'Color palette', _cats.palettes),
                      _categoryEditor('decor', 'Decor elements', _cats.decor),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: const Text('Save all categories'),
                      ),
                    ],
                  ),
                ),
    );
  }
}
