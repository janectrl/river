#define AppName "river"
#define AppVersion "1.0.0"
#define AppPublisher "river"
#define AppExeName "river.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7B635A79-750A-4BF7-9B7C-A47A9F43E2CF}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\river
DefaultGroupName=river
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=river-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\river"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\river"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch river"; Flags: nowait postinstall skipifsilent
