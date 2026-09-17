import 'dart:convert';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'app_icons.dart';

/// Модальний перегляд/редактор текстового файлу.
///
/// Відкриває велику панель зверху екрана, завантажує вміст через [load],
/// дозволяє редагувати та зберігати назад через [save].
Future<void> showFileEditor(
  BuildContext context, {
  required bool isDark,
  required String path,
  required Future<String> Function() load,
  required Future<void> Function(String content) save,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'file-editor',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, sec, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.06),
            end: Offset.zero,
          ).animate(curved),
          child: _FileEditorScaffold(
            isDark: isDark,
            path: path,
            load: load,
            save: save,
          ),
        ),
      );
    },
  );
}

class _FileEditorScaffold extends StatelessWidget {
  final bool isDark;
  final String path;
  final Future<String> Function() load;
  final Future<void> Function(String content) save;

  const _FileEditorScaffold({
    required this.isDark,
    required this.path,
    required this.load,
    required this.save,
  });

  @override
  Widget build(BuildContext context) {
    final lc = LC(isDark);
    final media = MediaQuery.of(context);
    final width = (media.size.width * 0.90).clamp(320.0, 1000.0);
    final height = media.size.height * 0.82;

    return Theme(
      data: buildTheme(isDark),
      child: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: const Alignment(0, -0.72),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: width,
                maxHeight: height,
              ),
              child: Container(
                width: width,
                decoration: BoxDecoration(
                  color: lc.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: lc.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 40,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _FileEditorBody(
                  lc: lc,
                  path: path,
                  load: load,
                  save: save,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileEditorBody extends StatefulWidget {
  final LC lc;
  final String path;
  final Future<String> Function() load;
  final Future<void> Function(String content) save;

  const _FileEditorBody({
    required this.lc,
    required this.path,
    required this.load,
    required this.save,
  });

  @override
  State<_FileEditorBody> createState() => _FileEditorBodyState();
}

enum _LoadState { loading, ready, error }

class _FileEditorBodyState extends State<_FileEditorBody> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _hScroll = ScrollController();
  final ScrollController _vScroll = ScrollController();

  _LoadState _state = _LoadState.loading;
  String _original = '';
  String _loadError = '';

  bool _modified = false;
  bool _wordWrap = true;
  bool _saving = false;
  String _saveError = '';
  bool _savedToast = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _startLoad();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final nowModified = _controller.text != _original;
    if (nowModified != _modified || _savedToast) {
      setState(() {
        _modified = nowModified;
        if (nowModified) _savedToast = false;
      });
    }
  }

  Future<void> _startLoad() async {
    setState(() {
      _state = _LoadState.loading;
      _loadError = '';
    });
    try {
      final content = await widget.load();
      if (!mounted) return;
      setState(() {
        _original = content;
        _controller.text = content;
        _modified = false;
        _state = _LoadState.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _state = _LoadState.error;
      });
    }
  }

  Future<void> _doSave() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = '';
    });
    final content = _controller.text;
    try {
      await widget.save(content);
      if (!mounted) return;
      setState(() {
        _original = content;
        _modified = _controller.text != _original;
        _saving = false;
        _savedToast = true;
      });
      // Приховати індикатор збереження за кілька секунд.
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _savedToast) setState(() => _savedToast = false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = e.toString();
        _saving = false;
      });
    }
  }

  Future<void> _attemptClose() async {
    if (!_modified) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await _confirmDiscard();
    if (discard == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool?> _confirmDiscard() {
    final lc = widget.lc;
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Container(
              decoration: BoxDecoration(
                color: lc.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: lc.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Незбережені зміни',
                    style: TextStyle(
                      color: lc.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'У файлі є незбережені зміни. Закрити без збереження?',
                    style: TextStyle(color: lc.dim, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _GhostButton(
                        lc: lc,
                        label: 'Скасувати',
                        onPressed: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 10),
                      _FilledButton(
                        lc: lc,
                        label: 'Відхилити',
                        color: lc.bad,
                        onPressed: () => Navigator.of(ctx).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _basename {
    final p = widget.path.replaceAll('\\', '/');
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? widget.path : parts.last;
  }

  int get _lineCount {
    if (_controller.text.isEmpty) return 1;
    return '\n'.allMatches(_controller.text).length + 1;
  }

  int get _byteSize => utf8.encode(_controller.text).length;

  @override
  Widget build(BuildContext context) {
    final lc = widget.lc;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(lc),
        Divider(height: 1, thickness: 1, color: lc.border),
        Expanded(child: _content(lc)),
        Divider(height: 1, thickness: 1, color: lc.border),
        _footer(lc),
      ],
    );
  }

  Widget _header(LC lc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      child: Row(
        children: [
          AppIcon('file', size: 18, color: lc.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _basename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: lc.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_modified) ...[
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: lc.warn,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  widget.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: lc.dim,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _IconButton(
            lc: lc,
            icon: 'x',
            tooltip: 'Закрити',
            onPressed: _attemptClose,
          ),
        ],
      ),
    );
  }

  Widget _content(LC lc) {
    switch (_state) {
      case _LoadState.loading:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(lc.accent),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Завантаження…',
                style: TextStyle(color: lc.dim, fontSize: 13),
              ),
            ],
          ),
        );
      case _LoadState.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon('zap', size: 26, color: lc.bad),
                const SizedBox(height: 14),
                Text(
                  'Не вдалося завантажити файл',
                  style: TextStyle(
                    color: lc.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: lc.dim,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Consolas', 'monospace'],
                  ),
                ),
                const SizedBox(height: 18),
                _FilledButton(
                  lc: lc,
                  label: 'Повторити',
                  icon: 'refresh',
                  color: lc.accent,
                  onPressed: _startLoad,
                ),
              ],
            ),
          ),
        );
      case _LoadState.ready:
        return Column(
          children: [
            Expanded(child: _editor(lc)),
            _toolbar(lc),
          ],
        );
    }
  }

  TextStyle _editorTextStyle(LC lc) => TextStyle(
        color: lc.text,
        fontSize: 13,
        height: 1.45,
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
      );

  InputDecoration _editorDecoration(LC lc) => InputDecoration(
        isCollapsed: true,
        filled: true,
        fillColor: lc.termBg,
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      );

  Widget _editor(LC lc) {
    return Container(
      color: lc.termBg,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: _wordWrap ? _wrappedEditor(lc) : _unwrappedEditor(lc),
    );
  }

  Widget _wrappedEditor(LC lc) {
    return Scrollbar(
      thumbVisibility: true,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        cursorColor: lc.accent,
        scrollPhysics: const ClampingScrollPhysics(),
        style: _editorTextStyle(lc),
        decoration: _editorDecoration(lc),
      ),
    );
  }

  Widget _unwrappedEditor(LC lc) {
    // Без переносу: горизонтальний + вертикальний скрол, поле не переносить рядки.
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth = constraints.maxWidth;
        return Scrollbar(
          controller: _vScroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _vScroll,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: minWidth, maxWidth: 6000),
                child: IntrinsicWidth(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    cursorColor: lc.accent,
                    style: _editorTextStyle(lc),
                    decoration: _editorDecoration(lc),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(LC lc) {
    return Container(
      decoration: BoxDecoration(
        color: lc.surface2,
        border: Border(top: BorderSide(color: lc.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Text(
            '$_lineCount ${_pluralLines(_lineCount)}',
            style: TextStyle(color: lc.dim, fontSize: 12),
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 14, color: lc.border),
          const SizedBox(width: 14),
          Text(
            _formatBytes(_byteSize),
            style: TextStyle(color: lc.dim, fontSize: 12),
          ),
          const Spacer(),
          if (_savedToast) ...[
            AppIcon('activity', size: 14, color: lc.good),
            const SizedBox(width: 6),
            Text(
              'Збережено',
              style: TextStyle(
                color: lc.good,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 14),
          ],
          _WrapToggle(
            lc: lc,
            value: _wordWrap,
            onChanged: (v) => setState(() => _wordWrap = v),
          ),
          const SizedBox(width: 12),
          _FilledButton(
            lc: lc,
            label: 'Зберегти',
            icon: 'download',
            color: lc.accent,
            compact: true,
            loading: _saving,
            onPressed: _modified && !_saving ? _doSave : null,
          ),
        ],
      ),
    );
  }

  Widget _footer(LC lc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      child: Row(
        children: [
          if (_saveError.isNotEmpty)
            Expanded(
              child: Row(
                children: [
                  AppIcon('zap', size: 14, color: lc.bad),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _saveError,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: lc.bad, fontSize: 12),
                    ),
                  ),
                ],
              ),
            )
          else
            const Spacer(),
          _GhostButton(
            lc: lc,
            label: 'Скасувати',
            onPressed: _attemptClose,
          ),
          const SizedBox(width: 10),
          _FilledButton(
            lc: lc,
            label: 'Зберегти',
            color: lc.accent,
            loading: _saving,
            onPressed: _state == _LoadState.ready && _modified && !_saving
                ? _doSave
                : null,
          ),
        ],
      ),
    );
  }

  String _pluralLines(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'рядок';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'рядки';
    return 'рядків';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
}

// ─────────────────────────── допоміжні віджети ───────────────────────────

class _IconButton extends StatelessWidget {
  final LC lc;
  final String icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _IconButton({
    required this.lc,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: AppIcon(icon, size: 18, color: lc.dim),
          ),
        ),
      ),
    );
  }
}

class _WrapToggle extends StatelessWidget {
  final LC lc;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _WrapToggle({
    required this.lc,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final active = value;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? lc.accent.withValues(alpha: 0.14) : lc.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? lc.accent.withValues(alpha: 0.6) : lc.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                'menu',
                size: 14,
                color: active ? lc.accent : lc.dim,
              ),
              const SizedBox(width: 7),
              Text(
                'Перенос рядків',
                style: TextStyle(
                  color: active ? lc.accent : lc.dim,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  final LC lc;
  final String label;
  final VoidCallback onPressed;

  const _GhostButton({
    required this.lc,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: lc.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: lc.text,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilledButton extends StatelessWidget {
  final LC lc;
  final String label;
  final String? icon;
  final Color color;
  final VoidCallback? onPressed;
  final bool loading;
  final bool compact;

  const _FilledButton({
    required this.lc,
    required this.label,
    required this.color,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final bg = enabled ? color : color.withValues(alpha: 0.4);
    final fg = _readableOn(color);
    final vpad = compact ? 7.0 : 10.0;
    final hpad = compact ? 14.0 : 18.0;

    return Opacity(
      opacity: enabled ? 1 : 0.85,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: enabled ? onPressed : null,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: hpad, vertical: vpad),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(fg),
                    ),
                  )
                else if (icon != null)
                  AppIcon(icon!, size: 15, color: fg),
                if (loading || icon != null) const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _readableOn(Color c) {
    // Білий текст на насичених кольорах читається краще.
    final luminance = c.computeLuminance();
    return luminance > 0.6 ? const Color(0xFF10131A) : Colors.white;
  }
}
