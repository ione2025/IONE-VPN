; IONE VPN – Windows Installer Script for Inno Setup 6
; =============================================================================
; 1. Build the Flutter Windows release first:
;       flutter build windows --release
;    (from the flutter_app/ directory)
;
; 2. WireGuard is automatically bundled with this installer (wireguard-amd64.msi).
;    It will be installed automatically if not already present on the target system.
;
; 3. Open this file in Inno Setup Compiler and press Ctrl+F9 to compile.
;    The output installer will be created in dist\IONE_VPN_Setup.exe
;    Note: The final installer size will be ~100MB+ (includes Flutter app + WireGuard)
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
PrivilegesRequiredOverridesAllowed=dialog
; Require admin to install WireGuard
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

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

; WireGuard installer bundled with this setup (will be extracted to temp during install)
Source: "wireguard-amd64.msi"; \
  DestDir: "{tmp}"; \
  Flags: ignoreversion

[Icons]
Name: "{group}\IONE VPN";          Filename: "{app}\ione_vpn.exe"
Name: "{group}\Uninstall IONE VPN"; Filename: "{uninstallexe}"
Name: "{commondesktop}\IONE VPN";  Filename: "{app}\ione_vpn.exe"; Tasks: desktopicon
Name: "{userstartup}\IONE VPN";    Filename: "{app}\ione_vpn.exe"; Tasks: startupicon

[Run]
; Install WireGuard if not already installed on the system
; WireGuard is bundled with this installer, so no network download needed.
; The installer only installs the dependency and does not launch WireGuard UI.
Filename: "msiexec.exe"; \
  Parameters: "/i ""{tmp}\wireguard-amd64.msi"" /qn /norestart"; \
  StatusMsg: "Installing WireGuard prerequisites..."; \
  Flags: waituntilterminated runhidden; \
  Check: not WireGuardInstalled

; Launch IONE VPN after installation complete
Filename: "{app}\ione_vpn.exe"; \
  Description: "{cm:LaunchProgram,IONE VPN}"; \
  Flags: nowait postinstall skipifsilent

[Code]
function WireGuardInstalled: Boolean;
var
  ResultCode: Integer;
begin
  { Check if WireGuard executable exists in standard paths }
  if FileExists('C:\Program Files\WireGuard\wireguard.exe') then
    Result := True
  else if FileExists('C:\Program Files (x86)\WireGuard\wireguard.exe') then
    Result := True
  else
  begin
    { Try checking registry for installation }
    Result := RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WireGuard');
    if not Result then
      Result := RegKeyExists(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\WireGuard');
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and not WireGuardInstalled then
  begin
    MsgBox('WARNING: WireGuard is not installed on this system.' + #13 + #13 +
           'IONE VPN requires WireGuard to establish VPN tunnels.' + #13 + #13 +
           'Please install WireGuard from: https://www.wireguard.com/install/' + #13 + #13 +
           'Then restart IONE VPN.', mbInformation, MB_OK);
  end;
end;

[Messages]
WelcomeLabel2=This will install IONE VPN on your computer.%n%nIONE VPN requires WireGuard for Windows to establish secure VPN tunnels. WireGuard is bundled with this installer and will be installed automatically if not already present, but it will not be launched during setup.%n%nAdministrator privileges are required to proceed.%n%nClick Next to continue.
