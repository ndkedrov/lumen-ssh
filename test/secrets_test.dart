import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen_ssh/dpapi.dart';
import 'package:lumen_ssh/secrets.dart';
import 'package:lumen_ssh/server.dart';

void main() {
  final skip = Platform.isWindows ? false : 'DPAPI є лише у Windows';

  test('DPAPI: зашифроване відкривається тим самим користувачем', () {
    final sealed = Dpapi.protect([1, 2, 3, 250])!;
    expect(sealed, isNot(equals([1, 2, 3, 250])));
    expect(Dpapi.unprotect(sealed), [1, 2, 3, 250]);
    expect(Dpapi.unprotect([9, 9, 9]), isNull);
  }, skip: skip);

  test('без майстер-пароля секрет однаково не лежить відкритим', () {
    final v = Secrets.seal('pa\$\$ word ї', null);
    expect(v, startsWith(Secrets.dpapiPrefix));
    expect(v, isNot(contains('word')));
    expect(Secrets.open(v, null), 'pa\$\$ word ї');
    expect(Secrets.seal(v, null), v, reason: 'повторне шифрування не загортає вдруге');
    expect(Secrets.seal('', null), '');
  }, skip: skip);

  test('майстер-пароль — внутрішній шар, без нього секрет лишається закритим', () {
    final v = Secrets.seal('secret', 'm');
    final failed = <String>[];
    final locked = Secrets.open(v, null, failed);
    expect(locked, startsWith(Secrets.masterPrefix));
    expect(Secrets.open(v, 'm'), 'secret');
    expect(Secrets.open(v, 'wrong', failed), startsWith(Secrets.masterPrefix));
    expect(failed, ['master']);
    // Заблокований (не відкритий) секрет записується назад без втрат.
    expect(Secrets.open(Secrets.seal(locked, null), 'm'), 'secret');
  }, skip: skip);

  test('нерозшифровне поле зберігається як є, а не стирається', () {
    const broken = '${Secrets.dpapiPrefix}AAAA';
    final failed = <String>[];
    expect(Secrets.open(broken, null, failed), broken);
    expect(failed, ['dpapi']);
    expect(Secrets.seal(broken, null), broken);
  }, skip: skip);

  test('старі відкриті паролі читаються й шифруються всі три поля', () {
    final plain = Server(
        host: 'h', password: 'p1', passphrase: 'p2', jumpPassword: 'p3');
    final sealed = Secrets.sealServer(plain, null);
    for (final f in [sealed.password, sealed.passphrase, sealed.jumpPassword]) {
      expect(f, startsWith(Secrets.dpapiPrefix));
    }
    final back = Secrets.openServer(sealed, null);
    expect([back.password, back.passphrase, back.jumpPassword], ['p1', 'p2', 'p3']);
    expect(Secrets.openServer(plain, null).password, 'p1');
  }, skip: skip);
}
