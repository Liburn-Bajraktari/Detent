; Inno Setup script: the Windows installer for the frozen app (PyInstaller's
; dist\Detent, see Detent.spec).
;
;   iscc /DAppVersion=0.17.0 packaging\windows\Detent.iss
;
; Per user, no administrator rights: %LOCALAPPDATA%\Programs\Detent (an update keeps
; the folder of the first install, so copies from before the rename stay in Programs\Touch Dashboard),
; an entry in Installed Apps. Only the optional firewall rule asks for
; administrator rights, once. The app's own update runs it with
;   /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TDWAIT=<the app's process id>
; and exits; Setup waits for that process to be gone, installs, and starts
; the new version.

#ifndef AppVersion
  #error Pass /DAppVersion=X.Y.Z
#endif

[Setup]
AppId={{6F1C2B7E-3D4A-4E59-9A0B-7D2E1C5F8A31}
AppName=Detent
AppVersion={#AppVersion}
AppVerName=Detent {#AppVersion}
AppPublisher=Invar
AppPublisherURL=https://github.com/Liburn-Bajraktari/Detent
AppSupportURL=https://github.com/Liburn-Bajraktari/Detent/issues
DefaultDirName={localappdata}\Programs\Detent
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=Output
OutputBaseFilename=Detent-Setup-v{#AppVersion}
SetupIconFile=..\..\static\favicon.ico
UninstallDisplayIcon={app}\Detent.exe
UninstallDisplayName=Detent
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The running app is waited for in InitializeSetup ([Code]), not by AppMutex,
; whose check may come before an update's app has exited
CloseApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "autostart"; Description: "Start Detent when I sign in to Windows"; Flags: unchecked
Name: "firewall"; Description: "Let tablets on my home network connect (asks for administrator rights once)"

[Files]
Source: "..\..\dist\Detent\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

; A release replaces the whole program folder: nothing it removed lingers
[InstallDelete]
Type: filesandordirs; Name: "{app}\_internal"
; Shortcuts made before the rename to Detent
Type: files; Name: "{autoprograms}\Touch Dashboard.lnk"
; The executable before the rename (TouchDashboard.exe)
Type: files; Name: "{app}\TouchDashboard.exe"
Type: files; Name: "{autodesktop}\Touch Dashboard.lnk"

[Icons]
; The window's own AppUserModelID (desktop.py), so a pinned shortcut and the running window are one taskbar button
Name: "{autoprograms}\Detent"; Filename: "{app}\Detent.exe"; AppUserModelID: "TouchDashboard.TouchDashboard"
Name: "{autodesktop}\Detent"; Filename: "{app}\Detent.exe"; AppUserModelID: "TouchDashboard.TouchDashboard"; Tasks: desktopicon

[Registry]
; The same value the app's own "Start with Windows" switch sets (server.py _autostart).
; Not on an update: a silent Setup reuses the first install's tasks and would turn
; it back on after the switch turned it off.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "TouchDashboard"; ValueData: """{app}\Detent.exe"""; Tasks: autostart; Check: not WizardSilent; Flags: uninsdeletevalue

[Run]
; Port 8888 on private networks only, and only from the local subnet (as install.ps1)
Filename: "{sys}\cmd.exe"; Parameters: "/c netsh advfirewall firewall delete rule name=""Touch Dashboard Backend"" >nul & netsh advfirewall firewall delete rule name=""Detent Backend"" >nul & netsh advfirewall firewall add rule name=""Detent Backend"" dir=in action=allow protocol=TCP localport=8888 profile=private remoteip=localsubnet"; Verb: runas; Flags: shellexec runhidden waituntilterminated; Tasks: firewall; Check: not WizardSilent; StatusMsg: "Opening port 8888 for your home network..."
Filename: "{app}\Detent.exe"; Description: "Start Detent"; Flags: nowait postinstall skipifsilent
; An update from the app: it comes back by itself
Filename: "{app}\Detent.exe"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\cmd.exe"; Parameters: "/c netsh advfirewall firewall delete rule name=""Detent Backend"" & netsh advfirewall firewall delete rule name=""Touch Dashboard Backend"""; Verb: runas; Flags: shellexec runhidden waituntilterminated; RunOnceId: "firewall"

[Code]
function OpenProcess(Access: Cardinal; Inherit: Boolean; Pid: Cardinal): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Ms: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

const
  RunningMutex = 'Global\TouchDashboard_Mutex_8888';   { held by the running app (desktop.py) }

// An update from the app: wait for the app that started it to be gone, so its
// files can be replaced. Then for any other copy still running (its mutex):
// asked to be closed when someone is at the wizard, waited for a minute when silent.
function InitializeSetup(): Boolean;
var
  Pid: Cardinal;
  H: THandle;
  Waited: Integer;
begin
  Result := False;
  Pid := StrToIntDef(ExpandConstant('{param:TDWAIT|0}'), 0);
  if Pid <> 0 then begin
    H := OpenProcess($00100000, False, Pid);   { SYNCHRONIZE }
    if H <> 0 then begin
      WaitForSingleObject(H, 60000);
      CloseHandle(H);
    end;
  end;
  Waited := 0;
  while CheckForMutexes(RunningMutex) do begin
    if WizardSilent then begin
      if Waited >= 60 then exit;
      Sleep(1000);
      Waited := Waited + 1;
    end else if MsgBox('Detent is running. Close it (its tray icon: Quit), then press OK.',
                       mbInformation, MB_OKCANCEL) = IDCANCEL then
      exit;
  end;
  Result := True;
end;

// install.ps1 put an earlier setup in %LOCALAPPDATA%\Touch-Dashboard (Python
// and a launcher script); offer to remove it, and its start-with-Windows value.
procedure RemoveScriptInstall();
var
  Old, Value: String;
begin
  Old := ExpandConstant('{localappdata}\Touch-Dashboard');
  if not DirExists(Old + '\.venv') then exit;
  if MsgBox('An earlier Detent installed by its PowerShell installer is in ' + Old +
            '. Remove it? Your settings and paired tablets stay.', mbConfirmation, MB_YESNO) <> IDYES then exit;
  DelTree(Old, True, True, True);
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'TouchDashboard', Value) and
     (Pos('TouchDashboard.vbs', Value) > 0) then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'TouchDashboard');
end;

// Start with Windows set before the rename points at TouchDashboard.exe, which this
// release removes: point it at Detent.exe. The value's name stays "TouchDashboard",
// which the app's own switch (server.py) reads and writes.
procedure MoveAutostartToDetent();
var
  Value: String;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'TouchDashboard', Value) and
     (Pos('\TouchDashboard.exe', Value) > 0) then begin
    StringChangeEx(Value, '\TouchDashboard.exe', '\Detent.exe', True);
    RegWriteStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'TouchDashboard', Value);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    MoveAutostartToDetent();
    if not WizardSilent then
      RemoveScriptInstall();
  end;
end;

// Settings, paired tablets and sign-ins live in %APPDATA%\touch-dashboard: asked about, not assumed.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep <> usPostUninstall then exit;
  Data := ExpandConstant('{userappdata}\touch-dashboard');
  if DirExists(Data) and not UninstallSilent and
     (MsgBox('Also delete your settings, paired tablets and sign-ins (' + Data + ')?',
             mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES) then
    DelTree(Data, True, True, True);
end;
