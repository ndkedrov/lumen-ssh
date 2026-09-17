import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'theme.dart';

/// Password-based encryption for saved server passwords.
///
/// A key is derived from the master password with PBKDF2-HMAC-SHA256 over a
/// random salt, then used with AES-GCM (authenticated) so that a wrong password
/// or any tampering makes decryption fail (returns null).
class SecureStore {
  static const int _iterations = 120000;
  static const int _saltLen = 16;
  static const int _ivLen = 12;
  static const int _keyLen = 32; // 256-bit

  static final Random _rng = Random.secure();

  static Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }

  /// PBKDF2-HMAC-SHA256 (RFC 2898). For a 32-byte derived key with SHA-256
  /// (32-byte output) a single block is sufficient.
  static Uint8List _pbkdf2(
    String password,
    Uint8List salt,
    int iterations,
    int keyLen,
  ) {
    final hmac = Hmac(sha256, utf8.encode(password));
    const int hLen = 32; // SHA-256 digest length in bytes
    final int blocks = (keyLen + hLen - 1) ~/ hLen;
    final out = Uint8List(blocks * hLen);

    for (var block = 1; block <= blocks; block++) {
      // U1 = HMAC(password, salt || INT_32_BE(block))
      final intBlock = Uint8List(4);
      intBlock[0] = (block >> 24) & 0xff;
      intBlock[1] = (block >> 16) & 0xff;
      intBlock[2] = (block >> 8) & 0xff;
      intBlock[3] = block & 0xff;

      final firstInput = Uint8List(salt.length + 4)
        ..setRange(0, salt.length, salt)
        ..setRange(salt.length, salt.length + 4, intBlock);

      var u = Uint8List.fromList(hmac.convert(firstInput).bytes);
      final t = Uint8List.fromList(u); // running XOR accumulator

      for (var i = 1; i < iterations; i++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var j = 0; j < hLen; j++) {
          t[j] ^= u[j];
        }
      }

      out.setRange((block - 1) * hLen, block * hLen, t);
    }

    return Uint8List.sublistView(out, 0, keyLen);
  }

  /// Encrypts [plaintext] with a key derived from [password]. Returns a
  /// self-describing base64/JSON blob that embeds the random salt + IV, so
  /// [decryptString] only needs the password.
  static String encryptString(String plaintext, String password) {
    final salt = _randomBytes(_saltLen);
    final iv = _randomBytes(_ivLen);
    final keyBytes = _pbkdf2(password, salt, _iterations, _keyLen);

    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm),
    );
    final encrypted = encrypter.encrypt(plaintext, iv: enc.IV(iv));

    final map = <String, dynamic>{
      'v': 1,
      'salt': base64.encode(salt),
      'iv': base64.encode(iv),
      'ct': encrypted.base64,
    };
    return base64.encode(utf8.encode(jsonEncode(map)));
  }

  /// Returns the plaintext, or null if the password is wrong or the blob is
  /// malformed/tampered (GCM authentication failure, bad base64, missing
  /// fields all return null).
  static String? decryptString(String blob, String password) {
    try {
      final jsonStr = utf8.decode(base64.decode(blob));
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;

      final salt = base64.decode(map['salt'] as String);
      final iv = base64.decode(map['iv'] as String);
      final ct = map['ct'] as String;

      final keyBytes = _pbkdf2(password, salt, _iterations, _keyLen);
      final encrypter = enc.Encrypter(
        enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm),
      );

      return encrypter.decrypt(
        enc.Encrypted.fromBase64(ct),
        iv: enc.IV(iv),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Shows a modal asking for the master password.
///
/// If [creating] is true, also shows a "confirm password" field and validates
/// they match. Returns the entered password, or null if cancelled.
Future<String?> showMasterPasswordDialog(
  BuildContext context, {
  required bool isDark,
  required bool creating,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'master-password',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Align(
        alignment: Alignment.topCenter,
        child: FractionalTranslation(
          translation: Offset(0, (1 - curved.value) * -0.4),
          child: Opacity(
            opacity: curved.value.clamp(0.0, 1.0),
            child: Padding(
              padding: const EdgeInsets.only(top: 96),
              child: _MasterPasswordPanel(isDark: isDark, creating: creating),
            ),
          ),
        ),
      );
    },
  );
}

class _MasterPasswordPanel extends StatefulWidget {
  const _MasterPasswordPanel({required this.isDark, required this.creating});

  final bool isDark;
  final bool creating;

  @override
  State<_MasterPasswordPanel> createState() => _MasterPasswordPanelState();
}

class _MasterPasswordPanelState extends State<_MasterPasswordPanel> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _passFocus = FocusNode();
  final _confirmFocus = FocusNode();

  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _passFocus.requestFocus();
    });
    _passCtrl.addListener(_revalidate);
    _confirmCtrl.addListener(_revalidate);
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _passFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool get _valid {
    if (_passCtrl.text.isEmpty) return false;
    if (widget.creating && _confirmCtrl.text != _passCtrl.text) return false;
    return true;
  }

  void _revalidate() {
    if (_error != null) setState(() => _error = null);
    setState(() {});
  }

  void _submit() {
    if (_passCtrl.text.isEmpty) {
      setState(() => _error = 'Введіть пароль');
      return;
    }
    if (widget.creating && _confirmCtrl.text != _passCtrl.text) {
      setState(() => _error = 'Паролі не збігаються');
      return;
    }
    Navigator.of(context).pop(_passCtrl.text);
  }

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final lc = LC(widget.isDark);
    final title =
        widget.creating ? 'Встановити майстер-пароль' : 'Майстер-пароль';
    final confirmLabel = widget.creating ? 'Встановити' : 'OK';

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: lc.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lc.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: lc.surface2,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: lc.border),
                        ),
                        alignment: Alignment.center,
                        child: AppIcon('lock', size: 18, color: lc.accent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: lc.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _IconBtn(
                        lc: lc,
                        name: 'x',
                        onTap: _cancel,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _Field(
                    lc: lc,
                    controller: _passCtrl,
                    focusNode: _passFocus,
                    label: 'Пароль',
                    autofocus: true,
                    onSubmitted: (_) {
                      if (widget.creating) {
                        _confirmFocus.requestFocus();
                      } else {
                        _submit();
                      }
                    },
                  ),
                  if (widget.creating) ...[
                    const SizedBox(height: 12),
                    _Field(
                      lc: lc,
                      controller: _confirmCtrl,
                      focusNode: _confirmFocus,
                      label: 'Підтвердіть пароль',
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: TextStyle(color: lc.bad, fontSize: 12.5),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _TextButton(
                        lc: lc,
                        label: 'Скасувати',
                        onTap: _cancel,
                      ),
                      const SizedBox(width: 10),
                      _PrimaryButton(
                        lc: lc,
                        label: confirmLabel,
                        enabled: _valid,
                        onTap: _submit,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.lc,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final LC lc;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            label,
            style: TextStyle(color: lc.dim, fontSize: 12),
          ),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          obscureText: true,
          style: TextStyle(color: lc.text, fontSize: 14),
          cursorColor: lc.accent,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: lc.surface2,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: lc.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: lc.accent),
            ),
          ),
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.lc, required this.name, required this.onTap});

  final LC lc;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AppIcon(name, size: 16, color: lc.dim),
      ),
    );
  }
}

class _TextButton extends StatelessWidget {
  const _TextButton({
    required this.lc,
    required this.label,
    required this.onTap,
  });

  final LC lc;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: lc.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: lc.border),
        ),
        child: Text(
          label,
          style: TextStyle(color: lc.text, fontSize: 13.5),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.lc,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final LC lc;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: lc.accent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
