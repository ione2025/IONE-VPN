; IONE VPN – Windows Installer Script for Inno Setup 6
; =============================================================================
; 1. Build the Flutter Windows release first:
;       flutter build windows --release
;    (from the flutter_app/ directory)
;
; 2. Open this file in Inno Setup Compiler and press Ctrl+F9 to compile.
;    The output installer will be created in dist\IONE_VPN_Setup.exe
; =============================================================================

[Setup]
AppName=IONE VPN
AppVersion=1.0.0
AppPublisher=IONE
AppPublisherURL=https://github.com/ione2025/IONE-VPN
AppSupportURL=https://github.com/ione2025/IONE-VPN/issues
AppUpdatesURL=https://github.com/ione2025/IONE-VPN/releases
DefaultDirName={autopf}\IONE VPN
DefaultGroupName=IONE VPN
AllowNoIcons=yes
; Output location (relative to this .iss file)
OutputDir=..\dist
OutputBaseFilename=IONE_VPN_Setup
SetupIconFile=..\flutter_app\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.17763
; Require WireGuard for Windows (warn but don't block)
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon";    Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startupicon";   Description: "Start IONE VPN automatically at login";  GroupDescription: "Startup"

[Files]
; All compiled Flutter files (exe + DLLs + data)
Source: "..\flutter_app\build\windows\x64\runner\Release\*"; \
  DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\IONE VPN";          Filename: "{app}\ione_vpn.exe"
Name: "{group}\Uninstall IONE VPN"; Filename: "{uninstallexe}"
Name: "{commondesktop}\IONE VPN";  Filename: "{app}\ione_vpn.exe"; Tasks: desktopicon
Name: "{userstartup}\IONE VPN";    Filename: "{app}\ione_vpn.exe"; Tasks: startupicon

[Run]
Filename: "{app}\ione_vpn.exe"; \
  Description: "{cm:LaunchProgram,IONE VPN}"; \
  Flags: nowait postinstall skipifsilent

[Messages]
WelcomeLabel2=This will install IONE VPN on your computer.%n%nIONE VPN requires WireGuard for Windows to establish the VPN tunnel. If not already installed, please download it from https://www.wireguard.com/install/ after setup.%n%nClick Next to continue.
