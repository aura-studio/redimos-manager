import 'package:flutter/material.dart';

import 'ui_tokens.dart';

/// Typography roles for compact data-table cells.
enum CodexTableCellKind {
  text,
  identifier,
  numeric,
}

/// A transient horizontal scrollbar for bounded desktop data regions.
///
/// Native pointer routing remains intact: a mouse wheel scrolls the enclosing
/// vertical page, Shift+wheel scrolls this axis, and trackpads retain both axes.
/// The local ScrollIntent action also routes PageUp/PageDown to the nearest
/// vertical ancestor instead of letting the inner horizontal viewport swallow
/// the intent.
class CodexHorizontalScrollView extends StatefulWidget {
  const CodexHorizontalScrollView({
    super.key,
    required this.child,
    this.controller,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  @override
  State<CodexHorizontalScrollView> createState() =>
      _CodexHorizontalScrollViewState();
}

class _CodexHorizontalScrollViewState extends State<CodexHorizontalScrollView> {
  ScrollController? _ownedController;

  ScrollController get _controller =>
      widget.controller ??
      (_ownedController ??= ScrollController(debugLabel: 'data-horizontal'));

  @override
  void didUpdateWidget(CodexHorizontalScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _ownedController?.dispose();
      _ownedController = null;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ScrollIntent: _AxisAwareScrollAction(),
      },
      child: Scrollbar(
        controller: _controller,
        notificationPredicate: (notification) =>
            notification.depth == 0 &&
            notification.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
  }
}

class _AxisAwareScrollAction extends ContextAction<ScrollIntent> {
  @override
  bool isEnabled(ScrollIntent intent, [BuildContext? context]) {
    if (context == null) return false;
    final axis = axisDirectionToAxis(intent.direction);
    final state = Scrollable.maybeOf(context, axis: axis);
    return state != null &&
        (state.resolvedPhysics?.shouldAcceptUserOffset(state.position) ?? true);
  }

  @override
  void invoke(ScrollIntent intent, [BuildContext? context]) {
    if (context == null) return;
    final axis = axisDirectionToAxis(intent.direction);
    final state = Scrollable.maybeOf(context, axis: axis);
    if (state == null) return;
    final increment = ScrollAction.getDirectionalIncrement(state, intent);
    if (increment == 0) return;
    state.position.moveTo(
      state.position.pixels + increment,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeInOut,
    );
  }
}

/// A table viewport that keeps its horizontal and vertical scroll positions
/// externally controllable. The child always fills the available width before
/// overflowing horizontally.
class CodexTableViewport extends StatefulWidget {
  const CodexTableViewport({
    super.key,
    required this.child,
    this.horizontalController,
    this.verticalController,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final ScrollController? horizontalController;
  final ScrollController? verticalController;
  final EdgeInsetsGeometry padding;

  @override
  State<CodexTableViewport> createState() => _CodexTableViewportState();
}

class _CodexTableViewportState extends State<CodexTableViewport> {
  ScrollController? _ownedHorizontal;
  ScrollController? _ownedVertical;

  ScrollController get _horizontal =>
      widget.horizontalController ??
      (_ownedHorizontal ??= ScrollController(debugLabel: 'table-horizontal'));

  ScrollController get _vertical =>
      widget.verticalController ??
      (_ownedVertical ??= ScrollController(debugLabel: 'table-vertical'));

  @override
  void didUpdateWidget(CodexTableViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.horizontalController == null &&
        widget.horizontalController != null) {
      _ownedHorizontal?.dispose();
      _ownedHorizontal = null;
    }
    if (oldWidget.verticalController == null &&
        widget.verticalController != null) {
      _ownedVertical?.dispose();
      _ownedVertical = null;
    }
  }

  @override
  void dispose() {
    _ownedHorizontal?.dispose();
    _ownedVertical?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Suppress the framework's auto-inserted vertical scrollbar: it would
      // pin to the horizontally-scrollable content's right edge (off-screen).
      // The explicit vertical Scrollbar below stays pinned to the viewport.
      final content = ScrollConfiguration(
        behavior:
            ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _vertical,
          padding: widget.padding,
          child: widget.child,
        ),
      );
      final verticalViewport = constraints.hasBoundedHeight
          ? SizedBox(height: constraints.maxHeight, child: content)
          : content;

      // Both scrollbars wrap the OUTER axes so each track is pinned to a
      // viewport edge (right / bottom) instead of an edge of the scrolled
      // content. Visibility comes from the shared scrollbar theme: hidden
      // when idle, revealed on hover.
      return Actions(
        actions: <Type, Action<Intent>>{
          ScrollIntent: _AxisAwareScrollAction(),
        },
        child: Scrollbar(
          controller: _vertical,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.vertical &&
              notification.depth == 1,
          child: Scrollbar(
            controller: _horizontal,
            notificationPredicate: (notification) =>
                notification.depth == 0 &&
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth:
                        constraints.hasBoundedWidth ? constraints.maxWidth : 0,
                  ),
                  child: verticalViewport,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// A fixed-height table header row with shared neutral paint and hairline.
class CodexTableHeader extends StatelessWidget {
  const CodexTableHeader({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Semantics(
      container: true,
      child: Container(
        height: Dim.rowH,
        decoration: BoxDecoration(
          color: tokens.panel,
          border: Border(bottom: BorderSide(color: tokens.border)),
        ),
        child: Row(children: children),
      ),
    );
  }
}

/// Uppercase compact heading text. Width and flex are mutually exclusive.
class CodexTableHeaderCell extends StatelessWidget {
  const CodexTableHeaderCell({
    super.key,
    required this.label,
    this.width,
    this.flex,
    this.alignment = Alignment.centerLeft,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.semanticLabel,
  }) : assert(width == null || flex == null);

  final String label;
  final double? width;
  final int? flex;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final content = Semantics(
      label: semanticLabel ?? label,
      header: true,
      child: Container(
        width: width,
        alignment: alignment,
        padding: padding,
        child: ExcludeSemantics(
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ts.style(
              size: 10.5,
              weight: FontWeight.w600,
              letterSpacing: 0.7,
              color: tokens.text3,
            ),
          ),
        ),
      ),
    );
    return flex == null ? content : Expanded(flex: flex!, child: content);
  }
}

/// A fixed-height data row. Hover, selection, disabled, and zebra states only
/// change paint; they never alter row geometry.
class CodexTableRow extends StatefulWidget {
  const CodexTableRow({
    super.key,
    required this.children,
    this.selected = false,
    this.striped = false,
    this.enabled = true,
    this.onTap,
    this.onSecondaryTapUp,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.statesController,
  });

  final List<Widget> children;
  final bool selected;
  final bool striped;
  final bool enabled;
  final VoidCallback? onTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStatesController? statesController;

  @override
  State<CodexTableRow> createState() => _CodexTableRowState();
}

class _CodexTableRowState extends State<CodexTableRow> {
  late WidgetStatesController _states;
  late bool _ownsStates;

  @override
  void initState() {
    super.initState();
    _setController(widget.statesController);
    _syncStates();
  }

  @override
  void didUpdateWidget(CodexTableRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      _states.removeListener(_handleStatesChanged);
      if (_ownsStates) _states.dispose();
      _setController(widget.statesController);
    }
    _syncStates();
  }

  void _setController(WidgetStatesController? controller) {
    _ownsStates = controller == null;
    _states = controller ?? WidgetStatesController();
    _states.addListener(_handleStatesChanged);
  }

  void _syncStates() {
    _states.update(WidgetState.selected, widget.selected);
    _states.update(WidgetState.disabled, !widget.enabled);
  }

  void _handleStatesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _states.removeListener(_handleStatesChanged);
    if (_ownsStates) _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final states = _states.value;
    final selected = states.contains(WidgetState.selected);
    final disabled = states.contains(WidgetState.disabled);
    final hovered = states.contains(WidgetState.hovered) && !disabled;
    final focused = states.contains(WidgetState.focused) && !disabled;
    final fill = selected
        ? tokens.selection
        : hovered
            ? tokens.hover
            : widget.striped
                ? tokens.panel2
                : tokens.panel;
    final interactive = !disabled && widget.onTap != null;

    final row = ExcludeFocus(
      excluding: disabled,
      child: InkWell(
        onTap: interactive ? widget.onTap : null,
        onSecondaryTapUp: disabled ? null : widget.onSecondaryTapUp,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        canRequestFocus: interactive,
        onHover: (value) => _states.update(WidgetState.hovered, value),
        onFocusChange: (value) => _states.update(WidgetState.focused, value),
        mouseCursor:
            (interactive || widget.onSecondaryTapUp != null) && !disabled
                ? SystemMouseCursors.click
                : MouseCursor.defer,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: Container(
          height: Dim.rowH,
          color: fill,
          foregroundDecoration: BoxDecoration(
            border: Border(
              top: focused
                  ? BorderSide(color: tokens.focus, width: Dim.borderW)
                  : BorderSide.none,
              right: focused
                  ? BorderSide(color: tokens.focus, width: Dim.borderW)
                  : BorderSide.none,
              bottom: focused
                  ? BorderSide(color: tokens.focus, width: Dim.borderW)
                  : BorderSide.none,
              left: selected
                  ? BorderSide(color: tokens.accent, width: 2)
                  : focused
                      ? BorderSide(color: tokens.focus, width: Dim.borderW)
                      : const BorderSide(
                          color: Colors.transparent,
                          width: 2,
                        ),
            ),
          ),
          child: Row(children: widget.children),
        ),
      ),
    );

    return Semantics(
      container: true,
      selected: selected,
      enabled: !disabled,
      button: widget.onTap != null || widget.onSecondaryTapUp != null,
      label: widget.semanticLabel,
      onTap: interactive ? widget.onTap : null,
      child: widget.semanticLabel == null ? row : ExcludeSemantics(child: row),
    );
  }
}

/// A data cell using the shared UI, identifier, or numeric type stack. Width and
/// flex are mutually exclusive.
class CodexTableCell extends StatelessWidget {
  const CodexTableCell({
    super.key,
    required this.value,
    this.kind = CodexTableCellKind.text,
    this.width,
    this.flex,
    this.alignment = Alignment.centerLeft,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.semanticLabel,
    this.emphasized = false,
  }) : assert(width == null || flex == null);

  final String value;
  final CodexTableCellKind kind;
  final double? width;
  final int? flex;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final mono = kind != CodexTableCellKind.text;
    final numeric = kind == CodexTableCellKind.numeric;
    final content = Semantics(
      label: semanticLabel ?? value,
      child: Container(
        width: width,
        alignment: alignment,
        padding: padding,
        child: ExcludeSemantics(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ts.style(
              size: Ts.md,
              weight: emphasized ? FontWeight.w600 : FontWeight.normal,
              color: emphasized ? tokens.text : tokens.text2,
              monoFont: mono,
              tabularNums: numeric,
            ),
          ),
        ),
      ),
    );
    return flex == null ? content : Expanded(flex: flex!, child: content);
  }
}

/// A bounded table-body placeholder. Empty and loading variants share exactly
/// the same geometry so asynchronous state changes do not move surrounding UI.
class CodexTablePlaceholder extends StatelessWidget {
  const CodexTablePlaceholder.empty({
    super.key,
    required this.message,
    this.height = 120,
  }) : loading = false;

  const CodexTablePlaceholder.loading({
    super.key,
    required this.message,
    this.height = 120,
  }) : loading = true;

  final String message;
  final double height;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Semantics(
      container: true,
      liveRegion: loading,
      label: message,
      child: SizedBox(
        height: height,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) ...[
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: tokens.accent,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              ExcludeSemantics(
                child: Text(
                  message,
                  style: Ts.style(size: Ts.md, color: tokens.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
