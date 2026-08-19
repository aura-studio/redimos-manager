import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui_primitives.dart';
import 'ui_tokens.dart';

/// Compact text input with Codex paint and theme-invariant field geometry.
class CodexTextField extends StatelessWidget {
  const CodexTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.style,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.textAlignVertical,
    this.height = Dim.ctlH,
    this.hasError = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final double height;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        readOnly: readOnly,
        autofocus: autofocus,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        style: style ?? Ts.style(size: Ts.md, color: tokens.text),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onEditingComplete: onEditingComplete,
        onTap: onTap,
        inputFormatters: inputFormatters,
        maxLines: maxLines,
        minLines: minLines,
        expands: expands,
        textAlignVertical: textAlignVertical,
        decoration: codexInputDecoration(
          context,
          decoration,
          hasError: hasError,
        ),
      ),
    );
  }
}

/// Form-aware text input. Validation paint and copy live outside the fixed
/// input rectangle, so validation cannot resize the control itself.
class CodexTextFormField extends StatefulWidget {
  const CodexTextFormField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.style,
    this.validator,
    this.onSaved,
    this.onChanged,
    this.onSubmitted,
    this.autovalidateMode,
    this.height = Dim.ctlH,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final FormFieldValidator<String>? validator;
  final FormFieldSetter<String>? onSaved;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final AutovalidateMode? autovalidateMode;
  final double height;

  @override
  State<CodexTextFormField> createState() => _CodexTextFormFieldState();
}

class _CodexTextFormFieldState extends State<CodexTextFormField> {
  final _fieldKey = GlobalKey<FormFieldState<String>>();
  TextEditingController? _controller;

  TextEditingController get _effectiveController =>
      widget.controller ?? _controller!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _controller = TextEditingController(text: widget.initialValue);
    }
    _effectiveController.addListener(_syncControllerValue);
  }

  @override
  void didUpdateWidget(CodexTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget.controller ?? _controller;
    if (widget.controller == null && oldWidget.controller != null) {
      oldController?.removeListener(_syncControllerValue);
      _controller = TextEditingController(text: oldWidget.controller!.text);
      _controller!.addListener(_syncControllerValue);
    } else if (widget.controller != null && oldWidget.controller == null) {
      oldController?.removeListener(_syncControllerValue);
      _controller?.dispose();
      _controller = null;
      widget.controller!.addListener(_syncControllerValue);
    } else if (widget.controller != oldWidget.controller &&
        widget.controller != null) {
      oldWidget.controller?.removeListener(_syncControllerValue);
      widget.controller!.addListener(_syncControllerValue);
    }
    _syncControllerValue();
  }

  void _syncControllerValue() {
    final field = _fieldKey.currentState;
    if (field != null && field.value != _effectiveController.text) {
      field.didChange(_effectiveController.text);
    }
  }

  @override
  void dispose() {
    _effectiveController.removeListener(_syncControllerValue);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormField<String>(
        key: _fieldKey,
        initialValue: _effectiveController.text,
        enabled: widget.enabled,
        validator: widget.validator,
        onSaved: widget.onSaved,
        autovalidateMode: widget.autovalidateMode ?? AutovalidateMode.disabled,
        builder: (field) => _FieldWithError(
          errorText: field.errorText,
          child: CodexTextField(
            controller: _effectiveController,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
            readOnly: widget.readOnly,
            autofocus: widget.autofocus,
            obscureText: widget.obscureText,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            style: widget.style,
            height: widget.height,
            hasError: field.hasError,
            decoration: widget.decoration.copyWith(
              errorText: null,
              error: null,
            ),
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
          ),
        ),
      );
}

/// Search input with stable prefix/action slots and native text callbacks.
class CodexSearchField extends StatelessWidget {
  const CodexSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.enabled = true,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.onSearch,
    this.searchLabel = 'Search',
    this.style,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onSearch;
  final String searchLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => CodexTextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        style: style,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: const Icon(Icons.search, size: 15),
          suffixIcon: onSearch == null
              ? null
              : CodexIconButton(
                  icon: const Icon(Icons.arrow_forward, size: 14),
                  semanticLabel: searchLabel,
                  onPressed: enabled ? onSearch : null,
                ),
        ),
      );
}

/// Generic compact select field. The selected value and callback retain the
/// native nullable DropdownButton contract.
class CodexSelectField<T> extends StatefulWidget {
  const CodexSelectField({
    super.key,
    required this.items,
    required this.onChanged,
    this.value,
    this.decoration = const InputDecoration(),
    this.hint,
    this.disabledHint,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.style,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final Widget? hint;
  final Widget? disabledHint;
  final FormFieldValidator<T>? validator;
  final FormFieldSetter<T>? onSaved;
  final AutovalidateMode? autovalidateMode;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;
  final TextStyle? style;

  @override
  State<CodexSelectField<T>> createState() => _CodexSelectFieldState<T>();
}

class _CodexSelectFieldState<T> extends State<CodexSelectField<T>> {
  final _fieldKey = GlobalKey<FormFieldState<T>>();
  final _anchorKey = GlobalKey();
  FocusNode? _focusNode;

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _focusNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) _focusNode = FocusNode();
    _effectiveFocusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(CodexSelectField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      final oldFocusNode = oldWidget.focusNode ?? _focusNode;
      oldFocusNode?.removeListener(_handleFocusChange);
      if (widget.focusNode == null) {
        _focusNode = FocusNode();
      } else {
        _focusNode?.dispose();
        _focusNode = null;
      }
      _effectiveFocusNode.addListener(_handleFocusChange);
    }
    if (widget.value != oldWidget.value) {
      _fieldKey.currentState?.didChange(widget.value);
    }
  }

  void _handleFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _effectiveFocusNode.removeListener(_handleFocusChange);
    _focusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final enabled = widget.enabled && widget.onChanged != null;
    var textStyle = widget.style ??
        Ts.themedStyle(
          Theme.of(context),
          size: Ts.md,
          color: tokens.text,
        );
    if (!enabled) {
      textStyle = textStyle.copyWith(color: tokens.text3);
    }
    return FormField<T>(
      key: _fieldKey,
      initialValue: widget.value,
      enabled: enabled,
      validator: widget.validator,
      onSaved: widget.onSaved,
      autovalidateMode: widget.autovalidateMode ?? AutovalidateMode.disabled,
      builder: (field) => _FieldWithError(
        errorText: field.errorText,
        child: SizedBox(
          key: _anchorKey,
          height: Dim.ctlH,
          child: InputDecorator(
            isEmpty: field.value == null,
            isFocused: _effectiveFocusNode.hasFocus,
            decoration: codexInputDecoration(
              context,
              widget.decoration.copyWith(errorText: null, error: null),
              hasError: field.hasError,
            ),
            child: InkWell(
              focusNode: _effectiveFocusNode,
              autofocus: widget.autofocus,
              canRequestFocus: enabled,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onTap: enabled
                  ? () => _openMenu(context, field, tokens, textStyle)
                  : null,
              child: SizedBox.expand(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: DefaultTextStyle(
                        style: textStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: _selectedChild(field, enabled, tokens),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 16,
                      color: tokens.text3,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectedChild(
    FormFieldState<T> field,
    bool enabled,
    AppTokens tokens,
  ) {
    final value = field.value;
    if (value == null) {
      final placeholder =
          enabled ? widget.hint : (widget.disabledHint ?? widget.hint);
      return placeholder ?? const SizedBox.shrink();
    }
    for (final item in widget.items) {
      if (item.value == value) return item.child;
    }
    return const SizedBox.shrink();
  }

  Future<void> _openMenu(
    BuildContext context,
    FormFieldState<T> field,
    AppTokens tokens,
    TextStyle textStyle,
  ) async {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final selected = await showMenu<T>(
      context: context,
      position: position,
      initialValue: field.value,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      surfaceTintColor: Colors.transparent,
      color: tokens.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dim.radiusS),
        side: BorderSide(
          color: Color.lerp(tokens.border, tokens.text, 0.35)!,
        ),
      ),
      constraints: BoxConstraints(
        minWidth: box.size.width,
        maxWidth: box.size.width,
      ),
      items: [
        for (final item in widget.items)
          PopupMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            height: 32,
            padding: EdgeInsets.zero,
            child: _menuRow(item, field.value == item.value, tokens,
                textStyle),
          ),
      ],
    );
    if (!mounted) return;
    _effectiveFocusNode.unfocus();
    if (selected != null) {
      field.didChange(selected);
      widget.onChanged?.call(selected);
    }
  }

  Widget _menuRow(
    DropdownMenuItem<T> item,
    bool selected,
    AppTokens tokens,
    TextStyle textStyle,
  ) {
    final child = DefaultTextStyle(
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: item.child,
    );
    if (!selected) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Align(alignment: Alignment.centerLeft, child: child),
      );
    }
    return Container(
      color: tokens.hover,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Expanded(child: child),
          Icon(Icons.check, size: 14, color: tokens.accent),
        ],
      ),
    );
  }
}

InputDecoration codexInputDecoration(
  BuildContext context,
  InputDecoration decoration, {
  bool hasError = false,
}) {
  final tokens = AppTokens.of(context);
  final radius = BorderRadius.circular(Dim.radiusS);
  OutlineInputBorder border(Color color, [double width = Dim.borderW]) =>
      OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: color, width: width),
      );

  return decoration
      .applyDefaults(Theme.of(context).inputDecorationTheme)
      .copyWith(
        // isDense 使 InputDecorator 的 container 以输入行内在高度(约 18)为下
        // 限绘制边框，SizedBox(ctlH) 的固定高度画不满。改为非 dense：
        // minContainerHeight = kMinInteractiveDimension(48)，被盒高截断后
        // 边框/填充按整盒高度绘制（textarea 走 expands 分支不受影响）。
        isDense: false,
        filled: true,
        fillColor: tokens.panel,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        border: border(hasError ? tokens.danger : tokens.border),
        enabledBorder: border(hasError ? tokens.danger : tokens.border),
        focusedBorder: border(
          hasError ? tokens.danger : tokens.focus,
          Dim.borderW,
        ),
        disabledBorder: border(tokens.hairline),
        errorBorder: border(tokens.danger),
        focusedErrorBorder: border(tokens.danger),
        prefixIconConstraints: const BoxConstraints.tightFor(
          width: Dim.ctlH,
          height: Dim.ctlH,
        ),
        suffixIconConstraints: const BoxConstraints.tightFor(
          width: Dim.ctlH,
          height: Dim.ctlH,
        ),
      );
}

class _FieldWithError extends StatelessWidget {
  const _FieldWithError({required this.child, this.errorText});

  final Widget child;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final error = errorText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(
            error,
            style: Theme.of(context).inputDecorationTheme.errorStyle,
          ),
        ],
      ],
    );
  }
}
