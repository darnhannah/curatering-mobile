/// Venue reference photos stored on event [theme_design] for seating floor backgrounds.
List<String> venueReferencePhotosFromThemeDesign(Map<String, dynamic> themeDesign) {
  final out = <String>[];
  void add(dynamic raw) {
    final s = '$raw'.trim();
    if (s.isEmpty) return;
    if (!out.contains(s)) out.add(s);
  }

  add(themeDesign['venuePhotoBase64']);
  final refs = themeDesign['reference_images'];
  if (refs is List) {
    for (final r in refs) {
      add(r);
    }
  }
  final photos = themeDesign['venuePhotos'];
  if (photos is List) {
    for (final r in photos) {
      add(r);
    }
  }
  return out;
}
