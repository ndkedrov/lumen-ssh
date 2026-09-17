# Lumen SSH

Нативний кросплатформний SSH-клієнт на Flutter (Dart) з термінальним UI, файловим менеджером (SFTP), монітором навантаження та набором інструментів адміністрування.

## Можливості

**Термінал**
- Повноцінний термінал (xterm) з власним обробником клавіатури
- Вкладки, split-панелі, дублювання сесій, перепідключення
- Пошук у терміналі (Ctrl+F), broadcast-ввід у всі вкладки
- Копіювання/вставлення (Ctrl+C/V, правий клік = вставка+Enter)
- Швидке очищення, копіювання всього логу, пакетний ввід команд
- Меню швидких команд (ls, du, df, free, ss, top-процеси тощо)

**Файловий менеджер (SFTP)**
- Перегляд каталогів, хлібні крихти, слідування за `cd` у терміналі (OSC 7)
- Мультивибір (Shift/Ctrl), завантаження/скачування з прогресом, drag&drop
- Перегляд/редагування текстових файлів, chmod, перейменування, видалення,
  нова папка/файл, копіювання шляху, показ прихованих, пошук

**Моніторинг**
- Нижня панель: CPU, RAM, SWAP, LA, uptime, мережа ↑↓, диск
- Детальний монітор (клік по панелі): CPU по ядрах, топ-процеси, мережа, диск

**Підключення / безпека**
- Пароль / приватний ключ, jump-host (бастіон), автокоманда при підключенні
- Групи, теги та пошук серверів
- Майстер-пароль (AES-256-GCM + PBKDF2) для шифрування збережених паролів
- Проброс портів (тунелі local/remote), генерація SSH-ключів

**Оформлення**
- Світла/темна тема, налаштовуваний акцентний колір
- Збереження розміру вікна, векторні SVG-іконки

## Стек

Flutter · `xterm` (термінал) · `dartssh2` (SSH/SFTP) · `flutter_svg` · `encrypt`/`crypto` · `window_manager` · `desktop_drop` · `file_picker` · `shared_preferences`.

## Завантаження

Готові збірки для Windows x64 — на сторінці [Releases](https://github.com/ndkedrov/lumen-ssh/releases/latest):

- `LumenSSH-Setup.exe` — інсталятор (меню «Пуск», ярлик, деінсталяція);
- `LumenSSH-windows-x64-portable.zip` — без встановлення: розпакуйте і запустіть `lumen_ssh.exe`.
  Запускайте з розпакованої теки — поруч з exe мають лежати `*.dll` і тека `data`.

Windows може показати попередження SmartScreen, бо збірки не підписані: «Докладніше» → «Виконати все одно».

## Збірка з вихідного коду

### Що потрібно

- Windows 10/11 x64
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/desktop) (stable, перевірено на 3.44; Dart ≥ 3.4)
- [Visual Studio 2022](https://visualstudio.microsoft.com/) з навантаженням **«Desktop development with C++»**
  (Build Tools теж підходять)
- Увімкнений **Developer Mode** у Windows (потрібен Flutter-плагінам для symlink):
  «Параметри» → «Система» → «Для розробників»
- Git

Перевірити оточення: `flutter doctor` — пункти *Flutter* і *Visual Studio* мають бути зеленими.

### Кроки

```bash
git clone https://github.com/ndkedrov/lumen-ssh.git
cd lumen-ssh
flutter pub get
flutter run -d windows            # запуск у режимі розробки (hot reload)
flutter build windows --release   # реліз -> build\windows\x64\runner\Release
```

Для запуску або поширення потрібна **вся** тека `build\windows\x64\runner\Release`
(`lumen_ssh.exe` + `*.dll` + `data\`), один exe окремо не запуститься.

### Інсталятор (необов'язково)

1. Встановіть [Inno Setup 6](https://jrsoftware.org/isdl.php).
2. Зберіть реліз (`flutter build windows --release`).
3. Скомпілюйте скрипт — з IDE Inno Setup або з командного рядка:
   ```bash
   "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" installer.iss
   ```
   (якщо Inno Setup встановлено для всіх користувачів — `"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"`).
   Результат: `dist\LumenSSH-Setup.exe`.

### Інші платформи

У репозиторії є лише платформа Windows. Код на Flutter і теоретично переноситься на
Linux/macOS (`flutter create --platforms=linux,macos .`), але там не тестувався.

## Дані користувача

Збережені сервери, сніпети й налаштування зберігаються локально (`shared_preferences`,
у Windows — `%APPDATA%`), у репозиторій не потрапляють. Паролі серверів можна зашифрувати
майстер-паролем.

## Ліцензія

[GPL-3.0](LICENSE)

## Структура

- `lib/main.dart` — точка входу, тема, вікно
- `lib/home_page.dart` — головний UI
- `lib/ssh_session.dart` — SSH/SFTP-сесія, метрики, тунелі-хост
- `lib/server.dart` — модель і сховище серверів
- `lib/theme.dart`, `lib/app_icons.dart` — палітра та іконки
- `lib/file_editor.dart`, `snippets.dart`, `monitor_panel.dart`,
  `secure_store.dart`, `ssh_keygen.dart`, `tunnels.dart` — модулі
