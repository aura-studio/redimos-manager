// Stage 11: central multi-Service state for the Flutter shell.
//
// One polling source, one ID-addressed model (requirement 12):
//
// * Services are keyed by their immutable core ID — never by name, port, list
//   position, or Endpoint association (12.2).
// * A SINGLE periodic refresher (the HomePage timer) drives `refresh()` for
//   every Service at once; there is no timer per Service (12.5).
// * Metric history is sampled only for live (running / preparing / restarting)
//   Services, into a per-ID fixed-capacity ring buffer; a stopped Service's
//   history freezes, a deleted Service's history is dropped — without touching
//   any other Service's state (12.3).
// * Both the snapshot refresh and the on-demand log request carry a generation
//   token: once a newer request is issued, the selection moves, or the state is
//   disposed, the stale reply is rejected instead of overwriting fresh data
//   (12.4).
//
// The class is a ChangeNotifier so the rail / sidebar / detail tabs (stages
// 12–14) can listen without owning any polling of their own.

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'native.dart';

/// Fixed-capacity metric ring buffer for ONE Service ID. Stopped Services keep
/// their last samples frozen on screen; nothing ever grows unbounded (12.3,
/// 12.5).
class ServiceHistory {
  ServiceHistory(this.capacity);

  /// Shared capacity with the instance sparklines (~2 min at the 1.5 s poll).
  static const defaultCapacity = 90;

  final int capacity;
  final List<double> cpuPercent = [];
  final List<double> memMb = [];
  final List<double> diskBytesPerSec = [];

  bool get isEmpty => cpuPercent.isEmpty;

  void sample(ServiceMetrics m) {
    _push(cpuPercent, m.cpuPercent);
    _push(memMb, m.memBytes / (1024 * 1024));
    _push(diskBytesPerSec, m.diskBytesPerSec);
  }

  void _push(List<double> ring, double v) {
    ring.add(v);
    if (ring.length > capacity) ring.removeAt(0);
  }
}

/// Central ID-addressed Service state: list, selection, detail tab, per-ID
/// history, and generation-guarded async requests.
class ServicesState extends ChangeNotifier {
  ServicesState(this._core,
      {int historyCapacity = ServiceHistory.defaultCapacity})
      : _historyCapacity = historyCapacity;

  final NativeCore _core;
  final int _historyCapacity;

  List<ServiceInfo> _services = const [];
  final Map<String, ServiceHistory> _histories = {};

  String? _selectedId;
  // The Service detail's active tab. Like the instance TabController index it
  // SURVIVES switching between Services and switching to another entity kind
  // (12.6): every entity kind keeps its own selected ID + tab.
  int _selectedTab = 0;

  // Generation tokens (12.4): every issued request bumps its counter; a reply
  // that lands after a newer request / selection change / dispose is dropped.
  int _refreshGen = 0;
  int _logsGen = 0;
  bool _disposed = false;

  // List envelope extras from the last successful refresh.
  List<String> _loadErrors = const [];
  List<String> _warnings = const [];

  // ---- read side -----------------------------------------------------------

  /// All Services in display order (case-insensitive name, ID tie-break).
  List<ServiceInfo> get services => _services;

  List<String> get loadErrors => _loadErrors;
  List<String> get warnings => _warnings;

  ServiceInfo? serviceById(String id) {
    for (final s in _services) {
      if (s.id == id) return s;
    }
    return null;
  }

  String? get selectedId => _selectedId;
  ServiceInfo? get selected =>
      _selectedId == null ? null : serviceById(_selectedId!);

  int get selectedTab => _selectedTab;

  /// History for one ID; absent Services get a shared empty instance, so a
  /// late render after a delete never throws and never resurrects state.
  static final ServiceHistory _noHistory = ServiceHistory(0);
  ServiceHistory historyOf(String id) => _histories[id] ?? _noHistory;

  int get refreshGeneration => _refreshGen;

  // ---- write side ----------------------------------------------------------

  void select(String? id) {
    if (id == _selectedId) return;
    _selectedId = id;
    _logsGen++; // a pending log reply for the previous ID is now stale (12.4)
    notifyListeners();
  }

  set selectedTab(int index) {
    if (index == _selectedTab) return;
    _selectedTab = index;
    notifyListeners();
  }

  /// One full snapshot refresh over EVERY Service (12.5 — the only poller).
  /// Returns false when this reply was superseded before it landed.
  Future<bool> refresh() async {
    final gen = ++_refreshGen;
    final res = await Future(() => _core.services());
    if (gen != _refreshGen || _disposed) return false; // stale — drop (12.4)
    _apply(res);
    return true;
  }

  void _apply(
      ({List<ServiceInfo> services, List<String> errors, List<String> warnings})
          res) {
    final sorted = [...res.services]
      ..sort((a, b) {
        final byName = a.config.name.toLowerCase().compareTo(
            b.config.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });

    // Sample metrics for live Services only; a stopped one freezes its ring.
    final liveIds = <String>{};
    for (final info in sorted) {
      final m = info.runtime.metrics;
      if (!info.runtime.isLive || m == null) continue;
      liveIds.add(info.id);
      (_histories[info.id] ??= ServiceHistory(_historyCapacity)).sample(m);
    }
    // Drop history for IDs that vanished from the core entirely (deleted
    // elsewhere). Stopped-but-existing IDs keep their frozen tail (12.3).
    final present = sorted.map((s) => s.id).toSet();
    _histories.removeWhere((id, _) => !present.contains(id));

    // Selection successor: keep the selection when it survives; when the
    // selected Service vanished, move to the same slot (the card that slid
    // into its place) or, when it WAS the last card, to the new last one
    // (12.1 follow-up).
    if (_selectedId != null && !present.contains(_selectedId!)) {
      final oldIndex =
          _services.indexWhere((s) => s.id == _selectedId); // pre-update slot
      _selectedId = sorted.isEmpty
          ? null
          : sorted[oldIndex >= 0 && oldIndex < sorted.length
                ? oldIndex
                : sorted.length - 1]
              .id;
      _logsGen++; // any pending log reply targeted the vanished ID
    }

    _services = sorted;
    _loadErrors = res.errors;
    _warnings = res.warnings;
    notifyListeners();
  }

  /// On-demand log fetch for ONE Service, generation-guarded (12.4): returns
  /// null when the reply is stale (newer request issued, selection moved away
  /// from [id], or the state was disposed) — the caller must drop it.
  Future<List<String>?> requestLogs(String id) async {
    final gen = ++_logsGen;
    final lines = await Future(() => _core.serviceLogs(id));
    if (gen != _logsGen || _disposed || _selectedId != id) return null;
    return lines;
  }

  /// Stage-13 hook: after a successful delete, forget the ID's history and
  /// move the selection if it pointed at the corpse. Idempotent.
  void onServiceDeleted(String id) {
    _histories.remove(id);
    if (_selectedId == id) {
      final idx = _services.indexWhere((s) => s.id == id);
      final rest = _services.where((s) => s.id != id).toList();
      _selectedId = rest.isEmpty
          ? null
          : rest[idx >= 0 && idx < rest.length ? idx : rest.length - 1].id;
      _logsGen++;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshGen++; // poison every in-flight reply (12.4 lifecycle token)
    _logsGen++;
    super.dispose();
  }
}
