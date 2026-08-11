// pixel-fidelity-v23 CP 4.14 — bundled variable-font smoke test.
//
// Proves the app really renders Inter's variable wght instances (not engine
// faux-bolding): the same string laid out at w400/w500/w600/w700 must get
// STRICTLY wider at every step. A synthetic bold renderer would collapse the
// intermediate weights onto one or two widths.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_fonts.dart';

void main() {
  testWidgets('Inter wght instances widen strictly 400→700 (CP 4.14)', (t) async {
    await loadGoldenFonts();
    const sample = 'Redis Manager v2.3 — 0123456789 quick';
    const weights = [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ];
    await t.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var i = 0; i < weights.length; i++)
              Text(
                sample,
                key: ValueKey('smoke-$i'),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 24,
                  fontWeight: weights[i],
                ),
              ),
          ],
        ),
      ),
    );
    final widths = [
      for (var i = 0; i < weights.length; i++)
        t.getSize(find.byKey(ValueKey('smoke-$i'))).width,
    ];
    for (var i = 1; i < widths.length; i++) {
      expect(
        widths[i],
        greaterThan(widths[i - 1]),
        reason: 'wght must widen at every step (got $widths) — '
            'equal widths would mean faux-bolding, not the variable face',
      );
    }
  });
}
