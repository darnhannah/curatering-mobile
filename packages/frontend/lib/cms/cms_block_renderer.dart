import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'mobile_ui_config_store.dart';
import 'mobile_ui_models.dart';

typedef CmsRouteHandler = void Function(String route, {String url});

/// Renders CMS blocks for a screen; injects [slots] where `native_slot` appears.
class CmsScreenBody extends StatelessWidget {
  const CmsScreenBody({
    super.key,
    required this.screenId,
    this.slots = const {},
    this.onRoute,
    this.padding = const EdgeInsets.all(12),
    this.fallback,
  });

  final String screenId;
  final Map<String, Widget> slots;
  final CmsRouteHandler? onRoute;
  final EdgeInsetsGeometry padding;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final store = MobileUiConfigStore.instance;
    final blocks = store.blocksFor(screenId);
    if (blocks.isEmpty) {
      return fallback ?? const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final brand = store.config.brand;
        return ListView(
          padding: padding,
          children: [
            for (final b in store.blocksFor(screenId))
              CmsBlockRenderer(
                block: b,
                brand: brand,
                slots: slots,
                onRoute: onRoute,
              ),
          ],
        );
      },
    );
  }
}

/// Banner-only strip for auth/checkout/payment (non-scrolling column children).
class CmsBannerStrip extends StatelessWidget {
  const CmsBannerStrip({super.key, required this.screenId});

  final String screenId;

  @override
  Widget build(BuildContext context) {
    final store = MobileUiConfigStore.instance;
    final blocks = store.blocksFor(screenId).where((b) => b.type == 'banner_notice' || b.type == 'heading' || b.type == 'hero');
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          CmsBlockRenderer(
            block: b,
            brand: store.config.brand,
            slots: const {},
          ),
      ],
    );
  }
}

class CmsBlockRenderer extends StatelessWidget {
  const CmsBlockRenderer({
    super.key,
    required this.block,
    required this.brand,
    this.slots = const {},
    this.onRoute,
  });

  final MobileUiBlock block;
  final MobileUiBrand brand;
  final Map<String, Widget> slots;
  final CmsRouteHandler? onRoute;

  Color _primary(BuildContext context) {
    final parsed = _parseHex(brand.primary);
    return parsed ?? Theme.of(context).colorScheme.primary;
  }

  static Color? _parseHex(String hex) {
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    return Color(0xFF000000 | v);
  }

  void _handleRoute(String route, {String url = ''}) {
    if (onRoute != null) {
      onRoute!(route, url: url);
      return;
    }
    if (route == 'url' && url.trim().isNotEmpty) {
      final uri = Uri.tryParse(url.trim());
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (block.type) {
      case 'hero':
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (block.mediaId != null && block.mediaId!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      MobileUiConfigStore.instance.mediaPublicUrl(block.mediaId!),
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              if (block.title.isNotEmpty)
                Text(
                  block.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: _primary(context),
                  ),
                ),
              if (block.body.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(block.body, textAlign: TextAlign.center, style: const TextStyle(height: 1.35)),
              ],
            ],
          ),
        );
      case 'banner_notice':
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3CD),
            border: Border.all(color: const Color(0xFFFFC107)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(block.body.isNotEmpty ? block.body : block.title, style: const TextStyle(height: 1.35)),
        );
      case 'heading':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(block.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        );
      case 'rich_text':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(block.body.replaceAll(RegExp(r'<[^>]*>'), ''), style: const TextStyle(height: 1.4)),
        );
      case 'image':
        if (block.mediaId == null || block.mediaId!.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              MobileUiConfigStore.instance.mediaPublicUrl(block.mediaId!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      case 'cta':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _primary(context)),
            onPressed: () => _handleRoute(block.route, url: block.url),
            child: Text(block.ctaLabel.isEmpty ? 'Continue' : block.ctaLabel),
          ),
        );
      case 'tile_grid':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final t in block.tiles)
                SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 44) / 2,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _handleRoute(t.route, url: t.url),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                            if (t.subtitle.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(t.subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      case 'nav_tabs':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              for (final t in block.tiles)
                Expanded(
                  child: TextButton(
                    onPressed: () => _handleRoute(t.route, url: t.url),
                    child: Text(t.title, textAlign: TextAlign.center, maxLines: 2),
                  ),
                ),
            ],
          ),
        );
      case 'package_cards':
        return Column(
          children: [
            for (final p in block.packages)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      for (final line in p.lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(line),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      case 'native_slot':
        final key = block.slot.trim().isEmpty ? 'body' : block.slot.trim();
        final child = slots[key];
        if (child == null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Missing native slot: $key', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          );
        }
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
      case 'spacer':
        return SizedBox(height: block.height.clamp(0, 200));
      case 'divider':
        return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider());
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Column children for embedding CMS blocks above a native Expanded body.
List<Widget> cmsChromeBlocks({
  required String screenId,
  required Map<String, Widget> slots,
  CmsRouteHandler? onRoute,
  EdgeInsetsGeometry chromePadding = const EdgeInsets.fromLTRB(12, 8, 12, 0),
}) {
  final store = MobileUiConfigStore.instance;
  final blocks = store.blocksFor(screenId);
  if (blocks.isEmpty) return const [];
  return [
    for (final b in blocks)
      if (b.type == 'native_slot')
        ...(slots.containsKey(b.slot.trim().isEmpty ? 'body' : b.slot.trim())
            ? [slots[b.slot.trim().isEmpty ? 'body' : b.slot.trim()]!]
            : <Widget>[])
      else
        Padding(
          padding: chromePadding,
          child: CmsBlockRenderer(block: b, brand: store.config.brand, slots: slots, onRoute: onRoute),
        ),
  ];
}

/// Full-height CMS shell: chrome blocks + native slots (pass [Expanded] widgets in [slots]).
class CmsFlexShell extends StatelessWidget {
  const CmsFlexShell({
    super.key,
    required this.screenId,
    required this.slots,
    this.onRoute,
    this.fallback,
  });

  final String screenId;
  final Map<String, Widget> slots;
  final CmsRouteHandler? onRoute;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final store = MobileUiConfigStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.screenHasBlocks(screenId)) {
          return fallback ?? const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cmsChromeBlocks(screenId: screenId, slots: slots, onRoute: onRoute),
        );
      },
    );
  }
}
