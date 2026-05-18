import 'package:flutter/material.dart';

import '../features/seating/seating_layout_export.dart';
import '../features/seating/seating_plan.dart';
import '../features/seating/seating_plan_canvas.dart';
import '../utils/allergen_ui.dart';
import '../utils/order_type_utils.dart';

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
}) {
  final plan = SeatingPlanData.fromJson(seatingPlanJson);
  final hasPlan = !plan.isEffectivelyEmpty;

  Future<void> previewPdf() => previewSeatingLayoutPdf(
        context: context,
        plan: plan,
        eventTitle: eventTitle,
        transactionNo: transactionNo,
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
      if (hasPlan) ...[
        SizedBox(
          height: 220,
          child: SeatingPlanInteractive(
            plan: plan,
            editable: false,
          ),
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
