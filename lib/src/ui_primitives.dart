import 'package:flutter/material.dart';

import 'ui_tokens.dart';

enum CodexButtonVariant { primary, secondary, ghost, danger }

/// Compact domain-free action primitive used across Redimos screens.
///
/// Variants change paint only. Geometry, focus handling, and interaction
/// callbacks stay aligned with the shared Material theme.
class CodexButton extends StatelessWidget {
  const CodexButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = CodexButtonVariant.secondary,
    this.icon,
    this.semanticLabel,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.statesController,
  });

  final Widget label;
  final VoidCallback? onPressed;
  final CodexButtonVariant variant;
  final Widget? icon;
  final String? semanticLabel;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) {
    final child = switch (variant) {
      CodexButtonVariant.primary => _filled(),
      CodexButtonVariant.secondary => _outlined(),
      CodexButtonVariant.ghost => _text(),
      CodexButtonVariant.danger => _outlined(style: _dangerStyle(context)),
    };

    return _ActionSemantics(
      label: semanticLabel,
      enabled: onPressed != null,
      onTap: onPressed,
      child: child,
    );
  }

  Widget _filled() => icon == null
      ? FilledButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          child: label,
        )
      : FilledButton.icon(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          icon: icon!,
          label: label,
        );

  Widget _outlined({ButtonStyle? style}) => icon == null
      ? OutlinedButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          style: style,
          child: label,
        )
      : OutlinedButton.icon(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          style: style,
          icon: icon!,
          label: label,
        );

  Widget _text() => icon == null
      ? TextButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          child: label,
        )
      : TextButton.icon(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          icon: icon!,
          label: label,
        );
}

/// Fixed-footprint icon action. A semantic label is required because the icon
/// alone must never be the accessible name of an operation.
class CodexIconButton extends StatelessWidget {
  const CodexIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.variant = CodexButtonVariant.ghost,
    this.tooltip,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.statesController,
  });

  final Widget icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final CodexButtonVariant variant;
  final String? tooltip;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) => _ActionSemantics(
        label: semanticLabel,
        enabled: onPressed != null,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: Dim.ctlH,
          child: Focus(
            onFocusChange: onFocusChange,
            skipTraversal: true,
            child: IconButton(
              tooltip: tooltip ?? semanticLabel,
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              focusNode: focusNode,
              autofocus: autofocus,
              statesController: statesController,
              style: _iconStyle(context, variant),
              icon: icon,
            ),
          ),
        ),
      );
}

class _ActionSemantics extends StatelessWidget {
  const _ActionSemantics({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final String? label;
  final bool enabled;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (label == null) return child;
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      onTap: onTap,
      excludeSemantics: true,
      child: child,
    );
  }
}

ButtonStyle _dangerStyle(BuildContext context) {
  final tokens = AppTokens.of(context);
  return ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? tokens.danger.withValues(alpha: 0.45)
          : tokens.danger,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => _semanticInteractionFill(states, tokens.danger),
    ),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.focused)
            ? tokens.focus
            : tokens.danger.withValues(
                alpha: states.contains(WidgetState.disabled) ? 0.35 : 0.8,
              ),
        width: Dim.borderW,
      ),
    ),
  );
}

ButtonStyle _iconStyle(
  BuildContext context,
  CodexButtonVariant variant,
) {
  final tokens = AppTokens.of(context);
  final radius = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Dim.radiusS),
  );

  Color foreground(Set<WidgetState> states) {
    final disabled = states.contains(WidgetState.disabled);
    final color = switch (variant) {
      CodexButtonVariant.primary => tokens.onAccent,
      CodexButtonVariant.secondary => tokens.text,
      CodexButtonVariant.ghost => tokens.text2,
      CodexButtonVariant.danger => tokens.danger,
    };
    return disabled ? color.withValues(alpha: 0.45) : color;
  }

  Color background(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      return variant == CodexButtonVariant.primary
          ? tokens.accent.withValues(alpha: 0.3)
          : Colors.transparent;
    }
    if (variant == CodexButtonVariant.primary) {
      if (states.contains(WidgetState.pressed)) {
        return Color.alphaBlend(
          tokens.text.withValues(alpha: 0.12),
          tokens.accent,
        );
      }
      if (states.contains(WidgetState.hovered)) {
        return Color.alphaBlend(
          tokens.text.withValues(alpha: 0.07),
          tokens.accent,
        );
      }
      return tokens.accent;
    }
    if (variant == CodexButtonVariant.danger) {
      return _semanticInteractionFill(states, tokens.danger);
    }
    if (states.contains(WidgetState.pressed)) return tokens.selection;
    if (states.contains(WidgetState.hovered)) return tokens.hover;
    return Colors.transparent;
  }

  BorderSide side(Set<WidgetState> states) {
    if (states.contains(WidgetState.focused)) {
      return BorderSide(color: tokens.focus, width: Dim.borderW);
    }
    return switch (variant) {
      CodexButtonVariant.secondary =>
        BorderSide(color: tokens.border, width: Dim.borderW),
      CodexButtonVariant.danger => BorderSide(
          color: tokens.danger.withValues(
            alpha: states.contains(WidgetState.disabled) ? 0.35 : 0.8,
          ),
          width: Dim.borderW,
        ),
      _ => BorderSide.none,
    };
  }

  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size.square(Dim.ctlH)),
    maximumSize: const WidgetStatePropertyAll(Size.square(Dim.ctlH)),
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    shape: WidgetStatePropertyAll(radius),
    foregroundColor: WidgetStateProperty.resolveWith(foreground),
    backgroundColor: WidgetStateProperty.resolveWith(background),
    side: WidgetStateProperty.resolveWith(side),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  );
}

Color _semanticInteractionFill(Set<WidgetState> states, Color color) {
  if (states.contains(WidgetState.disabled)) return Colors.transparent;
  if (states.contains(WidgetState.pressed)) {
    return color.withValues(alpha: 0.16);
  }
  if (states.contains(WidgetState.hovered)) {
    return color.withValues(alpha: 0.1);
  }
  return Colors.transparent;
}
