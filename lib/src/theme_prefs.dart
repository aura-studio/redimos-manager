import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ui_tokens.dart';

/// Currently active UI palette. Mirrors the appLang pattern: a global
/// ValueNotifier that RedimosManagerApp's AnimatedBuilder listens to, so
/// setting [appStyle.value] re-themes the whole window on the next frame.
final ValueNotifier<AppStyle> appStyle = ValueNotifier(AppStyle.parchment);

/// The prefs file lives under the app's own config dir — never ~/.redimos,
/// which holds native-core state and credentials we must not touch.
File? _themeFile({Directory? dir}) {
  final effective = dir ?? debugPrefsDir;
  if (effective != null) return File('${effective.path}/theme.json');
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File('$home/.redimosmanager/theme.json');
}

/// Test-only override for the prefs directory, so widget tests never touch
/// the real ~/.redimosmanager.
Directory? debugPrefsDir;

/// Synchronously restores the persisted style before runApp. Any failure
/// (missing file, corrupt JSON, unknown id) silently keeps the Parchment
/// default — theme prefs must never block startup.
void loadAppStyle({Directory? dir}) {
  final file = _themeFile(dir: dir);
  if (file == null) return;
  try {
    if (!file.existsSync()) return;
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map) return;
    final parsed = AppStyleX.fromId('${raw['style']}');
    if (parsed != null) appStyle.value = parsed;
  } catch (_) {
    // Corrupt or unreadable file: keep the Parchment default.
  }
}

/// Persists the current style atomically (tmp + rename), creating the config
/// directory on first write. IO failures are swallowed: the in-memory style
/// still applies for this session.
void saveAppStyle({Directory? dir}) {
  final file = _themeFile(dir: dir);
  if (file == null) return;
  try {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'style': appStyle.value.id}));
    tmp.renameSync(file.path);
  } catch (_) {
    // Best-effort persistence.
  }
}
