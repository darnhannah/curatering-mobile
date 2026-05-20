// Display labels and checks for catering vs catering + event orders.
// From handoff `lib/utils/order_type_utils.dart` + MOBILE_COPY_PASTE.md §7 seating rules.

String orderTypeDisplayLabel(String orderType, {String eventTitle = ''}) {
  final t = orderType.trim().toLowerCase();
  if (t == 'catering') return 'Catering only';
  if (t == 'catering_event' || t == 'event') return 'Catering with Event Styling';
  if (eventTitle.trim().isNotEmpty) return 'Catering with Event Styling';
  return 'Catering only';
}

bool isCateringPlusEventOrderType(String orderType, {String eventTitle = ''}) {
  final t = orderType.trim().toLowerCase();
  if (t == 'catering_event' || t == 'event') return true;
  if (t == 'catering') return false;
  return eventTitle.trim().isNotEmpty;
}

/// Catering-only and catering + event styling orders both support seating layout.
bool orderSupportsSeatingLayout(String orderKind) {
  final k = orderKind.trim().toLowerCase();
  return k == 'catering' || k == 'event';
}

/// Show seating section for catering and catering + event styling orders in active pipeline stages.
bool canShowSeatingLayout(String status) {
  final s = status.trim().toLowerCase();
  return s == 'for_down_payment' || s == 'for_ongoing' || s == 'for_full_payment' || s == 'completed';
}

/// Edit seating layout while the order is still in processing (not completed/cancelled).
bool canEditSeatingLayout(String status) {
  final s = status.trim().toLowerCase();
  const editable = {
    'new_event',
    'online_inquiries',
    'for_down_payment',
    'for_ongoing',
    'for_full_payment',
    'for_processing',
  };
  return editable.contains(s);
}

String eventDesignSourceLabel(Map<String, dynamic> themeDesign) {
  final src = '${themeDesign['eventDesignSource'] ?? ''}'.trim().toLowerCase();
  if (src == 'customer_ai') return 'Customer theme design';
  if (src == 'macrina') return "Macrina's design team";
  return src.isEmpty ? 'Event theme' : src;
}

bool hasEventThemeDesign(Map<String, dynamic> themeDesign) {
  if (themeDesign.isEmpty) return false;
  final gen = '${themeDesign['generatedImageUrl'] ?? themeDesign['imageUrl'] ?? ''}'.trim();
  if (gen.isNotEmpty) return true;
  final venue = '${themeDesign['venuePhotoBase64'] ?? ''}'.trim();
  if (venue.isNotEmpty) return true;
  final note = '${themeDesign['note'] ?? themeDesign['customInstructions'] ?? ''}'.trim();
  if (note.isNotEmpty) return true;
  if (themeDesign['eventDesignSource'] != null) return true;
  return false;
}
