// The right pane when a Connect entry (a persisted Redis client connection)
// is selected in the rail's fourth group. Four screens behind the MidBar tabs
// (Configure / Browse / Console / Playground), kept alive in an IndexedStack
// exactly like EndpointDetailView. The Configure pane carries ONLY the NAME
// and REDIS sections — a connection is a client object, so host/database are
// real persisted fields here (unlike the instance Configure's mockup-only
// placeholders).

import 'package:flutter/material.dart';

import 'browser_page.dart';
import 'cmd_console.dart';
import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'playground_page.dart';
import 'redis_connection.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

class ConnectDetailView extends StatefulWidget {
  final NativeCore core;
  final RedisConnection connection;
  final int screenIndex;
  final Future<void> Function(RedisConnection saved)? onSave;
  final Future<void> Function()? onDelete;
  const ConnectDetailView({
    super.key,
    required this.core,
    required this.connection,
    this.screenIndex = 0,
    this.onSave,
    this.onDelete,
  });

  @override
  State<ConnectDetailView> createState() => _ConnectDetailViewState();
}

class _ConnectDetailViewState extends State<ConnectDetailView> {
  RedisConnection get c => widget.connection;

  // The three client screens take a RedimosConfig; synthesize one from the
  // connection (id-prefixed so didUpdateWidget generation checks see changes).
  RedimosConfig get _synthConfig => RedimosConfig(
        id: 'connect-${c.id}',
        name: c.name,
        port: c.port,
        requirepass: c.password,
      );

  List<Widget> get _screens => [
        ConnectConfigPane(
          key: ValueKey('connect-config-${c.id}'),
          connection: c,
          onSave: widget.onSave,
          onDelete: widget.onDelete,
        ),
        BrowserPageView(
          key: ValueKey('connect-browser-${c.id}'),
          config: _synthConfig,
          running: true,
          core: widget.core,
          host: c.host,
          database: c.database,
        ),
        CmdConsole(
          key: ValueKey('connect-console-${c.id}'),
          host: c.host,
          port: c.port,
          auth: c.password.isEmpty ? null : c.password,
          running: true,
          initialDb: c.database,
          instanceName: c.name,
        ),
        PlaygroundView(
          key: ValueKey('connect-playground-${c.id}'),
          core: widget.core,
          config: _synthConfig,
          kind: 'redis',
          running: true,
          host: c.host,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final screens = _screens;
    final i = widget.screenIndex.clamp(0, screens.length - 1);
    return SizedBox.expand(
      child: IndexedStack(
        index: i,
        children: [
          for (var screenIndex = 0;
              screenIndex < screens.length;
              screenIndex++)
            ExcludeFocus(
              key: ValueKey('connect-screen-$screenIndex-focus'),
              excluding: screenIndex != i,
              child: screens[screenIndex],
            ),
        ],
      ),
    );
  }
}

// The Connect Configure pane: numbered section cards in the house grammar
// (same shape as EndpointConfigPane), exactly two sections.
class ConnectConfigPane extends StatefulWidget {
  final RedisConnection connection;
  final Future<void> Function(RedisConnection saved)? onSave;
  final Future<void> Function()? onDelete;
  const ConnectConfigPane({
    super.key,
    required this.connection,
    this.onSave,
    this.onDelete,
  });

  @override
  State<ConnectConfigPane> createState() => _ConnectConfigPaneState();
}

class _ConnectConfigPaneState extends State<ConnectConfigPane>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _password;
  late final TextEditingController _database;
  late bool _tls;
  late bool _replica;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reseed();
  }

  @override
  void didUpdateWidget(ConnectConfigPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-seed only when the connection itself changes; poll-driven rebuilds
    // must not clobber in-progress edits.
    if (oldWidget.connection.id != widget.connection.id) _reseed();
  }

  void _reseed() {
    final c = widget.connection;
    _name = TextEditingController(text: c.name);
    _host = TextEditingController(text: c.host);
    _port = TextEditingController(text: '${c.port}');
    _password = TextEditingController(text: c.password);
    _database = TextEditingController(text: '${c.database}');
    _tls = c.tls;
    _replica = c.readOnlyReplica;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _password.dispose();
    _database.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.connection;
    final saved = RedisConnection(
      id: c.id,
      name: _name.text.trim(),
      host: _host.text.trim().isEmpty ? '127.0.0.1' : _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 6379,
      password: _password.text,
      database: int.tryParse(_database.text.trim()) ?? 0,
      tls: _tls,
      readOnlyReplica: _replica,
    );
    setState(() => _busy = true);
    try {
      await widget.onSave?.call(saved);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    final c = widget.connection;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('connect-delete-dialog'),
        title: Text(tr('connect.delete')),
        content: Text('${c.name.isEmpty ? tr('connect.unnamed') : c.name} '
            '${c.host}:${c.port}'),
        actions: [
          CodexButton(
            variant: CodexButtonVariant.secondary,
            semanticLabel: tr('home.cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            label: Text(tr('home.cancel')),
          ),
          CodexButton(
            key: const ValueKey('connect-delete-confirm'),
            variant: CodexButtonVariant.danger,
            semanticLabel: tr('home.delete'),
            onPressed: () => Navigator.pop(ctx, true),
            label: Text(tr('home.delete')),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onDelete?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppTokens.of(context);
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          key: const ValueKey('connect-config-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _section(t, '1', 'Name', [
              _field(t, _name, 'Connection name',
                  key: const ValueKey('connect-config-name')),
            ]),
            _section(t, '2', 'Redis', [
              _field(t, _host, 'Host', key: const ValueKey('connect-config-host')),
              _field(t, _port, 'Port',
                  number: true, key: const ValueKey('connect-config-port')),
              _field(t, _password, 'Password',
                  obscure: true, key: const ValueKey('connect-config-password')),
              _field(t, _database, 'Database',
                  number: true, key: const ValueKey('connect-config-database')),
              _switchField(t, 'TLS', _tls, (v) => setState(() => _tls = v)),
              _switchField(t, 'Read-only replica', _replica,
                  (v) => setState(() => _replica = v)),
            ]),
          ]),
        ),
      ),
      _actionBar(t),
    ]);
  }

  Widget _section(AppTokens t, String n, String title, List<Widget> fields) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CodexSurface(
        key: ValueKey('connect-config-section-$n'),
        variant: CodexSurfaceVariant.elevated,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: t.panel2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: BorderRadius.circular(Dim.radiusS),
                    ),
                    child: Text(
                      n,
                      style: Ts.style(
                        size: Ts.xs,
                        color: t.onAccent,
                        weight: FontWeight.w700,
                        monoFont: true,
                        tabularNums: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title.toUpperCase(),
                    style: Ts.style(
                      size: Ts.md,
                      letterSpacing: 0.9,
                      weight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                ]),
              ),
            ),
            const CodexDivider(),
            Padding(
              padding: const EdgeInsets.all(14),
              child: _grid(fields),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<Widget> fields) {
    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += 2) {
      final left = fields[i];
      final right = i + 1 < fields.length ? fields[i + 1] : null;
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right ?? const SizedBox.shrink()),
      ]));
      if (i + 2 < fields.length) rows.add(const SizedBox(height: 12));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _field(AppTokens t, TextEditingController c, String label,
      {bool number = false, bool obscure = false, Key? key}) {
    return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: Ts.style(
                  size: Ts.xs,
                  weight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: t.text3,
                  height: 14 / 11)),
          const SizedBox(height: 5),
          CodexTextField(
            controller: c,
            obscureText: obscure,
            keyboardType: number ? TextInputType.number : null,
            height: Dim.ctlH,
            style: Ts.style(size: Ts.md, color: t.text, monoFont: true),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ]);
  }

  Widget _switchField(
          AppTokens t, String label, bool value, ValueChanged<bool> on) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: Ts.style(
                size: Ts.xs,
                weight: FontWeight.w600,
                letterSpacing: 0.5,
                color: t.text3,
                height: 14 / 11)),
        const SizedBox(height: 5),
        SizedBox(
          height: 19,
          child: Row(children: [
            _ConnectSwitch(label: label, value: value, onChanged: on),
            const SizedBox(width: 8),
            Flexible(
              child: Text(value ? 'on' : 'off',
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(size: Ts.md, color: t.text2)),
            ),
          ]),
        ),
      ]);

  Widget _actionBar(AppTokens t) {
    return Container(
      key: const ValueKey('connect-config-action-bar'),
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        const Spacer(),
        CodexButton(
          key: const ValueKey('connect-config-revert'),
          variant: CodexButtonVariant.secondary,
          semanticLabel: tr('home.revert'),
          onPressed: _busy
              ? null
              : () {
                  _reseed();
                  setState(() {});
                },
          icon: const Icon(Icons.restore, size: 15),
          label: Text(tr('home.revert')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('connect-config-delete'),
          variant: CodexButtonVariant.danger,
          semanticLabel: tr('home.delete'),
          onPressed: _busy ? null : _confirmDelete,
          icon: const Icon(Icons.delete_outline, size: 15),
          label: Text(tr('home.delete')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('connect-config-save'),
          variant: CodexButtonVariant.primary,
          semanticLabel: tr('home.save'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 15),
          label: Text(tr('home.save')),
        ),
      ]),
    );
  }
}

// The 34×19 house switch (same footprint as configure_page's).
class _ConnectSwitch extends StatefulWidget {
  const _ConnectSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_ConnectSwitch> createState() => _ConnectSwitchState();
}

class _ConnectSwitchState extends State<_ConnectSwitch> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Semantics(
      label: widget.label,
      toggled: widget.value,
      button: true,
      onTap: () => widget.onChanged(!widget.value),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => widget.onChanged(!widget.value),
          onFocusChange: (next) {
            if (_focused == next) return;
            setState(() => _focused = next);
          },
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: t.hover,
          focusColor: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 19,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: widget.value ? t.accent : t.border,
              border: Border.all(
                color: _focused ? t.focus : Colors.transparent,
                width: Dim.borderW,
              ),
            ),
            child: Align(
              alignment:
                  widget.value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  color: widget.value ? t.onAccent : t.panel,
                  shape: BoxShape.circle,
                  border: Border.all(color: t.hairline),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
