import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

import 'server.dart';

/// Метрики навантаження сервера для нижньої панелі.
class Metrics {
  double cpu = 0;
  int memUsed = 0;
  int memTotal = 0;
  int swapUsed = 0;
  int swapTotal = 0;
  List<double> load = [0, 0, 0];
  double uptime = 0;
  int cores = 1;
  int netRx = 0; // байт/с завантаження
  int netTx = 0; // байт/с відвантаження
  int diskUsed = 0;
  int diskTotal = 0;
}

/// Запис у файловому браузері.
class FileEntry {
  final String name;
  final bool isDir;
  final bool isLink;
  final int size;
  FileEntry(this.name, this.isDir, this.isLink, this.size);
}

/// Одна SSH-сесія: клієнт + shell + термінал + метрики + SFTP.
class TermSession {
  final int id;
  final Server server;
  final Terminal terminal = Terminal(maxLines: 100000);
  final TerminalController controller = TerminalController();
  final StringBuffer log = StringBuffer();

  bool alive = false;
  Metrics? metrics;

  SSHClient? _client;
  SSHClient? _jumpClient;
  ServerSocket? _jumpServer;
  SSHSession? _shell; // канал shell з dartssh2
  SftpClient? _sftp;
  Timer? _metricsTimer;
  Map<String, int>? _prevCpu;
  int? _prevNetRx;
  int? _prevNetTx;
  DateTime? _prevNetTime;

  void Function()? onData; // оновити UI (метрики/лог)
  void Function()? onClosed;
  void Function(String path)? onCwd; // зміна робочої теки ($PWD)

  static final RegExp _osc7 =
      RegExp(r'\x1B\]7;file://[^/\x07\x1B]*(/[^\x07\x1B]*)(?:\x07|\x1B\\)');
  String? _lastCwd;
  String? _suppressEcho; // приховати відлуння службової команди при підключенні
  StringBuffer? _echoBuf;
  Timer? _echoTimer;

  TermSession(this.id, this.server);

  static const _metricsCmd =
      "LC_ALL=C sh -c \"head -1 /proc/stat; echo ---; "
      "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; echo ---; "
      "cat /proc/loadavg; echo ---; cat /proc/uptime; echo ---; nproc; echo ---; "
      "cat /proc/net/dev; echo ---; df -PB1 / | tail -1\"";

  // Відкриває сокет до цільового сервера — напряму або через jump-host.
  Future<SSHSocket> _openSocket() async {
    if (server.jumpHost.isEmpty) {
      return SSHSocket.connect(server.host, server.port,
          timeout: const Duration(seconds: 20));
    }
    final jumpSocket = await SSHSocket.connect(
        server.jumpHost, server.jumpPort,
        timeout: const Duration(seconds: 20));
    _jumpClient = SSHClient(
      jumpSocket,
      username: server.jumpUser.isEmpty ? server.username : server.jumpUser,
      onPasswordRequest: () => server.jumpPassword,
    );
    final ss = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _jumpServer = ss;
    ss.listen((sock) async {
      try {
        final ch = await _jumpClient!.forwardLocal(server.host, server.port);
        sock.listen((d) => ch.sink.add(d),
            onDone: () => ch.sink.close(), onError: (_) => ch.sink.close());
        ch.stream.listen((d) => sock.add(d),
            onDone: () => sock.destroy(), onError: (_) => sock.destroy());
      } catch (_) {
        sock.destroy();
      }
    });
    return SSHSocket.connect('127.0.0.1', ss.port,
        timeout: const Duration(seconds: 20));
  }

  Future<void> connect() async {
    final socket = await _openSocket();

    List<SSHKeyPair> identities = [];
    if (server.keyPath.isNotEmpty) {
      final pem = await File(server.keyPath).readAsString();
      identities = SSHKeyPair.fromPem(
        pem,
        server.passphrase.isEmpty ? null : server.passphrase,
      );
    }

    _client = SSHClient(
      socket,
      username: server.username,
      identities: identities,
      onPasswordRequest: () => server.password,
    );

    // TerminalView підганяє розмір терміналу ще до підключення, тому PTY
    // відкриваємо одразу з реальним розміром (а не 80x24) — інакше bash
    // переносить довгі рядки на 80-й колонці й пише поверх запрошення.
    _shell = await _client!.shell(
      pty: SSHPtyConfig(width: terminal.viewWidth, height: terminal.viewHeight),
    );
    alive = true;

    // ввід користувача з терміналу -> у shell
    terminal.onOutput = (data) {
      _shell?.write(utf8.encode(data));
    };
    // зміна розміру терміналу -> pty
    terminal.onResize = (w, h, pw, ph) {
      _shell?.resizeTerminal(w, h);
    };
    // розмір міг змінитися, поки відкривався shell
    _shell!.resizeTerminal(terminal.viewWidth, terminal.viewHeight);

    // вивід сервера -> у термінал + лог; потоковий декодер не рве
    // багатобайтові UTF-8 символи (кирилицю) на межі пакетів
    const decoder = Utf8Decoder(allowMalformed: true);
    _shell!.stdout.cast<List<int>>().transform(decoder).listen(
      _onOutput,
      onDone: _handleClose,
    );
    _shell!.stderr.cast<List<int>>().transform(decoder).listen(_onOutput);

    _startMetrics();

    // Відстеження робочої теки: bash емітує OSC 7 з $PWD перед кожним запрошенням.
    // Відлуння цієї службової команди приховуємо у _onOutput (див. _suppressEcho),
    // тож банер лишається, а рядка не видно.
    const cwdCmd =
        " export PROMPT_COMMAND='printf \"\\033]7;%s\\007\" \"\$PWD\"'";
    _suppressEcho = cwdCmd;
    _shell!.write(utf8.encode('$cwdCmd\r'));

    // Автокоманда при підключенні.
    if (server.onConnect.trim().isNotEmpty) {
      var cmd = server.onConnect.replaceAll('\r\n', '\n');
      if (!cmd.endsWith('\n')) cmd += '\n';
      _shell!.write(utf8.encode(cmd));
    }
  }

  void _onOutput(String s) {
    if (_suppressEcho != null) {
      _bufferEcho(s);
      return;
    }
    _emit(s);
  }

  // Притримує вивід, поки не побачить відлуння службової команди, тоді викидає
  // її разом із наступним запрошенням (лишаючи банер). Стійке до розбиття на пакети.
  void _bufferEcho(String s) {
    final buf = (_echoBuf ??= StringBuffer())..write(s);
    final full = buf.toString();
    final idx = full.indexOf(_suppressEcho!);
    if (idx >= 0) {
      _echoTimer?.cancel();
      _echoTimer = Timer(const Duration(milliseconds: 220), () {
        final f = _echoBuf?.toString() ?? '';
        final i = f.indexOf(_suppressEcho!);
        final before = i >= 0 ? f.substring(0, i) : f;
        _resetEcho();
        _emit(before);
      });
      return;
    }
    if (full.length > 16384) {
      final f = full;
      _resetEcho();
      _emit(f);
      return;
    }
    // Запобіжник: якщо команда так і не відлунала (не bash) — віддати як є.
    _echoTimer ??= Timer(const Duration(milliseconds: 1200), () {
      final f = _echoBuf?.toString() ?? '';
      _resetEcho();
      _emit(f);
    });
  }

  void _resetEcho() {
    _echoTimer?.cancel();
    _echoTimer = null;
    _echoBuf = null;
    _suppressEcho = null;
  }

  void _emit(String s) {
    if (s.isEmpty) return;
    terminal.write(s);
    log.write(s);
    _detectCwd(s);
    // обмежуємо буфер логу ~8 МБ
    if (log.length > 8000000) {
      final txt = log.toString();
      log
        ..clear()
        ..write(txt.substring(txt.length - 8000000));
    }
  }

  void _detectCwd(String data) {
    final matches = _osc7.allMatches(data);
    if (matches.isEmpty) return;
    final enc = matches.last.group(1);
    if (enc == null) return;
    String path;
    try {
      path = Uri.decodeFull(enc);
    } catch (_) {
      path = enc;
    }
    if (path.isNotEmpty && path != _lastCwd) {
      _lastCwd = path;
      onCwd?.call(path);
    }
  }

  void _handleClose() {
    if (!alive) return;
    alive = false;
    terminal.write("\r\n\x1b[31m[з'єднання закрито]\x1b[0m\r\n");
    onClosed?.call();
  }

  // -------------------- Метрики --------------------
  void _startMetrics() {
    _poll();
    _metricsTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (_) => _poll());
  }

  Future<void> _poll() async {
    final c = _client;
    if (c == null || !alive) return;
    try {
      final out = await c.run(_metricsCmd);
      final m = _parseMetrics(utf8.decode(out, allowMalformed: true));
      if (m != null) {
        metrics = m;
        onData?.call();
      }
    } catch (_) {}
  }

  Metrics? _parseMetrics(String out) {
    final parts = out.split('---').map((e) => e.trim()).toList();
    if (parts.length < 5) return null;
    final m = Metrics();

    // CPU
    final cpuNums = parts[0]
        .split(RegExp(r'\s+'))
        .skip(1)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    if (cpuNums.length >= 5) {
      final idle = cpuNums[3] + cpuNums[4];
      final total = cpuNums.fold<int>(0, (a, b) => a + b);
      if (_prevCpu != null) {
        final dIdle = idle - _prevCpu!['idle']!;
        final dTotal = total - _prevCpu!['total']!;
        m.cpu = dTotal > 0
            ? ((1 - dIdle / dTotal) * 100).clamp(0, 100).toDouble()
            : 0;
      }
      _prevCpu = {'idle': idle, 'total': total};
    }

    // Пам'ять
    final mem = <String, int>{};
    for (final line in parts[1].split('\n')) {
      final mm = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (mm != null) mem[mm.group(1)!] = int.parse(mm.group(2)!);
    }
    m.memTotal = (mem['MemTotal'] ?? 0) * 1024;
    m.memUsed = m.memTotal - (mem['MemAvailable'] ?? 0) * 1024;
    m.swapTotal = (mem['SwapTotal'] ?? 0) * 1024;
    m.swapUsed = m.swapTotal - (mem['SwapFree'] ?? 0) * 1024;

    // Load average
    final la = parts[2].split(RegExp(r'\s+'));
    double at(int i) => i < la.length ? (double.tryParse(la[i]) ?? 0) : 0;
    m.load = [at(0), at(1), at(2)];

    // Uptime
    m.uptime = double.tryParse(parts[3].split(RegExp(r'\s+')).first) ?? 0;

    // Ядра
    m.cores = int.tryParse(parts[4].trim()) ?? 1;

    // Мережа (байт/с)
    if (parts.length > 5) {
      int rx = 0, tx = 0;
      for (final line in parts[5].split('\n')) {
        final ci = line.indexOf(':');
        if (ci < 0) continue;
        final name = line.substring(0, ci).trim();
        if (name.isEmpty || name == 'lo') continue;
        final f = line.substring(ci + 1).trim().split(RegExp(r'\s+'));
        if (f.length >= 9) {
          rx += int.tryParse(f[0]) ?? 0;
          tx += int.tryParse(f[8]) ?? 0;
        }
      }
      final now = DateTime.now();
      if (_prevNetRx != null && _prevNetTime != null) {
        final dt = now.difference(_prevNetTime!).inMilliseconds / 1000.0;
        if (dt > 0) {
          final r = ((rx - _prevNetRx!) / dt).round();
          final t = ((tx - _prevNetTx!) / dt).round();
          m.netRx = r < 0 ? 0 : r;
          m.netTx = t < 0 ? 0 : t;
        }
      }
      _prevNetRx = rx;
      _prevNetTx = tx;
      _prevNetTime = now;
    }

    // Диск (root)
    if (parts.length > 6) {
      final f = parts[6].trim().split(RegExp(r'\s+'));
      if (f.length >= 3) {
        m.diskTotal = int.tryParse(f[1]) ?? 0;
        m.diskUsed = int.tryParse(f[2]) ?? 0;
      }
    }
    return m;
  }

  // -------------------- SFTP --------------------
  Future<SftpClient> _getSftp() async {
    _sftp ??= await _client!.sftp();
    return _sftp!;
  }

  Future<({String path, List<FileEntry> entries})> listDir(String dir) async {
    final sftp = await _getSftp();
    final target = dir.isEmpty ? '.' : dir;
    final real = await sftp.absolute(target);
    final names = await sftp.listdir(real);
    final entries = <FileEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      final ln = n.longname;
      final isDir = ln.isNotEmpty ? ln[0] == 'd' : (n.attr.isDirectory);
      final isLink = ln.isNotEmpty && ln[0] == 'l';
      entries.add(FileEntry(n.filename, isDir, isLink, n.attr.size ?? 0));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return (path: real, entries: entries);
  }

  Future<void> downloadFile(String remotePath, String localPath,
      {void Function(int received, int total)? onProgress}) async {
    final sftp = await _getSftp();
    final file = await sftp.open(remotePath);
    try {
      int total = 0;
      try {
        final attrs = await file.stat();
        total = attrs.size ?? 0;
      } catch (_) {}
      final sink = File(localPath).openWrite();
      int received = 0;
      await for (final chunk in file.read()) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
    } finally {
      await file.close();
    }
  }

  Future<void> uploadFile(String localPath, String remotePath) async {
    final sftp = await _getSftp();
    final data = await File(localPath).readAsBytes();
    final file = await sftp.open(remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate);
    try {
      await file.writeBytes(data);
    } finally {
      await file.close();
    }
  }

  Future<void> deletePath(String path, bool isDir) async {
    final sftp = await _getSftp();
    if (!isDir) {
      await sftp.remove(path);
      return;
    }
    await _rmRecursive(sftp, path);
  }

  Future<void> _rmRecursive(SftpClient sftp, String path) async {
    final names = await sftp.listdir(path);
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      final child =
          path.endsWith('/') ? '$path${n.filename}' : '$path/${n.filename}';
      final ln = n.longname;
      final isDir = ln.isNotEmpty ? ln[0] == 'd' : n.attr.isDirectory;
      if (isDir) {
        await _rmRecursive(sftp, child);
      } else {
        await sftp.remove(child);
      }
    }
    await sftp.rmdir(path);
  }

  Future<void> chmod(String path, int mode) async {
    final sftp = await _getSftp();
    await sftp.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode)));
  }

  Future<int?> statMode(String path) async {
    final sftp = await _getSftp();
    final st = await sftp.stat(path);
    return st.mode?.value;
  }

  Future<void> mkdir(String path) async {
    final sftp = await _getSftp();
    await sftp.mkdir(path);
  }

  Future<void> renamePath(String oldPath, String newPath) async {
    final sftp = await _getSftp();
    await sftp.rename(oldPath, newPath);
  }

  Future<void> createFile(String path) async {
    final sftp = await _getSftp();
    final f = await sftp.open(path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write);
    await f.close();
  }

  // Доступ для модулів (тунелі тощо)
  SSHClient? get client => _client;

  // Виконати команду в окремому каналі, повернути stdout.
  Future<String> run(String cmd) async {
    final c = _client;
    if (c == null) return '';
    final out = await c.run(cmd);
    return utf8.decode(out, allowMalformed: true);
  }

  Future<String> readTextFile(String path) async {
    final sftp = await _getSftp();
    final file = await sftp.open(path);
    try {
      final data = await file.readBytes();
      return utf8.decode(data, allowMalformed: true);
    } finally {
      await file.close();
    }
  }

  Future<void> writeTextFile(String path, String content) async {
    final sftp = await _getSftp();
    final file = await sftp.open(path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate);
    try {
      await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
    } finally {
      await file.close();
    }
  }

  // -------------------- Дії --------------------
  // Прибирає ANSI/escape-послідовності та керуючі символи для чистого копіювання.
  static final RegExp _ansi = RegExp(
    r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)' // OSC (напр. заголовок вікна)
    r'|\x1B\[[0-?]*[ -/]*[@-~]' // CSI (кольори, курсор, ?2004h тощо)
    r'|\x1B[@-Z^_\\]' // інші Fe-escape
    r'|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', // керуючі символи (крім \t \n \r)
  );

  String get plainLog => log.toString().replaceAll(_ansi, '');

  void sendText(String text) {
    _shell?.write(utf8.encode(text));
  }

  void clear() {
    // очистити екран + буфер прокрутки
    terminal.write('\x1b[3J\x1b[2J\x1b[H');
    log.clear();
  }

  String get selectedText {
    final sel = controller.selection;
    if (sel == null) return '';
    return terminal.buffer.getText(sel);
  }

  void clearSelection() => controller.clearSelection();

  Future<void> dispose() async {
    _metricsTimer?.cancel();
    _echoTimer?.cancel();
    controller.dispose();
    alive = false;
    try {
      _shell?.close();
    } catch (_) {}
    try {
      _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    try {
      _jumpServer?.close();
    } catch (_) {}
    try {
      _jumpClient?.close();
    } catch (_) {}
  }
}
