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
import 'package:flutter/semantics.dart';

import 'i18n.dart';
import 'models.dart';
import 'theme_prefs.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_status.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

/// v2.3 rail entity kind — which group the entity sidebar lists. v1.2 adds
/// Service as the third first-class entity (stage 12).
enum EntityKind { instance, endpoint, service }

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
    required this.lang,
    this.services = const [],
    this.selectedServiceId,
  });

  final EntityKind entityKind;
  final List<RedimosConfig> configs;
  final List<DdbEndpoint> endpoints;
  final Map<String, InstanceStatus> statuses;
  final String? selectedConfigId;
  final String? selectedEndpointId;
  final String? hoveredCardId;
  final String entityQuery;

  /// Stage 12: the Service entity list (ID-addressed snapshots from the core,
  /// already sorted by ServicesState) and its own selected ID — kept separate
  /// from the instance/endpoint selections so switching kinds never loses a
  /// selection (requirement 12.6).
  final List<ServiceInfo> services;
  final String? selectedServiceId;

  /// MidBar labels for the CURRENT mode (instance tabs or endpoint screens).
  final List<String> tabLabels;

  /// Active MidBar index within [tabLabels].
  final int tabIndex;
  final List<String> stopAllSnapshot;
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

  ServiceInfo? get selectedService {
    for (final s in services) {
      if (s.id == selectedServiceId) return s;
    }
    return null;
  }

  bool get isEndpointMode => selectedEndpointId != null;
  bool get isServiceMode => entityKind == EntityKind.service;
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
    required this.onLang,
    this.onSelectService = _noopId,
    this.onNewService = _noopVoid,
    this.onServiceStartStop = _noopSvc,
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
  final ValueChanged<AppLang> onLang;

  // Stage 12 Service callbacks. Defaults keep every pre-Service construction
  // site (fixtures / capture channel) compiling untouched; the live HomePage
  // passes real handlers.
  final ValueChanged<String> onSelectService;
  final VoidCallback onNewService;
  final void Function(ServiceInfo) onServiceStartStop;
}

void _noopId(String _) {}
void _noopSvc(ServiceInfo _) {}
void _noopVoid() {}

/// The full chrome around the detail area: rail + entity sidebar on the left,
/// top bar / mid bar / detail / status bar in the main column. [midBarCta]
/// is the context CTA for the mid bar's end slot (HomePage builds it — it can
/// reach the content screens' GlobalKeys; the capture passes a lookalike).
class HomeChrome extends StatelessWidget {
  const HomeChrome({
    super.key,
    required this.state,
    required this.cb,
    required this.child,
    this.midBarCta,
  });

  final ChromeState state;
  final ChromeCallbacks cb;
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
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _topBar(),
            _midBar(),
            Expanded(child: child),
            _statusBar(),
          ]),
        ),
      ],
    );
  }

  // Top bar (48px): invariant entity context first, variable screen name last,
  // followed by a fixed action group. Tab changes only replace the final text
  // run, so the entity and sub-entity keep their logical X coordinates.
  Widget _topBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final brightness = Theme.of(context).brightness;
      return Container(
        key: const ValueKey('home-topbar'),
        height: Dim.topBarH,
        decoration: BoxDecoration(
          color: t.panel,
          border: Border(bottom: BorderSide(color: t.hairline)),
          boxShadow: Depth.elev1(brightness),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          _topBarCrumb(t),
          const Spacer(),
          Row(
            key: const ValueKey('home-topbar-actions'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                key: const ValueKey('home-topbar-stop-slot'),
                dimension: Dim.ctlH,
                child: _stopAllButton(t),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                key: const ValueKey('home-topbar-style-slot'),
                dimension: Dim.ctlH,
                child: _styleMenu(),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                key: const ValueKey('home-topbar-lang-slot'),
                dimension: Dim.ctlH,
                child: _langMenu(),
              ),
            ],
          ),
        ]),
      );
    });
  }

  Widget _topBarCrumb(AppTokens t) {
    return Builder(builder: (context) {
      final isSvc = state.isServiceMode;
      final isEp = !isSvc && state.isEndpointMode;
      String entity = '';
      String sub = '';
      if (isSvc) {
        final s = state.selectedService;
        if (s != null) {
          entity =
              s.config.name.isEmpty ? tr('service.unnamed') : s.config.name;
          sub = '${s.config.engine.wire} · :${s.config.port}';
        }
      } else if (isEp) {
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
          sub =
              ':${c.port} · ${_endpointFor(c)?.name ?? (c.endpoint.isEmpty ? 'AWS' : _hostOf(c.endpoint))}';
        }
      }
      final screenName =
          state.tabLabels[state.tabIndex.clamp(0, state.tabLabels.length - 1)];
      return Row(
        key: const ValueKey('home-topbar-crumb'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entity.isNotEmpty)
            Text(
              entity,
              key: const ValueKey('home-topbar-entity'),
              style: Ts.style(
                size: 11.5,
                weight: FontWeight.w600,
                color: t.text,
                monoFont: true,
              ),
            ),
          if (entity.isNotEmpty && sub.isNotEmpty)
            Text(
              ' · $sub',
              key: const ValueKey('home-topbar-sub-entity'),
              style: Ts.style(size: 11.5, color: t.text3, monoFont: true),
            ),
          if (entity.isNotEmpty) const SizedBox(width: 10),
          Text(
            screenName,
            key: const ValueKey('home-topbar-screen-name'),
            style: Ts.style(
              size: 13.5,
              weight: FontWeight.w600,
              color: t.text,
            ),
          ),
        ],
      );
    });
  }

  // Mid bar (44px): compact underline tabs centred between equal start/end
  // regions. Four- and six-tab endpoint sets therefore keep the detail pane at
  // the same origin while only the bounded tab strip changes width.
  Widget _midBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final brightness = Theme.of(context).brightness;
      final labels = state.tabLabels;
      final index = state.tabIndex;
      return Container(
        key: const ValueKey('home-midbar'),
        height: Dim.midBarH,
        decoration: BoxDecoration(
          color: t.panel,
          border: Border(bottom: BorderSide(color: t.border)),
          boxShadow: Depth.elev1(brightness),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Expanded(
            child: SizedBox.shrink(key: ValueKey('home-midbar-start')),
          ),
          SingleChildScrollView(
            key: const ValueKey('home-midbar-tabs'),
            scrollDirection: Axis.horizontal,
            child: Row(
              key: const ValueKey('home-midbar-tab-row'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  _midTab(
                    t,
                    i,
                    labels[i],
                    i == index,
                    () => cb.onMidTab(i),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Align(
              key: const ValueKey('home-midbar-cta-slot'),
              alignment: Alignment.centerRight,
              child: midBarCta ?? const SizedBox.shrink(),
            ),
          ),
        ]),
      );
    });
  }

  // The active state changes only text and the warm 2px indicator. Hover/focus
  // use bounded paint feedback; Material splash and press highlights stay off.
  Widget _midTab(
    AppTokens t,
    int tabIndex,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    return InkWell(
      key: ValueKey('home-midbar-tab-$tabIndex-action'),
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: t.hover,
      focusColor: t.focus.withValues(alpha: 0.12),
      child: Container(
        key: ValueKey('home-midbar-tab-$tabIndex'),
        height: Dim.midBarH,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? t.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          key: ValueKey('home-midbar-tab-$tabIndex-label'),
          style: Ts.style(
            size: Ts.sm,
            weight: FontWeight.w600,
            color: active ? t.text : t.text3,
          ),
        ),
      ),
    );
  }

  // Status bar (24px): a low-emphasis shell around the existing connection
  // summary. Operational paint comes from the shared status roles, never from
  // the brand accent; state changes leave the shell and edge anchors fixed.
  Widget _statusBar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final isSvc = state.isServiceMode;
      final isEp = !isSvc && state.isEndpointMode;
      Widget leading;
      if (isSvc) {
        final s = state.selectedService;
        final statusLabel = s?.runtime.state.name ?? 'stopped';
        leading = Row(
          key: const ValueKey('home-statusbar-leading'),
          mainAxisSize: MainAxisSize.min,
          children: [
            CodexStatusDot(
              key: const ValueKey('home-statusbar-dot'),
              status: _codexStatus(statusLabel),
              semanticLabel: 'Service $statusLabel',
            ),
            const SizedBox(width: 7),
            Text(
              '127.0.0.1:${s?.config.port ?? 0}',
              key: const ValueKey('home-statusbar-host'),
              style: Ts.style(
                size: Ts.xs,
                color: t.text2,
                monoFont: true,
                tabularNums: true,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              statusLabel,
              key: const ValueKey('home-statusbar-status'),
              style: Ts.style(
                size: Ts.xs,
                color: codexStatusColor(context, _codexStatus(statusLabel)),
                monoFont: true,
              ),
            ),
          ],
        );
      } else if (isEp) {
        final e = state.selectedEndpoint;
        final sub = e == null
            ? ''
            : switch (e.kind) {
                'aws' => e.region.isEmpty
                    ? 'dynamodb · aws'
                    : 'dynamodb · ${e.region}',
                'local' => 'local · ${_hostOf(e.endpoint)}',
                _ => _hostOf(e.endpoint),
              };
        leading = Row(
          key: const ValueKey('home-statusbar-leading'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const CodexStatusDot(
              key: ValueKey('home-statusbar-dot'),
              status: CodexStatus.success,
              semanticLabel: 'Endpoint available',
            ),
            const SizedBox(width: 7),
            Text(
              sub,
              key: const ValueKey('home-statusbar-endpoint-summary'),
              style: Ts.style(size: Ts.xs, color: t.text2, monoFont: true),
            ),
          ],
        );
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
        final semanticStatus = _codexStatus(statusLabel);
        leading = Row(
          key: const ValueKey('home-statusbar-leading'),
          mainAxisSize: MainAxisSize.min,
          children: [
            CodexStatusDot(
              key: const ValueKey('home-statusbar-dot'),
              status: semanticStatus,
              semanticLabel: 'Instance $statusLabel',
            ),
            const SizedBox(width: 7),
            Text(
              '127.0.0.1:${c?.port ?? 0}',
              key: const ValueKey('home-statusbar-host'),
              style: Ts.style(
                size: Ts.xs,
                color: t.text2,
                monoFont: true,
                tabularNums: true,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              statusLabel,
              key: const ValueKey('home-statusbar-status'),
              style: Ts.style(
                size: Ts.xs,
                color: codexStatusColor(context, semanticStatus),
                monoFont: true,
              ),
            ),
            if (running && !ready) ...[
              const SizedBox(width: 10),
              Text(
                'backend degraded',
                key: const ValueKey('home-statusbar-backend'),
                style: Ts.style(size: Ts.xs, color: t.warning, monoFont: true),
              ),
            ],
          ],
        );
      }
      return Container(
        key: const ValueKey('home-statusbar'),
        height: Dim.statusBarH,
        decoration: BoxDecoration(
          color: t.panel2,
          border: Border(top: BorderSide(color: t.hairline)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          leading,
          const Spacer(),
          Text(
            'db0 · redimos',
            key: const ValueKey('home-statusbar-trailing'),
            style: Ts.style(size: Ts.xs, color: t.text3, monoFont: true),
          ),
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

  Widget _langMenu() => Builder(builder: (context) {
        final t = AppTokens.of(context);
        return PopupMenuButton<AppLang>(
          key: const ValueKey('home-language-menu'),
          initialValue: state.lang,
          tooltip: tr('app.language'),
          padding: EdgeInsets.zero,
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          constraints: const BoxConstraints(minWidth: 152, maxWidth: 196),
          position: PopupMenuPosition.under,
          requestFocus: true,
          style: _menuButtonStyle(t),
          icon: Text(
            '文',
            style: Ts.style(
              size: 14,
              weight: FontWeight.w600,
              color: t.text2,
            ),
          ),
          onSelected: cb.onLang,
          itemBuilder: (_) => [
            _langMenuItem(AppLang.zh, '中文'),
            _langMenuItem(AppLang.en, 'English'),
          ],
        );
      });

  ButtonStyle _menuButtonStyle(AppTokens t) => ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        minimumSize: const WidgetStatePropertyAll(Size(Dim.ctlH, Dim.ctlH)),
        maximumSize: const WidgetStatePropertyAll(Size(Dim.ctlH, Dim.ctlH)),
        fixedSize: const WidgetStatePropertyAll(Size.square(Dim.ctlH)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        foregroundColor: WidgetStatePropertyAll(t.text2),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) return t.selection;
          if (states.contains(WidgetState.hovered)) return t.hover;
          return t.panel;
        }),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused) ? t.focus : t.border,
            width: Dim.borderW,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Dim.radiusS),
          ),
        ),
      );

  PopupMenuEntry<AppLang> _langMenuItem(AppLang lang, String label) =>
      _CodexPopupMenuItem<AppLang>(
        key: ValueKey('home-language-menu-${lang.name}-item'),
        keyName: 'home-language-menu-${lang.name}',
        value: lang,
        selected: state.lang == lang,
        label: label,
      );

  // v1.3: theme-style picker. A square swatch button (current palette bg with
  // an accent core, same chrome as the language button) sitting between
  // stop-all and the language menu; picking a style swaps the global appStyle
  // (rebuilding MaterialApp's theme) and persists the choice.
  Widget _styleMenu() => Builder(builder: (context) {
        final t = AppTokens.of(context);
        final st = appStyle.value.tokens;
        return PopupMenuButton<AppStyle>(
          key: const ValueKey('home-style-menu'),
          initialValue: appStyle.value,
          tooltip: tr('app.theme'),
          padding: EdgeInsets.zero,
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          constraints: const BoxConstraints(minWidth: 152, maxWidth: 196),
          position: PopupMenuPosition.under,
          requestFocus: true,
          style: _menuButtonStyle(t),
          onSelected: (s) {
            if (s == appStyle.value) return;
            appStyle.value = s;
            saveAppStyle();
          },
          itemBuilder: (_) => [
            for (final s in AppStyle.values)
              _CodexPopupMenuItem<AppStyle>(
                key: ValueKey('home-style-menu-${s.id}-item'),
                keyName: 'home-style-menu-${s.id}',
                value: s,
                selected: s == appStyle.value,
                label: s.label,
              ),
          ],
          child: Center(
            child: Container(
              key: const ValueKey('home-style-menu-swatch'),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: st.bg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: t.border, width: Dim.borderW),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: st.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        );
      });

  // AppBar action: stop-all / restore toggle. When anything is running it stops
  // all (recording the running set); when nothing is running but a set was
  // recorded, it becomes a triangle that restores exactly that set.
  Widget _stopAllButton(AppTokens t) {
    final anyRunning = state.statuses.values
            .any((s) => s.isRunning || s.status == 'restarting') ||
        state.services.any((s) => s.runtime.isLive);
    if (anyRunning) {
      return IconButton(
        tooltip: tr('app.stopAll'),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
        splashRadius: 14,
        icon:
            _tbtnBox(t, Icon(Icons.stop, size: 14, color: t.text2)), // mockup ⏹
        onPressed: cb.onStopAll,
      );
    }
    if (state.stopAllSnapshot.isNotEmpty) {
      return IconButton(
        tooltip:
            '${tr('app.startAll')} — ${tr('home.restore')} ${state.stopAllSnapshot.length} ${tr('home.configsSuffix')}',
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

  // The fixed 64px rail follows the active theme palette. Active, hover and
  // focus treatments are paint-only, so they never change item geometry.
  Widget _rail() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      return Container(
        key: const ValueKey('main-rail'),
        width: Dim.railW,
        decoration: BoxDecoration(gradient: t.railGradient),
        child: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              child: Column(children: [
                const SizedBox(height: 14),
                const RedimosLogo(
                  key: ValueKey('main-rail-logo'),
                  size: 36,
                ),
                const SizedBox(height: 12),
                _railItem(
                  kind: EntityKind.instance,
                  icon: Icons.storage_outlined,
                  label: tr('nav.instances'),
                ),
                const SizedBox(height: 6),
                _railItem(
                  kind: EntityKind.endpoint,
                  icon: Icons.swap_horiz,
                  label: tr('nav.endpoints'),
                ),
                const SizedBox(height: 6),
                _railItem(
                  kind: EntityKind.service,
                  icon: Icons.widgets_outlined,
                  label: tr('nav.services'),
                ),
              ]),
            ),
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: Dim.borderW,
              child: ColoredBox(color: t.border),
            ),
          ],
        ),
      );
    });
  }

  Widget _railItem({
    required EntityKind kind,
    required IconData icon,
    required String label,
  }) {
    final active = state.entityKind == kind;
    final keyName = switch (kind) {
      EntityKind.instance => 'instance',
      EntityKind.endpoint => 'endpoint',
      EntityKind.service => 'service',
    };
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      var focused = false;
      return StatefulBuilder(builder: (context, setRailState) {
        // No Tooltip here: the label is already printed under the icon, and
        // the dark tooltip bubble popping/dismissing around clicks read as a
        // black flash that also spilled over the rail's right divider.
        return SizedBox(
          key: ValueKey('main-rail-$keyName-item'),
          width: Dim.railW,
          height: 42,
          child: Stack(children: [
            Center(
              child: Container(
                key: ValueKey('main-rail-$keyName-glow'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Dim.radiusM),
                  // The glow rides on a plain BoxDecoration shadow — the same
                  // render path the content cards already use.
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: t.railGlow,
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Material(
                  key: ValueKey('main-rail-$keyName-tile'),
                  color: active ? t.railActiveBg : Colors.transparent,
                  // Snap paint changes: the default 200ms animation lerps
                  // color from transparent black through a muddy dark gray.
                  animationDuration: Duration.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Dim.radiusM),
                    side: BorderSide(
                      color: focused ? t.focus : Colors.transparent,
                      width: Dim.borderW,
                    ),
                  ),
                  child: Semantics(
                    button: true,
                    enabled: true,
                    selected: active,
                    child: InkWell(
                      key: ValueKey('main-rail-$keyName-action'),
                      onTap: () => cb.onEntityKind(kind),
                      onFocusChange: (value) {
                        if (focused == value) return;
                        setRailState(() => focused = value);
                      },
                      borderRadius: BorderRadius.circular(Dim.radiusM),
                      // Never recolour a live ink feature to
                      // transparent-black: the hover/highlight ink created
                      // while the tile was inactive keeps its creation-time
                      // opacity, and swapping its colour to Colors.transparent
                      // on activation paints an opaque BLACK rounded rect over
                      // the tile until the pointer leaves and re-enters.
                      // Apricot-over-apricot is the invisible no-op.
                      hoverColor: active ? t.railActiveBg : t.hover,
                      focusColor: t.focus.withValues(alpha: 0.16),
                      highlightColor: active ? t.railActiveBg : t.selection,
                      splashColor: Colors.transparent,
                      // Press feedback on these tiles is the static highlight
                      // wash only — no splash feature at all.
                      splashFactory: NoSplash.splashFactory,
                      child: SizedBox(
                        key: ValueKey('main-rail-$keyName-focus-target'),
                        width: 44,
                        height: 42,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              icon,
                              size: active ? 18 : 16,
                              color: active ? t.railFgActive : t.railFg,
                            ),
                            const SizedBox(height: 3),
                            // Horizontal inset so the scaled-down label never
                            // paints flush against the tile's left/right edge.
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: .2,
                                    height: 1,
                                    color: active ? t.railFgActive : t.railFg,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (active)
              Positioned(
                left: 0,
                top: 9,
                bottom: 9,
                width: 2,
                child: DecoratedBox(
                  key: ValueKey('main-rail-$keyName-indicator'),
                  decoration: BoxDecoration(
                    color: t.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
          ]),
        );
      });
    });
  }

  // ---------------------------------------------------------------- v2.3 ---
  // Entity sidebar (280px): search + current-kind New button + a single group
  // of entity cards (instances XOR endpoints, driven by the rail selection).

  Widget _entitySidebar() {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      final isInstance = state.entityKind == EntityKind.instance;
      final isService = state.entityKind == EntityKind.service;
      final q = state.entityQuery.trim().toLowerCase();
      final items = isInstance
          ? state.configs
              .where((c) =>
                  q.isEmpty ||
                  c.name.toLowerCase().contains(q) ||
                  ':${c.port}'.contains(q))
              .map((c) => _entityCardShell(
                    cardKey: c.id,
                    selected: c.id == state.selectedConfigId,
                    hovered: c.id == state.hoveredCardId,
                    onTap: () => cb.onSelectConfig(c),
                    onHover: (h) => cb.onHoverCard(h ? c.id : null),
                    dot: _statusDot(state.statuses[c.id]?.status ?? 'stopped'),
                    badge: 'INST',
                    name: c.name.isEmpty ? tr('config.unnamed') : c.name,
                    sub:
                        ':${c.port} · ${_endpointFor(c)?.name ?? (c.endpoint.isEmpty ? 'AWS' : _hostOf(c.endpoint))}',
                    sub2: _statusLabel(c.id),
                    sub2Color: _statusColor(
                        context, state.statuses[c.id]?.status ?? 'stopped'),
                    trailing: _startStop(c),
                    trailingVisible: state.hoveredCardId == c.id ||
                        (state.statuses[c.id]?.isRunning ?? false) ||
                        state.statuses[c.id]?.status == 'restarting',
                  ))
          : isService
              ? state.services
                  .where((s) =>
                      q.isEmpty ||
                      s.config.name.toLowerCase().contains(q) ||
                      s.config.engine.wire.contains(q) ||
                      ':${s.config.port}'.contains(q))
                  .map((s) => _serviceCard(context, s))
              : state.endpoints
                  .where((e) =>
                      q.isEmpty ||
                      e.name.toLowerCase().contains(q) ||
                      e.endpoint.toLowerCase().contains(q))
                  .map((e) => _entityCardShell(
                        cardKey: e.id,
                        selected: e.id == state.selectedEndpointId,
                        hovered: e.id == state.hoveredCardId,
                        onTap: () => cb.onSelectEndpoint(e.id),
                        onHover: (h) => cb.onHoverCard(h ? e.id : null),
                        dot: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                                color: t.success, shape: BoxShape.circle)),
                        badge: switch (e.kind) {
                          'local' => 'LOCAL',
                          'aws' => 'AWS',
                          _ => 'URL'
                        },
                        name: e.name.isEmpty ? tr('config.unnamed') : e.name,
                        sub: switch (e.kind) {
                          'aws' =>
                            e.region.isEmpty ? 'AWS' : 'dynamodb · ${e.region}',
                          'local' => _portLabel(e.endpoint),
                          _ => _hostOf(e.endpoint),
                        },
                        sub2: '',
                        sub2Color: t.text3,
                        trailing: null,
                      ));
      final itemCount = isInstance
          ? state.configs.length
          : isService
              ? state.services.length
              : state.endpoints.length;
      return Container(
        key: const ValueKey('entity-sidebar'),
        decoration: BoxDecoration(
          color: t.sidebar,
          border: Border(right: BorderSide(color: t.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: CodexSearchField(
                key: const ValueKey('entity-sidebar-search'),
                hintText: tr('br.search'),
                onChanged: cb.onQueryChanged,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SizedBox(
                height: Dim.ctlH,
                child: CodexButton(
                  key: const ValueKey('entity-sidebar-new-action'),
                  variant: CodexButtonVariant.primary,
                  onPressed: isService ? cb.onNewService : cb.onNewConfig,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(isService ? tr('service.new') : tr('config.new')),
                ),
              ),
            ),
            Padding(
              key: const ValueKey('entity-sidebar-group-header'),
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              // One flat list per pane now — no collapsible groups — so the
              // old collapse-era chevron row becomes the design-system
              // section header (eyebrow + hairline rule), keeping the count
              // pill as its trailing element.
              child: CodexSectionHeader(
                label: (isInstance
                        ? tr('nav.instances')
                        : isService
                            ? tr('nav.services')
                            : tr('nav.endpoints'))
                    .toUpperCase(),
                trailing: Container(
                  key: const ValueKey('entity-sidebar-count'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: t.panel2,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: t.hairline),
                  ),
                  child: Text(
                    '$itemCount',
                    style: Ts.style(
                      size: 10,
                      weight: FontWeight.w500,
                      color: t.text2,
                      monoFont: true,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      key: const ValueKey('entity-sidebar-empty'),
                      child: Text(
                        isService ? tr('service.noneYet') : tr('nav.noneYet'),
                        style: Ts.style(size: Ts.md, color: t.text3),
                      ),
                    )
                  : ListView(
                      key: const ValueKey('entity-sidebar-list'),
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                      children: items.toList(),
                    ),
            ),
          ],
        ),
      );
    });
  }

  String _statusLabel(String id) {
    final s = state.statuses[id];
    if (s == null) return 'stopped';
    if (s.isRunning) return 'running';
    return s.status;
  }

  // Start/stop control for an instance card. The card shell decides when to
  // mount it: hover, active lifecycle, or keyboard focus anywhere in the card.
  Widget _startStop(RedimosConfig c) {
    final st = state.statuses[c.id];
    final active = (st?.isRunning ?? false) || st?.status == 'restarting';
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      return IconButton(
        key: ValueKey('entity-card-${c.id}-start-stop'),
        tooltip: active ? tr('config.stop') : tr('config.start'),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        icon: Icon(active ? Icons.stop_circle : Icons.play_circle_fill,
            color: active ? t.danger : t.success),
        onPressed: () => cb.onStartStop(c),
      );
    });
  }

  // Stage 12: one Service card. Same shell grammar as instance/endpoint cards
  // (12.3 — shared primitives, semantic tokens); identity is the Service ID,
  // status comes from the runtime state, badge from the engine family.
  String _serviceBadge(ServiceEngine e) => switch (e) {
        ServiceEngine.java => 'JAVA',
        ServiceEngine.dockerDynamodb => 'DOCKER',
        ServiceEngine.localStack => 'STACK',
      };

  Widget _serviceCard(BuildContext context, ServiceInfo s) {
    final stateWire = s.runtime.state.name;
    final live = s.runtime.isLive;
    return _entityCardShell(
      cardKey: s.id,
      selected: s.id == state.selectedServiceId,
      hovered: s.id == state.hoveredCardId,
      onTap: () => cb.onSelectService(s.id),
      onHover: (h) => cb.onHoverCard(h ? s.id : null),
      dot: _statusDot(stateWire),
      badge: _serviceBadge(s.config.engine),
      name: s.config.name.isEmpty ? tr('service.unnamed') : s.config.name,
      sub: ':${s.config.port} · ${s.config.engine.wire}',
      sub2: stateWire,
      sub2Color: _statusColor(context, stateWire),
      trailing: _serviceStartStop(s),
      trailingVisible: state.hoveredCardId == s.id || live,
    );
  }

  // Start/stop control for a Service card — mirrors the instance affordance.
  Widget _serviceStartStop(ServiceInfo s) {
    final active = s.runtime.isLive;
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      return IconButton(
        key: ValueKey('entity-card-${s.id}-start-stop'),
        tooltip: active ? tr('service.stop') : tr('service.start'),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        icon: Icon(active ? Icons.stop_circle : Icons.play_circle_fill,
            color: active ? t.danger : t.success),
        onPressed: () => cb.onServiceStartStop(s),
      );
    });
  }

  // One entity card (mockup .ep-card): status dot + name + badge + mono
  // sub-line (+ optional start/stop). Selected = accent border + selection
  // fill + inset 2px left accent (mockup .ep-card.selected).
  Widget _entityCardShell({
    required String cardKey,
    required bool selected,
    required bool hovered,
    required VoidCallback onTap,
    void Function(bool)? onHover,
    required Widget dot,
    required String badge,
    required String name,
    required String sub,
    required String sub2,
    required Color sub2Color,
    Widget? trailing,
    bool trailingVisible = false,
  }) {
    return Builder(builder: (context) {
      final t = AppTokens.of(context);
      var cardFocused = false;
      return StatefulBuilder(builder: (context, setCardState) {
        final cardColor = selected
            ? t.selection
            : hovered
                ? t.hover
                : t.panel;
        final showTrailing =
            trailing != null && (trailingVisible || cardFocused);
        return Focus(
          skipTraversal: true,
          onFocusChange: (value) {
            if (cardFocused == value) return;
            setCardState(() => cardFocused = value);
          },
          child: Padding(
            key: ValueKey('entity-card-$cardKey'),
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            child: Material(
              key: ValueKey('entity-card-$cardKey-material'),
              color: cardColor,
              borderRadius: BorderRadius.circular(Dim.radiusM),
              child: InkWell(
                key: ValueKey('entity-card-$cardKey-action'),
                onTap: onTap,
                onHover: onHover,
                borderRadius: BorderRadius.circular(Dim.radiusM),
                hoverColor: Colors.transparent,
                focusColor: t.focus.withValues(alpha: 0.12),
                highlightColor: Colors.transparent,
                splashColor: Colors.transparent,
                child: Container(
                  key: ValueKey('entity-card-$cardKey-surface'),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(Dim.radiusM),
                    border: Border.all(
                      color: cardFocused
                          ? t.focus
                          : selected
                              ? t.accent
                              : t.border,
                      width: Dim.borderW,
                    ),
                    boxShadow: Depth.elev1(Theme.of(context).brightness),
                  ),
                  // 2px left selection indicator (.ep-card.selected inset 2px).
                  foregroundDecoration: selected
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(Dim.radiusM),
                          border: Border(
                            left: BorderSide(color: t.accent, width: 2),
                          ),
                        )
                      : null,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(children: [
                    dot,
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text(
                                name,
                                key: ValueKey('entity-card-$cardKey-name'),
                                overflow: TextOverflow.ellipsis,
                                style: Ts.style(
                                  size: 13,
                                  weight: FontWeight.w700,
                                  color: t.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              key: ValueKey('entity-card-$cardKey-badge'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: t.panel2,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: t.hairline),
                              ),
                              child: Text(
                                badge,
                                style: Ts.style(
                                  size: 9.5,
                                  weight: FontWeight.w700,
                                  color: t.text2,
                                  letterSpacing: 0.6,
                                  monoFont: true,
                                ),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Row(children: [
                            Flexible(
                              child: Text(
                                sub,
                                overflow: TextOverflow.ellipsis,
                                style: Ts.style(
                                  size: Ts.xs,
                                  color: t.text3,
                                  monoFont: true,
                                ),
                              ),
                            ),
                            if (sub2.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Text(
                                sub2,
                                style: Ts.style(
                                  size: Ts.xs,
                                  weight: FontWeight.w600,
                                  color: sub2Color,
                                  monoFont: true,
                                ),
                              ),
                            ],
                          ]),
                        ],
                      ),
                    ),
                    // The slot remains fixed while the action mounts for hover,
                    // active lifecycle, or keyboard focus within this card.
                    SizedBox(
                      key: ValueKey('entity-card-$cardKey-trailing-slot'),
                      width: Dim.trailingSlot,
                      height: Dim.trailingSlot,
                      child: showTrailing ? trailing : const SizedBox.shrink(),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      });
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
    return (u != null && u.host.isNotEmpty)
        ? (u.hasPort ? '${u.host}:${u.port}' : u.host)
        : url;
  }

  String _portLabel(String url) {
    final u = Uri.tryParse(url);
    if (u != null && u.hasPort) return ':${u.port}';
    return _hostOf(url);
  }

  CodexStatus _codexStatus(String status) => switch (status) {
        'running' || 'ready' => CodexStatus.running,
        'preparing' ||
        'restarting' ||
        'degraded' ||
        'stopping' ||
        'recovering' =>
          CodexStatus.warning,
        'error' || 'failed' || 'exited' || 'stopped' => CodexStatus.danger,
        _ => CodexStatus.neutral,
      };

  Color _statusColor(BuildContext context, String status) =>
      codexStatusColor(context, _codexStatus(status));

  Widget _statusDot(String status) => CodexStatusDot(
        status: _codexStatus(status),
        semanticLabel: 'Instance $status',
        glow: true,
      );
}

class _CodexPopupMenuItem<T> extends PopupMenuEntry<T> {
  const _CodexPopupMenuItem({
    super.key,
    required this.keyName,
    required this.value,
    required this.selected,
    required this.label,
    this.icon,
  });

  final String keyName;
  final T value;
  final bool selected;
  final String label;
  final IconData? icon;

  @override
  double get height => Dim.rowH;

  @override
  bool represents(T? value) => value == this.value;

  @override
  State<_CodexPopupMenuItem<T>> createState() => _CodexPopupMenuItemState<T>();
}

class _CodexPopupMenuItemState<T> extends State<_CodexPopupMenuItem<T>> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  void _setFocused(bool value) {
    if (_focused != value) setState(() => _focused = value);
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final base = widget.selected ? t.selection : Colors.transparent;
    final background = _pressed
        ? t.selection
        : _hovered
            ? Color.alphaBlend(t.hover, base)
            : _focused
                ? Color.alphaBlend(t.focus.withValues(alpha: 0.12), base)
                : base;
    final foreground = widget.selected ? t.accent : t.text;

    return MergeSemantics(
      child: Semantics(
        role: SemanticsRole.menuItem,
        enabled: true,
        button: true,
        selected: widget.selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('${widget.keyName}-action'),
            onTap: () => Navigator.pop<T>(context, widget.value),
            onHover: _setHovered,
            onFocusChange: _setFocused,
            onHighlightChanged: _setPressed,
            canRequestFocus: true,
            mouseCursor: SystemMouseCursors.click,
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            child: Container(
              key: ValueKey('${widget.keyName}-row'),
              height: Dim.rowH,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: background,
                border: Border.all(
                  color: _focused ? t.focus : Colors.transparent,
                  width: Dim.borderW,
                ),
                borderRadius: BorderRadius.circular(Dim.radiusS),
              ),
              child: Row(children: [
                SizedBox.square(
                  dimension: 18,
                  child: widget.icon == null
                      ? null
                      : Icon(
                          widget.icon,
                          key: ValueKey('${widget.keyName}-icon'),
                          size: 16,
                          color: foreground,
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    key: ValueKey('${widget.keyName}-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.style(
                      size: Ts.md,
                      weight:
                          widget.selected ? FontWeight.w600 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 16,
                  child: widget.selected
                      ? Icon(
                          Icons.check,
                          key: ValueKey('${widget.keyName}-check'),
                          size: 15,
                          color: t.accent,
                        )
                      : null,
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared chrome bits used both by HomeChrome and the capture channel.
// ---------------------------------------------------------------------------

/// Primary CTA for the mid-bar end slot and contextual actions.
Widget chromeCta(
    BuildContext context, IconData icon, String label, VoidCallback onPressed) {
  final t = AppTokens.of(context);
  final bg = t.accent;
  final fg = t.onAccent;
  return Padding(
    padding: const EdgeInsets.only(right: 6),
    child: SizedBox(
      height: 32, // mockup .pbtn: 32px, radius-sm 6 (CP 9.x round 2)
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16, color: fg),
        // Explicit label style: styleFrom(textStyle:) loses the font family
        // in widget tests (blocky fallback face) — see home sidebar button.
        label:
            Text(label, style: Ts.style(size: Ts.md, weight: FontWeight.w600)),
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

/// Compact app mark for the rail. It uses the theme accent directly rather
/// than a separate brand gradient, keeping light and dark chrome consistent.
class RedimosLogo extends StatelessWidget {
  const RedimosLogo({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.accent,
        borderRadius: BorderRadius.circular(Dim.radiusL),
        border: Border.all(color: t.onAccent.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.24 : 0.12),
            offset: const Offset(0, 2),
            blurRadius: 5,
          ),
        ],
      ),
      child: Text(
        'R',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: t.onAccent,
          height: 1,
        ),
      ),
    );
  }
}
