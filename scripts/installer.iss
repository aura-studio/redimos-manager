; Inno Setup 6.3+ script for the Redimos Manager Windows installer.
;
; Compile inside the Windows VM AFTER `build.cmd -SkipDll` has produced the
; Release folder (and bin\redimos-v*.exe exist — prepped on the Mac by
; scripts/build-windows-prep.sh):
;
;   powershell -ExecutionPolicy Bypass -File scripts\build-installer.ps1
;   (or directly:  ISCC /DAppVersion=1.0.0 scripts\installer.iss)
;
; Output: dist\redimos-manager-<ver>-setup-x64.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Redimos Manager"

[Setup]
; Fixed AppId so upgrades replace the same installation.
AppId={{A7C1E5D0-4B2F-4C1A-9E76-3D2F8B1C6A55}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=aura-studio
AppPublisherURL=https://github.com/aura-studio/redimos-manager
AppSupportURL=https://github.com/aura-studio/redimos-manager/issues
DefaultDirName={autopf}\Redimos Manager
DefaultGroupName=Redimos Manager
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=redimos-manager-{#AppVersion}-setup-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\redimos_manager.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; The whole Flutter Release folder: redimos_manager.exe + flutter_windows.dll
; + data\ + redimos_core.dll (build.ps1 drops the DLL next to the exe).
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
; redimos server binaries — point Settings at {app}\bin\redimos-v*.exe.
Source: "..\bin\redimos-v1.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\bin\redimos-v2.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\redimos_manager.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\redimos_manager.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\redimos_manager.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
