import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'theme.dart';

/// Тип тунелю: локальний (-L) чи віддалений (-R) проброс портів.
enum TunnelType { local, remote }

/// Модель одного тунелю. Тримає лише серіалізовані дані —
/// runtime-хендли зберігаються в [TunnelManager].
class Tunnel {
  final String id;
  TunnelType type;

  /// Для local: локальний хост прослуховування (типово '127.0.0.1').
  /// Для remote: хост прив'язки на віддаленій стороні.
  String bindHost;

  /// Порт прослуховування.
  int bindPort;

  /// Хост призначення (як його бачить ІНША сторона).
  String destHost;
  int destPort;

  bool active;
  String? error;

  Tunnel({
    required this.id,
    this.type = TunnelType.local,
    this.bindHost = '127.0.0.1',
    this.bindPort = 0,
    this.destHost = '127.0.0.1',
    this.destPort = 0,
    this.active = false,
    this.error,
  });
}

/// Внутрішній стан запущеного тунелю (не серіалізується).
class _TunnelRuntime {
  /// Для локального тунелю — серверний сокет прослуховування.
  ServerSocket? serverSocket;

  /// Для віддаленого тунелю — активний віддалений форвард.
  SSHRemoteForward? remoteForward;

  /// Підписки, які треба скасувати при зупинці.
  final List<StreamSubscription> subscriptions = [];

  /// Відкриті локальні сокети (для примусового закриття).
  final Set<Socket> sockets = {};

  /// Відкриті SSH-канали форварду.
  final Set<SSHForwardChannel> channels = {};
}

/// Менеджер SSH-пробросу портів (тунелів) поверх одного [SSHClient].
class TunnelManager {
  TunnelManager(this._client);

  final SSHClient _client;
  final List<Tunnel> _tunnels = [];
  final Map<String, _TunnelRuntime> _runtimes = {};

  List<Tunnel> get tunnels => _tunnels;

  /// Додає тунель у список (без запуску).
  void add(Tunnel t) {
    _tunnels.add(t);
  }

  /// Видаляє тунель (попередньо зупиняючи його).
  Future<void> remove(Tunnel t) async {
    await stop(t);
    _tunnels.removeWhere((e) => e.id == t.id);
  }

  /// Запускає тунель відповідно до [t.type]. Помилки не кидає —
  /// натомість виставляє [t.error] і [t.active] = false.
  Future<void> start(Tunnel t) async {
    if (t.active) return;
    t.error = null;
    if (!_tunnels.any((e) => e.id == t.id)) {
      _tunnels.add(t);
    }
    try {
      if (t.type == TunnelType.local) {
        await _startLocal(t);
      } else {
        await _startRemote(t);
      }
      t.active = true;
    } catch (e) {
      t.active = false;
      t.error = _describe(e);
      await _teardown(t.id);
    }
  }

  Future<void> _startLocal(Tunnel t) async {
    final runtime = _TunnelRuntime();
    _runtimes[t.id] = runtime;

    final server = await ServerSocket.bind(t.bindHost, t.bindPort);
    runtime.serverSocket = server;

    final sub = server.listen(
      (socket) => _handleLocalSocket(t, runtime, socket),
      onError: (Object e) {
        t.error = _describe(e);
      },
    );
    runtime.subscriptions.add(sub);
  }

  Future<void> _handleLocalSocket(
    Tunnel t,
    _TunnelRuntime runtime,
    Socket socket,
  ) async {
    runtime.sockets.add(socket);
    SSHForwardChannel channel;
    try {
      channel = await _client.forwardLocal(t.destHost, t.destPort);
    } catch (e) {
      runtime.sockets.remove(socket);
      try {
        socket.destroy();
      } catch (_) {}
      return;
    }
    runtime.channels.add(channel);
    _pipe(
      runtime: runtime,
      socket: socket,
      channel: channel,
      // socket -> channel
      socketToChannel: true,
    );
  }

  Future<void> _startRemote(Tunnel t) async {
    final runtime = _TunnelRuntime();
    _runtimes[t.id] = runtime;

    final forward = await _client.forwardRemote(
      host: t.bindHost,
      port: t.bindPort,
    );
    if (forward == null) {
      throw const _TunnelError(
        'Віддалений сервер відхилив запит на проброс порту',
      );
    }
    runtime.remoteForward = forward;

    final sub = forward.connections.listen(
      (channel) => _handleRemoteChannel(t, runtime, channel),
      onError: (Object e) {
        t.error = _describe(e);
      },
    );
    runtime.subscriptions.add(sub);
  }

  Future<void> _handleRemoteChannel(
    Tunnel t,
    _TunnelRuntime runtime,
    SSHForwardChannel channel,
  ) async {
    runtime.channels.add(channel);
    Socket socket;
    try {
      socket = await Socket.connect(t.destHost, t.destPort);
    } catch (e) {
      runtime.channels.remove(channel);
      try {
        channel.destroy();
      } catch (_) {}
      return;
    }
    runtime.sockets.add(socket);
    _pipe(
      runtime: runtime,
      socket: socket,
      channel: channel,
      socketToChannel: true,
    );
  }

  /// Двонаправлене перекачування даних між локальним сокетом і SSH-каналом.
  void _pipe({
    required _TunnelRuntime runtime,
    required Socket socket,
    required SSHForwardChannel channel,
    required bool socketToChannel,
  }) {
    var closed = false;
    void closeBoth() {
      if (closed) return;
      closed = true;
      runtime.sockets.remove(socket);
      runtime.channels.remove(channel);
      try {
        socket.destroy();
      } catch (_) {}
      try {
        channel.destroy();
      } catch (_) {}
    }

    // socket -> channel
    final subA = socket.listen(
      (Uint8List data) {
        try {
          channel.sink.add(data);
        } catch (_) {
          closeBoth();
        }
      },
      onError: (Object _) => closeBoth(),
      onDone: () {
        try {
          channel.sink.close();
        } catch (_) {}
        closeBoth();
      },
      cancelOnError: true,
    );

    // channel -> socket
    final subB = channel.stream.listen(
      (Uint8List data) {
        try {
          socket.add(data);
        } catch (_) {
          closeBoth();
        }
      },
      onError: (Object _) => closeBoth(),
      onDone: closeBoth,
      cancelOnError: true,
    );

    runtime.subscriptions.add(subA);
    runtime.subscriptions.add(subB);
  }

  /// Зупиняє тунель і звільняє всі його ресурси.
  Future<void> stop(Tunnel t) async {
    await _teardown(t.id);
    t.active = false;
  }

  Future<void> _teardown(String id) async {
    final runtime = _runtimes.remove(id);
    if (runtime == null) return;

    for (final sub in runtime.subscriptions) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    runtime.subscriptions.clear();

    for (final socket in runtime.sockets.toList()) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    runtime.sockets.clear();

    for (final channel in runtime.channels.toList()) {
      try {
        channel.destroy();
      } catch (_) {}
    }
    runtime.channels.clear();

    final remote = runtime.remoteForward;
    if (remote != null) {
      try {
        remote.close();
      } catch (_) {}
    }

    final server = runtime.serverSocket;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
  }

  /// Зупиняє всі тунелі та звільняє ресурси.
  Future<void> dispose() async {
    for (final t in _tunnels.toList()) {
      await stop(t);
    }
  }

  String _describe(Object e) {
    if (e is _TunnelError) return e.message;
    if (e is SocketException) {
      final msg = e.osError?.message ?? e.message;
      return msg.isEmpty ? 'Помилка сокета' : msg;
    }
    return e.toString();
  }
}

class _TunnelError implements Exception {
  final String message;
  const _TunnelError(this.message);
  @override
  String toString() => message;
}

/// Показує діалог керування тунелями (проброс портів).
Future<void> showTunnelsDialog(
  BuildContext context, {
  required bool isDark,
  required TunnelManager manager,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'tunnels',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, sec, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Align(
        alignment: Alignment.topCenter,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.12),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: curved,
            child: Padding(
              padding: const EdgeInsets.only(top: 56),
              child: _TunnelsPanel(isDark: isDark, manager: manager),
            ),
          ),
        ),
      );
    },
  );
}

class _TunnelsPanel extends StatefulWidget {
  final bool isDark;
  final TunnelManager manager;
  const _TunnelsPanel({required this.isDark, required this.manager});

  @override
  State<_TunnelsPanel> createState() => _TunnelsPanelState();
}

class _TunnelsPanelState extends State<_TunnelsPanel> {
  late final LC lc = LC(widget.isDark);
  bool _showForm = false;
  bool _busy = false;

  TunnelType _formType = TunnelType.local;
  final _bindHostCtl = TextEditingController(text: '127.0.0.1');
  final _bindPortCtl = TextEditingController();
  final _destHostCtl = TextEditingController(text: '127.0.0.1');
  final _destPortCtl = TextEditingController();
  String? _formError;

  @override
  void dispose() {
    _bindHostCtl.dispose();
    _bindPortCtl.dispose();
    _destHostCtl.dispose();
    _destPortCtl.dispose();
    super.dispose();
  }

  List<Tunnel> get _tunnels => widget.manager.tunnels;

  Future<void> _toggle(Tunnel t) async {
    setState(() => _busy = true);
    if (t.active) {
      await widget.manager.stop(t);
    } else {
      await widget.manager.start(t);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(Tunnel t) async {
    setState(() => _busy = true);
    await widget.manager.remove(t);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addFromForm() async {
    final bindPort = int.tryParse(_bindPortCtl.text.trim());
    final destPort = int.tryParse(_destPortCtl.text.trim());
    final destHost = _destHostCtl.text.trim();
    var bindHost = _bindHostCtl.text.trim();
    if (bindHost.isEmpty) bindHost = '127.0.0.1';

    if (bindPort == null || bindPort < 0 || bindPort > 65535) {
      setState(() => _formError = 'Некоректний порт прослуховування');
      return;
    }
    if (destHost.isEmpty) {
      setState(() => _formError = 'Вкажіть хост призначення');
      return;
    }
    if (destPort == null || destPort < 1 || destPort > 65535) {
      setState(() => _formError = 'Некоректний порт призначення');
      return;
    }

    final t = Tunnel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: _formType,
      bindHost: bindHost,
      bindPort: bindPort,
      destHost: destHost,
      destPort: destPort,
    );
    widget.manager.add(t);

    setState(() {
      _busy = true;
      _showForm = false;
      _formError = null;
    });

    await widget.manager.start(t);

    _bindPortCtl.clear();
    _destPortCtl.clear();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 560,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height - 120,
        ),
        decoration: BoxDecoration(
          color: lc.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: lc.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_tunnels.isEmpty && !_showForm) _emptyState(),
                    for (final t in _tunnels) _tunnelRow(t),
                    const SizedBox(height: 10),
                    if (_showForm) _form() else _addButton(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
      child: Row(
        children: [
          AppIcon('network', size: 18, color: lc.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Проброс портів (тунелі)',
              style: TextStyle(
                color: lc.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _iconButton(
            'x',
            lc.dim,
            () => Navigator.of(context).maybePop(),
            tooltip: 'Закрити',
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        children: [
          AppIcon('network', size: 30, color: lc.dim),
          const SizedBox(height: 10),
          Text(
            'Немає активних тунелів',
            style: TextStyle(color: lc.dim, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _tunnelRow(Tunnel t) {
    final Color dotColor = t.error != null
        ? lc.bad
        : (t.active ? lc.good : lc.dim);
    final typeLabel = t.type == TunnelType.local ? 'Локальний' : 'Віддалений';
    final route =
        '${t.bindHost}:${t.bindPort} → ${t.destHost}:${t.destPort}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: lc.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: t.active && t.error == null
                    ? [
                        BoxShadow(
                          color: dotColor.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: lc.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        typeLabel,
                        style: TextStyle(
                          color: lc.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  route,
                  style: TextStyle(
                    color: lc.text,
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (t.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    t.error!,
                    style: TextStyle(color: lc.bad, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _iconButton(
            t.active ? 'link' : 'arrow-up',
            t.active ? lc.good : lc.dim,
            _busy ? null : () => _toggle(t),
            tooltip: t.active ? 'Зупинити' : 'Запустити',
          ),
          _iconButton(
            'trash',
            lc.bad,
            _busy ? null : () => _delete(t),
            tooltip: 'Видалити',
          ),
        ],
      ),
    );
  }

  Widget _addButton() {
    return InkWell(
      onTap: () => setState(() {
        _showForm = true;
        _formError = null;
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: lc.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon('plus', size: 16, color: lc.accent),
            const SizedBox(width: 8),
            Text(
              'Додати тунель',
              style: TextStyle(
                color: lc.accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: lc.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _typeChip(TunnelType.local, 'Локальний (-L)'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _typeChip(TunnelType.remote, 'Віддалений (-R)'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: _field(
                  _bindHostCtl,
                  _formType == TunnelType.local
                      ? 'Локальний хост'
                      : 'Хост прив\'язки (віддалений)',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _field(_bindPortCtl, 'Порт', number: true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: _field(_destHostCtl, 'Хост призначення'),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _field(_destPortCtl, 'Порт', number: true),
              ),
            ],
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: TextStyle(color: lc.bad, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _showForm = false;
                  _formError = null;
                }),
                child: Text(
                  'Скасувати',
                  style: TextStyle(color: lc.dim),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _addFromForm,
                style: FilledButton.styleFrom(
                  backgroundColor: lc.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Додати та запустити'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeChip(TunnelType type, String label) {
    final selected = _formType == type;
    return InkWell(
      onTap: () => setState(() => _formType = type),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? lc.accent.withValues(alpha: 0.15) : lc.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? lc.accent : lc.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? lc.accent : lc.dim,
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctl,
    String label, {
    bool number = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: lc.dim, fontSize: 11.5),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: ctl,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          style: TextStyle(color: lc.text, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            filled: true,
            fillColor: lc.surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: lc.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: lc.accent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _iconButton(
    String name,
    Color color,
    VoidCallback? onTap, {
    String? tooltip,
  }) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: AppIcon(
          name,
          size: 16,
          color: onTap == null ? color.withValues(alpha: 0.4) : color,
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip, child: btn);
  }
}
