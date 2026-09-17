import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Глобальний акцентний колір (перекриває стандартний, якщо заданий).
Color? gAccent;

/// Палітра застосунку — залежить від яскравості теми.
class LC {
  final bool dark;
  const LC(this.dark);
  static LC of(BuildContext c) => LC(Theme.of(c).brightness == Brightness.dark);

  Color get bg => dark ? const Color(0xFF0F1117) : const Color(0xFFEEF1F6);
  Color get surface => dark ? const Color(0xFF161922) : const Color(0xFFFFFFFF);
  Color get surface2 => dark ? const Color(0xFF1C2029) : const Color(0xFFF2F5FA);
  Color get border => dark ? const Color(0xFF262B36) : const Color(0xFFD7DDE7);
  Color get text => dark ? const Color(0xFFD7DBE4) : const Color(0xFF1D2430);
  Color get dim => dark ? const Color(0xFF8B93A3) : const Color(0xFF66707F);
  Color get accent =>
      gAccent ?? (dark ? const Color(0xFF5B9DFF) : const Color(0xFF2F6BFF));
  Color get good => dark ? const Color(0xFF3ECF8E) : const Color(0xFF17A673);
  Color get warn => dark ? const Color(0xFFF5B74E) : const Color(0xFFD9902A);
  Color get bad => dark ? const Color(0xFFFF6B6B) : const Color(0xFFE5484D);
  Color get termBg => dark ? const Color(0xFF0C0E14) : const Color(0xFFFBFCFE);

  Color barColor(double pct) => pct >= 90 ? bad : (pct >= 70 ? warn : good);
}

ThemeData buildTheme(bool dark) {
  final lc = LC(dark);
  final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: lc.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: lc.accent,
      surface: lc.surface,
    ),
    textTheme: base.textTheme.apply(bodyColor: lc.text, displayColor: lc.text),
    dividerColor: lc.border,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: lc.surface2, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: lc.text, fontSize: 12),
    ),
  );
}

/// Кольорова тема самого терміналу.
TerminalTheme terminalTheme(bool dark) {
  if (dark) {
    return const TerminalTheme(
      cursor: Color(0xFF5B9DFF),
      selection: Color(0x552A3550),
      foreground: Color(0xFFD7DBE4),
      background: Color(0xFF0C0E14),
      black: Color(0xFF1C2029),
      red: Color(0xFFFF6B6B),
      green: Color(0xFF3ECF8E),
      yellow: Color(0xFFF5B74E),
      blue: Color(0xFF5B9DFF),
      magenta: Color(0xFF7C5CFF),
      cyan: Color(0xFF42C8D4),
      white: Color(0xFFD7DBE4),
      brightBlack: Color(0xFF4A5262),
      brightRed: Color(0xFFFF8A8A),
      brightGreen: Color(0xFF6BE0AC),
      brightYellow: Color(0xFFFFCB73),
      brightBlue: Color(0xFF83B6FF),
      brightMagenta: Color(0xFF9E85FF),
      brightCyan: Color(0xFF6FDBE6),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFFF5B74E),
      searchHitBackgroundCurrent: Color(0xFF5B9DFF),
      searchHitForeground: Color(0xFF0C0E14),
    );
  }
  return const TerminalTheme(
    cursor: Color(0xFF2F6BFF),
    selection: Color(0x33CFE0FF),
    foreground: Color(0xFF1D2430),
    background: Color(0xFFFBFCFE),
    black: Color(0xFF1D2430),
    red: Color(0xFFE5484D),
    green: Color(0xFF17A673),
    yellow: Color(0xFFC47F1A),
    blue: Color(0xFF2F6BFF),
    magenta: Color(0xFF7C5CFF),
    cyan: Color(0xFF178A9C),
    white: Color(0xFF5C6673),
    brightBlack: Color(0xFF9AA4B2),
    brightRed: Color(0xFFE5484D),
    brightGreen: Color(0xFF17A673),
    brightYellow: Color(0xFFC47F1A),
    brightBlue: Color(0xFF2F6BFF),
    brightMagenta: Color(0xFF7C5CFF),
    brightCyan: Color(0xFF178A9C),
    brightWhite: Color(0xFF1D2430),
    searchHitBackground: Color(0xFFF5B74E),
    searchHitBackgroundCurrent: Color(0xFF2F6BFF),
    searchHitForeground: Color(0xFFFBFCFE),
  );
}
