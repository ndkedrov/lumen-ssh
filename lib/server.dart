import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Опис збереженого сервера.
class Server {
  String id;
  String name;
  String host;
  int port;
  String username;
  String password;
  String keyPath;
  String passphrase;
  String group; // група (папка) серверів
  List<String> tags;
  String onConnect; // команда, що виконується після підключення
  // Jump-host (бастіон)
  String jumpHost;
  int jumpPort;
  String jumpUser;
  String jumpPassword;

  Server({
    this.id = '',
    this.name = '',
    this.host = '',
    this.port = 22,
    this.username = 'root',
    this.password = '',
    this.keyPath = '',
    this.passphrase = '',
    this.group = '',
    List<String>? tags,
    this.onConnect = '',
    this.jumpHost = '',
    this.jumpPort = 22,
    this.jumpUser = '',
    this.jumpPassword = '',
  }) : tags = tags ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'keyPath': keyPath,
        'passphrase': passphrase,
        'group': group,
        'tags': tags,
        'onConnect': onConnect,
        'jumpHost': jumpHost,
        'jumpPort': jumpPort,
        'jumpUser': jumpUser,
        'jumpPassword': jumpPassword,
      };

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        host: (j['host'] ?? '') as String,
        port: (j['port'] ?? 22) as int,
        username: (j['username'] ?? 'root') as String,
        password: (j['password'] ?? '') as String,
        keyPath: (j['keyPath'] ?? '') as String,
        passphrase: (j['passphrase'] ?? '') as String,
        group: (j['group'] ?? '') as String,
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        onConnect: (j['onConnect'] ?? '') as String,
        jumpHost: (j['jumpHost'] ?? '') as String,
        jumpPort: (j['jumpPort'] ?? 22) as int,
        jumpUser: (j['jumpUser'] ?? '') as String,
        jumpPassword: (j['jumpPassword'] ?? '') as String,
      );

  Server copy() => Server.fromJson(toJson());
}

/// Збереження списку серверів у SharedPreferences.
class ServerStore {
  static const _key = 'lumen_servers';

  static Future<List<Server>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Server.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Server> servers) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(servers.map((e) => e.toJson()).toList()));
  }
}
