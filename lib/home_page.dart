import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:xterm/xterm.dart';

import 'app_icons.dart';
import 'theme.dart';
import 'server.dart';
import 'ssh_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_editor.dart';
import 'snippets.dart';
import 'monitor_panel.dart';
import 'secure_store.dart';
import 'secrets.dart';
import 'device_key.dart';
import 'key_switch.dart';
import 'ssh_keygen.dart';
import 'tunnels.dart';

class HomePage extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  final Future<void> Function(Color) onAccentChanged;
  const HomePage({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
    required this.onAccentChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<TermSession> _sessions = [];
  final Map<int, FocusNode> _focus = {};
  int _activeId = -1;
  int _counter = 0;
  List<Server> _servers = [];

  final Map<int, String> _cwd = {};
  String _filePath = '';
  List<FileEntry> _files = [];
  final Set<String> _selected = {};
  int? _lastIndex;

  String? _toastMsg;
  Timer? _toastTimer;

  bool _broadcast = false;
  String? _devicePub; // публічний ключ цього ПК, якщо вже створено
  static const _keyDeclinedPref = 'lumen_key_declined';
  String? _master;
  bool _masterEnabled = false;
  final Map<int, TunnelManager> _tunnels = {};

  String _serverFilter = '';
  bool _showHidden = true;
  String _fileFilter = '';
  bool _fileSearchOpen = false;
  bool _split = false;
  bool _dragOver = false;
  String? _transferLabel;
  double? _transferValue;

  final Map<int, ScrollController> _scroll = {};
  int? _searchSessionId;
  String _searchQuery = '';
  List<List<int>> _matches = [];
  int _matchIdx = 0;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    for (final f in _focus.values) {
      f.dispose();
    }
    for (final t in _tunnels.values) {
      t.dispose();
    }
    for (final sc in _scroll.values) {
      sc.dispose();
    }
    super.dispose();
  }

  Future<void> _loadServers() async {
    final stored = _dedupe(await ServerStore.load());
    final prefs = await SharedPreferences.getInstance();
    final check = prefs.getString('lumen_master_check');
    if (check != null) {
      _masterEnabled = true;
      while (_master == null && mounted) {
        final pw = await showMasterPasswordDialog(context,
            isDark: widget.isDark, creating: false);
        if (pw == null) break; // залишити заблокованим
        if (SecureStore.decryptString(check, pw) == 'LUMEN_OK') {
          _master = pw;
        } else {
          _toast('Невірний майстер-пароль');
        }
      }
    }
    final failed = <String>[];
    _servers =
        stored.map((s) => Secrets.openServer(s, _master, failed)).toList();
    // Записані відкритим текстом секрети (старі версії) тут же йдуть під DPAPI.
    await _saveServers();
    if (failed.isNotEmpty) {
      _toast('Не вдалося розшифрувати секретів: ${failed.length} — '
          'введіть їх заново в налаштуваннях сервера');
    }
    if (mounted) setState(() {});
    _loadDeviceKey();
  }

  // Зберегти сервери: секрети — під DPAPI (і майстер-паролем, якщо ввімкнено).
  Future<void> _saveServers() => ServerStore.save(
      _servers.map((s) => Secrets.sealServer(s, _master)).toList());

  Future<void> _setupMaster() async {
    if (_masterEnabled) {
      _toast('Майстер-пароль уже увімкнено');
      return;
    }
    final pw = await showMasterPasswordDialog(context,
        isDark: widget.isDark, creating: true);
    if (pw == null || pw.isEmpty) return;
    _master = pw;
    _masterEnabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'lumen_master_check', SecureStore.encryptString('LUMEN_OK', pw));
    await _saveServers();
    _toast('Майстер-пароль увімкнено — паролі зашифровано');
  }

  List<Server> _dedupe(List<Server> list) {
    final seen = <String>{};
    final out = <Server>[];
    for (final s in list) {
      final k = '${s.host}|${s.username}|${s.port}';
      if (seen.add(k)) out.add(s);
    }
    return out;
  }

  TermSession? get _active {
    for (final s in _sessions) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  void _focusActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus[_activeId]?.requestFocus();
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    setState(() => _toastMsg = msg);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toastMsg = null);
    });
  }

  // -------------------- Клавіатура терміналу --------------------
  KeyEventResult _onTermKey(TermSession s, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // Копіювати виділене: Ctrl+C (за наявності виділення) або Ctrl+Shift+C
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyC) {
      final sel = s.selectedText;
      if (sel.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: sel));
        s.clearSelection();
        if (mounted) setState(() {});
        _toast('Скопійовано виділене');
        return KeyEventResult.handled;
      }
      if (shift) return KeyEventResult.handled; // без виділення — нічого
      // інакше нижче Ctrl+C піде як SIGINT
    }

    // Вставити: Ctrl+V або Ctrl+Shift+V (без примусового Enter)
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyV) {
      _paste(s);
      return KeyEventResult.handled;
    }

    // Пошук у терміналі: Ctrl+F
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyF) {
      _openSearch(s);
      return KeyEventResult.handled;
    }

    final data = _encodeKey(e);
    if (data != null) {
      _sendInput(s, data);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _encodeKey(KeyEvent e) {
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;

    // Спеціальні клавіші
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      return '\r';
    }
    if (k == LogicalKeyboardKey.backspace) return '\x7f';
    if (k == LogicalKeyboardKey.tab) return '\t';
    if (k == LogicalKeyboardKey.escape) return '\x1b';
    if (k == LogicalKeyboardKey.arrowUp) return '\x1b[A';
    if (k == LogicalKeyboardKey.arrowDown) return '\x1b[B';
    if (k == LogicalKeyboardKey.arrowRight) return '\x1b[C';
    if (k == LogicalKeyboardKey.arrowLeft) return '\x1b[D';
    if (k == LogicalKeyboardKey.home) return '\x1b[H';
    if (k == LogicalKeyboardKey.end) return '\x1b[F';
    if (k == LogicalKeyboardKey.delete) return '\x1b[3~';
    if (k == LogicalKeyboardKey.insert) return '\x1b[2~';
    if (k == LogicalKeyboardKey.pageUp) return '\x1b[5~';
    if (k == LogicalKeyboardKey.pageDown) return '\x1b[6~';

    // Ctrl + літера -> контрольний код (Ctrl+C = 0x03 тощо)
    if (ctrl && !alt) {
      final ch = e.character;
      if (ch != null && ch.length == 1) {
        final c = ch.toLowerCase().codeUnitAt(0);
        if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
      }
      final lbl = k.keyLabel.toLowerCase();
      if (lbl.length == 1) {
        final c = lbl.codeUnitAt(0);
        if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
      }
      if (k == LogicalKeyboardKey.space) return '\x00';
      return null;
    }

    // Друкований символ (враховує розкладку та Shift)
    final ch = e.character;
    if (ch != null && ch.isNotEmpty) {
      if (ch.codeUnitAt(0) >= 0x20) return ch;
    }
    return null;
  }

  // Надіслати ввід у поточний термінал (або в усі, якщо broadcast).
  void _sendInput(TermSession s, String data) {
    if (_broadcast) {
      for (final x in _sessions) {
        if (x.alive) x.sendText(data);
      }
    } else {
      s.sendText(data);
    }
  }

  Future<void> _paste(TermSession s) async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text;
    if (t != null && t.isNotEmpty) {
      _sendInput(s, t.replaceAll('\r\n', '\n'));
    }
  }

  // Правий клік: вставити з буфера як пакет + Enter у кінці (без вікна).
  Future<void> _pasteAndEnter(TermSession s) async {
    final d = await Clipboard.getData('text/plain');
    var t = d?.text;
    if (t == null || t.isEmpty) return;
    t = t.replaceAll('\r\n', '\n');
    if (!t.endsWith('\n')) t += '\n';
    _sendInput(s, t);
    _toast('Вставлено');
  }

  // -------------------- Пошук / сесії --------------------
  void _openSearch(TermSession s) {
    setState(() {
      _searchSessionId = s.id;
      _searchQuery = '';
      _matches = [];
      _matchIdx = 0;
    });
  }

  void _closeSearch(TermSession s) {
    s.controller.clearSelection();
    setState(() {
      _searchSessionId = null;
      _matches = [];
      _searchQuery = '';
    });
    _focusActive();
  }

  void _runSearch(TermSession s, String q) {
    _searchQuery = q;
    _matches = [];
    _matchIdx = 0;
    if (q.isEmpty) {
      s.controller.clearSelection();
      setState(() {});
      return;
    }
    final ql = q.toLowerCase();
    final h = s.terminal.buffer.height;
    for (var r = 0; r < h; r++) {
      final text = s.terminal.buffer.lines[r].getText().toLowerCase();
      var idx = text.indexOf(ql);
      while (idx >= 0) {
        _matches.add([r, idx, q.length]);
        idx = text.indexOf(ql, idx + 1);
      }
    }
    if (_matches.isNotEmpty) {
      _jumpToMatch(s, _matches.length - 1);
    } else {
      setState(() {});
    }
  }

  void _jumpToMatch(TermSession s, int i) {
    if (_matches.isEmpty) return;
    var idx = i % _matches.length;
    if (idx < 0) idx += _matches.length;
    _matchIdx = idx;
    final m = _matches[idx];
    try {
      final line = s.terminal.buffer.lines[m[0]];
      s.controller.setSelection(
          line.createAnchor(m[1]), line.createAnchor(m[1] + m[2]));
    } catch (_) {}
    final sc = _scroll[s.id];
    if (sc != null && sc.hasClients) {
      final h = s.terminal.buffer.height;
      final vh = s.terminal.viewHeight;
      final max = sc.position.maxScrollExtent;
      final denom = h - vh;
      final cell = denom > 0 ? max / denom : 17.0;
      final target = ((m[0] - 2) * cell).clamp(0.0, max);
      sc.jumpTo(target);
    }
    setState(() {});
  }

  void _duplicate(TermSession s) => _connect(s.server.copy());

  Future<void> _reconnect(TermSession s) async {
    final srv = s.server.copy();
    await _closeSession(s);
    await _connect(srv);
  }

  Future<void> _showTabMenu(TermSession s, Offset pos) async {
    final lc = LC(widget.isDark);
    final v = await showMenu<String>(
      context: context,
      color: lc.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: lc.border)),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(
            value: 'dup', child: _menuRow(lc, 'copy-plus', 'Дублювати')),
        if (!s.alive)
          PopupMenuItem(
              value: 'recon',
              child: _menuRow(lc, 'refresh', 'Перепідключитися')),
        PopupMenuItem(value: 'close', child: _menuRow(lc, 'x', 'Закрити')),
      ],
    );
    if (v == 'dup') _duplicate(s);
    if (v == 'recon') _reconnect(s);
    if (v == 'close') _closeSession(s);
  }

  Widget _menuRow(LC lc, String icon, String label) => Row(children: [
        AppIcon(icon, size: 15, color: lc.accent),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: lc.text, fontSize: 13)),
      ]);

  // -------------------- Підключення --------------------
  Future<void> _connect(Server server) async {
    final session = TermSession(++_counter, server);
    _focus[session.id] = FocusNode();
    _scroll[session.id] = ScrollController();
    session.onData = () {
      if (mounted) setState(() {});
    };
    session.onClosed = () {
      if (mounted) setState(() {});
    };
    session.onCwd = (path) => _syncFmCwd(session, path);
    setState(() {
      _sessions.add(session);
      _activeId = session.id;
    });
    _toast('Підключення до ${server.host}…');
    try {
      await session.connect();
      if (mounted) setState(() {});
      _refreshFiles();
      _focusActive();
      _toast('Підключено: ${server.name.isEmpty ? server.host : server.name}');
      _maybeOfferKey(session);
    } catch (e) {
      _focus.remove(session.id)?.dispose();
      setState(() => _sessions.remove(session));
      _toast('Помилка підключення: $e');
    }
  }

  Future<void> _closeSession(TermSession s) async {
    await s.dispose();
    _focus.remove(s.id)?.dispose();
    _scroll.remove(s.id)?.dispose();
    _tunnels.remove(s.id)?.dispose();
    if (_searchSessionId == s.id) _searchSessionId = null;
    setState(() {
      _sessions.remove(s);
      if (_activeId == s.id) {
        _activeId = _sessions.isNotEmpty ? _sessions.last.id : -1;
      }
    });
    _refreshFiles();
    if (_activeId != -1) _focusActive();
  }

  void _activate(int id) {
    setState(() {
      _activeId = id;
      _selected.clear();
      _lastIndex = null;
    });
    _refreshFiles();
    _focusActive();
  }

  // -------------------- Файли (SFTP) --------------------
  Future<void> _refreshFiles() async {
    final s = _active;
    if (s == null || !s.alive) {
      setState(() {
        _files = [];
        _filePath = '';
      });
      return;
    }
    final dir = _cwd[s.id] ?? '.';
    try {
      final res = await s.listDir(dir);
      _cwd[s.id] = res.path;
      if (!mounted) return;
      setState(() {
        _filePath = res.path;
        _files = res.entries;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _files = [];
        _filePath = 'SFTP: $e';
      });
    }
  }

  void _navigate(String path) {
    final s = _active;
    if (s == null) return;
    _cwd[s.id] = path;
    _selected.clear();
    _lastIndex = null;
    _refreshFiles();
  }

  // ФМ слідує за `cd` у терміналі (реальний $PWD через OSC 7).
  void _syncFmCwd(TermSession s, String path) {
    _cwd[s.id] = path;
    if (s.id == _activeId) {
      _selected.clear();
      _lastIndex = null;
      _refreshFiles();
    }
  }

  String _parent(String p) {
    if (p == '/' || p.isEmpty) return '/';
    final t = p.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i <= 0 ? '/' : t.substring(0, i);
  }

  String _join(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';

  void _onFileTap(int index, FileEntry f) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final vis = _visibleFiles;
    setState(() {
      if (shift && _lastIndex != null) {
        final a = _lastIndex! <= index ? _lastIndex! : index;
        final b = _lastIndex! <= index ? index : _lastIndex!;
        if (!ctrl) _selected.clear();
        for (var i = a; i <= b && i < vis.length; i++) {
          _selected.add(vis[i].name);
        }
      } else if (ctrl) {
        if (!_selected.add(f.name)) _selected.remove(f.name);
        _lastIndex = index;
      } else {
        _selected
          ..clear()
          ..add(f.name);
        _lastIndex = index;
      }
    });
  }

  Future<void> _download(FileEntry f) async {
    final s = _active;
    if (s == null) return;
    final remote = _join(_filePath, f.name);
    final local = await FilePicker.platform.saveFile(fileName: f.name);
    if (local == null) return;
    await _runTransfer('Скачування ${f.name}', (p) async {
      try {
        await s.downloadFile(remote, local,
            onProgress: (r, t) => p(t > 0 ? r / t : null));
        _toast('Збережено: $local');
      } catch (e) {
        _toast('Помилка: $e');
      }
    });
  }

  // -------------------- Операції з файлами --------------------
  List<FileEntry> get _selectedEntries =>
      _files.where((f) => _selected.contains(f.name)).toList();

  Future<void> _uploadToCurrent() async {
    final s = _active;
    if (s == null) return;
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null || res.files.isEmpty) return;
    int ok = 0;
    for (var i = 0; i < res.files.length; i++) {
      final f = res.files[i];
      if (f.path == null) continue;
      await _runTransfer(
          'Вивантаження ${f.name} (${i + 1}/${res.files.length})', (p) async {
        try {
          await s.uploadFile(f.path!, _join(_filePath, f.name));
          ok++;
        } catch (e) {
          _toast('Помилка ${f.name}: $e');
        }
      });
    }
    _toast('Вивантажено $ok файл(ів) сюди');
    _refreshFiles();
  }

  Future<void> _downloadSelected() async {
    final s = _active;
    if (s == null) return;
    final files = _selectedEntries.where((f) => !f.isDir).toList();
    if (files.isEmpty) {
      _toast('Оберіть файли (не папки)');
      return;
    }
    if (files.length == 1) {
      await _download(files.first);
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    int ok = 0;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      await _runTransfer(
          'Скачування ${f.name} (${i + 1}/${files.length})', (p) async {
        try {
          await s.downloadFile(_join(_filePath, f.name), '$dir/${f.name}',
              onProgress: (r, t) => p(t > 0 ? r / t : null));
          ok++;
        } catch (e) {
          _toast('Помилка ${f.name}: $e');
        }
      });
    }
    _toast('Скачано $ok файл(ів) → $dir');
  }

  Future<void> _deleteSelected() async {
    final s = _active;
    if (s == null) return;
    final sel = _selectedEntries;
    if (sel.isEmpty) return;
    final names = sel.map((e) => e.name).join(', ');
    final ok = await _confirm(
      'Видалити ${sel.length} елемент(ів)?',
      'Буде видалено безповоротно:\n$names\n\nПапки видаляються з усім вмістом.',
    );
    if (!ok) return;
    int done = 0;
    for (final f in sel) {
      try {
        await s.deletePath(_join(_filePath, f.name), f.isDir);
        done++;
      } catch (e) {
        _toast('Помилка ${f.name}: $e');
      }
    }
    _selected.clear();
    _toast('Видалено $done');
    _refreshFiles();
  }

  Future<void> _renameSelected() async {
    final s = _active;
    if (s == null || _selected.length != 1) return;
    final old = _selected.first;
    final nn = await _promptText('Перейменувати', 'Нова назва', old);
    if (nn == null || nn.trim().isEmpty || nn.trim() == old) return;
    try {
      await s.renamePath(_join(_filePath, old), _join(_filePath, nn.trim()));
      _selected.clear();
      _toast('Перейменовано');
      _refreshFiles();
    } catch (e) {
      _toast('Помилка: $e');
    }
  }

  Future<void> _newFolder() async {
    final s = _active;
    if (s == null) return;
    final nn = await _promptText('Нова папка', 'Назва', 'new-folder');
    if (nn == null || nn.trim().isEmpty) return;
    try {
      await s.mkdir(_join(_filePath, nn.trim()));
      _toast('Створено');
      _refreshFiles();
    } catch (e) {
      _toast('Помилка: $e');
    }
  }

  Future<void> _chmodSelected() async {
    final s = _active;
    if (s == null) return;
    final sel = _selectedEntries;
    if (sel.isEmpty) return;
    int? cur;
    try {
      cur = await s.statMode(_join(_filePath, sel.first.name));
    } catch (_) {}
    final initial =
        cur != null ? (cur & 0x1FF).toRadixString(8).padLeft(3, '0') : '644';
    final octal = await _chmodDialog(initial);
    if (octal == null) return;
    final mode = int.tryParse(octal, radix: 8);
    if (mode == null) {
      _toast('Невірний формат (напр. 644)');
      return;
    }
    int done = 0;
    for (final f in sel) {
      try {
        await s.chmod(_join(_filePath, f.name), mode);
        done++;
      } catch (e) {
        _toast('Помилка ${f.name}: $e');
      }
    }
    _toast('Права змінено: $done');
    _refreshFiles();
  }

  // -------------------- Малі діалоги --------------------
  Future<String?> _promptText(String title, String label, String initial) {
    final ctrl = TextEditingController(text: initial);
    final lc = LC(widget.isDark);
    return _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 420,
        title: title,
        body: _field(ctrl, label, lc, autofocus: true),
        actions: [
          _ghostBtn(lc, 'Скасувати', () => Navigator.pop(ctx)),
          const SizedBox(width: 8),
          _primaryBtn(lc, 'OK', () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    final lc = LC(widget.isDark);
    final r = await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 440,
        title: title,
        body: Text(message, style: TextStyle(color: lc.text, fontSize: 13)),
        actions: [
          _ghostBtn(lc, 'Скасувати', () => Navigator.pop(ctx)),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: lc.bad),
            onPressed: () => Navigator.pop(ctx, 'ok'),
            child: const Text('Видалити'),
          ),
        ],
      ),
    );
    return r == 'ok';
  }

  Future<String?> _chmodDialog(String initial) {
    final ctrl = TextEditingController(text: initial);
    final lc = LC(widget.isDark);
    return _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 420,
        title: 'Змінити права (chmod)',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(ctrl, 'Вісімкові права (напр. 644, 755)', lc,
                autofocus: true),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ['644', '600', '755', '700', '777', '666']
                  .map((p) => ActionChip(
                        label: Text(p),
                        backgroundColor: lc.surface2,
                        labelStyle: TextStyle(color: lc.text, fontSize: 12),
                        onPressed: () => setLocal(() => ctrl.text = p),
                      ))
                  .toList(),
            ),
          ],
        ),
        actions: [
          _ghostBtn(lc, 'Скасувати', () => Navigator.pop(ctx)),
          const SizedBox(width: 8),
          _primaryBtn(lc, 'Застосувати', () => Navigator.pop(ctx, ctrl.text.trim())),
        ],
      ),
    );
  }

  // -------------------- Дії тулбару --------------------
  void _clear() {
    _active?.clear();
    setState(() {});
    _focusActive();
    _toast('Термінал і лог очищено');
  }

  Future<void> _copyLog() async {
    final s = _active;
    if (s == null) return;
    final text = s.plainLog;
    await Clipboard.setData(ClipboardData(text: text));
    _toast('Скопійовано весь лог (${_fmtBytes(text.length)})');
  }

  // -------------------- Діалоги (зверху екрана) --------------------
  Future<T?> _showTopSheet<T>(Widget Function(BuildContext, StateSetter) build) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, a, b) => StatefulBuilder(builder: build),
      transitionBuilder: (ctx, anim, sec, child) => Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 60, left: 12, right: 12),
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, -0.06), end: Offset.zero)
                .animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: FadeTransition(opacity: anim, child: child),
          ),
        ),
      ),
    );
  }

  Widget _dialogCard(
    BuildContext ctx,
    LC lc, {
    required String title,
    required Widget body,
    required List<Widget> actions,
    double width = 460,
  }) {
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: lc.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: lc.border),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 30,
                  offset: const Offset(0, 12)),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Text(title,
                    style: TextStyle(
                        color: lc.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                InkWell(
                  onTap: () => Navigator.pop(ctx),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: AppIcon('x', size: 18, color: lc.dim),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: body)),
              const SizedBox(height: 16),
              Row(children: [const Spacer(), ...actions]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _primaryBtn(LC lc, String label, VoidCallback onTap) => FilledButton(
        style: FilledButton.styleFrom(backgroundColor: lc.accent),
        onPressed: onTap,
        child: Text(label),
      );

  Widget _ghostBtn(LC lc, String label, VoidCallback onTap) => TextButton(
        onPressed: onTap,
        child: Text(label, style: TextStyle(color: lc.dim)),
      );

  Future<void> _openConnectDialog([Server? edit]) async {
    final s = edit?.copy() ?? Server();
    final name = TextEditingController(text: s.name);
    final host = TextEditingController(text: s.host);
    final port = TextEditingController(text: s.port.toString());
    final user = TextEditingController(text: s.username);
    final pass = TextEditingController(text: s.password);
    final key = TextEditingController(text: s.keyPath);
    final phrase = TextEditingController(text: s.passphrase);
    final group = TextEditingController(text: s.group);
    final tags = TextEditingController(text: s.tags.join(', '));
    final onConnect = TextEditingController(text: s.onConnect);
    final jHost = TextEditingController(text: s.jumpHost);
    final jPort = TextEditingController(text: s.jumpPort.toString());
    final jUser = TextEditingController(text: s.jumpUser);
    final jPass = TextEditingController(text: s.jumpPassword);
    bool saveIt = true;
    bool adv = s.jumpHost.isNotEmpty || s.onConnect.isNotEmpty;
    final lc = LC(widget.isDark);

    void fill(Server src) {
      s.id = src.id; // важливо: щоб оновлювати, а не дублювати
      name.text = src.name;
      host.text = src.host;
      port.text = src.port.toString();
      user.text = src.username;
      pass.text = src.password;
      key.text = src.keyPath;
      phrase.text = src.passphrase;
      group.text = src.group;
      tags.text = src.tags.join(', ');
      onConnect.text = src.onConnect;
      jHost.text = src.jumpHost;
      jPort.text = src.jumpPort.toString();
      jUser.text = src.jumpUser;
      jPass.text = src.jumpPassword;
    }

    final result = await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 480,
        title: edit == null ? 'Нове підключення' : 'Редагувати сервер',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_servers.isNotEmpty && edit == null) ...[
              DropdownButtonFormField<String>(
                isExpanded: true,
                dropdownColor: lc.surface,
                decoration: _dec(lc, 'Обрати збережений сервер'),
                items: _servers
                    .map((sv) => DropdownMenuItem(
                          value: sv.id,
                          child: Text(
                              '${sv.name}  ·  ${sv.username}@${sv.host}',
                              style: TextStyle(color: lc.text, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (id) {
                  final sv = _servers.firstWhere((x) => x.id == id);
                  fill(sv);
                  setLocal(() {});
                },
              ),
              const SizedBox(height: 4),
              Divider(color: lc.border, height: 20),
            ],
            _field(name, 'Назва', lc),
            Row(children: [
              Expanded(flex: 3, child: _field(host, 'Хост', lc)),
              const SizedBox(width: 8),
              Expanded(child: _field(port, 'Порт', lc, number: true)),
            ]),
            _field(user, 'Користувач', lc),
            _field(pass, 'Пароль', lc, obscure: true),
            Row(children: [
              Expanded(child: _field(key, 'Приватний ключ', lc)),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Обрати файл ключа',
                child: IconButton(
                  icon: AppIcon('folder-open', size: 20, color: lc.accent),
                  onPressed: () async {
                    final r = await FilePicker.platform.pickFiles();
                    if (r != null && r.files.single.path != null) {
                      key.text = r.files.single.path!;
                      setLocal(() {});
                    }
                  },
                ),
              ),
            ]),
            _field(phrase, 'Passphrase ключа', lc, obscure: true),
            Row(children: [
              Expanded(child: _field(group, 'Група', lc)),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: _field(tags, 'Теги (через кому)', lc)),
            ]),
            InkWell(
              onTap: () => setLocal(() => adv = !adv),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  AppIcon(adv ? 'eye' : 'eye-off', size: 15, color: lc.dim),
                  const SizedBox(width: 8),
                  Text('Додатково: автокоманда та jump-host',
                      style: TextStyle(color: lc.dim, fontSize: 12)),
                ]),
              ),
            ),
            if (adv) ...[
              _field(onConnect, 'Команда при підключенні', lc),
              Row(children: [
                Expanded(flex: 3, child: _field(jHost, 'Jump-host', lc)),
                const SizedBox(width: 8),
                Expanded(child: _field(jPort, 'Порт', lc, number: true)),
              ]),
              Row(children: [
                Expanded(child: _field(jUser, 'Jump-користувач', lc)),
                const SizedBox(width: 8),
                Expanded(
                    child: _field(jPass, 'Jump-пароль', lc, obscure: true)),
              ]),
            ],
            const SizedBox(height: 4),
            Row(children: [
              Checkbox(
                value: saveIt,
                activeColor: lc.accent,
                onChanged: (v) => setLocal(() => saveIt = v ?? true),
              ),
              Text('Зберегти сервер', style: TextStyle(color: lc.dim)),
            ]),
          ],
        ),
        actions: [
          _ghostBtn(lc, 'Скасувати', () => Navigator.pop(ctx, 'cancel')),
          const SizedBox(width: 8),
          _primaryBtn(lc, 'Підключитися', () => Navigator.pop(ctx, 'connect')),
        ],
      ),
    );

    if (result != 'connect') return;
    s
      ..name = name.text.trim().isEmpty ? host.text.trim() : name.text.trim()
      ..host = host.text.trim()
      ..port = int.tryParse(port.text.trim()) ?? 22
      ..username = user.text.trim()
      ..password = pass.text
      ..keyPath = key.text.trim()
      ..passphrase = phrase.text
      ..group = group.text.trim()
      ..tags = tags.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList()
      ..onConnect = onConnect.text
      ..jumpHost = jHost.text.trim()
      ..jumpPort = int.tryParse(jPort.text.trim()) ?? 22
      ..jumpUser = jUser.text.trim()
      ..jumpPassword = jPass.text;
    if (s.host.isEmpty || s.username.isEmpty) {
      _toast('Вкажіть хост і користувача');
      return;
    }
    if (saveIt) {
      if (s.id.isEmpty) {
        // якщо такий сервер уже є — оновити, а не дублювати
        final ex = _servers.indexWhere((x) =>
            x.host == s.host && x.username == s.username && x.port == s.port);
        if (ex >= 0) {
          s.id = _servers[ex].id;
          _servers[ex] = s;
        } else {
          s.id = 's_${DateTime.now().microsecondsSinceEpoch}';
          _servers.add(s);
        }
      } else {
        final i = _servers.indexWhere((x) => x.id == s.id);
        if (i >= 0) {
          _servers[i] = s;
        } else {
          _servers.add(s);
        }
      }
      await _saveServers();
      if (mounted) setState(() {});
    }
    await _connect(s);
  }

  Future<void> _deleteServer(Server s) async {
    _servers.removeWhere((x) => x.id == s.id);
    await _saveServers();
    setState(() {});
  }

  // -------------------- Вхід ключем цього ПК --------------------
  Future<void> _loadDeviceKey() async {
    _devicePub = await DeviceKey.publicLine();
    if (mounted) setState(() {});
  }

  // Збережений запис сервера, з якого відкрито сесію (сесія може мати копію).
  Server? _stored(Server s) {
    for (final x in _servers) {
      if (x.id.isNotEmpty && x.id == s.id) return x;
    }
    for (final x in _servers) {
      if (x.host == s.host && x.username == s.username && x.port == s.port) {
        return x;
      }
    }
    return null;
  }

  // Після входу паролем — запропонувати ключ (раз; «Не питати» запам'ятовується).
  Future<void> _maybeOfferKey(TermSession session) async {
    final s = _stored(session.server);
    if (s == null || s.keyPath.isNotEmpty || s.password.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final declined = prefs.getStringList(_keyDeclinedPref) ?? [];
    if (declined.contains(s.id) || !mounted) return;
    final lc = LC(widget.isDark);
    final v = await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        title: 'Входити на ${s.host} ключем?',
        body: Text(
            'Lumen допише ключ цього ПК у authorized_keys на сервері й перевірить, '
            'що він пускає. Пароль лишиться збереженим як запасний вхід.',
            style: TextStyle(color: lc.dim, fontSize: 12.5)),
        actions: [
          _ghostBtn(lc, 'Не питати', () => Navigator.pop(ctx, 'never')),
          _ghostBtn(lc, 'Не зараз', () => Navigator.pop(ctx, 'later')),
          const SizedBox(width: 8),
          _primaryBtn(lc, 'Перейти на ключ', () => Navigator.pop(ctx, 'yes')),
        ],
      ),
    );
    if (v == 'never') {
      await prefs.setStringList(_keyDeclinedPref, [...declined, s.id]);
    } else if (v == 'yes') {
      await _enableKey(s, via: session);
    }
  }

  Future<bool> _enableKey(Server s, {TermSession? via, bool quiet = false}) async {
    if (!quiet) _toast('Ставлю ключ на ${s.host}…');
    final err = await KeySwitch.enable(s, via: via);
    if (err != null) {
      if (!quiet) _toast('${s.host}: лишаю вхід паролем — $err');
      return false;
    }
    s.keyPath = DeviceKey.ref;
    via?.server.keyPath = DeviceKey.ref;
    await _saveServers();
    await _loadDeviceKey();
    if (!quiet) _toast('${s.host}: тепер вхід ключем, пароль — запасний');
    return true;
  }

  Future<void> _disableKey(Server s) async {
    _toast('Прибираю ключ із ${s.host}…');
    final err = await KeySwitch.disable(s);
    if (err != null) {
      _toast('${s.host}: ключ не прибрано — $err');
      return;
    }
    s.keyPath = '';
    await _saveServers();
    if (mounted) setState(() {});
    _toast('${s.host}: ключ прибрано, вхід паролем');
  }

  Future<void> _openServerKeyDialog(Server s) async {
    final lc = LC(widget.isDark);
    final uses = DeviceKey.uses(s);
    final custom = s.keyPath.isNotEmpty && !uses;
    final v = await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        title: 'Вхід на ${s.host}',
        body: Text(
            uses
                ? 'Ключ цього ПК (${_devicePub == null ? '—' : DeviceKey.fingerprint(_devicePub!)}). '
                    'Пароль: ${s.password.isEmpty ? 'не збережено' : 'збережено як запасний'}.'
                : custom
                    ? 'Власний ключ: ${s.keyPath}'
                    : 'Пароль. Ключ цього ПК на сервері не встановлено.',
            style: TextStyle(color: lc.dim, fontSize: 12.5)),
        actions: [
          _ghostBtn(lc, 'Закрити', () => Navigator.pop(ctx)),
          const SizedBox(width: 8),
          if (uses)
            _primaryBtn(lc, 'Прибрати ключ із сервера',
                () => Navigator.pop(ctx, 'off'))
          else if (!custom)
            _primaryBtn(lc, 'Перейти на ключ', () => Navigator.pop(ctx, 'on')),
        ],
      ),
    );
    if (v == 'on') await _enableKey(s);
    if (v == 'off') await _disableKey(s);
    if (mounted) setState(() {});
  }

  Future<void> _openDeviceKeyDialog() async {
    final lc = LC(widget.isDark);
    final targets = _servers
        .where((s) => s.keyPath.isEmpty && s.password.isNotEmpty)
        .toList();
    final log = ValueNotifier<List<String>>([]);
    var running = false;
    await _showTopSheet<void>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 620,
        title: 'Ключ цього ПК',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                _devicePub == null
                    ? 'Ключ ще не створено — з\'явиться під час першого переходу на ключ.'
                    : 'ed25519, ${DeviceKey.fingerprint(_devicePub!)}. Приватна частина '
                        'зашифрована DPAPI і не лежить окремим файлом.',
                style: TextStyle(color: lc.dim, fontSize: 12.5)),
            const SizedBox(height: 8),
            Text(
                'Серверів із паролем без ключа: ${targets.length}. На кожен Lumen '
                'увійде паролем, допише ключ і перевірить вхід ключем; '
                'де не вийде — лишиться пароль.',
                style: TextStyle(color: lc.dim, fontSize: 12.5)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ValueListenableBuilder<List<String>>(
                valueListenable: log,
                builder: (_, lines, __) => ListView(
                  shrinkWrap: true,
                  children: lines
                      .map((l) => Text(l,
                          style: TextStyle(
                              color: lc.text,
                              fontFamily: 'monospace',
                              fontSize: 12)))
                      .toList(),
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_devicePub != null)
            _ghostBtn(lc, 'Копіювати публічний ключ', () {
              Clipboard.setData(ClipboardData(text: _devicePub!));
              _toast('Публічний ключ скопійовано');
            }),
          _ghostBtn(lc, 'Закрити', () => Navigator.pop(ctx)),
          const SizedBox(width: 8),
          if (targets.isNotEmpty)
            _primaryBtn(lc, running ? 'Триває…' : 'Перевести всі на ключ', () async {
              if (running) return;
              setLocal(() => running = true);
              var ok = 0;
              for (final s in targets) {
                log.value = [...log.value, '${s.host} …'];
                final err = await KeySwitch.enable(s);
                if (err == null) {
                  s.keyPath = DeviceKey.ref;
                  ok++;
                  await _saveServers();
                }
                log.value = [
                  ...log.value.sublist(0, log.value.length - 1),
                  err == null ? '✓ ${s.host}' : '✗ ${s.host}: $err',
                ];
              }
              await _loadDeviceKey();
              log.value = [...log.value, 'Готово: $ok з ${targets.length} — по ключу.'];
              targets.removeWhere((s) => s.keyPath.isNotEmpty);
              if (ctx.mounted) setLocal(() => running = false);
            }),
        ],
      ),
    );
    log.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _openBatchDialog() async {
    final s = _active;
    if (s == null) {
      _toast('Немає активної сесії');
      return;
    }
    final ctrl = TextEditingController();
    bool addNewline = true;
    final lc = LC(widget.isDark);

    final result = await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 760,
        title: 'Пакетний ввід команд',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Вставте команди/скрипт — буде надіслано у поточний термінал.',
                style: TextStyle(color: lc.dim, fontSize: 12)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 18,
              style: TextStyle(
                  color: lc.text, fontFamily: 'monospace', fontSize: 13),
              decoration: _dec(lc, null).copyWith(
                hintText: "sudo bash <<'EOF'\n...\nEOF",
                hintStyle: TextStyle(color: lc.dim, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Checkbox(
                value: addNewline,
                activeColor: lc.accent,
                onChanged: (v) => setLocal(() => addNewline = v ?? true),
              ),
              Text('Додати Enter в кінці', style: TextStyle(color: lc.dim)),
            ]),
          ],
        ),
        actions: [
          _ghostBtn(lc, 'Скасувати', () => Navigator.pop(ctx, 'cancel')),
          const SizedBox(width: 8),
          _primaryBtn(lc, 'Надіслати', () => Navigator.pop(ctx, 'send')),
        ],
      ),
    );

    if (result != 'send') return;
    var text = ctrl.text.replaceAll('\r\n', '\n');
    if (addNewline && !text.endsWith('\n')) text += '\n';
    s.sendText(text);
    _focusActive();
    _toast('Команди надіслано');
  }

  Future<void> _openAccentDialog() async {
    final lc = LC(widget.isDark);
    const swatches = [
      0xFF5B9DFF,
      0xFF7C5CFF,
      0xFF3ECF8E,
      0xFFF5B74E,
      0xFFFF6B6B,
      0xFF42C8D4,
      0xFFEC4899,
      0xFF2F6BFF,
      0xFF14B8A6,
      0xFFF97316,
    ];
    await _showTopSheet<String>(
      (ctx, setLocal) => _dialogCard(
        ctx,
        lc,
        width: 360,
        title: 'Акцентний колір',
        body: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: swatches.map((v) {
            final c = Color(v);
            final sel = gAccent?.toARGB32() == v;
            return InkWell(
              onTap: () async {
                await widget.onAccentChanged(c);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: sel ? lc.text : lc.border, width: sel ? 3 : 1),
                ),
              ),
            );
          }).toList(),
        ),
        actions: [
          _ghostBtn(lc, 'Закрити', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  // -------------------- Модулі --------------------
  void _openSnippets() {
    showSnippetsDialog(context, isDark: widget.isDark, onRun: (cmd) {
      final a = _active;
      if (a != null) {
        a.sendText('$cmd\n');
        _focusActive();
      }
    });
  }

  void _openMonitor() {
    final s = _active;
    if (s == null || !s.alive) {
      _toast('Немає активної сесії');
      return;
    }
    showMonitorPanel(context, isDark: widget.isDark, run: (cmd) => s.run(cmd));
  }

  Future<void> _openTunnels() async {
    final s = _active;
    if (s == null || !s.alive) {
      _toast('Немає активної сесії');
      return;
    }
    final client = s.client;
    if (client == null) {
      _toast('Немає з\'єднання');
      return;
    }
    final mgr = _tunnels.putIfAbsent(s.id, () => TunnelManager(client));
    await showTunnelsDialog(context, isDark: widget.isDark, manager: mgr);
  }

  Future<void> _openEditor(FileEntry f) async {
    final s = _active;
    if (s == null) return;
    final path = _join(_filePath, f.name);
    if (f.size > 3 * 1024 * 1024) {
      _toast('Файл завеликий для редактора — скачайте його');
      return;
    }
    await showFileEditor(
      context,
      isDark: widget.isDark,
      path: path,
      load: () => s.readTextFile(path),
      save: (c) => s.writeTextFile(path, c),
    );
  }

  Future<void> _createFile() async {
    final s = _active;
    if (s == null) return;
    final nn = await _promptText('Новий файл', 'Назва', 'new-file.txt');
    if (nn == null || nn.trim().isEmpty) return;
    try {
      await s.createFile(_join(_filePath, nn.trim()));
      _toast('Створено');
      _refreshFiles();
    } catch (e) {
      _toast('Помилка: $e');
    }
  }

  Future<void> _copyPath() async {
    final p = _selected.length == 1 ? _join(_filePath, _selected.first) : _filePath;
    await Clipboard.setData(ClipboardData(text: p));
    _toast('Шлях скопійовано: $p');
  }

  Widget _toolsMenu(LC lc) {
    return Tooltip(
      message: 'Інструменти',
      child: PopupMenuButton<String>(
        tooltip: '',
        color: lc.surface,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: lc.border),
        ),
        icon: AppIcon('wrench', size: 18, color: lc.text),
        onSelected: (v) {
          switch (v) {
            case 'monitor':
              _openMonitor();
              break;
            case 'tunnels':
              _openTunnels();
              break;
            case 'keygen':
              showKeygenDialog(context, isDark: widget.isDark);
              break;
            case 'master':
              _setupMaster();
              break;
            case 'devkey':
              _openDeviceKeyDialog();
              break;
            case 'accent':
              _openAccentDialog();
              break;
            case 'broadcast':
              setState(() => _broadcast = !_broadcast);
              _toast(_broadcast
                  ? 'Broadcast увімкнено — ввід іде в усі вкладки'
                  : 'Broadcast вимкнено');
              break;
          }
        },
        itemBuilder: (ctx) => [
          _toolItem(lc, 'monitor', 'activity', 'Монітор системи'),
          _toolItem(lc, 'tunnels', 'network', 'Проброс портів (тунелі)'),
          _toolItem(lc, 'keygen', 'key', 'Генерація SSH-ключа'),
          _toolItem(lc, 'devkey', 'key', 'Ключ цього ПК і перехід на ключі'),
          _toolItem(lc, 'master', 'lock',
              _masterEnabled ? 'Майстер-пароль ✓' : 'Майстер-пароль'),
          _toolItem(lc, 'accent', 'palette', 'Акцентний колір'),
          const PopupMenuDivider(height: 8),
          _toolItem(lc, 'broadcast', 'radio',
              _broadcast ? 'Broadcast: увімкнено' : 'Broadcast: вимкнено'),
        ],
      ),
    );
  }

  PopupMenuItem<String> _toolItem(
      LC lc, String value, String icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      height: 42,
      child: Row(
        children: [
          AppIcon(icon, size: 16, color: lc.accent),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: lc.text, fontSize: 13)),
        ],
      ),
    );
  }

  // -------------------- UI --------------------
  @override
  Widget build(BuildContext context) {
    final lc = LC(widget.isDark);
    final narrow = MediaQuery.of(context).size.width < 720;
    return Scaffold(
      backgroundColor: lc.bg,
      drawer: narrow ? Drawer(child: _sidebar(lc)) : null,
      body: Stack(
        children: [
          Column(
            children: [
              _toolbar(lc, narrow),
              Expanded(
                child: Row(
                  children: [
                    if (!narrow) SizedBox(width: 264, child: _sidebar(lc)),
                    if (!narrow) VerticalDivider(width: 1, color: lc.border),
                    Expanded(child: _terminalArea(lc)),
                  ],
                ),
              ),
              _statusBar(lc),
            ],
          ),
          if (_toastMsg != null)
            Positioned(
              top: 58,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(child: _toastChip(lc, _toastMsg!)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toastChip(LC lc, String msg) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: lc.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.accent.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Text(msg,
          textAlign: TextAlign.center,
          style: TextStyle(color: lc.text, fontSize: 12.5)),
    );
  }

  Widget _toolbar(LC lc, bool narrow) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: lc.surface,
        border: Border(bottom: BorderSide(color: lc.border)),
      ),
      child: Row(
        children: [
          if (narrow)
            Builder(
              builder: (ctx) => IconButton(
                icon: AppIcon('menu', size: 22, color: lc.text),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          if (!narrow) ...[
            AppIcon('terminal', size: 18, color: lc.accent),
            const SizedBox(width: 6),
            Text('Lumen SSH',
                style: TextStyle(
                    color: lc.text, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(width: 12),
          ],
          Expanded(child: _tabBar(lc)),
          _tbtn(lc, 'plus', 'Нова сесія', () => _openConnectDialog()),
          _tbtn(lc, 'eraser', 'Очистити (лог теж)', _clear),
          _tbtn(lc, 'copy', 'Копіювати весь лог', _copyLog),
          _tbtn(lc, 'terminal-square', 'Пакетні команди', _openBatchDialog),
          _tbtn(lc, 'bookmark', 'Сніпети', _openSnippets),
          Tooltip(
            message: 'Split-панелі',
            child: IconButton(
              icon: AppIcon('split',
                  size: 19, color: _split ? lc.accent : lc.text),
              onPressed: () => setState(() => _split = !_split),
            ),
          ),
          _quickMenu(lc),
          _toolsMenu(lc),
          _tbtn(lc, widget.isDark ? 'sun' : 'moon', 'Світла / темна тема',
              widget.onToggleTheme),
        ],
      ),
    );
  }

  Widget _tabBar(LC lc) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _sessions.map((s) {
          final active = s.id == _activeId;
          return GestureDetector(
            onTap: () => _activate(s.id),
            onSecondaryTapUp: (d) => _showTabMenu(s, d.globalPosition),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                color: active ? lc.surface2 : lc.surface,
                border: Border.all(color: active ? lc.accent : lc.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: s.alive ? lc.good : lc.bad,
                        shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.server.name.isEmpty ? s.server.host : s.server.name,
                    style: TextStyle(
                        color: active ? lc.text : lc.dim, fontSize: 12.5),
                  ),
                  IconButton(
                    icon: AppIcon('x', size: 15, color: lc.dim),
                    splashRadius: 14,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    onPressed: () => _closeSession(s),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _tbtn(LC lc, String icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: IconButton(
        icon: AppIcon(icon, size: 19, color: lc.text),
        onPressed: onTap,
      ),
    );
  }

  // Групи швидких команд: [іконка, назва, команда]
  static const List<Map<String, Object>> _quickGroups = [
    {
      'title': 'Файли і диск',
      'items': [
        ['folder', 'Детальний лістинг', 'ls -lahF --color=auto'],
        ['folder', 'Розміри вмісту теки', 'du -sh -- ./* 2>/dev/null | sort -h'],
        ['hard-drive', 'Розмір поточної теки', 'du -sh .'],
        ['hard-drive', 'Місце на дисках', 'df -hT'],
      ],
    },
    {
      'title': 'Система',
      'items': [
        ['cpu', "Пам'ять", 'free -h'],
        ['activity', 'Топ процесів за RAM', 'ps aux --sort=-%mem | head -n 20'],
        ['activity', 'Топ процесів за CPU', 'ps aux --sort=-%cpu | head -n 20'],
        ['clock', 'Аптайм і навантаження', 'uptime'],
      ],
    },
    {
      'title': 'Мережа і сесії',
      'items': [
        ['network', 'Відкриті порти', 'ss -lntup'],
        ['users', 'Хто в системі', 'w'],
      ],
    },
  ];

  Widget _quickMenu(LC lc) {
    final s = _active;
    final enabled = s != null && s.alive;
    return Tooltip(
      message: 'Швидкі команди',
      child: PopupMenuButton<String>(
        enabled: enabled,
        tooltip: '',
        color: lc.surface,
        elevation: 10,
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 360),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: lc.border),
        ),
        icon: AppIcon('zap',
            size: 19,
            color: enabled ? lc.text : lc.dim.withValues(alpha: 0.4)),
        onSelected: (cmd) {
          final a = _active;
          if (a != null) {
            a.sendText('$cmd\n');
            _focusActive();
          }
        },
        itemBuilder: (ctx) {
          final entries = <PopupMenuEntry<String>>[];
          for (var g = 0; g < _quickGroups.length; g++) {
            if (g > 0) entries.add(const PopupMenuDivider(height: 8));
            entries.add(PopupMenuItem<String>(
              enabled: false,
              height: 26,
              child: Text(
                (_quickGroups[g]['title'] as String).toUpperCase(),
                style: TextStyle(
                    color: lc.dim,
                    fontSize: 10,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700),
              ),
            ));
            final items = _quickGroups[g]['items'] as List;
            for (final it in items) {
              final row = it as List;
              entries.add(PopupMenuItem<String>(
                value: row[2] as String,
                height: 48,
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: lc.surface2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: AppIcon(row[0] as String,
                          size: 15, color: lc.accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row[1] as String,
                              style:
                                  TextStyle(color: lc.text, fontSize: 12.5)),
                          const SizedBox(height: 1),
                          Text(row[2] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: lc.dim,
                                  fontSize: 10,
                                  fontFamily: 'monospace')),
                        ],
                      ),
                    ),
                  ],
                ),
              ));
            }
          }
          return entries;
        },
      ),
    );
  }

  // -------------------- Бокова панель --------------------
  Widget _sidebar(LC lc) {
    return Container(
      color: lc.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sideHead(lc, 'СЕРВЕРИ', 'plus', () => _openConnectDialog()),
          if (_servers.length > 3)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: SizedBox(
                height: 30,
                child: TextField(
                  onChanged: (v) => setState(() => _serverFilter = v),
                  style: TextStyle(color: lc.text, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Пошук серверів…',
                    hintStyle: TextStyle(color: lc.dim, fontSize: 12),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: AppIcon('search', size: 14, color: lc.dim),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 0, minHeight: 0),
                    filled: true,
                    fillColor: lc.surface2,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                  ),
                ),
              ),
            ),
          _serverList(lc),
          Divider(height: 1, color: lc.border),
          _filesHeader(lc),
          if (_fileSearchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: SizedBox(
                height: 30,
                child: TextField(
                  autofocus: true,
                  onChanged: (v) => setState(() => _fileFilter = v),
                  style: TextStyle(color: lc.text, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Фільтр файлів…',
                    hintStyle: TextStyle(color: lc.dim, fontSize: 12),
                    filled: true,
                    fillColor: lc.surface2,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                  ),
                ),
              ),
            ),
          if (_filePath.isNotEmpty) _breadcrumbs(lc),
          if (_transferLabel != null) _transferBar(lc),
          Expanded(
            child: DropTarget(
              onDragDone: (d) => _onDropFiles(d.files),
              onDragEntered: (_) => setState(() => _dragOver = true),
              onDragExited: (_) => setState(() => _dragOver = false),
              child: Container(
                color:
                    _dragOver ? lc.accent.withValues(alpha: 0.08) : null,
                child: _fileList(lc),
              ),
            ),
          ),
          _fileActions(lc),
        ],
      ),
    );
  }

  Widget _sideHead(LC lc, String title, String icon, VoidCallback onTap) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  color: lc.dim,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            icon: AppIcon(icon, size: 16, color: lc.dim),
            splashRadius: 14,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
            onPressed: onTap,
          ),
        ],
      ),
    );
  }

  Widget _filesHeader(LC lc) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      child: Row(
        children: [
          Text('ФАЙЛИ',
              style: TextStyle(
                  color: lc.dim,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          _hIcon(lc, _showHidden ? 'eye' : 'eye-off',
              _showHidden ? 'Ховати приховані' : 'Показати приховані',
              () => setState(() => _showHidden = !_showHidden)),
          _hIcon(lc, 'search', 'Пошук файлів', () {
            setState(() {
              _fileSearchOpen = !_fileSearchOpen;
              if (!_fileSearchOpen) _fileFilter = '';
            });
          }),
          _hIcon(lc, 'refresh', 'Оновити', _refreshFiles),
        ],
      ),
    );
  }

  Widget _hIcon(LC lc, String icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: IconButton(
          icon: AppIcon(icon, size: 15, color: lc.dim),
          splashRadius: 14,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(4),
          onPressed: onTap,
        ),
      );

  List<FileEntry> get _visibleFiles {
    var items = _files;
    if (!_showHidden) {
      items = items.where((f) => !f.name.startsWith('.')).toList();
    }
    if (_fileFilter.isNotEmpty) {
      final q = _fileFilter.toLowerCase();
      items = items.where((f) => f.name.toLowerCase().contains(q)).toList();
    }
    return items;
  }

  Future<void> _runTransfer(String label,
      Future<void> Function(void Function(double?) p) body) async {
    setState(() {
      _transferLabel = label;
      _transferValue = null;
    });
    try {
      await body((v) {
        if (mounted) setState(() => _transferValue = v);
      });
    } finally {
      if (mounted) {
        setState(() {
          _transferLabel = null;
          _transferValue = null;
        });
      }
    }
  }

  Widget _transferBar(LC lc) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_transferLabel!,
                style: TextStyle(color: lc.dim, fontSize: 10.5),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  minHeight: 3,
                  value: _transferValue,
                  backgroundColor: lc.surface2,
                  color: lc.accent),
            ),
          ],
        ),
      );

  Future<void> _onDropFiles(List<XFile> files) async {
    final s = _active;
    if (s == null || !s.alive) {
      _toast('Немає активної сесії');
      return;
    }
    setState(() => _dragOver = false);
    int ok = 0;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      await _runTransfer(
          'Вивантаження ${f.name} (${i + 1}/${files.length})', (p) async {
        try {
          await s.uploadFile(f.path, _join(_filePath, f.name));
          ok++;
        } catch (e) {
          _toast('Помилка ${f.name}: $e');
        }
      });
    }
    _toast('Вивантажено $ok файл(ів)');
    _refreshFiles();
  }

  bool _serverMatch(Server s) {
    if (_serverFilter.isEmpty) return true;
    final q = _serverFilter.toLowerCase();
    return s.name.toLowerCase().contains(q) ||
        s.host.toLowerCase().contains(q) ||
        s.group.toLowerCase().contains(q) ||
        s.tags.any((t) => t.toLowerCase().contains(q));
  }

  Widget _serverList(LC lc) {
    if (_servers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text('Немає збережених серверів',
            style: TextStyle(color: lc.dim, fontSize: 12)),
      );
    }
    final filtered = _servers.where(_serverMatch).toList();
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child:
            Text('Нічого не знайдено', style: TextStyle(color: lc.dim, fontSize: 12)),
      );
    }
    final groups = <String, List<Server>>{};
    for (final s in filtered) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return a.compareTo(b);
      });
    final children = <Widget>[];
    for (final g in keys) {
      if (g.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Text(g.toUpperCase(),
              style: TextStyle(
                  color: lc.dim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
        ));
      }
      for (final s in groups[g]!) {
        children.add(_serverTile(lc, s));
      }
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: children,
      ),
    );
  }

  Widget _serverTile(LC lc, Server s) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _connect(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(s.jumpHost.isNotEmpty ? 'network' : 'server',
                      size: 16, color: lc.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(s.name,
                        style: TextStyle(color: lc.text, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text('${s.username}@${s.host}',
                      style: TextStyle(color: lc.dim, fontSize: 10.5)),
                  InkWell(
                    onTap: () => _openServerKeyDialog(s),
                    borderRadius: BorderRadius.circular(4),
                    child: Tooltip(
                      message: DeviceKey.uses(s)
                          ? 'Вхід ключем цього ПК'
                          : 'Вхід паролем — перейти на ключ',
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: AppIcon(DeviceKey.uses(s) ? 'key' : 'lock',
                            size: 15,
                            color: DeviceKey.uses(s) ? lc.accent : lc.dim),
                      ),
                    ),
                  ),
                  _rowIcon(lc, 'pencil', () => _openConnectDialog(s)),
                  _rowIcon(lc, 'trash', () => _deleteServer(s)),
                ],
              ),
              if (s.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 3),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: s.tags
                        .map((t) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                  color: lc.surface2,
                                  borderRadius: BorderRadius.circular(4)),
                              child: Text(t,
                                  style: TextStyle(
                                      color: lc.dim, fontSize: 9.5)),
                            ))
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _breadcrumbs(LC lc) {
    final content = _filePath.startsWith('SFTP:')
        ? Text(_filePath,
            style: TextStyle(color: lc.bad, fontSize: 11),
            overflow: TextOverflow.ellipsis)
        : Builder(builder: (_) {
            final parts =
                _filePath.split('/').where((e) => e.isNotEmpty).toList();
            final crumbs = <Widget>[_crumb(lc, '/', '/')];
            var acc = '';
            for (final p in parts) {
              acc += '/$p';
              crumbs.add(Text('/',
                  style: TextStyle(color: lc.dim, fontSize: 11)));
              crumbs.add(_crumb(lc, p, acc));
            }
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(children: crumbs),
            );
          });
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
          color: lc.surface2, borderRadius: BorderRadius.circular(6)),
      child: content,
    );
  }

  Widget _crumb(LC lc, String label, String path) => InkWell(
        onTap: () => _navigate(path),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(label,
              style: TextStyle(
                  color: path == _filePath ? lc.text : lc.accent,
                  fontSize: 11,
                  fontFamily: 'monospace')),
        ),
      );

  Widget _rowIcon(LC lc, String icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AppIcon(icon, size: 15, color: lc.dim),
        ),
      );

  Widget _fileList(LC lc) {
    final s = _active;
    if (s == null || !s.alive) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text('Підключіться до сервера',
            style: TextStyle(color: lc.dim, fontSize: 12)),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _fileRow(lc,
            icon: 'arrow-up',
            label: '..',
            color: lc.dim,
            onDoubleTap: () => _navigate(_parent(_filePath))),
        ..._visibleFiles.asMap().entries.map((entry) {
          final i = entry.key;
          final f = entry.value;
          return _fileRow(
            lc,
            icon: f.isDir ? 'folder' : (f.isLink ? 'link' : 'file'),
            label: f.name,
            color: f.isDir ? lc.accent : lc.text,
            trailing: f.isDir ? null : _fmtBytes(f.size),
            selected: _selected.contains(f.name),
            onTap: () => _onFileTap(i, f),
            onDoubleTap: () =>
                f.isDir ? _navigate(_join(_filePath, f.name)) : _openEditor(f),
            onDownload: f.isDir ? null : () => _download(f),
          );
        }),
      ],
    );
  }

  Widget _fileRow(
    LC lc, {
    required String icon,
    required String label,
    required Color color,
    String? trailing,
    bool selected = false,
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
    VoidCallback? onDownload,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color:
            selected ? lc.accent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: Container(
            decoration: selected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: lc.accent.withValues(alpha: 0.55)))
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                AppIcon(icon,
                    size: 15, color: color == lc.text ? lc.dim : color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: TextStyle(color: color, fontSize: 12.5),
                      overflow: TextOverflow.ellipsis),
                ),
                if (trailing != null)
                  Text(trailing,
                      style: TextStyle(color: lc.dim, fontSize: 10.5)),
                if (onDownload != null)
                  InkWell(
                    onTap: onDownload,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: AppIcon('download', size: 15, color: lc.dim),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileActions(LC lc) {
    final s = _active;
    final has = s != null && s.alive;
    final n = _selected.length;
    return Container(
      decoration: BoxDecoration(
        color: lc.surface,
        border: Border(top: BorderSide(color: lc.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _fabtn(lc, 'upload', 'Завантажити файли сюди',
                      has ? _uploadToCurrent : null),
                  _fabtn(lc, 'folder-plus', 'Нова папка',
                      has ? _newFolder : null),
                  _fabtn(lc, 'file-plus', 'Новий файл',
                      has ? _createFile : null),
                  _fabtn(lc, 'download', 'Скачати вибране',
                      has && n > 0 ? _downloadSelected : null),
                  _fabtn(lc, 'copy', 'Копіювати шлях', has ? _copyPath : null),
                  _fabtn(lc, 'pencil', 'Перейменувати',
                      has && n == 1 ? _renameSelected : null),
                  _fabtn(lc, 'lock', 'Права (chmod)',
                      has && n > 0 ? _chmodSelected : null),
                  _fabtn(lc, 'trash', 'Видалити вибране',
                      has && n > 0 ? _deleteSelected : null,
                      danger: true),
                ],
              ),
            ),
          ),
          if (n > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('$n',
                  style: TextStyle(
                      color: lc.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _fabtn(LC lc, String icon, String tip, VoidCallback? onTap,
      {bool danger = false}) {
    final enabled = onTap != null;
    final color = !enabled
        ? lc.dim.withValues(alpha: 0.35)
        : (danger ? lc.bad : lc.text);
    return Tooltip(
      message: tip,
      child: IconButton(
        icon: AppIcon(icon, size: 18, color: color),
        splashRadius: 16,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }

  // -------------------- Область терміналів --------------------
  Widget _terminalArea(LC lc) {
    if (_sessions.isEmpty) {
      return Container(
        color: lc.termBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon('terminal', size: 46, color: lc.accent),
              const SizedBox(height: 10),
              Text('Lumen SSH',
                  style: TextStyle(
                      color: lc.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Оберіть сервер або створіть нову сесію',
                  style: TextStyle(color: lc.dim)),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: lc.accent),
                onPressed: () => _openConnectDialog(),
                icon: const AppIcon('plus', size: 18, color: Colors.white),
                label: const Text('Нова сесія'),
              ),
            ],
          ),
        ),
      );
    }
    // Split-режим: активна + перша інша сесія поруч.
    if (_split && _sessions.length >= 2) {
      final active = _active ?? _sessions.first;
      final other = _sessions.firstWhere((x) => x.id != active.id,
          orElse: () => _sessions.first);
      return Container(
        color: lc.termBg,
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            Expanded(child: _termView(active, lc)),
            const SizedBox(width: 6),
            Expanded(child: _termView(other, lc)),
          ],
        ),
      );
    }
    final idx = _sessions.indexWhere((s) => s.id == _activeId);
    return Container(
      color: lc.termBg,
      padding: const EdgeInsets.all(6),
      child: IndexedStack(
        index: idx < 0 ? 0 : idx,
        children: _sessions.map((s) => _termView(s, lc)).toList(),
      ),
    );
  }

  Widget _termView(TermSession s, LC lc) {
    final node = _focus[s.id]!;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              node.requestFocus();
              if (_activeId != s.id) setState(() => _activeId = s.id);
              if (e.buttons == kSecondaryButton) _pasteAndEnter(s);
            },
            child: Focus(
              focusNode: node,
              autofocus: s.id == _activeId,
              onKeyEvent: (n, e) => _onTermKey(s, e),
              child: TerminalView(
                s.terminal,
                controller: s.controller,
                scrollController: _scroll[s.id],
                readOnly: true,
                hardwareKeyboardOnly: true,
                theme: terminalTheme(widget.isDark),
                textStyle: const TerminalStyle(fontSize: 13),
              ),
            ),
          ),
        ),
        if (_searchSessionId == s.id)
          Positioned(top: 8, right: 8, child: _searchBar(lc, s)),
        if (!s.alive)
          Positioned.fill(
            child: Container(
              color: lc.termBg.withValues(alpha: 0.72),
              child: Center(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: lc.accent),
                  onPressed: () => _reconnect(s),
                  icon: const AppIcon('refresh', size: 16, color: Colors.white),
                  label: const Text('Перепідключитися'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _searchBar(LC lc, TermSession s) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        decoration: BoxDecoration(
          color: lc.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: lc.border),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 190,
              height: 30,
              child: Focus(
                onKeyEvent: (n, e) {
                  if (e is KeyDownEvent &&
                      e.logicalKey == LogicalKeyboardKey.escape) {
                    _closeSearch(s);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  autofocus: true,
                  onChanged: (v) => _runSearch(s, v),
                  onSubmitted: (_) => _jumpToMatch(s, _matchIdx - 1),
                  style: TextStyle(color: lc.text, fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Пошук у терміналі…',
                    hintStyle: TextStyle(color: lc.dim, fontSize: 12),
                    filled: true,
                    fillColor: lc.surface2,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 6, horizontal: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide(color: lc.border)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _searchQuery.isEmpty
                  ? ''
                  : (_matches.isEmpty ? '0/0' : '${_matchIdx + 1}/${_matches.length}'),
              style: TextStyle(color: lc.dim, fontSize: 11),
            ),
            _hIcon(lc, 'chevron-up', 'Попереднє',
                () => _jumpToMatch(s, _matchIdx - 1)),
            _hIcon(lc, 'chevron-down', 'Наступне',
                () => _jumpToMatch(s, _matchIdx + 1)),
            _hIcon(lc, 'x', 'Закрити', () => _closeSearch(s)),
          ],
        ),
      ),
    );
  }

  // -------------------- Нижня панель --------------------
  Widget _statusBar(LC lc) {
    final s = _active;
    final m = s?.metrics;
    final Widget bar = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: lc.surface,
        border: Border(top: BorderSide(color: lc.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (s != null && s.alive) ? lc.good : lc.bad,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            s == null
                ? 'не підключено'
                : (s.alive
                    ? (s.server.name.isEmpty ? s.server.host : s.server.name)
                    : 'закрито'),
            style: TextStyle(color: lc.dim, fontSize: 11.5),
          ),
          const SizedBox(width: 18),
          if (m != null)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _metric(lc, 'CPU', '${m.cpu.toStringAsFixed(0)}%', m.cpu),
                  _metric(
                      lc,
                      'RAM',
                      '${_fmtBytes(m.memUsed)}/${_fmtBytes(m.memTotal)}',
                      m.memTotal > 0 ? m.memUsed / m.memTotal * 100 : 0),
                  _metric(
                      lc,
                      'SWAP',
                      m.swapTotal > 0
                          ? '${_fmtBytes(m.swapUsed)}/${_fmtBytes(m.swapTotal)}'
                          : 'нема',
                      m.swapTotal > 0 ? m.swapUsed / m.swapTotal * 100 : 0),
                  _metric(
                      lc,
                      'ДИСК',
                      '${_fmtBytes(m.diskUsed)}/${_fmtBytes(m.diskTotal)}',
                      m.diskTotal > 0 ? m.diskUsed / m.diskTotal * 100 : 0),
                  _textMetric(lc, 'МЕР',
                      '↓${_fmtBytes(m.netRx)}/s  ↑${_fmtBytes(m.netTx)}/s'),
                  _textMetric(lc, 'LA',
                      '${m.load.map((x) => x.toStringAsFixed(2)).join(" ")} (${m.cores}c)'),
                  _textMetric(lc, 'UP', _fmtUptime(m.uptime)),
                ]),
              ),
            )
          else if (s != null && s.alive)
            Text('збір метрик…',
                style: TextStyle(color: lc.dim, fontSize: 11.5)),
          if (s != null && s.alive) ...[
            const SizedBox(width: 8),
            AppIcon('activity', size: 14, color: lc.dim),
          ],
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: (s != null && s.alive) ? _openMonitor : null,
        child: bar,
      ),
    );
  }

  Widget _metric(LC lc, String label, String value, double pct) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  color: lc.dim, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Container(
            width: 56,
            height: 6,
            decoration: BoxDecoration(
                color: lc.surface2, borderRadius: BorderRadius.circular(4)),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: (pct / 100).clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                    color: lc.barColor(pct),
                    borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(value, style: TextStyle(color: lc.dim, fontSize: 11.5)),
        ],
      ),
    );
  }

  Widget _textMetric(LC lc, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(children: [
        Text(label,
            style: TextStyle(
                color: lc.dim, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Text(value, style: TextStyle(color: lc.dim, fontSize: 11.5)),
      ]),
    );
  }

  // -------------------- Дрібне --------------------
  InputDecoration _dec(LC lc, String? label) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: lc.dim, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: lc.surface2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: BorderSide(color: lc.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: BorderSide(color: lc.accent)),
      );

  Widget _field(TextEditingController c, String label, LC lc,
      {bool obscure = false, bool number = false, bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: c,
        obscureText: obscure,
        autofocus: autofocus,
        keyboardType: number ? TextInputType.number : null,
        style: TextStyle(color: lc.text, fontSize: 13),
        decoration: _dec(lc, label),
      ),
    );
  }

  static String _fmtBytes(int n) {
    const u = ['B', 'K', 'M', 'G', 'T'];
    double v = n.toDouble();
    int i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)}${u[i]}';
  }

  static String _fmtUptime(double sec) {
    final d = sec ~/ 86400;
    final h = (sec % 86400) ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (d > 0) return '${d}д ${h}г';
    if (h > 0) return '${h}г ${m}хв';
    return '${m}хв';
  }
}
