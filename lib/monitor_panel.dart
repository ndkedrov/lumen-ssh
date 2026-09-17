import 'dart:async';

import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'theme.dart';

/// Показує живу панель моніторингу системи ("міні-htop").
Future<void> showMonitorPanel(
  BuildContext context, {
  required bool isDark,
  required Future<String> Function(String command) run,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, a, b) => _MonitorDialog(isDark: isDark, run: run),
    transitionBuilder: (ctx, anim, sec, child) => Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 48, left: 12, right: 12, bottom: 24),
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -0.06), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        ),
      ),
    ),
  );
}

// Розділювач секцій у комбінованій команді.
const String _sec = '@@SEC@@';

// Єдина команда, що повертає всі потрібні секції за один виклик run().
const String _command =
    "LC_ALL=C sh -c 'cat /proc/stat; echo @@SEC@@; cat /proc/meminfo; "
    "echo @@SEC@@; cat /proc/net/dev; echo @@SEC@@; df -PB1 /; echo @@SEC@@; "
    "ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head -n 13; echo @@SEC@@; nproc'";

/// Зразок /proc/stat (сумарний і по ядрах) для обчислення дельт.
class _CpuSample {
  final int total;
  final int idle;
  const _CpuSample(this.total, this.idle);
}

/// Зразок мережевого трафіку (сумарні байти) для обчислення швидкості.
class _NetSample {
  final int rx;
  final int tx;
  final DateTime at;
  const _NetSample(this.rx, this.tx, this.at);
}

/// Рядок таблиці процесів.
class _Proc {
  final String pid;
  final String cpu;
  final String mem;
  final String comm;
  const _Proc(this.pid, this.cpu, this.mem, this.comm);
}

/// Розібрані показники одного оновлення.
class _Stats {
  List<double> coreBusy = const [];
  double cpuBusy = 0;
  int memTotal = 0;
  int memUsed = 0;
  int swapTotal = 0;
  int swapUsed = 0;
  double rxRate = 0;
  double txRate = 0;
  int diskUsed = 0;
  int diskSize = 0;
  List<_Proc> procs = const [];
  bool hasCpu = false;
  bool hasNet = false;
}

class _MonitorDialog extends StatefulWidget {
  final bool isDark;
  final Future<String> Function(String command) run;
  const _MonitorDialog({required this.isDark, required this.run});

  @override
  State<_MonitorDialog> createState() => _MonitorDialogState();
}

class _MonitorDialogState extends State<_MonitorDialog> {
  Timer? _timer;
  bool _inFlight = false;
  bool _busy = false;
  String? _error;
  _Stats? _stats;

  // Попередні зразки для обчислення дельт.
  List<_CpuSample> _prevCores = const [];
  _CpuSample? _prevCpu;
  _NetSample? _prevNet;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_inFlight) return; // не запускаємо паралельні виклики
    _inFlight = true;
    if (mounted) setState(() => _busy = true);
    try {
      final out = await widget.run(_command);
      if (!mounted) return;
      final s = _parse(out);
      setState(() {
        _stats = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _inFlight = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  _Stats _parse(String out) {
    final s = _Stats();
    final sections = out.split(_sec);
    String sec(int i) => i < sections.length ? sections[i] : '';

    _parseCpu(sec(0), s);
    _parseMem(sec(1), s);
    _parseNet(sec(2), s);
    _parseDisk(sec(3), s);
    _parseProcs(sec(4), s);
    return s;
  }

  void _parseCpu(String raw, _Stats s) {
    try {
      final lines = raw.split('\n');
      _CpuSample? cpuNow;
      final coresNow = <_CpuSample>[];
      for (final line in lines) {
        if (!line.startsWith('cpu')) continue;
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;
        final label = parts[0];
        final nums = <int>[];
        for (var i = 1; i < parts.length; i++) {
          nums.add(int.tryParse(parts[i]) ?? 0);
        }
        var total = 0;
        for (final n in nums) {
          total += n;
        }
        // idle = field4 (idle) + field5 (iowait) -> indexes 3 та 4.
        final idle = (nums.length > 3 ? nums[3] : 0) +
            (nums.length > 4 ? nums[4] : 0);
        final sample = _CpuSample(total, idle);
        if (label == 'cpu') {
          cpuNow = sample;
        } else {
          coresNow.add(sample);
        }
      }

      if (cpuNow != null && _prevCpu != null) {
        s.cpuBusy = _busyPct(_prevCpu!, cpuNow);
        s.hasCpu = true;
      }
      if (coresNow.isNotEmpty && _prevCores.length == coresNow.length) {
        final list = <double>[];
        for (var i = 0; i < coresNow.length; i++) {
          list.add(_busyPct(_prevCores[i], coresNow[i]));
        }
        s.coreBusy = list;
        s.hasCpu = true;
      }
      _prevCpu = cpuNow;
      _prevCores = coresNow;
    } catch (_) {
      // Ігноруємо помилки розбору цієї секції.
    }
  }

  double _busyPct(_CpuSample prev, _CpuSample now) {
    final totalDelta = now.total - prev.total;
    final idleDelta = now.idle - prev.idle;
    if (totalDelta <= 0) return 0;
    final busy = (1 - idleDelta / totalDelta) * 100;
    return busy.clamp(0, 100).toDouble();
  }

  void _parseMem(String raw, _Stats s) {
    try {
      int? memTotal, memAvail, swapTotal, swapFree;
      for (final line in raw.split('\n')) {
        final m = RegExp(r'^(\w+):\s+(\d+)\s*kB').firstMatch(line.trim());
        if (m == null) continue;
        final key = m.group(1);
        final kb = int.tryParse(m.group(2) ?? '') ?? 0;
        final bytes = kb * 1024;
        switch (key) {
          case 'MemTotal':
            memTotal = bytes;
            break;
          case 'MemAvailable':
            memAvail = bytes;
            break;
          case 'SwapTotal':
            swapTotal = bytes;
            break;
          case 'SwapFree':
            swapFree = bytes;
            break;
        }
      }
      if (memTotal != null) {
        s.memTotal = memTotal;
        s.memUsed = (memTotal - (memAvail ?? memTotal)).clamp(0, memTotal);
      }
      if (swapTotal != null) {
        s.swapTotal = swapTotal;
        s.swapUsed = (swapTotal - (swapFree ?? swapTotal)).clamp(0, swapTotal);
      }
    } catch (_) {}
  }

  void _parseNet(String raw, _Stats s) {
    try {
      var rx = 0, tx = 0;
      for (final line in raw.split('\n')) {
        final idx = line.indexOf(':');
        if (idx < 0) continue;
        final iface = line.substring(0, idx).trim();
        if (iface.isEmpty || iface == 'lo') continue;
        final parts = line.substring(idx + 1).trim().split(RegExp(r'\s+'));
        if (parts.length < 9) continue;
        rx += int.tryParse(parts[0]) ?? 0; // rx bytes
        tx += int.tryParse(parts[8]) ?? 0; // tx bytes
      }
      final now = _NetSample(rx, tx, DateTime.now());
      if (_prevNet != null) {
        final secs = now.at.difference(_prevNet!.at).inMilliseconds / 1000.0;
        if (secs > 0) {
          final dRx = now.rx - _prevNet!.rx;
          final dTx = now.tx - _prevNet!.tx;
          s.rxRate = dRx > 0 ? dRx / secs : 0;
          s.txRate = dTx > 0 ? dTx / secs : 0;
          s.hasNet = true;
        }
      }
      _prevNet = now;
    } catch (_) {}
  }

  void _parseDisk(String raw, _Stats s) {
    try {
      final lines = raw.split('\n');
      for (final line in lines) {
        if (line.startsWith('Filesystem')) continue;
        final t = line.trim();
        if (t.isEmpty) continue;
        final parts = t.split(RegExp(r'\s+'));
        if (parts.length < 4) continue;
        // Filesystem  1B-blocks  Used  Available  Capacity  Mounted
        final size = int.tryParse(parts[1]) ?? 0;
        final used = int.tryParse(parts[2]) ?? 0;
        if (size > 0) {
          s.diskSize = size;
          s.diskUsed = used;
          break;
        }
      }
    } catch (_) {}
  }

  void _parseProcs(String raw, _Stats s) {
    try {
      final list = <_Proc>[];
      final lines = raw.split('\n');
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('PID') || t.contains('%CPU')) continue;
        final parts = t.split(RegExp(r'\s+'));
        if (parts.length < 4) continue;
        final pid = parts[0];
        if (int.tryParse(pid) == null) continue;
        final cpu = parts[1];
        final mem = parts[2];
        final comm = parts.sublist(3).join(' ');
        list.add(_Proc(pid, cpu, mem, comm));
      }
      s.procs = list;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final lc = LC(widget.isDark);
    final media = MediaQuery.of(context);
    final width = (media.size.width * 0.92).clamp(0.0, 900.0);
    final height = media.size.height * 0.80;

    return Material(
      color: Colors.transparent,
      child: Center(
        child: SizedBox(
          width: width.toDouble(),
          height: height,
          child: Container(
            decoration: BoxDecoration(
              color: lc.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lc.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(lc),
                Divider(height: 1, color: lc.border),
                Expanded(child: _body(lc)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(LC lc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          AppIcon('activity', size: 18, color: lc.accent),
          const SizedBox(width: 10),
          Text(
            'Монітор системи',
            style: TextStyle(
              color: lc.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 14,
            height: 14,
            child: _busy
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(lc.dim),
                  )
                : const SizedBox.shrink(),
          ),
          const Spacer(),
          _IconBtn(
            lc: lc,
            icon: 'x',
            tooltip: 'Закрити',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _body(LC lc) {
    final s = _stats;
    if (s == null && _error == null) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(lc.dim),
          ),
        ),
      );
    }
    if (_error != null && s == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Не вдалося отримати дані:\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: lc.bad, fontSize: 13),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cpuSection(lc, s!),
          const SizedBox(height: 18),
          _memSection(lc, s),
          const SizedBox(height: 18),
          _netDiskSection(lc, s),
          const SizedBox(height: 18),
          _procSection(lc, s),
        ],
      ),
    );
  }

  Widget _sectionTitle(LC lc, String icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          AppIcon(icon, size: 15, color: lc.dim),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: lc.dim,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cpuSection(LC lc, _Stats s) {
    final cores = s.coreBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(lc, 'cpu', 'ПРОЦЕСОР'),
        _LabeledBar(
          lc: lc,
          label: 'CPU',
          pct: s.hasCpu ? s.cpuBusy : null,
          trailing: s.hasCpu ? '${s.cpuBusy.toStringAsFixed(0)}%' : '—',
          bold: true,
        ),
        if (cores.isNotEmpty) const SizedBox(height: 8),
        for (var i = 0; i < cores.length; i++)
          _LabeledBar(
            lc: lc,
            label: '#$i',
            pct: cores[i],
            trailing: '${cores[i].toStringAsFixed(0)}%',
          ),
      ],
    );
  }

  Widget _memSection(LC lc, _Stats s) {
    final memPct = s.memTotal > 0 ? s.memUsed / s.memTotal * 100 : null;
    final swapPct = s.swapTotal > 0 ? s.swapUsed / s.swapTotal * 100 : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(lc, 'activity', "ПАМ'ЯТЬ"),
        _LabeledBar(
          lc: lc,
          label: 'RAM',
          pct: memPct,
          trailing: s.memTotal > 0
              ? '${_human(s.memUsed)} / ${_human(s.memTotal)}'
              : '—',
        ),
        const SizedBox(height: 8),
        _LabeledBar(
          lc: lc,
          label: 'SWAP',
          pct: swapPct,
          trailing: s.swapTotal > 0
              ? '${_human(s.swapUsed)} / ${_human(s.swapTotal)}'
              : '—',
        ),
      ],
    );
  }

  Widget _netDiskSection(LC lc, _Stats s) {
    final diskPct = s.diskSize > 0 ? s.diskUsed / s.diskSize * 100 : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(lc, 'network', 'МЕРЕЖА ТА ДИСК'),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                lc: lc,
                icon: 'download',
                label: 'Завантаження',
                value: s.hasNet ? '${_human(s.rxRate.round())}/с' : '—',
                color: lc.good,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatTile(
                lc: lc,
                icon: 'upload',
                label: 'Вивантаження',
                value: s.hasNet ? '${_human(s.txRate.round())}/с' : '—',
                color: lc.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _LabeledBar(
          lc: lc,
          label: 'Диск /',
          pct: diskPct,
          trailing: s.diskSize > 0
              ? '${_human(s.diskUsed)} / ${_human(s.diskSize)}'
              : '—',
        ),
      ],
    );
  }

  Widget _procSection(LC lc, _Stats s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(lc, 'zap', 'ПРОЦЕСИ'),
        Container(
          decoration: BoxDecoration(
            color: lc.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: lc.border),
          ),
          child: Column(
            children: [
              _procHeader(lc),
              Divider(height: 1, color: lc.border),
              if (s.procs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text('—',
                      style: TextStyle(color: lc.dim, fontSize: 12)),
                )
              else
                for (var i = 0; i < s.procs.length; i++)
                  _procRow(lc, s.procs[i], i.isOdd),
            ],
          ),
        ),
      ],
    );
  }

  Widget _procHeader(LC lc) {
    Widget cell(String t, int flex, {TextAlign align = TextAlign.left}) {
      return Expanded(
        flex: flex,
        child: Text(
          t,
          textAlign: align,
          style: TextStyle(
            color: lc.dim,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          cell('PID', 3),
          cell('CPU%', 2, align: TextAlign.right),
          cell('MEM%', 2, align: TextAlign.right),
          const SizedBox(width: 12),
          cell('КОМАНДА', 7),
        ],
      ),
    );
  }

  Widget _procRow(LC lc, _Proc p, bool alt) {
    Widget cell(String t, int flex,
        {TextAlign align = TextAlign.left, Color? color}) {
      return Expanded(
        flex: flex,
        child: Text(
          t,
          textAlign: align,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color ?? lc.text,
            fontSize: 12,
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Consolas', 'Courier New', 'monospace'],
          ),
        ),
      );
    }

    return Container(
      color: alt ? lc.surface.withValues(alpha: 0.4) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          cell(p.pid, 3, color: lc.dim),
          cell(p.cpu, 2, align: TextAlign.right),
          cell(p.mem, 2, align: TextAlign.right),
          const SizedBox(width: 12),
          cell(p.comm, 7),
        ],
      ),
    );
  }
}

/// Горизонтальний бар з підписом та значенням праворуч.
class _LabeledBar extends StatelessWidget {
  final LC lc;
  final String label;
  final double? pct;
  final String trailing;
  final bool bold;
  const _LabeledBar({
    required this.lc,
    required this.label,
    required this.pct,
    required this.trailing,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = pct;
    final frac = p == null ? 0.0 : (p / 100).clamp(0.0, 1.0);
    final color = p == null ? lc.dim : lc.barColor(p);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: TextStyle(
                color: lc.dim,
                fontSize: 12,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Container(height: 12, color: lc.surface2),
                  FractionallySizedBox(
                    widthFactor: frac,
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: Text(
              trailing,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: lc.text,
                fontSize: 11,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Courier New', 'monospace'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Плитка з іконкою, підписом і значенням (для мережі).
class _StatTile extends StatelessWidget {
  final LC lc;
  final String icon;
  final String label;
  final String value;
  final Color color;
  const _StatTile({
    required this.lc,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: lc.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.border),
      ),
      child: Row(
        children: [
          AppIcon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: lc.dim, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: lc.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const [
                    'Consolas',
                    'Courier New',
                    'monospace'
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Кнопка-іконка в заголовку.
class _IconBtn extends StatelessWidget {
  final LC lc;
  final String icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({
    required this.lc,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: AppIcon(icon, size: 18, color: lc.dim),
        ),
      ),
    );
  }
}

/// Форматує байти у людиночитний вигляд (B/K/M/G/T).
String _human(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'K', 'M', 'G', 'T'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final str = u == 0
      ? v.toStringAsFixed(0)
      : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));
  return '$str ${units[u]}';
}
