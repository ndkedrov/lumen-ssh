import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen_ssh/device_key.dart';

/// Справжній POSIX sh, щоб прогнати скрипти, а не лише перевірити текст.
String? _sh() {
  for (final p in [r'C:\Program Files\Git\bin\sh.exe', '/bin/sh']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

Future<String> _run(String sh, String script, String home) async {
  final p = await Process.start(sh, ['-s'], environment: {'HOME': home});
  p.stdin.write(script);
  await p.stdin.close();
  final out = await p.stdout.transform(const SystemEncoding().decoder).join();
  await p.exitCode;
  return out;
}

void main() {
  const pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuK1o8Xl3m0Y1d lumen-ssh@PC';
  final sh = _sh();

  test('рядок ключа з лапками чи пробілами в коментарі не потрапляє в shell', () {
    expect(DeviceKey.isValidPublic(pub), isTrue);
    for (final bad in [
      "ssh-ed25519 AAAA x'; rm -rf ~; echo '",
      'ssh-ed25519 AAAA two words',
      'ssh-rsa AAAA x',
      'ssh-ed25519 AAAA x\nssh-ed25519 BBBB y',
    ]) {
      expect(DeviceKey.isValidPublic(bad), isFalse, reason: bad);
      expect(() => KeyScripts.install(bad), throwsArgumentError);
    }
  });

  test('встановлення ідемпотентне, не склеює рядки, видалення лишає чужі ключі',
      () async {
    final home = await Directory.systemTemp.createTemp('lumen_home_');
    addTearDown(() => home.delete(recursive: true));
    final ssh = Directory('${home.path}/.ssh')..createSync();
    final f = File('${ssh.path}/authorized_keys')
      ..writeAsStringSync('ssh-ed25519 OTHER other@host'); // без \n у кінці

    final out1 = await _run(sh!, KeyScripts.install(pub), home.path);
    expect(out1, contains(KeyScripts.okMarker));
    await _run(sh, KeyScripts.install(pub), home.path);
    expect(f.readAsLinesSync(), ['ssh-ed25519 OTHER other@host', pub]);

    final out2 = await _run(sh, KeyScripts.remove(pub), home.path);
    expect(out2, contains(KeyScripts.removedMarker));
    expect(f.readAsLinesSync(), ['ssh-ed25519 OTHER other@host']);
  }, skip: sh == null ? 'немає sh' : false);

  test('відбиток збігається з ssh-keygen -lf', () async {
    final dir = await Directory.systemTemp.createTemp('lumen_fp_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}k';
    final gen = await Process.run(
        'ssh-keygen', ['-t', 'ed25519', '-f', path, '-N', '', '-C', 't@x', '-q']);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    final line = File('$path.pub').readAsStringSync().trim();
    final lf = await Process.run('ssh-keygen', ['-lf', '$path.pub']);
    expect(DeviceKey.fingerprint(line), lf.stdout.toString().split(' ')[1]);
  });
}
