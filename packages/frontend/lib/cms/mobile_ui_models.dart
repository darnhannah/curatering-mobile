/// Mobile app layout CMS models (published inside website_content.mobileUi).

const kMobileUiScreenIds = <String>[
  'guest_landing',
  'customer_dashboard',
  'restaurant_menu',
  'inquire_packages',
  'inquire_form_chrome',
  'track_orders',
  'my_orders',
  'my_inquiries',
  'settings',
  'auth_banner',
  'checkout_banner',
  'payment_banner',
];

const kMobileUiScreenLabels = <String, String>{
  'guest_landing': 'Guest landing',
  'customer_dashboard': 'Customer dashboard',
  'restaurant_menu': 'Restaurant menu',
  'inquire_packages': 'Inquire · packages',
  'inquire_form_chrome': 'Inquire · form chrome',
  'track_orders': 'Track orders',
  'my_orders': 'My orders',
  'my_inquiries': 'My inquiries',
  'settings': 'Settings',
  'auth_banner': 'Auth banner',
  'checkout_banner': 'Checkout banner',
  'payment_banner': 'Payment banner',
};

const kMobileUiBlockTypes = <String>[
  'hero',
  'banner_notice',
  'heading',
  'rich_text',
  'image',
  'cta',
  'tile_grid',
  'nav_tabs',
  'package_cards',
  'spacer',
  'divider',
  'native_slot',
];

const kMobileUiRoutes = <String>[
  'menu',
  'inquire',
  'track',
  'login',
  'tray',
  'orders',
  'inquiries',
  'settings',
  'url',
];

class MobileUiBrand {
  MobileUiBrand({
    this.primary = '#FFC233',
    this.accent = '#EE4B3C',
    this.logoMediaId,
  });

  String primary;
  String accent;
  String? logoMediaId;

  Map<String, dynamic> toJson() => {
        'primary': primary,
        'accent': accent,
        if (logoMediaId != null && logoMediaId!.isNotEmpty) 'logoMediaId': logoMediaId,
      };

  factory MobileUiBrand.fromJson(Map<String, dynamic>? m) {
    if (m == null) return MobileUiBrand();
    return MobileUiBrand(
      primary: (m['primary'] ?? '#FFC233').toString(),
      accent: (m['accent'] ?? '#EE4B3C').toString(),
      logoMediaId: (m['logoMediaId'] ?? m['logo_media_id'])?.toString(),
    );
  }
}

class MobileUiTile {
  MobileUiTile({
    required this.id,
    this.title = '',
    this.subtitle = '',
    this.route = 'menu',
    this.url = '',
  });

  final String id;
  String title;
  String subtitle;
  String route;
  String url;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'route': route,
        if (url.isNotEmpty) 'url': url,
      };

  factory MobileUiTile.fromJson(Map<String, dynamic> m) => MobileUiTile(
        id: (m['id'] ?? 'tile_${DateTime.now().microsecondsSinceEpoch}').toString(),
        title: (m['title'] ?? '').toString(),
        subtitle: (m['subtitle'] ?? '').toString(),
        route: (m['route'] ?? 'menu').toString(),
        url: (m['url'] ?? '').toString(),
      );
}

class MobileUiPackageCard {
  MobileUiPackageCard({
    required this.id,
    this.title = '',
    this.lines = const [],
  });

  final String id;
  String title;
  List<String> lines;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'lines': lines,
      };

  factory MobileUiPackageCard.fromJson(Map<String, dynamic> m) {
    final raw = m['lines'];
    return MobileUiPackageCard(
      id: (m['id'] ?? 'pkg_${DateTime.now().microsecondsSinceEpoch}').toString(),
      title: (m['title'] ?? '').toString(),
      lines: raw is List ? raw.map((e) => e.toString()).toList() : const [],
    );
  }
}

class MobileUiBlock {
  MobileUiBlock({
    required this.id,
    required this.type,
    this.title = '',
    this.body = '',
    this.mediaId,
    this.ctaLabel = '',
    this.route = 'menu',
    this.url = '',
    this.slot = '',
    this.height = 16,
    List<MobileUiTile>? tiles,
    List<MobileUiPackageCard>? packages,
  })  : tiles = tiles ?? <MobileUiTile>[],
        packages = packages ?? <MobileUiPackageCard>[];

  final String id;
  String type;
  String title;
  String body;
  String? mediaId;
  String ctaLabel;
  String route;
  String url;
  String slot;
  double height;
  final List<MobileUiTile> tiles;
  final List<MobileUiPackageCard> packages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'body': body,
        if (mediaId != null && mediaId!.isNotEmpty) 'mediaId': mediaId,
        'ctaLabel': ctaLabel,
        'route': route,
        if (url.isNotEmpty) 'url': url,
        if (slot.isNotEmpty) 'slot': slot,
        'height': height,
        if (tiles.isNotEmpty) 'tiles': tiles.map((e) => e.toJson()).toList(),
        if (packages.isNotEmpty) 'packages': packages.map((e) => e.toJson()).toList(),
      };

  factory MobileUiBlock.fromJson(Map<String, dynamic> m) {
    final tilesRaw = m['tiles'];
    final pkgsRaw = m['packages'];
    return MobileUiBlock(
      id: (m['id'] ?? 'blk_${DateTime.now().microsecondsSinceEpoch}').toString(),
      type: (m['type'] ?? 'heading').toString(),
      title: (m['title'] ?? m['heading'] ?? '').toString(),
      body: (m['body'] ?? m['bodyHtml'] ?? '').toString(),
      mediaId: (m['mediaId'] ?? m['media_id'])?.toString(),
      ctaLabel: (m['ctaLabel'] ?? '').toString(),
      route: (m['route'] ?? 'menu').toString(),
      url: (m['url'] ?? m['ctaUrl'] ?? '').toString(),
      slot: (m['slot'] ?? '').toString(),
      height: (m['height'] is num) ? (m['height'] as num).toDouble() : 16,
      tiles: tilesRaw is List
          ? tilesRaw
              .whereType<Map>()
              .map((e) => MobileUiTile.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : null,
      packages: pkgsRaw is List
          ? pkgsRaw
              .whereType<Map>()
              .map((e) => MobileUiPackageCard.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : null,
    );
  }

  static MobileUiBlock create(String type) {
    final id = 'blk_${DateTime.now().microsecondsSinceEpoch}';
    switch (type) {
      case 'hero':
        return MobileUiBlock(id: id, type: type, title: 'Welcome', body: 'Choose how you would like to continue.');
      case 'banner_notice':
        return MobileUiBlock(
          id: id,
          type: type,
          body: 'Online orders are available within 5 km of our restaurant in Taguig City.',
        );
      case 'heading':
        return MobileUiBlock(id: id, type: type, title: 'New heading');
      case 'rich_text':
        return MobileUiBlock(id: id, type: type, body: 'New content');
      case 'cta':
        return MobileUiBlock(id: id, type: type, ctaLabel: 'Order Now', route: 'menu');
      case 'tile_grid':
        return MobileUiBlock(
          id: id,
          type: type,
          tiles: [
            MobileUiTile(id: 't1', title: 'Order Now', subtitle: 'Restaurant menu & delivery', route: 'menu'),
            MobileUiTile(id: 't2', title: 'Inquire Catering', subtitle: 'Events & catering quotes', route: 'inquire'),
          ],
        );
      case 'nav_tabs':
        return MobileUiBlock(
          id: id,
          type: type,
          tiles: [
            MobileUiTile(id: 'n1', title: 'Order Now', route: 'menu'),
            MobileUiTile(id: 'n2', title: 'Inquire', route: 'inquire'),
            MobileUiTile(id: 'n3', title: 'Track', route: 'track'),
            MobileUiTile(id: 'n4', title: 'Log In', route: 'login'),
          ],
        );
      case 'package_cards':
        return MobileUiBlock(
          id: id,
          type: type,
          packages: [
            MobileUiPackageCard(
              id: 'p1',
              title: 'Catering',
              lines: ['Php 500 per pax', 'Setup: staff and buffet service'],
            ),
            MobileUiPackageCard(
              id: 'p2',
              title: 'Catering with Event Styling',
              lines: [
                'Php 500 per pax',
                'Minimal Design: tables and chairs with linen and centerpiece',
                'Setup: staff and buffet service',
              ],
            ),
          ],
        );
      case 'native_slot':
        return MobileUiBlock(id: id, type: type, slot: 'body', title: 'Native content');
      case 'spacer':
        return MobileUiBlock(id: id, type: type, height: 16);
      case 'divider':
        return MobileUiBlock(id: id, type: type);
      case 'image':
        return MobileUiBlock(id: id, type: type, title: 'Image');
      default:
        return MobileUiBlock(id: id, type: type);
    }
  }
}

class MobileUiScreen {
  MobileUiScreen({required this.id, List<MobileUiBlock>? blocks})
      : blocks = blocks ?? <MobileUiBlock>[];

  final String id;
  final List<MobileUiBlock> blocks;

  Map<String, dynamic> toJson() => {
        'blocks': blocks.map((e) => e.toJson()).toList(),
      };

  factory MobileUiScreen.fromJson(String id, Map<String, dynamic>? m) {
    final blocks = <MobileUiBlock>[];
    final raw = m?['blocks'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) blocks.add(MobileUiBlock.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return MobileUiScreen(id: id, blocks: blocks);
  }
}

class MobileUiConfig {
  MobileUiConfig({
    this.version = 1,
    MobileUiBrand? brand,
    Map<String, MobileUiScreen>? screens,
  })  : brand = brand ?? MobileUiBrand(),
        screens = screens ?? {for (final id in kMobileUiScreenIds) id: MobileUiScreen(id: id)};

  int version;
  MobileUiBrand brand;
  final Map<String, MobileUiScreen> screens;

  bool get hasAnyBlocks => screens.values.any((s) => s.blocks.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'version': version,
        'brand': brand.toJson(),
        'screens': {
          for (final e in screens.entries) e.key: e.value.toJson(),
        },
      };

  factory MobileUiConfig.fromJson(dynamic raw) {
    if (raw is! Map) return MobileUiConfig();
    final m = Map<String, dynamic>.from(raw);
    final screensRaw = m['screens'];
    final screens = <String, MobileUiScreen>{};
    for (final id in kMobileUiScreenIds) {
      Map<String, dynamic>? screenMap;
      if (screensRaw is Map && screensRaw[id] is Map) {
        screenMap = Map<String, dynamic>.from(screensRaw[id] as Map);
      }
      screens[id] = MobileUiScreen.fromJson(id, screenMap);
    }
    final cfg = MobileUiConfig(
      version: m['version'] is num ? (m['version'] as num).toInt() : 1,
      brand: MobileUiBrand.fromJson(
        m['brand'] is Map ? Map<String, dynamic>.from(m['brand'] as Map) : null,
      ),
      screens: screens,
    );
    return cfg;
  }

  MobileUiScreen screen(String id) =>
      screens[id] ?? MobileUiScreen(id: id);
}

MobileUiConfig defaultMobileUiConfig() {
  return MobileUiConfig(
    screens: {
      'guest_landing': MobileUiScreen(
        id: 'guest_landing',
        blocks: [
          MobileUiBlock(id: 'gl_hero', type: 'hero', title: "Macrina's Kitchen", body: 'Choose how you would like to continue.'),
          MobileUiBlock.create('tile_grid'),
          MobileUiBlock.create('nav_tabs'),
        ],
      ),
      'customer_dashboard': MobileUiScreen(
        id: 'customer_dashboard',
        blocks: [
          MobileUiBlock(id: 'cd_hero', type: 'hero', title: 'What would you like to do?', body: ''),
          MobileUiBlock(
            id: 'cd_tiles',
            type: 'tile_grid',
            tiles: [
              MobileUiTile(id: 'a', title: "Macrina's Kitchen", subtitle: 'Order Now', route: 'menu'),
              MobileUiTile(id: 'b', title: "Macrina's Catering", subtitle: 'Inquire now', route: 'inquire'),
              MobileUiTile(id: 'c', title: 'Your Tray', subtitle: '', route: 'tray'),
              MobileUiTile(id: 'd', title: 'My Orders', subtitle: '', route: 'orders'),
              MobileUiTile(id: 'e', title: 'My Catering Inquiries', subtitle: '', route: 'inquiries'),
              MobileUiTile(id: 'f', title: 'My Profile', subtitle: '', route: 'settings'),
            ],
          ),
        ],
      ),
      'restaurant_menu': MobileUiScreen(
        id: 'restaurant_menu',
        blocks: [
          MobileUiBlock(
            id: 'rm_notice',
            type: 'banner_notice',
            body: 'Online orders are available within 5 km of our restaurant in Taguig City.',
          ),
          MobileUiBlock(id: 'rm_slot', type: 'native_slot', slot: 'menu_body', title: 'Menu'),
        ],
      ),
      'inquire_packages': MobileUiScreen(
        id: 'inquire_packages',
        blocks: [
          MobileUiBlock(id: 'iq_h', type: 'heading', title: 'Review our catering packages'),
          MobileUiBlock.create('package_cards'),
        ],
      ),
      'inquire_form_chrome': MobileUiScreen(
        id: 'inquire_form_chrome',
        blocks: [
          MobileUiBlock(
            id: 'iqc_notice',
            type: 'banner_notice',
            body: 'Our catering service is available in NCR, Bulacan, Cavite, Rizal, and Laguna ONLY.',
          ),
          MobileUiBlock(id: 'iqc_slot', type: 'native_slot', slot: 'inquire_wizard', title: 'Inquiry form'),
        ],
      ),
      'track_orders': MobileUiScreen(
        id: 'track_orders',
        blocks: [
          MobileUiBlock(id: 'tr_h', type: 'heading', title: 'Track My Order'),
          MobileUiBlock(id: 'tr_slot', type: 'native_slot', slot: 'track_body', title: 'Track form'),
        ],
      ),
      'my_orders': MobileUiScreen(
        id: 'my_orders',
        blocks: [
          MobileUiBlock(id: 'mo_h', type: 'heading', title: 'My Orders'),
          MobileUiBlock(id: 'mo_slot', type: 'native_slot', slot: 'orders_body', title: 'Orders list'),
        ],
      ),
      'my_inquiries': MobileUiScreen(
        id: 'my_inquiries',
        blocks: [
          MobileUiBlock(
            id: 'mi_notice',
            type: 'banner_notice',
            body: 'Our catering service is available in NCR, Bulacan, Cavite, Rizal, and Laguna ONLY.',
          ),
          MobileUiBlock(id: 'mi_slot', type: 'native_slot', slot: 'inquiries_body', title: 'Inquiries list'),
        ],
      ),
      'settings': MobileUiScreen(
        id: 'settings',
        blocks: [
          MobileUiBlock(id: 'st_h', type: 'heading', title: 'Settings'),
          MobileUiBlock(id: 'st_slot', type: 'native_slot', slot: 'settings_body', title: 'Settings'),
        ],
      ),
      'auth_banner': MobileUiScreen(
        id: 'auth_banner',
        blocks: [
          MobileUiBlock(id: 'au_b', type: 'banner_notice', body: "Welcome to Macrina's Kitchen and Catering."),
        ],
      ),
      'checkout_banner': MobileUiScreen(
        id: 'checkout_banner',
        blocks: [
          MobileUiBlock(
            id: 'ch_b',
            type: 'banner_notice',
            body: "Macrina's Kitchen is only open from 8:00 am to 7:00 pm",
          ),
        ],
      ),
      'payment_banner': MobileUiScreen(
        id: 'payment_banner',
        blocks: [
          MobileUiBlock(
            id: 'pay_b',
            type: 'banner_notice',
            body:
                'After you submit payment proof, watch your email or track your order with your entered email address through the app for payment confirmation and order updates!',
          ),
        ],
      ),
    },
  );
}
