import 'package:flutter/material.dart';

import 'ui_tokens.dart';

enum CodexStatus {
  running,
  success,
  warning,
  danger,
  error,
  stopped,
  neutral,
}

/// Resolves operational status paint without borrowing the brand accent.
Color codexStatusColor(BuildContext context, CodexStatus status) {
  final tokens = AppTokens.of(context);
  return switch (status) {
    CodexStatus.running || CodexStatus.success => tokens.success,
    CodexStatus.warning => tokens.warning,
    CodexStatus.danger ||
    CodexStatus.error ||
    CodexStatus.stopped =>
      tokens.danger,
    CodexStatus.neutral => tokens.text3,
  };
}

/// Fixed-footprint operational status dot with an explicit accessible name.
class CodexStatusDot extends StatelessWidget {
  const CodexStatusDot({
    super.key,
    required this.status,
    required this.semanticLabel,
    this.glow = false,
  });

  final CodexStatus status;
  final String semanticLabel;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final color = codexStatusColor(context, status);
    return Semantics(
      label: semanticLabel,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 7,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: glow
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.45),
                        blurRadius: 5,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact status pill. Status changes paint only; every variant keeps the same
/// padding, border allocation, radius, typography, and minimum height.
class CodexStatusBadge extends StatelessWidget {
  const CodexStatusBadge({
    super.key,
    required this.status,
    required this.label,
    this.semanticLabel,
  });

  final CodexStatus status;
  final String label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = codexStatusColor(context, status);
    return Semantics(
      label: semanticLabel ?? label,
      container: true,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            border: Border.all(
              color: color.withValues(alpha: 0.45),
              width: Dim.borderW,
            ),
            borderRadius: BorderRadius.circular(Dim.radiusS),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ts.style(
                size: Ts.xs,
                weight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline dot-and-label status used in tables, cards, and chrome status areas.
class CodexStatusIndicator extends StatelessWidget {
  const CodexStatusIndicator({
    super.key,
    required this.status,
    required this.label,
    this.semanticLabel,
    this.glow = false,
  });

  final CodexStatus status;
  final String label;
  final String? semanticLabel;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final color = codexStatusColor(context, status);
    return Semantics(
      label: semanticLabel ?? label,
      container: true,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CodexStatusDot(
            status: status,
            semanticLabel: semanticLabel ?? label,
            glow: glow,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ts.style(
              size: Ts.xs,
              weight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
