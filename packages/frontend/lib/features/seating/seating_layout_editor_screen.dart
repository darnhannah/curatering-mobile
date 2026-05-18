import 'package:flutter/material.dart';

import '../event_design/events_feature_api.dart';
import 'seating_layout_export.dart';
import 'seating_plan.dart';
import 'seating_plan_canvas.dart';

/// Full-screen seating layout editor (tables, chairs, venue shape / floor image).
class SeatingLayoutEditorScreen extends StatefulWidget {
  const SeatingLayoutEditorScreen({
    super.key,
    required this.apiBase,
    required this.userEmail,
    this.orderId = '',
    required this.orderKind,
    this.initialPlan,
    this.cashierEmail,
    this.cashierPassword,
    this.readOnly = false,
    this.draftOnly = false,
    this.eventTitle = '',
    this.transactionNo = '',
  });

  final String apiBase;
  final String userEmail;
  final String orderId;
  final String orderKind;
  final SeatingPlanData? initialPlan;
  final String? cashierEmail;
  final String? cashierPassword;
  final bool readOnly;
  /// When true, layout is kept locally (e.g. inquiry submit) — no API load/save.
  final bool draftOnly;
  final String eventTitle;
  final String transactionNo;

  @override
  State<SeatingLayoutEditorScreen> createState() => _SeatingLayoutEditorScreenState();
}

class _SeatingLayoutEditorScreenState extends State<SeatingLayoutEditorScreen> {
  late SeatingPlanData _plan;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _plan = widget.initialPlan ?? SeatingPlanData.empty;
    if (widget.draftOnly || widget.initialPlan != null || widget.orderId.trim().isEmpty) {
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.draftOnly || widget.orderId.trim().isEmpty) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      final plan = await api.getSeatingPlan(
        orderId: widget.orderId,
        orderKind: widget.orderKind,
        userEmail: widget.userEmail,
        cashierEmail: widget.cashierEmail,
        cashierPassword: widget.cashierPassword,
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
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

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Unsaved seating layout changes will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save() async {
    if (widget.readOnly) return;
    if (widget.draftOnly || widget.orderId.trim().isEmpty) {
      if (!mounted) return;
      Navigator.pop(context, _plan);
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save seating layout?'),
        content: const Text('This will update the seating plan for this event order.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      final api = EventsFeatureApi(apiBase: widget.apiBase);
      await api.saveSeatingPlan(
        orderId: widget.orderId,
        orderKind: widget.orderKind,
        plan: _plan,
        userEmail: widget.userEmail,
        cashierEmail: widget.cashierEmail,
        cashierPassword: widget.cashierPassword,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seating layout saved.')),
      );
      await previewSeatingLayoutPdf(
        plan: _plan,
        eventTitle: widget.eventTitle,
        transactionNo: widget.transactionNo,
      );
      if (!mounted) return;
      Navigator.pop(context, _plan);
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (widget.readOnly || await _confirmDiscard()) {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.readOnly ? 'Seating layout' : 'Edit seating layout'),
          actions: [
            if (widget.readOnly && !_plan.isEffectivelyEmpty) ...[
              IconButton(
                tooltip: 'Preview PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: () => previewSeatingLayoutPdf(
                  plan: _plan,
                  eventTitle: widget.eventTitle,
                  transactionNo: widget.transactionNo,
                ),
              ),
              IconButton(
                tooltip: 'Download image',
                icon: const Icon(Icons.image_outlined),
                onPressed: () async {
                  try {
                    await saveSeatingLayoutImageToGallery(context: context, plan: _plan);
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
              ),
            ],
            if (_saving)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, textAlign: TextAlign.center))
                : Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SeatingPlanInteractive(
                            plan: _plan,
                            editable: !widget.readOnly,
                            onChanged: widget.readOnly ? null : (next) => setState(() => _plan = next),
                          ),
                        ),
                      ),
                      if (!widget.readOnly)
                        SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                            child: Row(
                              children: [
                                TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () async {
                                          if (await _confirmDiscard()) {
                                            if (context.mounted) Navigator.pop(context);
                                          }
                                        },
                                  child: const Text('Cancel'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  onPressed: _saving ? null : _save,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFE8B923),
                                    foregroundColor: Colors.black87,
                                  ),
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}
