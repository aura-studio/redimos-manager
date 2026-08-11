// pixel-fidelity-v23 (CP 9.x) — the app chrome (rail / entity sidebar /
// top bar / mid bar / status bar) extracted from _HomePageState so the
// pixel-capture channel can wrap the very same widgets around its content
// screens. Extraction only: every builder moved here verbatim, parameterised
// over a ChromeState snapshot + ChromeCallbacks instead of _HomePageState
// fields. Behaviour is unchanged — HomePage still renders exactly this.
//
// The capture channel (test/pixel_capture_test.dart) pumps HomeChrome with
// fixture data + no-op callbacks, which is what puts the rail/sidebar/bars
// into the pixel-diff PNGs (they were content-only before, requirements 3.7).

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'local_ddb_panel.dart';
import 'models.dart';
import 'native.dart';
import 'ui_theme.dart';
import 'ui_tokens.dart';

/// v2.3 rail entity kind — which group the entity sidebar lists.
enum EntityKind { instance, endpoint }

/// Immutable snapshot of everything the chrome renders (the HomePage state
/// fields the former private builders read).
class ChromeState {
  const ChromeState({
    required this.entityKind,
    required this.configs,
    required this.endpoints,
    required this.statuses,
    required this.selectedConfigId,
    required this.selectedEndpointId,
    required this.hoveredCardId,
    required this.entityQuery,
    required this.tabLabels,
    required this.tabIndex,
    required this.stopAllSnapshot,
    required this.ddb,
    required this.themeMode,
    required this.lang,
  });

  final EntityKind entityKind;
  final List<RedimosConfig> configs;
  final List<DdbEndpoint> endpoints;
  final Map<String, InstanceStatus> statuses;
  final String? selectedConfigId;
  final String? selectedEndpointId;
  final String? hoveredCardId;
  final String entityQuery;
  /// MidBar labels for the CURRENT mode (instance tabs or endpoint screens).
  final List<String> tabLabels;
  /// Active MidBar index within [tabLabels].
  final int tabIndex;
  final List<String> stopAllSnapshot;
  final LocalDdbInfo? ddb;
  final ThemeMode themeMode;
  final AppLang lang;

  RedimosConfig? get selectedConfig {
    for (final c in configs) {
      if (c.id == selectedConfigId) return c;
    }
    return null;
  }

  DdbEndpoint? get selectedEndpoint {
    for (final e in endpoints) {
      if (e.id == selectedEndpointId) return e;
    }
    return null;
  }

  bool get isEndpointMode => selectedEndpointId != null;
}

/// Every interaction the chrome offers. HomePage wires real handlers; the
/// capture channel passes no-ops (it never taps the chrome).
class ChromeCallbacks {
  const ChromeCallbacks({
    required this.onEntityKind,
    required this.onSelectConfig,
    required this.onSelectEndpoint,
    required this.onHoverCard,
    required this.onQueryChanged,
    required this.onNewConfig,
    required this.onMidTab,
    required this.onStartStop,
    required this.onStopAll,
    required this.onRestoreAll,
    required this.onThemeMode,
    required this.onLang,
    required this.onDdbMutated,
  });

  final ValueChanged<EntityKind> onEntityKind;
  final void Function(RedimosConfig) onSelectConfig;
  final ValueChanged<String> onSelectEndpoint;
  final ValueChanged<String?> onHoverCard;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onNewConfig;
  final ValueChanged<int> onMidTab;
  final void Function(RedimosConfig) onStartStop;
  final VoidCallback onStopAll;
  final VoidCallback onRestoreAll;
  final ValueChanged<ThemeMode> onThemeMode;
  final ValueChanged<AppLang> onLang;
  final VoidCallback onDdbMutated;
}

/// The full chrome around the detail area: rail + entity sidebar on the left,
/// top bar / mid bar / detail / status bar in the main column. [midBarCta]
/// is the context CTA for the mid bar's end slot (HomePage builds it — it can
/// reach the content screens' GlobalKeys; the capture passes a lookalike).
class HomeChrome extends StatelessWidget {
  const HomeChrome({
    super.key,
    required this.state,
    required this.cb,
    required this.core,
    required this.child,
    this.midBarCta,
  });

  final ChromeState state;
  final ChromeCallbacks cb;
  final NativeCore core;
  final Widget child;
  final Widget? midBarCta;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _rail(),
        SizedBox(width: Dim.sidebarW, child: _entitySidebar()),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _topBar(),
            _midBar(),
            Expanded(child: child),
            _statusBar(),
          ]),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Top bar (48px): entity breadcrumb + screen name + spacer + the three
  // global buttons (stop-all / theme / language). No wordmark, no live metric
  // strip — those move to the rail logo and the status bar respectively.

  Widget _topBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final brightness = Theme.of(context).brightness;
      return Container(
        height: Dim.topBarH,
        decoration: BoxDecoration(
          color: t.panel,
          border: Border(
            bottom: BorderSide(color: t.hairline),
            // mockup .topbar: inset top white highlight (v2.3).
            top: BorderSide(color: t.highlight),
          ),
          boxShadow: Depth.elev1(brightness),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          _topBarCrumb(t),
          const Spacer(),
          _stopAllButton(t),
          const SizedBox(width: 8),
          _themeMenu(),
          const SizedBox(width: 8),
          _langMenu(),
        ]),
      );
    });
  }

  Widget _topBarCrumb(AppTokens t) {
    return Builder(builder: (context) {
      final isEp = state.isEndpointMode;
      String entity = '';
      String sub = '';
      if (isEp) {
        final e = state.selectedEndpoint;
        if (e != null) {
          entity = e.name.isEmpty ? tr('config.unnamed') : e.name;
          sub = switch (e.kind) {
            'aws' => e.region.isEmpty ? 'AWS' : 'AWS · ${e.region}',
            'local' => 'Local DynamoDB',
            _ => e.endpoint,
          };
        }
      } else {
        final c = state.selectedConfig;
        if (c != null) {
          entity = c.name.isEmpty ? tr('config.unnamed') : c.name;
          sub = ':${c.port} · ${_endpointFor(c)?.name ?? (c.endpoint.isEmpty ? 'AWS' : _hostOf(c.endpoint))}';
        }
      }
      final screenName =
          state.tabLabels[state.tabIndex.clamp(0, state.tabLabels.length - 1)];
      // Mockup pages2 topbar markup: <.screen-name> <.screen-sub mono> with
      // b.crumb-ent (--text w600) followed by the rest in text-3 — no chip,
      // no caret, no '/' separator (pixel-fidelity-v23 CP 9.x).
      // Plain Text runs instead of Text.rich: rich spans rasterise blocky in
      // the capture channel while identical plain Text renders correctly.
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Text(screenName,
            style: Ts.style(size: 13.5, weight: FontWeight.w600, color: t.text)),
        const SizedBox(width: 10),
        if (entity.isNotEmpty)
          Text(entity,
              style: Ts.style(size: 11.5, weight: FontWeight.w600, color: t.text, monoFont: true)),
        if (entity.isNotEmpty && sub.isNotEmpty)
          Text(' · $sub', style: Ts.style(size: 11.5, color: t.text3, monoFont: true)),
      ]);
    });
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Mid bar (44px): centred underline tabs + a context CTA in the end group.

  Widget _midBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final brightness = Theme.of(context).brightness;
      final labels = state.tabLabels;
      final index = state.tabIndex;
      return Container(
        height: Dim.midBarH,
        decoration: BoxDecoration(
          color: t.panel,
          // Mockup .midbar border-bottom is --border (193,203,217), a shade
          // darker than --hairline (pixel-fidelity-v23 CP 9.x round 2).
          border: Border(bottom: BorderSide(color: t.border)),
          boxShadow: Depth.elev1(brightness),
        ),
        // Mockup .midbar: padding 0 16, .mstart/.mend both flex:1 — the tab
        // row is centred across the FULL bar width, the CTA right-aligned
        // inside the end half (pixel-fidelity-v23 CP 9.x).
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Expanded(child: SizedBox.shrink()), // .mstart
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < labels.length; i++) ...[
                if (i > 0) const SizedBox(width: 4), // mockup .mtabs gap:4
                _midTab(t, labels[i], i == index, () => cb.onMidTab(i)),
              ],
            ]),
          ),
          Expanded(
            // .mend: flex:1 + justify-content:flex-end.
            child: Align(
              alignment: Alignment.centerRight,
              child: midBarCta ?? const SizedBox.shrink(),
            ),
          ),
        ]),
      );
    });
  }

  // Mockup .mtab: active tab keeps --text colour (v2.4 bumps weight to 700)
  // with ONLY the 2px underline accented; inactive = text-3.
  Widget _midTab(AppTokens t, String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: Dim.midBarH,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: active ? t.accent : Colors.transparent, width: 2)),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: Ts.style(
                size: Ts.md,
                weight: active ? FontWeight.w700 : FontWeight.normal,
                color: active ? t.text : t.text3)),
      ),
    );
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Status bar (24px): the single source of truth for connection state.
  // Left: dot + host:port + db + backend. Right: SCAN% + keys + latency (mono).

  Widget _statusBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final isEp = state.isEndpointMode;
      Widget leading;
      if (isEp) {
        final e = state.selectedEndpoint;
        final sub = e == null
            ? ''
            : switch (e.kind) {
                'aws' => e.region.isEmpty ? 'dynamodb · aws' : 'dynamodb · ${e.region}',
                'local' => 'local · ${_hostOf(e.endpoint)}',
                _ => _hostOf(e.endpoint),
              };
        leading = Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, // mockup .dot is 7px
              decoration: const BoxDecoration(color: Accents.teal, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(sub, style: Ts.style(size: Ts.xs, color: t.text2, monoFont: true)),
        ]);
      } else {
        final c = state.selectedConfig;
        final st = c == null ? null : state.statuses[c.id];
        final running = st?.isRunning ?? false;
        final ready = st?.ready ?? false;
        final statusLabel = st == null
            ? 'stopped'
            : running
                ? (ready ? 'ready' : 'degraded')
                : st.status;
        leading = Row(mainAxisSize: MainAxisSize.min, children: [
          _statusDot(st?.status ?? 'stopped'),
          const SizedBox(width: 7),
          Text('127.0.0.1:${c?.port ?? 0}',
              style: Ts.style(size: Ts.xs, color: t.text2, monoFont: true, tabularNums: true)),
          const SizedBox(width: 10),
          Text(statusLabel, style: Ts.style(size: Ts.xs, color: _statusColor(context, st?.status ?? 'stopped'), monoFont: true)),
          if (running && !ready) ...[
            const SizedBox(width: 10),
            Text('backend degraded', style: Ts.style(size: Ts.xs, color: t.warning, monoFont: true)),
          ],
        ]);
      }
      return Container(
        height: Dim.statusBarH,
        decoration: BoxDecoration(
          color: t.panel, // mockup .statusbar bg = panel (white), not panel-2
          border: Border(top: BorderSide(color: t.hairline)),
          // mockup .statusbar: upward 0 -1px 3px shadow.
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF173369).withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark ? 0.5 : 0.07),
              offset: const Offset(0, -1),
              blurRadius: 3,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          leading,
          const Spacer(),
          Text('db0 · redimos', style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)),
        ]),
      );
    });
  }

  // ---- top-bar global buttons (theme / language menus) ----

  // Mockup .tbtn: 30×30 (--ctl-h) bordered square, radius-sm, panel bg,
  // text-2 glyph at 14px (HTML shows ⏹ / ◐ / 文).
  Widget _tbtnBox(AppTokens t, Widget glyph) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(Dim.radiusS),
      ),
      child: glyph,
    );
  }

  Widget _themeMenu() => Builder(builder: (context) {
        final t = AppTokens.of(context);
        return PopupMenuButton<ThemeMode>(
          tooltip: tr('app.theme'),
          padding: EdgeInsets.zero,
          onSelected: cb.onThemeMode,
          itemBuilder: (_) => [
            _themeMenuItem(context, ThemeMode.light, Icons.light_mode_outlined, tr('theme.light')),
            _themeMenuItem(context, ThemeMode.dark, Icons.dark_mode_outlined, tr('theme.dark')),
            _themeMenuItem(context, ThemeMode.system, Icons.brightness_auto_outlined, tr('theme.system')),
          ],
          child: _tbtnBox(t, Icon(Icons.contrast, size: 14, color: t.text2)),
        );
      });

  Widget _langMenu() => Builder(builder: (context) {
        final t = AppTokens.of(context);
        return PopupMenuButton<AppLang>(
          tooltip: tr('app.language'),
          padding: EdgeInsets.zero,
          onSelected: cb.onLang,
          itemBuilder: (_) => [
            _langMenuItem(context, AppLang.zh, '中文'),
            _langMenuItem(context, AppLang.en, 'English'),
          ],
          // '文' rasterises as a tofu box in the capture channel (no CJK font
          // in the golden bundle) — kept anyway: the HTML mockup shows 文.
          child: _tbtnBox(
              t, Text('文', style: Ts.style(size: 14, weight: FontWeight.w600, color: t.text2))),
        );
      });

  PopupMenuItem<ThemeMode> _themeMenuItem(BuildContext context, ThemeMode m, IconData icon, String label) {
    final selected = state.themeMode == m;
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return PopupMenuItem<ThemeMode>(
      value: m,
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : null)),
        const Spacer(),
        if (selected) Icon(Icons.check, size: 16, color: color),
      ]),
    );
  }

  PopupMenuItem<AppLang> _langMenuItem(BuildContext context, AppLang l, String label) {
    final selected = state.lang == l;
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return PopupMenuItem<AppLang>(
      value: l,
      child: Row(children: [
        Text(label, style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : null)),
        const Spacer(),
        if (selected) Icon(Icons.check, size: 16, color: color),
      ]),
    );
  }

  // AppBar action: stop-all / restore toggle. When anything is running it stops
  // all (recording the running set); when nothing is running but a set was
  // recorded, it becomes a triangle that restores exactly that set.
  Widget _stopAllButton(AppTokens t) {
    final anyRunning = state.statuses.values
        .any((s) => s.isRunning || s.status == 'restarting');
    if (anyRunning) {
      return IconButton(
        tooltip: tr('app.stopAll'),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
        splashRadius: 14,
        icon: _tbtnBox(t, Icon(Icons.stop, size: 14, color: t.text2)), // mockup ⏹
        onPressed: cb.onStopAll,
      );
    }
    if (state.stopAllSnapshot.isNotEmpty) {
      return IconButton(
        tooltip: '${tr('app.startAll')} — ${tr('home.restore')} ${state.stopAllSnapshot.length} ${tr('home.configsSuffix')}',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
        splashRadius: 14,
        icon: _tbtnBox(t, Icon(Icons.play_arrow, size: 14, color: t.text2)),
        onPressed: cb.onRestoreAll,
      );
    }
    return IconButton(
      tooltip: tr('app.stopAll'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      splashRadius: 14,
      icon: _tbtnBox(t, Icon(Icons.stop, size: 14, color: t.text3)),
      onPressed: null, // nothing running, nothing to restore
    );
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Rail (leftmost 64px, constant dark navy) with the two entity-kind entries
  // (Instance / Endpoint). Active entry = a gradient-tinted rounded tile with
  // a glow + a 3px left indicator; inactive = a faint flat tile.

  Widget _rail() {
    return Container(
      width: Dim.railW,
      decoration: BoxDecoration(
        gradient: AppTokens.railGradient,
        boxShadow: Depth.railShadow,
      ),
      child: SafeArea(
        child: Column(children: [
          const SizedBox(height: 14),
          const RedimosLogo(size: 36),
          const SizedBox(height: 12),
          _railItem(
            kind: EntityKind.instance,
            icon: Icons.storage_outlined, // mockup rail glyph: DB drum
            label: tr('nav.instances'),
          ),
          const SizedBox(height: 6),
          _railItem(
            kind: EntityKind.endpoint,
            icon: Icons.swap_horiz, // mockup rail glyph: endpoint arrows
            label: tr('nav.endpoints'),
          ),
        ]),
      ),
    );
  }

  // Mockup .rail-item (方案 B override): a 44×42 tile filled EXACTLY by a
  // 32px icon row (with its ::after micro-gradient container) + a 10px/600
  // label row, gap 0 (CP 5.6). The active 3px gradient indicator sits at the
  // rail's left EDGE (overlapping the tile), so the icon stays centred.
  Widget _railItem({
    required EntityKind kind,
    required IconData icon,
    required String label,
  }) {
    final active = state.entityKind == kind;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 200),
      child: InkWell(
        onTap: () => cb.onEntityKind(kind),
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: Dim.railW,
          child: Stack(children: [
            // Active indicator pinned to the rail's left edge (mockup left:-10px).
            if (active)
              Positioned(
                left: 0, top: 7, bottom: 7, width: 3,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: AppTokens.railIndicatorGradient,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(color: const Color(0xFF8BA2FF).withValues(alpha: 0.85), blurRadius: 8),
                      BoxShadow(color: const Color(0xFFC3D0FF).withValues(alpha: 0.9), blurRadius: 2),
                    ],
                  ),
                ),
              ),
            Center(
              child: Container(
                width: 44,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: active ? const Color(0x248BA2FF) : Colors.transparent, // .14 alpha
                  boxShadow: active
                      ? [BoxShadow(color: const Color(0xFF8BA2FF).withValues(alpha: 0.18), blurRadius: 14)]
                      : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  // .rail-item::after — 32px icon container, micro gradient +
                  // hairline ring; icon (16px, line-height 32) centred in it.
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x219AA6DE), Color(0x0D9AA6DE)],
                      ),
                      border: Border.all(color: const Color(0x0DFFFFFF)),
                    ),
                    child: Center(
                      child: Icon(icon, size: 16,
                          color: active ? AppTokens.railFgActive : AppTokens.railFg),
                    ),
                  ),
                  // .r-label: 10px/600, line-height 10 (fills the tile: 32+10=42).
                  // scaleDown guard: the i18n labels ('Instances'/'Endpoints',
                  // 9 chars) are wider than the 44px tile in Inter 10px and
                  // would wrap to two lines and overflow the tile; the mockup
                  // shows one line, so scale down (≈0.94×) instead of wrapping.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                            fontSize: 10,
                            letterSpacing: .2,
                            height: 1,
                            color: active ? AppTokens.railFgActive : AppTokens.railFg,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Entity sidebar (280px): search + current-kind New button + a single group
  // of entity cards (instances XOR endpoints, driven by the rail selection).

  Widget _entitySidebar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final isInstance = state.entityKind == EntityKind.instance;
      final q = state.entityQuery.trim().toLowerCase();
      final items = isInstance
          ? state.configs
              .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || ':${c.port}'.contains(q))
              .map((c) => _entityCardShell(
                selected: c.id == state.selectedConfigId,
                onTap: () => cb.onSelectConfig(c),
                onHover: (h) => cb.onHoverCard(h ? c.id : null),
                dot: _statusDot(state.statuses[c.id]?.status ?? 'stopped'),
                badge: 'INST',
                // Mockup .ep-badge.inst: t-hash (#cdddf8) 18% fill, fg
                // #173369, 1px t-badge-border rgba(23,51,105,.28).
                badgeBg: const Color(0xFFCDDDF8).withValues(alpha: 0.18),
                badgeFg: const Color(0xFF173369),
                badgeBorder: const Color(0x47173369),
                name: c.name.isEmpty ? tr('config.unnamed') : c.name,
                sub: ':${c.port} · ${_endpointFor(c)?.name ?? (c.endpoint.isEmpty ? 'AWS' : _hostOf(c.endpoint))}',
                sub2: _statusLabel(c.id),
                sub2Color: _statusColor(context, state.statuses[c.id]?.status ?? 'stopped'),
                trailing: _hoverStartStop(c),
              ))
          : state.endpoints
              .where((e) => q.isEmpty || e.name.toLowerCase().contains(q) || e.endpoint.toLowerCase().contains(q))
              .map((e) => _entityCardShell(
                selected: e.id == state.selectedEndpointId,
                onTap: () => cb.onSelectEndpoint(e.id),
                dot: Container(
                    width: 7, height: 7, // mockup .dot is 7px
                    decoration: BoxDecoration(color: t.success, shape: BoxShape.circle)),
                badge: switch (e.kind) { 'local' => 'LOCAL', 'aws' => 'AWS', _ => 'URL' },
                // Mockup .ep-badge variants: local = success 15%, aws =
                // warning 16%, url = accent 13% fills, fg = same hue, no border.
                badgeBg: switch (e.kind) {
                  'local' => t.success.withValues(alpha: 0.15),
                  'aws' => t.warning.withValues(alpha: 0.16),
                  _ => t.accent.withValues(alpha: 0.13),
                },
                badgeFg: switch (e.kind) { 'local' => t.success, 'aws' => t.warning, _ => t.accent },
                name: e.name.isEmpty ? tr('config.unnamed') : e.name,
                sub: switch (e.kind) {
                  'aws' => e.region.isEmpty ? 'AWS' : 'dynamodb · ${e.region}',
                  'local' => _portLabel(e.endpoint),
                  _ => _hostOf(e.endpoint),
                },
                sub2: '',
                sub2Color: t.text3,
                trailing: null,
              ));
      return Container(
        decoration: BoxDecoration(
          color: t.sidebar,
          // mockup .sidebar: 1px right border + right-edge soft shadow (elevSide).
          border: Border(right: BorderSide(color: t.border)),
          boxShadow: Depth.elevSide(Theme.of(context).brightness),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Filter: search (current kind).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: SizedBox(
              height: Dim.ctlH,
              child: TextField(
                onChanged: cb.onQueryChanged,
                // Mockup .search-input: mono 12.
                style: Ts.style(size: 12, color: t.text, monoFont: true),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  hintText: tr('br.search'),
                  // Mockup .search-input: mono 12.
                  hintStyle: Ts.style(size: 12, color: t.text3, monoFont: true),
                  prefixIcon: Icon(Icons.search, size: 16, color: t.text3),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 0),
                  filled: true,
                  fillColor: t.panel, // mockup .search bg = --panel
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Dim.radiusS), // radius-sm 6
                      borderSide: BorderSide(color: t.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Dim.radiusS),
                      borderSide: BorderSide(color: t.focus, width: 1.4)),
                ),
              ),
            ),
          ),
          // New button for the current kind (kept on instances; endpoints gain one
          // only via their own flows, so the endpoint pane reuses the same button
          // and opens the new-config editor).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 32, // mockup .pbtn: 32px, radius-sm 6 (CP 9.x round 2)
              child: FilledButton.icon(
                onPressed: cb.onNewConfig,
                icon: const Icon(Icons.add, size: 16),
                // Explicit label style: the styleFrom(textStyle:) chain loses
                // the font family in widget tests (blocky fallback face), so
                // the label must carry its own Ts.style.
                label: Text(tr('config.new'),
                    style: Ts.style(size: Ts.md, weight: FontWeight.w600)),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(32),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Dim.radiusS))),
              ),
            ),
          ),
          // Group header (mockup .grp-head: ▾ twisty + uppercase 10.5/700
          // ls1 text-3 + .cnt-chip mono 10/500 panel-2 + hairline, radius
          // 999, padding 1×7, colour text-2).
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
            child: Row(children: [
              Icon(Icons.keyboard_arrow_down, size: 10, color: t.text3), // .twisty ▾
              const SizedBox(width: 7), // .grp-head gap:7
              Text((isInstance ? tr('nav.instances') : tr('nav.endpoints')).toUpperCase(),
                  style: Ts.style(size: 10.5, weight: FontWeight.w700, color: t.text3, letterSpacing: 1)),
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                    color: t.panel2,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: t.hairline)),
                child: Text('${isInstance ? state.configs.length : state.endpoints.length}',
                    style: Ts.style(size: 10, weight: FontWeight.w500, color: t.text2, monoFont: true)),
              ),
            ]),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(child: Text(tr('nav.noneYet'), style: Ts.style(size: Ts.md, color: t.text3)))
                : ListView(
                    // Mockup .ep-list: padding 10, gap 8 (cards carry 4+4
                    // vertical margin; pixel-fidelity-v23 CP 9.x).
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                    children: items.toList()),
          ),
          const Divider(height: 1),
          LocalDdbPanel(core: core, info: state.ddb, onMutated: cb.onDdbMutated),
        ]),
      );
    });
  }

  String _statusLabel(String id) {
    final s = state.statuses[id];
    if (s == null) return 'stopped';
    if (s.isRunning) return 'running';
    return s.status;
  }

  // Hover-revealed start/stop control for an instance card (kept visible while
  // active so a running instance can always be stopped).
  Widget? _hoverStartStop(RedimosConfig c) {
    final st = state.statuses[c.id];
    final active = (st?.isRunning ?? false) || st?.status == 'restarting';
    final hovered = state.hoveredCardId == c.id;
    if (!hovered && !active) return null;
    return Builder(builder: (context) {
      return IconButton(
        tooltip: active ? tr('config.stop') : tr('config.start'),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        icon: Icon(active ? Icons.stop_circle : Icons.play_circle_fill,
            color: active ? Colors.redAccent : Accents.green),
        onPressed: () => cb.onStartStop(c),
      );
    });
  }

  // One entity card (mockup .ep-card): status dot + name + badge + mono
  // sub-line (+ optional start/stop). Selected = accent border + selection
  // fill + inset 2px left accent (mockup .ep-card.selected).
  Widget _entityCardShell({
    required bool selected,
    required VoidCallback onTap,
    void Function(bool)? onHover,
    required Widget dot,
    required String badge,
    required Color badgeBg,
    required Color badgeFg,
    Color? badgeBorder,
    required String name,
    required String sub,
    required String sub2,
    required Color sub2Color,
    Widget? trailing,
  }) {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      return Padding(
        // Mockup .ep-list gap 8 → 4+4 per card.
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        child: Material(
          color: selected ? t.selection : t.panel,
          borderRadius: BorderRadius.circular(Dim.radiusM), // --radius 8
          child: InkWell(
            onTap: onTap,
            onHover: onHover,
            borderRadius: BorderRadius.circular(Dim.radiusM),
            child: Container(
              decoration: BoxDecoration(
                // Opaque fill REQUIRED: without it the elev-2 outer shadow
                // composites through the transparent box interior and the
                // card reads grey instead of white (ep-browser diagnosis).
                color: selected ? t.selection : t.panel,
                borderRadius: BorderRadius.circular(Dim.radiusM),
                // Mockup: 1px border in both states (accent when selected).
                border: Border.all(color: selected ? t.accent : t.border),
                boxShadow: Depth.elev2(Theme.of(context).brightness),
              ),
              // 2px left selection indicator (.ep-card.selected inset 2px).
              foregroundDecoration: selected
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(Dim.radiusM),
                      border: Border(left: BorderSide(color: t.accent, width: 2)),
                    )
                  : null,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10), // 10px 12px
              child: Row(children: [
                dot,
                const SizedBox(width: 7), // .ep-top gap:7
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        // Mockup .ep-name: 13/700 (v2.4 override).
                        child: Text(name, overflow: TextOverflow.ellipsis,
                            style: Ts.style(size: 13, weight: FontWeight.w700, color: t.text)),
                      ),
                      const SizedBox(width: 6),
                      // .ep-badge: margin-left:auto, mono 9.5/700 ls.6,
                      // padding 2×7, radius 4.
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: badgeBg,
                            borderRadius: BorderRadius.circular(4),
                            border: badgeBorder == null
                                ? null
                                : Border.all(color: badgeBorder)),
                        child: Text(badge,
                            style: Ts.style(size: 9.5, weight: FontWeight.w700, color: badgeFg, letterSpacing: 0.6, monoFont: true)),
                      ),
                    ]),
                    const SizedBox(height: 6), // .ep-card gap:6
                    Row(children: [
                      Flexible(
                        child: Text(sub, overflow: TextOverflow.ellipsis,
                            style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true)),
                      ),
                      if (sub2.isNotEmpty) ...[
                        const SizedBox(width: 12), // .ep-sub gap:12
                        // Mockup .st-* status words are 600.
                        Text(sub2, style: Ts.style(size: Ts.xs, weight: FontWeight.w600, color: sub2Color, monoFont: true)),
                      ],
                    ]),
                  ]),
                ),
                if (trailing != null) trailing,
              ]),
            ),
          ),
        ),
      );
    });
  }

  // The endpoint an instance's config points at (matched by backend tuple), so
  // an instance card can show "→ endpoint-name".
  DdbEndpoint? _endpointFor(RedimosConfig c) {
    for (final e in state.endpoints) {
      if (e.endpoint == c.endpoint &&
          e.region == c.region &&
          e.accessKeyId == c.accessKeyId &&
          e.secretKey == c.secretKey &&
          e.sessionToken == c.sessionToken &&
          e.source == c.source) {
        return e;
      }
    }
    return null;
  }

  String _hostOf(String url) {
    final u = Uri.tryParse(url);
    return (u != null && u.host.isNotEmpty) ? (u.hasPort ? '${u.host}:${u.port}' : u.host) : url;
  }

  String _portLabel(String url) {
    final u = Uri.tryParse(url);
    if (u != null && u.hasPort) return ':${u.port}';
    return _hostOf(url);
  }

  // Mockup maps stopped to .dot.err/.st-err (--danger), not grey.
  Color _statusColor(BuildContext context, String status) {
    final t = AppTokens.of(context);
    return switch (status) {
      'running' => goGreen(context),
      'restarting' => Colors.amberAccent,
      'error' => Colors.redAccent,
      'failed' => Colors.redAccent,
      'exited' => Colors.orangeAccent,
      'stopped' => t.danger,
      _ => Colors.grey,
    };
  }

  // Mockup .dot: 7×7 circle + same-hue 55% glow (0 0 5px).
  Widget _statusDot(String status) => Builder(builder: (context) {
        final c = _statusColor(context, status);
        return Container(
            width: 7, height: 7,
            decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: 5)]));
      });
}

// ---------------------------------------------------------------------------
// Shared chrome bits used both by HomeChrome and the capture channel.
// ---------------------------------------------------------------------------

/// The v2.3 primary CTA (mid bar end slot / context button). Dark theme flips
/// to a white fill + near-black text.
Widget chromeCta(BuildContext context, IconData icon, String label, VoidCallback onPressed) {
  final t = AppTokens.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final bg = dark ? const Color(0xFFF5F7FB) : t.accent;
  final fg = dark ? const Color(0xFF10142E) : t.onAccent;
  return Padding(
    padding: const EdgeInsets.only(right: 6),
    child: SizedBox(
      height: 32, // mockup .pbtn: 32px, radius-sm 6 (CP 9.x round 2)
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16, color: fg),
        // Explicit label style: styleFrom(textStyle:) loses the font family
        // in widget tests (blocky fallback face) — see home sidebar button.
        label: Text(label,
            style: Ts.style(size: Ts.md, weight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Dim.radiusS)),
        ),
      ),
    ),
  );
}

/// The app mark (mockup .rail-logo): a 36px rounded red tile (155° gradient
/// #ec5a4f→#d33a31→#ae2a21) with a bold white 'R', raised by a rich multi-layer
/// shadow (inset top highlight + inset bottom shade + 1px ring + drop shadow).
class RedimosLogo extends StatelessWidget {
  const RedimosLogo({super.key, this.size = 36});
  final double size;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEC5A4F), Color(0xFFD33A31), Color(0xFFAE2A21)],
          stops: [0.0, 0.48, 1.0],
        ),
        boxShadow: [
          // inset top highlight
          BoxShadow(
              color: Colors.white.withValues(alpha: dark ? 0.30 : 0.32),
              offset: const Offset(0, 1),
              blurRadius: 0),
          // inset bottom shade
          BoxShadow(
              color: const Color(0xFF600A05).withValues(alpha: dark ? 0.45 : 0.35),
              offset: const Offset(0, -2),
              blurRadius: 4),
          // 1px outer ring
          BoxShadow(
              color: Colors.white.withValues(alpha: dark ? 0.07 : 0.06),
              spreadRadius: 1,
              blurRadius: 0),
          // drop shadow
          BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.65 : 0.5),
              offset: const Offset(0, 3),
              blurRadius: dark ? 10 : 8,
              spreadRadius: -2),
        ],
      ),
      child: const Text('R',
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: Colors.white,
              height: 1)),
    );
  }
}
