import 'dart:convert';

import 'dpapi.dart';
import 'secure_store.dart';
import 'server.dart';

/// Як секрети сервера (пароль, passphrase ключа, пароль jump-хоста) лежать на
/// диску. Два незалежні шари:
///  * усередині — необов'язковий майстер-пароль (`enc:…`, [SecureStore]);
///  * зовні — завжди DPAPI поточного користувача Windows (`dpapi:…`).
/// Тож без майстер-пароля паролі однаково не лежать відкритим текстом, а з ним
/// навіть той самий користувач не прочитає їх без пароля.
class Secrets {
  static const dpapiPrefix = 'dpapi:';
  static const masterPrefix = 'enc:';

  /// Для запису на диск.
  static String seal(String value, String? master) {
    if (value.isEmpty || value.startsWith(dpapiPrefix)) return value;
    var inner = value;
    if (master != null && !inner.startsWith(masterPrefix)) {
      inner = '$masterPrefix${SecureStore.encryptString(inner, master)}';
    }
    if (!Dpapi.available) return inner;
    final sealed = Dpapi.protect(utf8.encode(inner));
    return sealed == null ? inner : '$dpapiPrefix${base64.encode(sealed)}';
  }

  /// Для роботи в пам'яті. Що не вдалося відкрити, лишається як є (зашифрованим),
  /// щоб наступний запис не стер секрет; [failed] рахує такі поля.
  static String open(String value, String? master, [List<String>? failed]) {
    var v = value;
    if (v.startsWith(dpapiPrefix)) {
      final plain = Dpapi.available
          ? Dpapi.unprotect(base64.decode(v.substring(dpapiPrefix.length)))
          : null;
      if (plain == null) {
        failed?.add('dpapi');
        return value;
      }
      v = utf8.decode(plain);
    }
    if (master != null && v.startsWith(masterPrefix)) {
      final plain = SecureStore.decryptString(v.substring(masterPrefix.length), master);
      if (plain == null) {
        failed?.add('master');
        return v;
      }
      v = plain;
    }
    return v;
  }

  static Server sealServer(Server s, String? master) => s.copy()
    ..password = seal(s.password, master)
    ..passphrase = seal(s.passphrase, master)
    ..jumpPassword = seal(s.jumpPassword, master);

  static Server openServer(Server s, String? master, [List<String>? failed]) =>
      s.copy()
        ..password = open(s.password, master, failed)
        ..passphrase = open(s.passphrase, master, failed)
        ..jumpPassword = open(s.jumpPassword, master, failed);
}
