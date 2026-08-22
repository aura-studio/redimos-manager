// Stage 13: the Service Configure screen — create/edit form + safe delete.
//
// House grammar follows the instance ConfigEditor (configure_page.dart):
// numbered section cards over a two-column field grid, a pinned action bar
// (Revert / Delete / Save). Two safety layers compose:
//
// * Client-side validation mirrors the Core's rules for instant feedback
//   (2.2/2.5/2.8): required name, case-folded name uniqueness among peers,
//   port 0..65535 + configured-port uniqueness, engine-conditional custom
//   storage location. Core validation remains the authoritative boundary.
// * Runtime identity lock (2.7): while the Service is live, the fields that
//   define process/container identity (engine, port, storage mode/location)
//   are disabled — never cleared, so a rejected save never loses user input.
//
// Deletion follows requirement 10: a first confirmation names the Service,
// its state, engine, and data location with data cleanup UNCHECKED by
// default; selecting cleanup raises a second destructive confirmation. The
// result distinguishes preserved data, proven-and-cleaned data, manual
// cleanup instructions, and partial deletion (retryable).

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';
import 'ui_fields.dart';
import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

class ServiceConfigEditor extends StatefulWidget {
  /// The current core view of ONE Service (identity + live runtime).
  final ServiceInfo service;

  /// Every OTHER Service — used for instant name/port conflict feedback.
  final List<ServiceInfo> peers;

  final NativeCore core;

  /// Fired after a successful save with the Service as the core sees it.
  final ValueChanged<ServiceInfo> onSaved;

  /// Fired after a fully successful delete with the removed ID.
  final ValueChanged<String> onDeleted;

  const ServiceConfigEditor({
    super.key,
    required this.service,
    required this.peers,
    required this.core,
    required this.onSaved,
    required this.onDeleted,
  });

  @override
  State<ServiceConfigEditor> createState() => ServiceConfigEditorState();
}

class ServiceConfigEditorState extends State<ServiceConfigEditor> {
  late final TextEditingController _name;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _volume;
  late final TextEditingController _heap;
  late final TextEditingController _servicesOpt;

  late ServiceEngine _engine;
  late ServiceStorageMode _storageMode;

  // Field-level errors (client validation or mapped Core taxonomy codes).
  String? _nameError;
  String? _portError;
  String? _storageError;
  String? _formError;

  bool _busy = false;

  /// 2.7: identity fields lock while the Service is live. The lock only
  /// DISABLES the controls — values stay in place, so stopping the Service
  /// restores exactly what the user last saw.
  bool get _locked => widget.service.runtime.isLive;

  @override
  void initState() {
    super.initState();
    final c = widget.service.config;
    _name = TextEditingController(text: c.name);
    _port = TextEditingController(text: c.port.toString());
    _path = TextEditingController(text: c.storage.path);
    _volume = TextEditingController(text: c.storage.volume);
    _heap = TextEditingController(
        text: (c.engineOptions['heap'] ?? '').toString());
    _servicesOpt = TextEditingController(
        text: (c.engineOptions['SERVICES'] ?? '').toString());
    _engine = c.engine;
    _storageMode = _displayStorageMode(c);
    _prefillVolume();
  }

  /// v1.1.5 storage mapping: the form offers In-memory / Persisted only.
  /// `managed` is read for legacy data and displays as Persisted — saving
  /// persists whatever the location fields hold (custom), except LocalStack,
  /// whose storage stays core-managed.
  ServiceStorageMode _displayStorageMode(ServiceConfig c) =>
      c.storage.mode == ServiceStorageMode.memory
          ? ServiceStorageMode.memory
          : ServiceStorageMode.custom;

  /// Docker Persisted default volume: `redimos-service-<id>-data` — reused
  /// when present, created when absent (requirement 3).
  void _prefillVolume() {
    if (_engine == ServiceEngine.java ||
        _storageMode != ServiceStorageMode.custom) {
      return;
    }
    if (_volume.text.trim().isNotEmpty) {
      return;
    }
    final id = widget.service.id;
    if (id.isEmpty) {
      return;
    }
    _volume.text = 'redimos-service-$id-data';
  }

  @override
  void dispose() {
    for (final ctl in [_name, _port, _path, _volume, _heap, _servicesOpt]) {
      ctl.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(ServiceConfigEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Polling refreshes the SAME widget with new runtime snapshots; the form
    // must keep whatever the user typed (13.2 "preserve user input"). Only a
    // different Service re-seeds the fields.
    if (oldWidget.service.id != widget.service.id) _reseed();
  }

  void _reseed() {
    final c = widget.service.config;
    _name.text = c.name;
    _port.text = c.port.toString();
    _path.text = c.storage.path;
    _volume.text = c.storage.volume;
    _heap.text = (c.engineOptions['heap'] ?? '').toString();
    _servicesOpt.text = (c.engineOptions['SERVICES'] ?? '').toString();
    setState(() {
      _engine = c.engine;
      _storageMode = _displayStorageMode(c);
      _prefillVolume();
      _clearErrors();
    });
  }

  void _clearErrors() {
    _nameError = null;
    _portError = null;
    _storageError = null;
    _formError = null;
  }

  // ---- client-side validation (mirrors native/service.go's rules) ---------

  static String _fold(String s) => s.trim().toLowerCase();

  bool _validate() {
    _clearErrors();
    final name = _name.text.trim();
    if (name.isEmpty) _nameError = tr('svc.nameRequired');
    final fold = _fold(name);
    if (name.isNotEmpty &&
        widget.peers.any((p) => _fold(p.config.name) == fold)) {
      _nameError = tr('svc.nameTaken');
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 0 || port > 65535) {
      _portError = tr('svc.portInvalid');
    } else if (port != 0 &&
        widget.peers.any((p) => p.config.port != 0 && p.config.port == port)) {
      _portError = tr('svc.portTaken');
    }
    if (_storageMode == ServiceStorageMode.custom &&
        _engine != ServiceEngine.localStack) {
      if (_engine == ServiceEngine.java && _path.text.trim().isEmpty) {
        _storageError = tr('svc.pathRequired');
      } else if (_engine != ServiceEngine.java &&
          _volume.text.trim().isEmpty) {
        _storageError = tr('svc.volumeRequired');
      }
    }
    final ok = _nameError == null && _portError == null && _storageError == null;
    if (!ok) setState(() {});
    return ok;
  }

  ServiceConfig _collect() {
    final c = widget.service.config;
    final options = <String, dynamic>{};
    if (_engine == ServiceEngine.java && _heap.text.trim().isNotEmpty) {
      options['heap'] = _heap.text.trim();
    }
    if (_engine == ServiceEngine.localStack &&
        _servicesOpt.text.trim().isNotEmpty) {
      options['SERVICES'] = _servicesOpt.text.trim();
    }
    return ServiceConfig(
      id: c.id, // immutable identity — the form never invents IDs (2.1)
      name: _name.text.trim(),
      engine: _engine,
      port: int.tryParse(_port.text.trim()) ?? 0,
      storage: _engine == ServiceEngine.localStack
          // LocalStack storage is core-managed; the UI exposes no fields (2.4).
          ? ServiceStorage(mode: ServiceStorageMode.managed)
          : ServiceStorage(
              mode: _storageMode,
              // Keep only the location field the selected engine reads; the
              // other one stays out of the persisted payload.
              path: _engine == ServiceEngine.java ? _path.text.trim() : '',
              volume: _engine != ServiceEngine.java ? _volume.text.trim() : '',
            ),
      engineOptions: options,
      desiredRunning: c.desiredRunning, // lifecycle-owned, never form-owned
    );
  }

  Future<void> _save() async {
    if (_busy || !_validate()) return;
    setState(() => _busy = true);
    try {
      final saved = widget.core.serviceSave(_collect());
      _clearErrors();
      _toast(tr('svc.saved'));
      widget.onSaved(saved);
    } on ServiceApiException catch (e) {
      // Map the taxonomy onto the responsible field (UI behavior: form errors
      // render at the field; everything else is a non-replacing banner).
      switch (e.code) {
        case 'duplicate_name':
          _nameError = e.message;
        case 'port_conflict':
          _portError = e.message;
        case 'invalid_request':
        case 'unsafe_data_path':
        case 'unowned_volume':
          _formError = e.message;
        default:
          _formError = '${e.code}: ${e.message}';
      }
    } catch (e) {
      _formError = '${tr('svc.saveFailed')}: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- safe delete (requirement 10) ----------------------------------------

  String get _dataLocationLabel {
    final s = widget.service.config.storage;
    return switch (s.mode) {
      ServiceStorageMode.memory => tr('svc.location.memory'),
      ServiceStorageMode.managed => tr('svc.location.managed'),
      ServiceStorageMode.custom =>
        _engine == ServiceEngine.java
            ? (s.path.isEmpty ? tr('svc.storage.custom') : s.path)
            : (s.volume.isEmpty ? tr('svc.storage.custom') : s.volume),
    };
  }

  Future<void> _confirmDelete() async {
    final svc = widget.service;
    var deleteData = false; // 10.2 default: preserve data
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          key: const ValueKey('service-delete-dialog'),
          title: Text(tr('svc.deleteTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${tr('svc.name')}: ${svc.config.name.isEmpty ? tr('service.unnamed') : svc.config.name}',
              ),
              Text('${tr('svc.state')}: ${svc.runtime.state.name}'),
              Text('${tr('svc.engine')}: ${svc.config.engine.wire}'),
              Text('${tr('svc.dataLocation')}: $_dataLocationLabel'),
              const SizedBox(height: 12),
              Text(tr('svc.deleteBody')),
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    key: const ValueKey('service-delete-data-check'),
                    value: deleteData,
                    onChanged: (v) =>
                        setDialogState(() => deleteData = v ?? false),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(tr('svc.deleteDataCheck'))),
              ]),
              Text(
                tr('svc.deleteDataPreserved'),
                style: Ts.style(size: Ts.xs, color: AppTokens.of(ctx).text3),
              ),
            ],
          ),
          actions: [
            CodexButton(
              variant: CodexButtonVariant.secondary,
              semanticLabel: tr('home.cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              label: Text(tr('home.cancel')),
            ),
            CodexButton(
              key: const ValueKey('service-delete-confirm'),
              variant: CodexButtonVariant.danger,
              semanticLabel: tr('home.delete'),
              onPressed: () => Navigator.pop(ctx, true),
              label: Text(tr('home.delete')),
            ),
          ],
        ),
      ),
    );
    if (proceed != true || !mounted) return;

    // 10.3: cleanup needs a SECOND, explicitly destructive confirmation.
    if (deleteData) {
      final destructive = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('service-delete-destructive-dialog'),
          title: Text(tr('svc.deleteDestructiveTitle')),
          content: Text(
              '"${svc.config.name}" ${tr('svc.deleteDestructiveBody')} ${tr('home.cannotBeUndone')}'),
          actions: [
            CodexButton(
              variant: CodexButtonVariant.secondary,
              semanticLabel: tr('home.cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              label: Text(tr('home.cancel')),
            ),
            CodexButton(
              key: const ValueKey('service-delete-destructive-confirm'),
              variant: CodexButtonVariant.danger,
              semanticLabel: tr('svc.deleteData'),
              onPressed: () => Navigator.pop(ctx, true),
              label: Text(tr('svc.deleteData')),
            ),
          ],
        ),
      );
      if (destructive != true || !mounted) return;
    }

    await _doDelete(deleteData);
  }

  Future<void> _doDelete(bool deleteData) async {
    final id = widget.service.id;
    setState(() => _busy = true);
    try {
      final res = widget.core.serviceDelete(id, deleteData: deleteData);
      if (res.partial) {
        // 10.7: never silently complete — the config stays, retryable.
        _formError = tr('svc.partialDelete');
        setState(() {});
        return;
      }
      widget.onDeleted(id);
      if (!mounted) return;
      if (res.manualCleanup.isNotEmpty) {
        // 10.6: unprovable data is preserved; surface the manual steps.
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            key: const ValueKey('service-delete-cleanup-dialog'),
            title: Text(tr('svc.manualCleanupTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('svc.manualCleanupBody')),
                const SizedBox(height: 8),
                for (final line in res.manualCleanup) Text('· $line'),
              ],
            ),
            actions: [
              CodexButton(
                variant: CodexButtonVariant.secondary,
                semanticLabel: 'OK',
                onPressed: () => Navigator.pop(ctx),
                label: const Text('OK'),
              ),
            ],
          ),
        );
      } else if (deleteData && res.dataCleaned) {
        _toast(tr('svc.deleted'));
      } else {
        _toast('${tr('svc.deleted')} · ${tr('svc.dataKept')}');
      }
    } on ServiceApiException catch (e) {
      _formError = '${e.code}: ${e.message}';
      setState(() {});
    } catch (e) {
      _formError = '${tr('svc.deleteFailed')}: $e';
      setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- layout ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          key: const ValueKey('service-configure-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_locked)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(children: [
                  Icon(Icons.lock_outline, size: 14, color: t.warning),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tr('svc.identityLocked'),
                      key: const ValueKey('service-config-locked-hint'),
                      style: Ts.style(size: Ts.sm, color: t.warning),
                    ),
                  ),
                ]),
              ),
            _section(t, '1', tr('svc.identitySection'), [
              _field(t, _name, tr('svc.name'),
                  key: const ValueKey('service-config-name'),
                  error: _nameError),
              _field(t, _port, tr('svc.port'),
                  key: const ValueKey('service-config-port'),
                  number: true,
                  enabled: !_locked,
                  placeholder: tr('svc.portHint'),
                  error: _portError),
              // 0 = engine default: name the effective port (1.3).
              if (_port.text.trim() == '0')
                Padding(
                  key: const ValueKey('service-config-port-default'),
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    '${tr('svc.portDefault')} ${_engine == ServiceEngine.localStack ? 4566 : 8000}',
                    style: Ts.style(size: Ts.sm, color: t.text3),
                  ),
                ),
            ]),
            _section(t, '2', tr('svc.engineSection'), [
              _selectField<ServiceEngine>(
                t,
                tr('svc.engine'),
                key: const ValueKey('service-config-engine'),
                value: _engine,
                enabled: !_locked,
                items: [
                  (ServiceEngine.java, tr('svc.engine.java')),
                  (ServiceEngine.dockerDynamodb, tr('svc.engine.docker')),
                  (ServiceEngine.localStack, tr('svc.engine.localstack')),
                ],
                onChanged: (v) => setState(() {
                  _engine = v ?? ServiceEngine.java;
                  _prefillVolume();
                }),
              ),
              // Engine-conditional options: JVM heap for the Java engine, the
              // SERVICES list for LocalStack. Docker DynamoDB Local has none.
              if (_engine == ServiceEngine.java)
                _field(t, _heap, tr('svc.heap'),
                    key: const ValueKey('service-config-heap'),
                    placeholder: tr('svc.heapHint')),
              if (_engine == ServiceEngine.localStack)
                _field(t, _servicesOpt, tr('svc.servicesOpt'),
                    key: const ValueKey('service-config-services'),
                    placeholder: tr('svc.servicesOptHint')),
            ]),
            _section(t, '3', tr('svc.storageSection'), [
              if (_engine == ServiceEngine.localStack)
                // LocalStack owns its storage; the UI only explains it (2.4).
                Padding(
                  key: const ValueKey('service-config-localstack-storage'),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Icon(Icons.storage_outlined, size: 15, color: t.text3),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        tr('svc.storage.localstackManaged'),
                        style: Ts.style(size: Ts.md, color: t.text2),
                      ),
                    ),
                  ]),
                )
              else ...[
                _selectField<ServiceStorageMode>(
                  t,
                  tr('svc.storage'),
                  key: const ValueKey('service-config-storage'),
                  value: _storageMode,
                  enabled: !_locked,
                  items: [
                    (ServiceStorageMode.memory, tr('svc.storage.memory')),
                    (ServiceStorageMode.custom, tr('svc.storage.persisted')),
                  ],
                  onChanged: (v) => setState(() {
                    _storageMode = v ?? ServiceStorageMode.memory;
                    _prefillVolume();
                  }),
                ),
                // Engine-conditional location for Persisted storage (java owns
                // a directory path; the docker engine owns a volume name that
                // is reused when present and created when absent).
                if (_storageMode == ServiceStorageMode.custom)
                  _engine == ServiceEngine.java
                      ? _field(t, _path, tr('svc.storage.path'),
                          key: const ValueKey('service-config-path'),
                          enabled: !_locked,
                          placeholder: tr('svc.storage.pathHint'),
                          error: _storageError)
                      : _field(t, _volume, tr('svc.storage.volume'),
                          key: const ValueKey('service-config-volume'),
                          enabled: !_locked,
                          placeholder: tr('svc.storage.volumeHint'),
                          error: _storageError),
              ],
            ]),
            if (_formError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _formError!,
                  key: const ValueKey('service-config-form-error'),
                  style: Ts.style(size: Ts.sm, color: t.danger),
                ),
              ),
            const SizedBox(height: 16),
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
        key: ValueKey('service-config-section-$n'),
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
      {Key? key,
      bool number = false,
      bool enabled = true,
      String? placeholder,
      String? error}) {
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
            key: key == null ? null : ValueKey('${(key as ValueKey).value}-input'),
            controller: c,
            enabled: enabled,
            hasError: error != null,
            keyboardType: number ? TextInputType.number : null,
            height: Dim.ctlH,
            style: Ts.style(size: Ts.md, color: t.text, monoFont: true),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle:
                  Ts.style(size: Ts.md, color: t.text3, monoFont: true),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: ValueKey('${(key! as ValueKey).value}-error'),
                style: Ts.style(size: Ts.xs, color: t.danger),
              ),
            ),
        ]);
  }

  Widget _selectField<T>(AppTokens t, String label,
      {Key? key,
      required T value,
      required List<(T, String)> items,
      required ValueChanged<T?> onChanged,
      bool enabled = true}) {
    final style = Ts.style(size: Ts.md, color: t.text, monoFont: true);
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
          CodexSelectField<T>(
            value: value,
            enabled: enabled,
            style: style,
            items: [
              for (final (itemValue, itemLabel) in items)
                DropdownMenuItem<T>(
                  value: itemValue,
                  child: Text(
                    itemLabel,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
            ],
            onChanged: onChanged,
          ),
        ]);
  }

  Widget _actionBar(AppTokens t) {
    return Container(
      key: const ValueKey('service-config-action-bar'),
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(children: [
        const Spacer(),
        CodexButton(
          key: const ValueKey('service-config-revert'),
          variant: CodexButtonVariant.secondary,
          semanticLabel: tr('home.revert'),
          onPressed: _busy ? null : _reseed,
          icon: const Icon(Icons.restore, size: 15),
          label: Text(tr('home.revert')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('service-config-delete'),
          variant: CodexButtonVariant.danger,
          semanticLabel: tr('home.delete'),
          onPressed: _busy ? null : _confirmDelete,
          icon: const Icon(Icons.delete_outline, size: 15),
          label: Text(tr('home.delete')),
        ),
        const SizedBox(width: 8),
        CodexButton(
          key: const ValueKey('service-config-save'),
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
