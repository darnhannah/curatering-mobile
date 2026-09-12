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

const int _kMaxPersistedVenueB64Chars = 200000;

List<String> _slimVenuePhotoList(dynamic raw, {int maxItems = 2}) {
  if (raw is! List) return const [];
  return raw
      .map((e) => '$e'.trim())
      .where((e) => e.isNotEmpty && e.length <= _kMaxPersistedVenueB64Chars)
      .take(maxItems)
      .toList();
}

/// Drop multi‑MB venue blobs from create/submit payloads (keep URLs + small refs).
Map<String, dynamic> slimThemeDesignForPersist(Map<String, dynamic>? themeDesign) {
  if (themeDesign == null || themeDesign.isEmpty) return {};
  final out = Map<String, dynamic>.from(themeDesign);
  for (final key in const [
    'venuePhotoBase64',
    'venue_photo_base64',
    'picksBase64',
    'picks_base64',
    'generatedImageBase64',
    'generated_image_base64',
  ]) {
    final v = out[key];
    if (v is String && v.length > _kMaxPersistedVenueB64Chars) {
      out.remove(key);
    }
  }
  final photos = _slimVenuePhotoList(out['venuePhotos']);
  if (photos.isEmpty) {
    out.remove('venuePhotos');
  } else {
    out['venuePhotos'] = photos;
    out['venuePhotoBase64'] = photos.first;
  }
  final refs = _slimVenuePhotoList(out['reference_images']);
  if (refs.isEmpty) {
    out.remove('reference_images');
  } else {
    out['reference_images'] = refs;
  }
  final prev = out['previousGeneratedImageUrls'];
  if (prev is List) {
    out['previousGeneratedImageUrls'] = prev
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .take(8)
        .toList();
  }
  return out;
}
