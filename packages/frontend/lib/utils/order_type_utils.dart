// Display labels and checks for catering vs catering + event orders.
// From handoff `lib/utils/order_type_utils.dart` + MOBILE_COPY_PASTE.md §7 seating rules.

String orderTypeDisplayLabel(String orderType, {String eventTitle = ''}) {
  final t = orderType.trim().toLowerCase();
  if (t == 'catering') return 'Catering only';
  if (t == 'catering_event' || t == 'event') return 'Catering + Event';
  if (eventTitle.trim().isNotEmpty) return 'Catering + Event';
  return 'Catering only';
}

bool isCateringPlusEventOrderType(String orderType, {String eventTitle = ''}) {
  final t = orderType.trim().toLowerCase();
  if (t == 'catering_event' || t == 'event') return true;
  if (t == 'catering') return false;
  return eventTitle.trim().isNotEmpty;
}

/// Show seating section on manager catering+event orders in these pipeline stages.
bool canShowSeatingLayout(String status) {
  final s = status.trim().toLowerCase();
  return s == 'online_inquiries' ||
      s == 'new_event' ||
      s == 'for_down_payment' ||
      s == 'for_ongoing' ||
      s == 'for_full_payment';
}

/// Edit seating in draft / active pipeline stages (not completed or cancelled).
bool canEditSeatingLayout(String status) {
  final s = status.trim().toLowerCase();
  return s == 'online_inquiries' ||
      s == 'new_event' ||
      s == 'for_down_payment' ||
      s == 'for_ongoing' ||
      s == 'for_full_payment' ||
      s == 'for_processing';
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
