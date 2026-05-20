import 'dart:convert';

import 'package:flutter/material.dart';

import '../features/seating/seating_layout_export.dart';
import '../features/seating/seating_plan.dart';
import '../features/seating/seating_plan_canvas.dart';
import '../utils/allergen_ui.dart';
import '../utils/order_type_utils.dart';
import '../utils/theme_design_venue_refs.dart';

Future<void> showSeatingLayoutFullscreen(
  BuildContext context, {
  required SeatingPlanData plan,
  List<String> venueReferencePhotosBase64 = const [],
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Seating layout', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SeatingPlanInteractive(
                plan: plan,
                editable: false,
                venueReferencePhotosBase64: venueReferencePhotosBase64,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Theme design preview + actions aligned with customer My Inquiries / Inquire Catering.
Widget buildManagerThemeDesignBlock({
  required Map<String, dynamic> themeDesign,
  required VoidCallback? onOpenEditor,
  required String openEditorLabel,
  bool showCostFields = false,
  TextEditingController? noteController,
  TextEditingController? costController,
  bool readOnlyCostFields = false,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (hasEventThemeDesign(themeDesign)) ...[
        Text(
          eventDesignSourceLabel(themeDesign),
          style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
        ),
        const SizedBox(height: 8),
      ],
      managerThemeDesignImagePreview(themeDesign),
      const SizedBox(height: 8),
      if (onOpenEditor != null)
        FilledButton.icon(
          onPressed: onOpenEditor,
          icon: const Icon(Icons.auto_awesome),
          label: Text(openEditorLabel),
        ),
      if (showCostFields && noteController != null && costController != null) ...[
        const SizedBox(height: 10),
        TextField(
          controller: noteController,
          readOnly: readOnlyCostFields,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Theme notes'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: costController,
          keyboardType: TextInputType.number,
          readOnly: readOnlyCostFields,
          decoration: const InputDecoration(labelText: 'Theme design cost'),
        ),
      ],
    ],
  );
}

/// Seating preview canvas + open editor or export-only actions.
Widget buildManagerSeatingLayoutBlock({
  required BuildContext context,
  required Map<String, dynamic> seatingPlanJson,
  required String helperText,
  required String buttonLabel,
  VoidCallback? onOpenEditor,
  bool exportOnly = false,
  String eventTitle = '',
  String transactionNo = '',
  String eventDateTime = '',
  String venueAddress = '',
  Map<String, dynamic> themeDesign = const {},
}) {
  final plan = SeatingPlanData.fromJson(seatingPlanJson);
  final hasPlan = !plan.isEffectivelyEmpty;
  final venueRefs = venueReferencePhotosFromThemeDesign(themeDesign);

  Future<void> previewPdf() => previewSeatingLayoutPdf(
        context: context,
        plan: plan,
        eventTitle: eventTitle,
        transactionNo: transactionNo,
        eventDateTime: eventDateTime,
        venueAddress: venueAddress,
      );

  Future<void> downloadImage() => saveSeatingLayoutImageToGallery(context: context, plan: plan);

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        helperText,
        style: TextStyle(color: Colors.grey.shade700, fontSize: 13, height: 1.35),
      ),
      const SizedBox(height: 10),
      if (venueRefs.isNotEmpty) ...[
        Text(
          'Venue reference photos (from event theme design)',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey.shade800),
        ),
        const SizedBox(height: 6),
        Text(
          exportOnly
              ? 'These photos were uploaded with the customer inquiry. Open the editor to set one as the floor background.'
              : 'In the seating editor, tap a photo below the tools to use it as the floor background.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.3),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: venueRefs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                base64Decode(venueRefs[i]),
                width: 72,
                height: 72,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
      if (hasPlan) ...[
        SizedBox(
          height: 220,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Material(
              color: Colors.grey.shade50,
              child: InkWell(
                onTap: () => showSeatingLayoutFullscreen(context, plan: plan, venueReferencePhotosBase64: venueRefs),
                child: FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 520,
                    height: 320,
                    child: SeatingPlanInteractive(
                      plan: plan,
                      editable: false,
                      venueReferencePhotosBase64: venueRefs,
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Tap the layout to view full screen.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 8),
      ] else
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'No seating layout saved yet.',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!exportOnly && onOpenEditor != null)
            OutlinedButton.icon(
              onPressed: onOpenEditor,
              icon: const Icon(Icons.table_restaurant),
              label: Text(buttonLabel),
            ),
          if (exportOnly && onOpenEditor != null)
            OutlinedButton.icon(
              onPressed: onOpenEditor,
              icon: const Icon(Icons.visibility_outlined),
              label: Text(buttonLabel),
            ),
          if (hasPlan) ...[
            OutlinedButton.icon(
              onPressed: () => previewPdf(),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Preview PDF'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await downloadImage();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Image saved to your gallery.')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
                    );
                  }
                }
              },
              icon: const Icon(Icons.image_outlined),
              label: const Text('Download image'),
            ),
          ],
        ],
      ),
    ],
  );
}
