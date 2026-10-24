import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows DPAPI (CryptProtectData / CryptUnprotectData) для поточного
/// користувача Windows: ключ знає сама система, тож шифрування не потребує
/// жодного пароля, а розшифрувати дані може лише той самий користувач на тому
/// самому ПК (скопійований файл налаштувань на іншому ПК не відкриється).
final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(Pointer<_Blob>, Pointer<Utf16>,
    Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(Pointer<_Blob>, Pointer<Utf16>,
    Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);

class Dpapi {
  static const int _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  static bool get available => Platform.isWindows;

  static final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _CryptDart _protect =
      _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
  static final _CryptDart _unprotect =
      _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
  static final _localFree = _kernel32
      .lookupFunction<_LocalFreeNative, _LocalFreeNative>('LocalFree');

  /// Зашифрувати; null — якщо система відмовила.
  static Uint8List? protect(List<int> data) => _call(_protect, data);

  /// Розшифрувати; null — чужий користувач/ПК або пошкоджені дані.
  static Uint8List? unprotect(List<int> data) => _call(_unprotect, data);

  static Uint8List? _call(_CryptDart fn, List<int> data) {
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = buf;
      final ok = fn(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden,
          output);
      if (ok == 0) return null;
      final out = Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return out;
    } finally {
      // Відкритий текст не лишаємо в пам'яті довше, ніж треба.
      buf.asTypedList(data.isEmpty ? 1 : data.length).fillRange(
          0, data.isEmpty ? 1 : data.length, 0);
      calloc.free(buf);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
