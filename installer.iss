; Inno Setup script for Lumen SSH
; Шляхи відносні до теки цього скрипта. Спершу: flutter build windows --release
#define MyName "Lumen SSH"
#define MyVersion "1.0.0"
#define MyExe "lumen_ssh.exe"
#define RelDir SourcePath + "build\windows\x64\runner\Release"

[Setup]
AppId=LumenSSH-9C1E7A204B3D4E9A
AppName={#MyName}
AppVersion={#MyVersion}
AppPublisher=Lumen
DefaultDirName={autopf}\Lumen SSH
DefaultGroupName=Lumen SSH
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyExe}
OutputDir=dist
OutputBaseFilename=LumenSSH-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=windows\runner\resources\app_icon.ico
LicenseFile=LICENSE
WizardStyle=modern

[Languages]
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Створити ярлик на робочому столі"; Flags: unchecked

[Files]
Source: "{#RelDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Lumen SSH"; Filename: "{app}\{#MyExe}"
Name: "{autodesktop}\Lumen SSH"; Filename: "{app}\{#MyExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyExe}"; Description: "Запустити Lumen SSH"; Flags: nowait postinstall skipifsilent
