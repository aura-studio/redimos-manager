import 'package:flutter/material.dart';

import 'ui_primitives.dart';
import 'ui_surfaces.dart';
import 'ui_tokens.dart';

/// Content states supported by [CodexStateShell].
enum CodexContentState { content, loading, empty, error }

/// A bounded page-state shell with persistent toolbar and filter anchors.
///
/// Only the expanded body changes when [state] changes. Callers retain ownership
/// of domain errors, retry callbacks, and loaded content. The shell must be used
/// below a parent with bounded height so every state receives identical bounds.
class CodexStateShell extends StatelessWidget {
  const CodexStateShell({
    super.key,
    required this.state,
    required this.content,
    this.message,
    this.detail,
    this.retryLabel,
    this.onRetry,
    this.toolbar,
    this.filters,
    this.icon,
    this.bodyPadding = const EdgeInsets.all(12),
    this.headerGap = 8,
  }) : assert(
          state != CodexContentState.error ||
              onRetry == null ||
              retryLabel != null,
          'retryLabel is required when onRetry is provided',
        );

  final CodexContentState state;
  final Widget content;
  final String? message;
  final String? detail;
  final String? retryLabel;
  final VoidCallback? onRetry;
  final Widget? toolbar;
  final Widget? filters;
  final Widget? icon;
  final EdgeInsetsGeometry bodyPadding;
  final double headerGap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        assert(
          constraints.hasBoundedHeight,
          'CodexStateShell requires a bounded height',
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (toolbar != null) toolbar!,
            if (toolbar != null && filters != null) SizedBox(height: headerGap),
            if (filters != null) filters!,
            if (toolbar != null || filters != null) SizedBox(height: headerGap),
            Expanded(
              child: ClipRect(
                child: KeyedSubtree(
                  key: ValueKey(state),
                  child: switch (state) {
                    CodexContentState.content => content,
                    CodexContentState.loading => _CodexStatePlaceholder(
                        state: state,
                        message: message ?? '',
                        icon: icon,
                        padding: bodyPadding,
                      ),
                    CodexContentState.empty => _CodexStatePlaceholder(
                        state: state,
                        message: message ?? '',
                        detail: detail,
                        icon: icon,
                        padding: bodyPadding,
                      ),
                    CodexContentState.error => _CodexStatePlaceholder(
                        state: state,
                        message: message ?? '',
                        detail: detail,
                        retryLabel: retryLabel,
                        onRetry: onRetry,
                        icon: icon,
                        padding: bodyPadding,
                      ),
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CodexStatePlaceholder extends StatelessWidget {
  const _CodexStatePlaceholder({
    required this.state,
    required this.message,
    required this.padding,
    this.detail,
    this.retryLabel,
    this.onRetry,
    this.icon,
  });

  final CodexContentState state;
  final String message;
  final String? detail;
  final String? retryLabel;
  final VoidCallback? onRetry;
  final Widget? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final loading = state == CodexContentState.loading;
    final error = state == CodexContentState.error;
    final stateIcon = icon ??
        (loading
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 1.75,
                  color: tokens.accent,
                ),
              )
            : Icon(
                error ? Icons.error_outline : Icons.inbox_outlined,
                size: 22,
                color: error ? tokens.danger : tokens.text3,
              ));

    return Semantics(
      container: true,
      liveRegion: loading || error,
      label: message,
      child: CodexSurface(
        variant: CodexSurfaceVariant.sunken,
        padding: EdgeInsets.zero,
        child: Center(
          child: SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: stateIcon),
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ExcludeSemantics(
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: Ts.style(
                          size: Ts.md,
                          weight: FontWeight.w600,
                          color: error ? tokens.danger : tokens.text2,
                        ),
                      ),
                    ),
                  ],
                  if (detail != null && detail!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    ExcludeSemantics(
                      child: Text(
                        detail!,
                        textAlign: TextAlign.center,
                        style: Ts.style(size: Ts.sm, color: tokens.text3),
                      ),
                    ),
                  ],
                  if (error && onRetry != null) ...[
                    const SizedBox(height: 14),
                    CodexButton(
                      semanticLabel: retryLabel,
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 15),
                      label: Text(retryLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
