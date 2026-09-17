import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_icons.dart';
import 'theme.dart';

const String _kSnippetsKey = 'lumen_snippets';

/// Один збережений сніпет команди.
class Snippet {
  String id;
  String name;
  String command;

  Snippet({required this.id, required this.name, required this.command});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
      };

  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        command: (j['command'] ?? '').toString(),
      );
}

/// Персистентне сховище сніпетів у shared_preferences.
class SnippetStore {
  static Future<List<Snippet>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSnippetsKey);
    if (raw == null || raw.isEmpty) return <Snippet>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => Snippet.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      // Пошкоджені дані — повертаємо порожній список.
    }
    return <Snippet>[];
  }

  static Future<void> save(List<Snippet> list) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_kSnippetsKey, raw);
  }
}

/// Генерує унікальний id для сніпета.
String _newSnippetId() => 'sn_${DateTime.now().microsecondsSinceEpoch}';

/// Показує діалог бібліотеки сніпетів.
Future<void> showSnippetsDialog(
  BuildContext context, {
  required bool isDark,
  required void Function(String command) onRun,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Сніпети',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, sec, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 56),
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.06),
                end: Offset.zero,
              ).animate(curved),
              child: _SnippetsPanel(isDark: isDark, onRun: onRun),
            ),
          ),
        ),
      );
    },
  );
}

class _SnippetsPanel extends StatefulWidget {
  final bool isDark;
  final void Function(String command) onRun;
  const _SnippetsPanel({required this.isDark, required this.onRun});

  @override
  State<_SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends State<_SnippetsPanel> {
  List<Snippet> _items = [];
  bool _loading = true;

  // Режим форми: null — список; інакше редагування/додавання.
  Snippet? _editing;
  bool _adding = false;
  String? _pendingDeleteId;

  final _nameCtrl = TextEditingController();
  final _cmdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await SnippetStore.load();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  bool get _inForm => _adding || _editing != null;

  void _openAdd() {
    _nameCtrl.text = '';
    _cmdCtrl.text = '';
    setState(() {
      _adding = true;
      _editing = null;
      _pendingDeleteId = null;
    });
  }

  void _openEdit(Snippet s) {
    _nameCtrl.text = s.name;
    _cmdCtrl.text = s.command;
    setState(() {
      _editing = s;
      _adding = false;
      _pendingDeleteId = null;
    });
  }

  void _cancelForm() {
    setState(() {
      _adding = false;
      _editing = null;
    });
  }

  Future<void> _saveForm() async {
    final name = _nameCtrl.text.trim();
    final command = _cmdCtrl.text.trim();
    if (name.isEmpty || command.isEmpty) return;

    if (_editing != null) {
      _editing!
        ..name = name
        ..command = command;
    } else {
      _items.add(Snippet(id: _newSnippetId(), name: name, command: command));
    }
    await SnippetStore.save(_items);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _editing = null;
    });
  }

  Future<void> _delete(Snippet s) async {
    _items.removeWhere((e) => e.id == s.id);
    await SnippetStore.save(_items);
    if (!mounted) return;
    setState(() => _pendingDeleteId = null);
  }

  void _run(Snippet s) {
    Navigator.of(context).maybePop();
    widget.onRun(s.command);
  }

  @override
  Widget build(BuildContext context) {
    final lc = LC(widget.isDark);
    final media = MediaQuery.of(context);
    final maxH = media.size.height * 0.8;

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
        child: Container(
          decoration: BoxDecoration(
            color: lc.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: lc.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(lc),
              Flexible(
                child: _inForm ? _form(lc) : _list(lc),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(LC lc) {
    final title = _adding
        ? 'Новий сніпет'
        : (_editing != null ? 'Редагувати сніпет' : 'Бібліотека сніпетів');
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
      child: Row(
        children: [
          AppIcon('terminal-square', size: 18, color: lc.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: lc.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _iconBtn(
            lc,
            icon: 'x',
            tooltip: 'Закрити',
            onTap: () {
              if (_inForm) {
                _cancelForm();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _list(LC lc) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: lc.accent),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: _items.isEmpty
              ? _emptyState(lc)
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) => _row(lc, _items[i]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: SizedBox(
            width: double.infinity,
            child: _primaryButton(
              lc,
              icon: 'plus',
              label: 'Додати сніпет',
              onTap: _openAdd,
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyState(LC lc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon('terminal', size: 32, color: lc.dim),
          const SizedBox(height: 12),
          Text(
            'Сніпетів ще немає',
            style: TextStyle(
              color: lc.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Збережіть команди, якими часто користуєтесь,\nщоб швидко надсилати їх у термінал.',
            textAlign: TextAlign.center,
            style: TextStyle(color: lc.dim, fontSize: 12.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _row(LC lc, Snippet s) {
    final confirming = _pendingDeleteId == s.id;
    return Container(
      decoration: BoxDecoration(
        color: lc.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.border),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: lc.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  s.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: lc.dim,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (confirming) ...[
            _iconBtn(
              lc,
              icon: 'trash',
              tooltip: 'Підтвердити видалення',
              color: lc.bad,
              onTap: () => _delete(s),
            ),
            _iconBtn(
              lc,
              icon: 'x',
              tooltip: 'Скасувати',
              onTap: () => setState(() => _pendingDeleteId = null),
            ),
          ] else ...[
            _iconBtn(
              lc,
              icon: 'zap',
              tooltip: 'Виконати',
              color: lc.accent,
              onTap: () => _run(s),
            ),
            _iconBtn(
              lc,
              icon: 'pencil',
              tooltip: 'Редагувати',
              onTap: () => _openEdit(s),
            ),
            _iconBtn(
              lc,
              icon: 'trash',
              tooltip: 'Видалити',
              onTap: () => setState(() => _pendingDeleteId = s.id),
            ),
          ],
        ],
      ),
    );
  }

  Widget _form(LC lc) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _fieldLabel(lc, 'Назва'),
          const SizedBox(height: 6),
          _textField(
            lc,
            controller: _nameCtrl,
            hint: 'Напр. Оновити пакети',
            autofocus: true,
          ),
          const SizedBox(height: 14),
          _fieldLabel(lc, 'Команда'),
          const SizedBox(height: 6),
          _textField(
            lc,
            controller: _cmdCtrl,
            hint: 'sudo apt update && sudo apt upgrade -y',
            mono: true,
            minLines: 3,
            maxLines: 8,
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ghostButton(lc, label: 'Скасувати', onTap: _cancelForm),
              const SizedBox(width: 10),
              _primaryButton(
                lc,
                icon: 'download',
                label: 'Зберегти',
                onTap: _saveForm,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── дрібні будівельні блоки ─────────────────────────────────────────

  Widget _fieldLabel(LC lc, String text) => Text(
        text,
        style: TextStyle(
          color: lc.dim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _textField(
    LC lc, {
    required TextEditingController controller,
    String? hint,
    bool mono = false,
    bool autofocus = false,
    int minLines = 1,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      cursorColor: lc.accent,
      style: TextStyle(
        color: lc.text,
        fontSize: 13,
        fontFamily: mono ? 'monospace' : null,
        fontFamilyFallback:
            mono ? const ['Consolas', 'Menlo', 'monospace'] : null,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: lc.dim.withValues(alpha: 0.7), fontSize: 13),
        filled: true,
        fillColor: lc.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.accent),
        ),
      ),
    );
  }

  Widget _iconBtn(
    LC lc, {
    required String icon,
    required VoidCallback onTap,
    String? tooltip,
    Color? color,
  }) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: AppIcon(icon, size: 17, color: color ?? lc.dim),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip, child: btn);
  }

  Widget _primaryButton(
    LC lc, {
    required String label,
    required VoidCallback onTap,
    String? icon,
  }) {
    return Material(
      color: lc.accent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                AppIcon(icon, size: 16, color: Colors.white),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ghostButton(
    LC lc, {
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: lc.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: lc.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
