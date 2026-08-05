// A minimal, dependency-free code editor: a syntax-highlighting
// TextEditingController (JS / Go) + a line-number gutter. The controller
// overrides buildTextSpan to colour comments / strings / numbers / keywords; the
// gutter renders line numbers in the same monospace metrics so they stay aligned.

import 'package:flutter/material.dart';

const double kCodeFontSize = 13;
const double kCodeLineHeight = 1.5;

const _jsKeywords = <String>{
  'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while',
  'do', 'of', 'in', 'new', 'class', 'extends', 'typeof', 'instanceof', 'try',
  'catch', 'finally', 'throw', 'switch', 'case', 'break', 'continue', 'default',
  'true', 'false', 'null', 'undefined', 'void', 'this', 'async', 'await',
  'yield', 'delete',
};

const _goKeywords = <String>{
  'package', 'import', 'func', 'return', 'if', 'else', 'for', 'range', 'map',
  'struct', 'interface', 'type', 'var', 'const', 'chan', 'go', 'defer',
  'select', 'switch', 'case', 'break', 'continue', 'default', 'fallthrough',
  'true', 'false', 'nil', 'make', 'len', 'append', 'cap', 'new', 'panic',
  'recover', 'string', 'int', 'int64', 'bool', 'byte', 'error', 'float64',
  'rune', 'uint', 'interface{}',
};

class _Palette {
  final Color plain, comment, str, number, keyword;
  const _Palette(this.plain, this.comment, this.str, this.number, this.keyword);
}

const _dark = _Palette(
  Color(0xFFD4D4D4), // plain
  Color(0xFF6A9955), // comment (green)
  Color(0xFFCE9178), // string
  Color(0xFFB5CEA8), // number
  Color(0xFF569CD6), // keyword (blue)
);
const _light = _Palette(
  Color(0xFF1F2328),
  Color(0xFF6A737D),
  Color(0xFFB2523B),
  Color(0xFF0550AE),
  Color(0xFF8250DF),
);

class CodeHighlightController extends TextEditingController {
  String lang; // 'js' | 'go'
  CodeHighlightController({super.text, this.lang = 'js'});

  @override
  TextSpan buildTextSpan(
      {required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = (style ?? const TextStyle());
    final b = Theme.of(context).brightness;
    final pal = b == Brightness.dark ? _dark : _light;
    return TextSpan(style: base, children: _highlight(text, lang, base, pal));
  }
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || c == '_' || c == r'$';
}

bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

List<TextSpan> _highlight(String src, String lang, TextStyle base, _Palette pal) {
  final kw = lang == 'go' ? _goKeywords : _jsKeywords;
  final spans = <TextSpan>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      spans.add(TextSpan(text: buf.toString(), style: base.copyWith(color: pal.plain)));
      buf.clear();
    }
  }

  final n = src.length;
  var i = 0;
  while (i < n) {
    final ch = src[i];
    // line comment
    if (ch == '/' && i + 1 < n && src[i + 1] == '/') {
      flush();
      var j = i;
      while (j < n && src[j] != '\n') {
        j++;
      }
      spans.add(TextSpan(
          text: src.substring(i, j),
          style: base.copyWith(color: pal.comment, fontStyle: FontStyle.italic)));
      i = j;
      continue;
    }
    // block comment
    if (ch == '/' && i + 1 < n && src[i + 1] == '*') {
      flush();
      var j = i + 2;
      while (j + 1 < n && !(src[j] == '*' && src[j + 1] == '/')) {
        j++;
      }
      j = (j + 1 < n) ? j + 2 : n;
      spans.add(TextSpan(
          text: src.substring(i, j),
          style: base.copyWith(color: pal.comment, fontStyle: FontStyle.italic)));
      i = j;
      continue;
    }
    // string / template
    if (ch == '"' || ch == "'" || ch == '`') {
      flush();
      final q = ch;
      var j = i + 1;
      while (j < n) {
        if (src[j] == '\\' && q != '`') {
          j += 2;
          continue;
        }
        if (src[j] == q) {
          j++;
          break;
        }
        if (src[j] == '\n' && q != '`') break; // unterminated single-line string
        j++;
      }
      if (j > n) j = n;
      spans.add(TextSpan(text: src.substring(i, j), style: base.copyWith(color: pal.str)));
      i = j;
      continue;
    }
    // number
    if (_isDigit(ch)) {
      flush();
      var j = i;
      while (j < n &&
          (_isDigit(src[j]) ||
              src[j] == '.' ||
              src[j] == 'x' ||
              src[j] == 'e' ||
              (src[j].toLowerCase().codeUnitAt(0) >= 0x61 &&
                  src[j].toLowerCase().codeUnitAt(0) <= 0x66))) {
        j++;
      }
      spans.add(TextSpan(text: src.substring(i, j), style: base.copyWith(color: pal.number)));
      i = j;
      continue;
    }
    // identifier / keyword
    if (_isIdentStart(ch)) {
      var j = i;
      while (j < n && _isIdentPart(src[j])) {
        j++;
      }
      final word = src.substring(i, j);
      if (kw.contains(word)) {
        flush();
        spans.add(TextSpan(text: word, style: base.copyWith(color: pal.keyword)));
      } else {
        buf.write(word);
      }
      i = j;
      continue;
    }
    buf.write(ch);
    i++;
  }
  flush();
  return spans;
}

// The TextField soft-wraps, so a logical line can occupy several visual rows and
// the gutter must allot it the same. RenderEditable lays the text out at
// (available width − caret margin), where the margin is a fixed 2px gap plus the
// cursor: match it exactly or long lines wrap one character early here and every
// number below drifts.
const double _kCursorWidth = 1.5;
const double _kCaretMargin = 2.0 + _kCursorWidth;
const double _kLineBox = kCodeFontSize * kCodeLineHeight;
const _kGutterPad = EdgeInsets.fromLTRB(12, 12, 8, 12);
const _kFieldPad = EdgeInsets.fromLTRB(12, 12, 12, 12);

double _measure(String s, TextStyle style) {
  final tp = TextPainter(
      text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)
    ..layout();
  return tp.width;
}

// How many visual rows one logical line wraps to at [maxWidth].
int _visualRows(String line, TextStyle style, double maxWidth) {
  if (maxWidth <= 0) return 1;
  final tp = TextPainter(
      text: TextSpan(text: line.isEmpty ? ' ' : line, style: style),
      textDirection: TextDirection.ltr)
    ..layout(maxWidth: maxWidth);
  final rows = tp.computeLineMetrics().length;
  return rows < 1 ? 1 : rows;
}

/// A code editor pane: line-number gutter + the highlighted TextField, sharing
/// one vertical scroll so numbers track the text.
class CodeField extends StatefulWidget {
  final CodeHighlightController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final String? hintText;
  const CodeField(
      {super.key, required this.controller, this.focusNode, this.onChanged, this.hintText});

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  // Only created when the caller supplies no node — tapping the pane's empty area
  // below the last line must still focus the editor.
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _own?.dispose();
    super.dispose();
  }

  void _onText() => setState(() {}); // relayout the gutter on line-count change

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    const codeStyle = TextStyle(
        fontFamily: 'monospace', fontSize: kCodeFontSize, height: kCodeLineHeight);
    final numberStyle = codeStyle.copyWith(color: muted?.withValues(alpha: 0.6));
    final lines = widget.controller.text.split('\n');
    final gutterTextW = _measure('${lines.length}', numberStyle);
    final gutterW = gutterTextW + _kGutterPad.horizontal;
    return Container(
      color: scheme.surface,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focus.requestFocus,
        child: LayoutBuilder(builder: (context, constraints) {
          final textW =
              constraints.maxWidth - gutterW - _kFieldPad.horizontal - _kCaretMargin;
          return Stack(children: [
            // The stripe is a background, not part of the scrolling content: it
            // must fill the pane's height even for a two-line script.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: gutterW,
              child: Container(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35)),
            ),
            SingleChildScrollView(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: gutterW,
                  child: Padding(
                    padding: _kGutterPad,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      for (var i = 0; i < lines.length; i++)
                        SizedBox(
                          height: _visualRows(lines[i], codeStyle, textW) * _kLineBox,
                          child: Text('${i + 1}',
                              textAlign: TextAlign.right, style: numberStyle),
                        ),
                    ]),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    onChanged: widget.onChanged,
                    maxLines: null,
                    expands: false,
                    cursorWidth: _kCursorWidth,
                    style: codeStyle,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      contentPadding: _kFieldPad,
                      hintText: widget.hintText,
                      hintStyle: codeStyle.copyWith(color: muted?.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ]),
            ),
          ]);
        }),
      ),
    );
  }
}
