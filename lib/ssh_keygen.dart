import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'theme.dart';

/// Показує діалог генерації SSH-ключа.
Future<void> showKeygenDialog(BuildContext context, {required bool isDark}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Генерація SSH-ключа',
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
              child: _KeygenPanel(isDark: isDark),
            ),
          ),
        ),
      );
    },
  );
}

class _KeygenPanel extends StatefulWidget {
  final bool isDark;
  const _KeygenPanel({required this.isDark});

  @override
  State<_KeygenPanel> createState() => _KeygenPanelState();
}

class _KeygenPanelState extends State<_KeygenPanel> {
  // Тип ключа: 'ed25519' або 'rsa'.
  String _type = 'ed25519';

  final _commentCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  String _path = '';
  bool _obscurePass = true;

  bool _busy = false;

  // Запит на перезапис існуючого файлу.
  bool _confirmOverwrite = false;

  // Результат генерації.
  String? _publicKey; // вміст <path>.pub при успіху
  String? _savedPath; // куди збережено приватний ключ
  String? _error; // текст помилки при невдачі

  @override
  void dispose() {
    _commentCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String get _defaultFileName => _type == 'rsa' ? 'id_rsa' : 'id_ed25519';

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.saveFile(
      dialogTitle: 'Куди зберегти приватний ключ',
      fileName: _defaultFileName,
    );
    if (res == null) return;
    if (!mounted) return;
    setState(() {
      _path = res;
      _confirmOverwrite = false;
      _error = null;
    });
  }

  Future<void> _generate() async {
    if (_busy) return;
    final path = _path.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Спочатку оберіть файл для збереження ключа.');
      return;
    }

    // Якщо файл уже існує — спершу питаємо підтвердження перезапису.
    final priv = File(path);
    final pub = File('$path.pub');
    final exists = await priv.exists() || await pub.exists();
    if (exists && !_confirmOverwrite) {
      if (!mounted) return;
      setState(() {
        _confirmOverwrite = true;
        _error = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _publicKey = null;
      _savedPath = null;
    });

    // ssh-keygen зависає, якщо файл існує (запитує підтвердження),
    // тому видаляємо обидва файли заздалегідь.
    try {
      if (await priv.exists()) await priv.delete();
      if (await pub.exists()) await pub.delete();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmOverwrite = false;
        _error = 'Не вдалося видалити наявний файл: $e';
      });
      return;
    }

    final args = <String>[
      '-t', _type,
      if (_type == 'rsa') ...['-b', '4096'],
      '-f', path,
      '-N', _passCtrl.text,
      '-C', _commentCtrl.text,
      '-q',
    ];

    try {
      final result = await Process.run('ssh-keygen', args);
      if (!mounted) return;

      if (result.exitCode == 0) {
        String pubText;
        try {
          pubText = await pub.readAsString();
        } catch (e) {
          pubText = 'Ключ згенеровано, але не вдалося прочитати $path.pub: $e';
        }
        setState(() {
          _busy = false;
          _confirmOverwrite = false;
          _publicKey = pubText.trim();
          _savedPath = path;
        });
      } else {
        final err = (result.stderr ?? '').toString().trim();
        setState(() {
          _busy = false;
          _confirmOverwrite = false;
          _error = err.isEmpty
              ? 'ssh-keygen завершився з кодом ${result.exitCode}.'
              : err;
        });
      }
    } on ProcessException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmOverwrite = false;
        _error =
            'ssh-keygen не знайдено. Встановіть OpenSSH Client (Windows Features).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmOverwrite = false;
        _error = 'Помилка запуску ssh-keygen: $e';
      });
    }
  }

  Future<void> _copyPublicKey() async {
    final key = _publicKey;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Публічний ключ скопійовано'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lc = LC(widget.isDark);
    final media = MediaQuery.of(context);
    final maxH = media.size.height * 0.85;

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: maxH),
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
                child: _publicKey != null ? _result(lc) : _form(lc),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(LC lc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
      child: Row(
        children: [
          AppIcon('lock', size: 18, color: lc.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Генерація SSH-ключа',
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
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  // ── Форма ───────────────────────────────────────────────────────────

  Widget _form(LC lc) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _fieldLabel(lc, 'Тип ключа'),
          const SizedBox(height: 8),
          _typeSelector(lc),
          const SizedBox(height: 16),
          _fieldLabel(lc, 'Коментар'),
          const SizedBox(height: 6),
          _textField(
            lc,
            controller: _commentCtrl,
            hint: 'напр. user@laptop',
          ),
          const SizedBox(height: 16),
          _fieldLabel(lc, 'Passphrase (необов’язково)'),
          const SizedBox(height: 6),
          _passField(lc),
          const SizedBox(height: 16),
          _fieldLabel(lc, 'Файл'),
          const SizedBox(height: 6),
          _fileRow(lc),
          if (_confirmOverwrite) ...[
            const SizedBox(height: 12),
            _overwriteNotice(lc),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            _errorBox(lc, _error!),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ghostButton(
                lc,
                label: 'Скасувати',
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              _primaryButton(
                lc,
                icon: 'lock',
                label: _confirmOverwrite ? 'Перезаписати' : 'Згенерувати',
                busy: _busy,
                onTap: _generate,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeSelector(LC lc) {
    return Row(
      children: [
        Expanded(
          child: _typeOption(
            lc,
            value: 'ed25519',
            title: 'ed25519',
            subtitle: 'Рекомендовано',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _typeOption(
            lc,
            value: 'rsa',
            title: 'rsa',
            subtitle: '4096 біт',
          ),
        ),
      ],
    );
  }

  Widget _typeOption(
    LC lc, {
    required String value,
    required String title,
    required String subtitle,
  }) {
    final selected = _type == value;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: _busy
            ? null
            : () => setState(() {
                  _type = value;
                  // Оновлюємо запропоноване ім’я файлу, якщо ще не обрано.
                  _confirmOverwrite = false;
                }),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? lc.accent.withValues(alpha: 0.12) : lc.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? lc.accent : lc.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              AppIcon(
                selected ? 'lock' : 'server',
                size: 16,
                color: selected ? lc.accent : lc.dim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: selected ? lc.text : lc.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        fontFamilyFallback: const [
                          'Consolas',
                          'Menlo',
                          'monospace'
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(color: lc.dim, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _passField(LC lc) {
    return TextField(
      controller: _passCtrl,
      obscureText: _obscurePass,
      enabled: !_busy,
      cursorColor: lc.accent,
      style: TextStyle(color: lc.text, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Порожньо — без пароля',
        hintStyle: TextStyle(color: lc.dim.withValues(alpha: 0.7), fontSize: 13),
        filled: true,
        fillColor: lc.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        suffixIcon: IconButton(
          splashRadius: 18,
          icon: AppIcon(
            _obscurePass ? 'lock' : 'zap',
            size: 16,
            color: lc.dim,
          ),
          tooltip: _obscurePass ? 'Показати' : 'Сховати',
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.accent),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.border),
        ),
      ),
    );
  }

  Widget _fileRow(LC lc) {
    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: lc.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: lc.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(
              _path.isEmpty ? 'Файл не обрано' : _path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _path.isEmpty ? lc.dim : lc.text,
                fontSize: 12.5,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _ghostButton(
          lc,
          icon: 'folder-open',
          label: 'Обрати…',
          onTap: _busy ? null : _pickFile,
        ),
      ],
    );
  }

  Widget _overwriteNotice(LC lc) {
    return Container(
      decoration: BoxDecoration(
        color: lc.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.warn.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon('refresh', size: 16, color: lc.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Файл уже існує. Натисніть «Перезаписати», щоб видалити '
              'наявні файли ключа (та .pub) і згенерувати нові.',
              style: TextStyle(color: lc.text, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(LC lc, String text) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: lc.bad.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.bad.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon('x', size: 16, color: lc.bad),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(
                color: lc.text,
                fontSize: 12.5,
                height: 1.4,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Результат ───────────────────────────────────────────────────────

  Widget _result(LC lc) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIcon('lock', size: 16, color: lc.good),
              const SizedBox(width: 8),
              Text(
                'Ключ згенеровано',
                style: TextStyle(
                  color: lc.good,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (_savedPath != null) ...[
            const SizedBox(height: 10),
            Text(
              'Приватний ключ збережено у:',
              style: TextStyle(color: lc.dim, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _savedPath!,
              style: TextStyle(
                color: lc.text,
                fontSize: 12.5,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
              ),
            ),
          ],
          const SizedBox(height: 14),
          _fieldLabel(lc, 'Публічний ключ'),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: lc.termBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: lc.border),
            ),
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _publicKey ?? '',
              style: TextStyle(
                color: lc.text,
                fontSize: 12.5,
                height: 1.45,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Додайте цей ключ у ~/.ssh/authorized_keys на сервері '
            '(або скористайтесь ssh-copy-id).',
            style: TextStyle(color: lc.dim, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ghostButton(
                lc,
                label: 'Закрити',
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              _primaryButton(
                lc,
                icon: 'copy',
                label: 'Копіювати',
                onTap: _copyPublicKey,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Дрібні будівельні блоки ─────────────────────────────────────────

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
  }) {
    return TextField(
      controller: controller,
      enabled: !_busy,
      cursorColor: lc.accent,
      style: TextStyle(color: lc.text, fontSize: 13),
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
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: lc.border),
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
    bool busy = false,
  }) {
    return Material(
      color: lc.accent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy) ...[
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
              ] else if (icon != null) ...[
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
    required VoidCallback? onTap,
    String? icon,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                AppIcon(icon, size: 15, color: lc.text),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: lc.text,
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
}
