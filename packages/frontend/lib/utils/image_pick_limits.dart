import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Max attachment size for customer/manager image uploads (event theme, seating floor, etc.).
const int kMaxImageAttachmentBytes = 25 * 1024 * 1024;

String imageAttachmentTooLargeMessage(int maxMb) =>
    'Each image must be $maxMb MB or smaller.';

/// Pick one or more gallery images; skips files over [maxBytes]. Returns base64 strings.
Future<List<String>> pickImagesBase64({
  required BuildContext context,
  bool allowMultiple = true,
  int maxBytes = kMaxImageAttachmentBytes,
  int imageQuality = 88,
  int? maxWidth,
}) async {
  final picker = ImagePicker();
  final List<XFile> files;
  if (allowMultiple) {
    final multi = await picker.pickMultiImage(
      imageQuality: imageQuality,
      maxWidth: maxWidth?.toDouble(),
    );
    if (multi.isEmpty) return [];
    files = multi;
  } else {
    final one = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: imageQuality,
      maxWidth: maxWidth?.toDouble(),
    );
    if (one == null) return [];
    files = [one];
  }

  final out = <String>[];
  var skipped = 0;
  for (final f in files) {
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) {
      skipped++;
      continue;
    }
    out.add(base64Encode(bytes));
  }
  if (skipped > 0 && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(imageAttachmentTooLargeMessage(maxBytes ~/ (1024 * 1024)))),
    );
  }
  return out;
}
