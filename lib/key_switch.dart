import 'device_key.dart';
import 'server.dart';
import 'ssh_session.dart';

/// Перевести сервер на вхід ключем цього ПК і назад.
///
/// Ключ стає основним лише після того, як окреме підключення ЛИШЕ ключем
/// пройшло: інакше сервер лишається на паролі. Пароль при цьому не стирається —
/// він запасний вхід, якщо ключ колись приберуть із сервера.
class KeySwitch {
  static const _timeout = Duration(seconds: 25);

  /// null — готово (можна ставити `keyPath = DeviceKey.ref`), інакше причина.
  /// [via] — уже відкрита сесія цього сервера, щоб не входити вдруге.
  static Future<String?> enable(Server s, {TermSession? via}) async {
    try {
      final pub = await DeviceKey.ensure();
      final out = await _run(s, KeyScripts.install(pub), via);
      final ok = out
          .split('\n')
          .where((l) => l.startsWith(KeyScripts.okMarker))
          .firstOrNull;
      if (ok == null) return 'ключ не записано${_tail(out)}';
      final probe = TermSession(-1, s.copy()..keyPath = DeviceKey.ref);
      try {
        await probe.open(keyOnly: true).timeout(_timeout);
      } catch (e) {
        final file = ok.substring(KeyScripts.okMarker.length).trim();
        return 'ключ записано в $file, але сервер не пускає ним ($e)';
      } finally {
        await probe.dispose();
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Прибрати ключ цього ПК із сервера. null — готово, інакше причина.
  static Future<String?> disable(Server s, {TermSession? via}) async {
    try {
      final pub = await DeviceKey.publicLine();
      if (pub == null) return null;
      final out = await _run(s, KeyScripts.remove(pub), via);
      return out.contains(KeyScripts.removedMarker)
          ? null
          : 'сервер не підтвердив видалення${_tail(out)}';
    } catch (e) {
      return '$e';
    }
  }

  static Future<String> _run(Server s, String script, TermSession? via) async {
    if (via != null && via.alive) return via.runScript(script).timeout(_timeout);
    final t = TermSession(-1, s);
    try {
      await t.open().timeout(_timeout);
      return await t.runScript(script).timeout(_timeout);
    } finally {
      await t.dispose();
    }
  }

  static String _tail(String out) {
    final t = out.trim();
    if (t.isEmpty) return '';
    return ': ${t.length > 160 ? '…${t.substring(t.length - 160)}' : t}';
  }
}
