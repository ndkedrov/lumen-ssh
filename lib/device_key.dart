import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secrets.dart';
import 'server.dart';

/// Ключ цього ПК для входу на сервери: один ed25519 на всі сервери.
///
/// Приватна частина живе не файлом, а в налаштуваннях під DPAPI, тож навіть
/// скопійований каталог застосунку на іншому ПК її не видасть. Сервер, що
/// входить цим ключем, має `keyPath == DeviceKey.ref`.
class DeviceKey {
  static const ref = 'lumen:device';
  static const _privPref = 'lumen_device_key';
  static const _pubPref = 'lumen_device_pub';

  static final RegExp _pubLine =
      RegExp(r'^ssh-ed25519 [A-Za-z0-9+/]+=* [A-Za-z0-9@._-]+$');

  /// Рядок `ssh-ed25519 AAAA… коментар` — без лапок і пробілів у коментарі,
  /// бо він вставляється в shell-скрипт на сервері.
  static bool isValidPublic(String line) => _pubLine.hasMatch(line);

  /// Публічний ключ, якщо вже згенеровано.
  static Future<String?> publicLine() async =>
      (await SharedPreferences.getInstance()).getString(_pubPref);

  /// Публічний ключ; за потреби спершу згенерувати пару.
  static Future<String> ensure() async {
    final existing = await publicLine();
    if (existing != null) return existing;
    final host = Platform.localHostname.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    final comment = 'lumen-ssh@${host.isEmpty ? 'pc' : host}';
    final dir = await Directory.systemTemp.createTemp('lumen_key_');
    final path = '${dir.path}${Platform.pathSeparator}id';
    try {
      final r = await Process.run('ssh-keygen',
          ['-t', 'ed25519', '-f', path, '-N', '', '-C', comment, '-q']);
      if (r.exitCode != 0) {
        throw Exception('ssh-keygen: ${r.stderr.toString().trim()}');
      }
      final pem = await File(path).readAsString();
      final pub = (await File('$path.pub').readAsString()).trim();
      if (!isValidPublic(pub)) throw Exception('неочікуваний формат ключа');
      final sealed = Secrets.seal(pem, null);
      if (!sealed.startsWith(Secrets.dpapiPrefix) && Platform.isWindows) {
        throw Exception('DPAPI не зашифрував ключ — не зберігаю його відкритим');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_privPref, sealed);
      await prefs.setString(_pubPref, pub);
      return pub;
    } on ProcessException {
      throw Exception('не знайдено ssh-keygen (OpenSSH Client у Windows)');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Приватний ключ у форматі OpenSSH для dartssh2.
  static Future<String> privatePem() async {
    final sealed =
        (await SharedPreferences.getInstance()).getString(_privPref);
    if (sealed == null) throw Exception('ключ цього ПК ще не створено');
    final pem = Secrets.open(sealed, null);
    if (pem.startsWith(Secrets.dpapiPrefix)) {
      throw Exception('ключ цього ПК не розшифровано (інший користувач Windows?)');
    }
    return pem;
  }

  /// Відбиток як у `ssh-keygen -lf`: `SHA256:` + base64 без доповнення.
  static String fingerprint(String pubLine) {
    final blob = base64.decode(pubLine.split(' ')[1]);
    return 'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll('=', '')}';
  }

  static bool uses(Server s) => s.keyPath == ref;
}

/// Shell-скрипти для `sh -s` на сервері: віддаються через stdin, тож не залежать
/// від того, яка в користувача оболонка входу (bash, fish, ash на роутері).
class KeyScripts {
  // Роутери на OpenWrt (GL.iNet тощо): dropbear бере ключі root з /etc/dropbear.
  static const _pickFile = 'if [ "\$(id -u)" = 0 ] && [ -d /etc/dropbear ] '
      '&& ! command -v sshd >/dev/null 2>&1 && ! [ -x /usr/sbin/sshd ]; then\n'
      '  F=/etc/dropbear/authorized_keys\n'
      'else\n'
      '  mkdir -p "\$HOME/.ssh" && chmod 700 "\$HOME/.ssh"\n'
      '  F="\$HOME/.ssh/authorized_keys"\n'
      'fi\n';

  static const okMarker = 'LUMEN_KEY_OK';
  static const removedMarker = 'LUMEN_KEY_REMOVED';

  /// Дописати ключ, якщо його ще немає (повторний запуск нічого не дублює).
  static String install(String pubLine) {
    _check(pubLine);
    return "umask 077\nK='$pubLine'\n$_pickFile"
        'touch "\$F"\n'
        'if ! grep -qxF "\$K" "\$F"; then\n'
        // Без цього ключ злипся б з останнім рядком файла без переводу рядка.
        '  if [ -s "\$F" ] && [ -n "\$(tail -c1 "\$F")" ]; then echo >> "\$F"; fi\n'
        '  printf \'%s\\n\' "\$K" >> "\$F"\n'
        'fi\n'
        'chmod 600 "\$F"\n'
        'grep -qxF "\$K" "\$F" && echo "$okMarker \$F"\n';
  }

  /// Прибрати саме цей ключ з усіх місць, куди [install] міг його покласти.
  static String remove(String pubLine) {
    _check(pubLine);
    return "K='$pubLine'\n"
        'for F in "\$HOME/.ssh/authorized_keys" /etc/dropbear/authorized_keys; do\n'
        '  [ -f "\$F" ] || continue\n'
        '  grep -vxF "\$K" "\$F" > "\$F.lumen-tmp"\n'
        // cat > зберігає власника й права самого файла.
        '  cat "\$F.lumen-tmp" > "\$F" && rm -f "\$F.lumen-tmp"\n'
        'done\n'
        'echo $removedMarker\n';
  }

  static void _check(String pubLine) {
    if (!DeviceKey.isValidPublic(pubLine)) {
      throw ArgumentError('небезпечний рядок ключа для shell');
    }
  }
}
