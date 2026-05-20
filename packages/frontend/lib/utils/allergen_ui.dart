import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Multi-select guest allergens (manager inquiry / new event).
Widget buildGuestAllergenSelector({
  required List<String> catalog,
  required Set<String> selected,
  required bool enabled,
  required ValueChanged<Set<String>> onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Select all allergens your guests must avoid (optional).',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.35),
      ),
      const SizedBox(height: 10),
      if (catalog.isEmpty)
        Text(
          'Loading allergen list… Pull down to refresh if empty.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final name in catalog)
              FilterChip(
                label: Text(name, style: const TextStyle(fontSize: 12)),
                selected: selected.contains(name),
                onSelected: enabled
                    ? (sel) {
                        final next = Set<String>.from(selected);
                        if (sel) {
                          next.add(name);
                        } else {
                          next.remove(name);
                        }
                        onChanged(next);
                      }
                    : null,
              ),
          ],
        ),
    ],
  );
}

/// Generated / uploaded theme design preview for manager inquiry screens.
Widget managerThemeDesignImagePreview(Map<String, dynamic> themeDesign, {double height = 160}) {
  final webImage = '${themeDesign['image'] ?? themeDesign['imageBase64'] ?? themeDesign['output'] ?? ''}'.trim();
  final webImageUrl =
      '${themeDesign['generatedImageUrl'] ?? themeDesign['imageUrl'] ?? themeDesign['url'] ?? ''}'.trim();
  if (webImage.isNotEmpty) {
    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          base64Decode(webImage),
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
  if (webImageUrl.isNotEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        webImageUrl,
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
  return Text(
    'No generated theme design image yet.',
    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
  );
}

/// Read-only dish sheet: image, description, allergens (Inquire Catering / menu browse).
Future<void> showMenuDishDetailDialog(
  BuildContext context, {
  required String dishName,
  String description = '',
  List<String> allergens = const [],
  String? imageBase64,
}) {
  final desc = description.trim();
  final list = allergens.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final raw = imageBase64?.trim();
  Widget? imageWidget;
  if (raw != null && raw.isNotEmpty) {
    try {
      final bytes = Uint8List.fromList(base64Decode(raw));
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          bytes,
          height: 200,
          fit: BoxFit.cover,
          width: double.infinity,
          cacheWidth: 480,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    } catch (_) {
      imageWidget = null;
    }
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(dishName, maxLines: 3),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (imageWidget != null) ...[
              imageWidget,
              const SizedBox(height: 12),
            ],
            if (desc.isNotEmpty) ...[
              const Text('Description', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(desc, style: TextStyle(height: 1.35, color: Colors.grey.shade800)),
              const SizedBox(height: 12),
            ],
            const Text('Allergens', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (list.isEmpty)
              Text(
                'No allergens listed for this dish.',
                style: TextStyle(color: Colors.grey.shade700),
              )
            else
              ...list.map(
                (a) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(a)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

/// Dialog listing allergens for a dish (Order Now / Inquire Catering menu).
Future<void> showDishAllergensDialog(
  BuildContext context, {
  required String dishName,
  required List<String> allergens,
}) {
  final list = allergens.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(dishName),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Allergens', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (list.isEmpty)
              Text(
                'No allergens listed for this dish.',
                style: TextStyle(color: Colors.grey.shade700),
              )
            else
              ...list.map(
                (a) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(a)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}
