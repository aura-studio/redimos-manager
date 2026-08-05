// Shared table-lifecycle operations (Purge items / Recreate / Provision /
// Delete table) with their friction-ladder confirm dialogs. Two surfaces host
// these: the full-width Endpoint tab (EndpointPageView) and the endpoint
// Browser's compact Tables sidebar (EndpointBrowserView) — both delegate here
// so the guards, confirmations and flows stay identical.
//
// The flows are unchanged from the original EndpointPageView implementation:
// inspect-precheck → confirm (type-the-name / big-table ack) → progress dialog
// → native op → refresh. Write gating (AWS read-only) happens BEFORE calling
// into this class, exactly as before.

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'native.dart';

const _green = Color(0xFF3BA55D);

class TableLifecycle {
  TableLifecycle({
    required this.core,
    required this.config,
    required this.toast,
    required this.onChanged,
    required this.setBusy,
  });

  final NativeCore core;

  /// The config through which the hosting view looks at the endpoint. Its id is
  /// the fallback when picking which bound config authors a recreate/provision.
  ///
  /// Deliberately NOT final: hosts must refresh it in `didUpdateWidget`
  /// (`_lc.config = widget.config;`) so every op runs against the currently
  /// selected endpoint. Ops read it at call time; a value captured once at
  /// `initState` would go stale as soon as the sidebar selection changes.
  RedimosConfig config;

  /// Snackbar reporter of the hosting widget.
  final void Function(String message, {bool error}) toast;

  /// Called after a successful op so the host refreshes its table list.
  final VoidCallback onChanged;

  /// Lets the host mirror the busy flag (disable menus/buttons while a flow
  /// with dialogs is in flight).
  final ValueChanged<bool> setBusy;

  bool _busy = false;
  bool get busy => _busy;

  // Picks which bound config should author a recreate/provision of a table:
  // the config the host is viewing first (its version is what its Table view
  // shows), else one whose version matches the row's detected kind, else the
  // first bound config. Otherwise a v1+v2 shared-table misconfig could rebuild
  // with the wrong keys.
  static String? authoringConfig(List<Map> usedBy, String? kind, String viewedConfigId) {
    if (usedBy.isEmpty) return null;
    for (final u in usedBy) {
      if (u['id'] == viewedConfigId) return u['id']?.toString(); // the viewed config
    }
    if (kind == 'v1' || kind == 'v2') {
      for (final u in usedBy) {
        if (u['version']?.toString() == kind) return u['id']?.toString(); // version match
      }
    }
    return usedBy.first['id']?.toString();
  }

  // ---- purge (empty items) / delete (drop table) — act on any table by name ----

  Future<void> purge(BuildContext context, String table) async {
    if (_busy) return;
    _busy = true;
    setBusy(true); // gate the host's menus during the whole flow
    try {
      final pre = await core.tableInspect(config, table);
      if (!context.mounted) return;
      if (pre['ok'] != true) {
        toast('${pre['error'] ?? tr('ep.inspectFailed')}', error: true);
        return;
      }
      if (pre['allowed'] != true) {
        toast('${pre['reason'] ?? tr('ep.notAllowed')}', error: true);
        return;
      }
      if (await _confirmDestroy(context, pre: pre, table: table, isDelete: false) != true ||
          !context.mounted) {
        return;
      }
      final progress = _progressDialog(context, tr('ep.purgingItems'));
      Map<String, dynamic> res;
      try {
        res = await core.tablePurge(config, table);
      } catch (e) {
        res = {'ok': false, 'error': '$e'};
      }
      if (context.mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await progress;
      if (!context.mounted) return;
      if (res['ok'] == true) {
        final n = (res['deleted'] as num?)?.toInt() ?? 0;
        toast(trp('ep.purgedItems', {'n': '$n', 'table': table}));
        onChanged();
      } else {
        toast('${res['error'] ?? tr('ep.purgeFailed')}', error: true);
      }
    } finally {
      _busy = false;
      setBusy(false);
    }
  }

  Future<void> delete(BuildContext context, String table) async {
    if (_busy) return;
    _busy = true; // gate the host's menus during the whole flow
    setBusy(true);
    try {
      final pre = await core.tableInspect(config, table);
      if (!context.mounted) return;
      if (pre['ok'] != true) {
        toast('${pre['error'] ?? tr('ep.inspectFailed')}', error: true);
        return;
      }
      if (pre['allowed'] != true) {
        toast('${pre['reason'] ?? tr('ep.notAllowed')}', error: true);
        return;
      }
      if (await _confirmDestroy(context, pre: pre, table: table, isDelete: true) != true ||
          !context.mounted) {
        return;
      }
      final progress = _progressDialog(context, tr('ep.deletingTable'));
      Map<String, dynamic> res;
      try {
        res = await core.tableDelete(config, table);
      } catch (e) {
        res = {'ok': false, 'error': '$e'};
      }
      if (context.mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await progress;
      if (!context.mounted) return;
      if (res['ok'] == true) {
        toast('${tr('ep.deletedTable')} "$table"');
        onChanged();
      } else {
        toast('${res['error'] ?? tr('ep.deleteFailed')}', error: true);
      }
    } finally {
      _busy = false;
      setBusy(false);
    }
  }

  // ---- recreate / provision (reuses the existing precheck + async recreate) ----

  Future<void> recreate(BuildContext context, String configId,
      {required bool provision}) async {
    if (_busy) return;
    final pre = core.tablePrecheck(configId);
    if (pre['ok'] != true) {
      toast('${pre['error'] ?? tr('ep.precheckFailed')}', error: true);
      return;
    }
    if (pre['allowed'] != true) {
      toast('${pre['reason'] ?? tr('ep.notAllowed')}', error: true);
      return;
    }
    final go = await _confirm(context, pre: pre, provision: provision);
    if (go != true || !context.mounted) return;

    _busy = true;
    setBusy(true);
    final progress = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Text(provision ? tr('ep.provisioningTable') : tr('ep.recreatingTable')),
        ]),
      ),
    );
    Map<String, dynamic> res;
    try {
      res = await core.tableRecreate(configId);
    } catch (e) {
      res = {'ok': false, 'error': '$e'};
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).maybePop();
    await progress;
    if (!context.mounted) return;
    _busy = false;
    setBusy(false);
    if (res['ok'] == true) {
      final warn = res['warning'];
      toast(provision
          ? tr('ep.tableProvisioned')
          : (warn != null ? '${tr('ep.tableRecreated')} — $warn' : tr('ep.tableRecreated')));
      onChanged();
    } else {
      toast('${res['error'] ?? tr('ep.operationFailed')}', error: true);
    }
  }

  // ---- dialogs ----

  Future<void> _progressDialog(BuildContext context, String label) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Text(label),
          ]),
        ),
      );

  // Confirmation for Purge/Delete with the same friction ladder as Recreate:
  // non-loopback (or any Delete) → type the table name; large/old table → an extra
  // acknowledgement checkbox.
  Future<bool?> _confirmDestroy(BuildContext context,
      {required Map<String, dynamic> pre,
      required String table,
      required bool isDelete}) async {
    final scheme = Theme.of(context).colorScheme;
    final endpoint = pre['endpoint']?.toString() ?? '';
    final loopback = pre['loopback'] == true;
    final itemCount = (pre['itemCount'] as num?)?.toInt() ?? -1;
    final ageDays = (pre['ageDays'] as num?)?.toInt() ?? -1;
    final deps = ((pre['dependents'] as List?) ?? []).cast<Map>();
    final runningDeps = deps.where((d) => d['running'] == true).toList();
    // Delete drops the table entirely → always type the name. Purge keeps the table
    // → require the name only on a non-loopback (possibly shared) endpoint.
    final needsName = isDelete || !loopback;
    // An unknown item count (DescribeTable failed, or DynamoDB's ~6h-stale ItemCount
    // reads 0 for a freshly bulk-loaded table) must NOT skip friction — treat it as big.
    final bigOrOld = (itemCount < 0) || (itemCount > 100000) || (ageDays > 30);
    final countStr = itemCount < 0
        ? tr('ep.unknownItemCount')
        : trp('ep.approxItems', {'n': fmtInt(itemCount)});
    final nameCtrl = TextEditingController();
    var ack = false;
    try {
      return await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
          final ok = (!needsName || nameCtrl.text == table) && (!bigOrOld || ack);
          return AlertDialog(
            title: Text(isDelete
                ? '${tr('ep.deleteTable')} "$table"?'
                : '${tr('ep.purgeAllItemsFrom')} "$table"?'),
            content: SizedBox(
              width: 460,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isDelete
                        ? trp('danger.deleteTableBody',
                            {'endpoint': endpoint, 'count': countStr})
                        : trp('danger.purgeItemsBody',
                            {'endpoint': endpoint, 'count': countStr})),
                    if (runningDeps.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        isDelete
                            ? trp('danger.deleteStopsConfigs',
                                {'n': '${runningDeps.length}'})
                            : '${runningDeps.length} ${tr('ep.runningConfigsStayUp')}',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final d in runningDeps)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.circle, size: 10, color: _green),
                            label: Text('${d['name']}'),
                          ),
                      ]),
                    ],
                    if (needsName) ...[
                      const SizedBox(height: 12),
                      if (!loopback) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(children: [
                            const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                  trp('danger.sharedEnvWarning', {'endpoint': endpoint}),
                                  style: TextStyle(
                                      fontSize: 12.5, color: Colors.orange.shade900)),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(tr('ep.typeTableName'),
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameCtrl,
                        autofocus: true,
                        decoration: InputDecoration(
                            hintText: table,
                            border: const OutlineInputBorder(),
                            isDense: true),
                        onChanged: (_) => setD(() {}),
                      ),
                    ],
                    if (bigOrOld) ...[
                      const SizedBox(height: 6),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: ack,
                        onChanged: (v) => setD(() => ack = v ?? false),
                        title: Text(
                          trp('ep.ackUnderstand', {
                            'count': itemCount < 0
                                ? tr('ep.ackCountMany')
                                : trp('ep.approxItems', {'n': fmtInt(itemCount)}),
                            'age': ageDays > 0
                                ? trp('ep.ackAge', {'d': '$ageDays'})
                                : '',
                          }),
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false), child: Text(tr('ep.cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: scheme.error),
                onPressed: ok ? () => Navigator.pop(ctx, true) : null,
                child: Text(isDelete ? tr('ep.delete') : tr('ep.purge')),
              ),
            ],
          );
        }),
      );
    } finally {
      nameCtrl.dispose();
    }
  }

  Future<bool?> _confirm(BuildContext context,
      {required Map<String, dynamic> pre, required bool provision}) async {
    final scheme = Theme.of(context).colorScheme;
    final table = pre['table']?.toString() ?? '';
    final endpoint = pre['endpoint']?.toString() ?? '';
    final loopback = pre['loopback'] == true;
    final itemCount = (pre['itemCount'] as num?)?.toInt() ?? -1;
    final ageDays = (pre['ageDays'] as num?)?.toInt() ?? -1;
    final version = pre['version']?.toString() ?? '';
    final deps = ((pre['dependents'] as List?) ?? []).cast<Map>();
    final runningDeps = deps.where((d) => d['running'] == true).toList();
    final needsName = !loopback && !provision;
    final nameCtrl = TextEditingController();
    final countStr = itemCount < 0
        ? tr('ep.unknownItemCount')
        : trp('ep.approxItems', {'n': fmtInt(itemCount)});
    // Extra friction when destroying a large or old table — recreate only, since
    // provision creates an empty table and there is nothing to lose.
    final bigOrOld = !provision && ((itemCount < 0) || (itemCount > 100000) || (ageDays > 30));
    var ack = false;

    try {
      return await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
          final ok = (!needsName || nameCtrl.text == table) && (!bigOrOld || ack);
          return AlertDialog(
            title: Text(provision
                ? '${tr('ep.provisionTable')} "$table"?'
                : '${tr('ep.recreateTable')} "$table"?'),
            content: SizedBox(
              width: 460,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(provision
                        ? trp('danger.provisionTableBody', {
                            'endpoint': endpoint,
                            'version': version.isEmpty
                                ? ''
                                : trp('danger.versionKeys', {'version': version}),
                          })
                        : trp('danger.recreateTableBody',
                            {'endpoint': endpoint, 'count': countStr})),
                    if (runningDeps.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        trp(provision ? 'danger.provisionStepsBody' : 'danger.recreateStepsBody',
                            {'n': '${runningDeps.length}'}),
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final d in runningDeps)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.circle, size: 10, color: _green),
                            label: Text('${d['name']}'),
                          ),
                      ]),
                    ],
                    if (needsName) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(children: [
                          const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(trp('danger.sharedEnvWarning', {'endpoint': endpoint}),
                                style: TextStyle(fontSize: 12.5, color: Colors.orange.shade900)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Text(tr('ep.typeTableName'),
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameCtrl,
                        autofocus: true,
                        decoration: InputDecoration(
                            hintText: table, border: const OutlineInputBorder(), isDense: true),
                        onChanged: (_) => setD(() {}),
                      ),
                    ],
                    if (bigOrOld) ...[
                      const SizedBox(height: 6),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: ack,
                        onChanged: (v) => setD(() => ack = v ?? false),
                        title: Text(
                          trp('ep.ackUnderstand', {
                            'count': itemCount < 0
                                ? tr('ep.ackCountMany')
                                : trp('ep.approxItems', {'n': fmtInt(itemCount)}),
                            'age': ageDays > 0
                                ? trp('ep.ackAge', {'d': '$ageDays'})
                                : '',
                          }),
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false), child: Text(tr('ep.cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: provision ? scheme.primary : scheme.error),
                onPressed: ok ? () => Navigator.pop(ctx, true) : null,
                child: Text(provision ? tr('ep.provision') : tr('ep.recreate')),
              ),
            ],
          );
        }),
      );
    } finally {
      nameCtrl.dispose();
    }
  }

  // ---- shared formatting helpers ----

  static String fmtInt(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  static String fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
