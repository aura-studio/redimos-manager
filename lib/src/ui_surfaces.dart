import 'package:flutter/material.dart';

import 'ui_tokens.dart';

enum CodexSurfaceVariant { standard, elevated, sunken }

/// Theme-aware content surface with geometry shared by both brightness modes.
///
/// The variant changes paint and depth only. Padding, border allocation, radius,
/// clipping, and child layout remain stable when the active theme changes.
class CodexSurface extends StatelessWidget {
  const CodexSurface({
    super.key,
    required this.child,
    this.variant = CodexSurfaceVariant.standard,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final CodexSurfaceVariant variant;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(Dim.radiusM);
    final elevated = variant == CodexSurfaceVariant.elevated;
    final sunken = variant == CodexSurfaceVariant.sunken;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: sunken ? tokens.panel2 : tokens.panel,
        borderRadius: radius,
        border: Border.all(color: tokens.border, width: Dim.borderW),
        boxShadow: elevated ? Depth.elev2(brightness) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Dim.radiusM - Dim.borderW),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Padding(padding: padding, child: child),
            // 边框叠加层：section 头带等 child 会铺满顶边盖住下层
            // DecoratedBox 的边框，此处重画一遍保证四边恒可见。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border:
                        Border.all(color: tokens.border, width: Dim.borderW),
                  ),
                ),
              ),
            ),
            if (sunken)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  child: SizedBox(
                    height: Dim.wellInsetH,
                    child: DecoratedBox(
                      decoration: Depth.wellTopLogs(brightness),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact section eyebrow with a rule that consumes all remaining width.
class CodexSectionHeader extends StatelessWidget {
  const CodexSectionHeader({
    super.key,
    required this.label,
    this.trailing,
  });

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Semantics(
      header: true,
      container: true,
      child: SizedBox(
        height: 20,
        child: Row(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ts.style(
                size: Ts.xs,
                letterSpacing: 1.3,
                weight: FontWeight.w700,
                color: tokens.text3,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: CodexDivider()),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Exact one-pixel divider that does not inherit Material divider margins.
class CodexDivider extends StatelessWidget {
  const CodexDivider({
    super.key,
    this.axis = Axis.horizontal,
  });

  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final color = AppTokens.of(context).hairline;
    return LayoutBuilder(
      builder: (context, constraints) => axis == Axis.horizontal
          ? SizedBox(
              width: constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : Dim.borderW,
              height: Dim.borderW,
              child: ColoredBox(color: color),
            )
          : SizedBox(
              width: Dim.borderW,
              height: constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : Dim.borderW,
              child: ColoredBox(color: color),
            ),
    );
  }
}
