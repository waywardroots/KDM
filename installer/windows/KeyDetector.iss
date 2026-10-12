; ============================================================================
;  Key Detector - Windows installer  (Inno Setup 6)
;  (c) 2026 Fuzzy Audio LLC
; ----------------------------------------------------------------------------
;  Builds a signed-ready setup .exe that installs the VST3 plug-in (and, if
;  present, the Standalone app).  The wizard lets the user choose both the VST3
;  folder and the Standalone/app destination.  Inno Setup is free: https://jrsoftware.org
;
;  USAGE (run from the repo root on Windows):
;     1. Download the "KeyDetector-VST3-Windows" artifact from the GitHub
;        Actions run and unzip it so you have:
;            installer\windows\artifacts\Key Detector.vst3\   (the bundle folder)
;        Optionally also drop a Standalone build there:
;            installer\windows\artifacts\Key Detector.exe
;     2. Compile:
;            iscc /DAppVersion=1.0.0 installer\windows\KeyDetector.iss
;        The finished installer lands in installer\windows\output\.
;
;  The license shown by the wizard is the canonical Fuzzy Audio EULA
;  (..\EULA.rtf, generated from the signed PDF).
; ============================================================================

#define AppName      "Key Detector"
#define AppPublisher "Fuzzy Audio LLC"
#define AppURL       "https://fuzzyaudio.example"      ; TODO: real website
#define AppExe       "Key Detector.exe"

; Version can be overridden on the command line:  iscc /DAppVersion=1.2.3 ...
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; Where the built plug-in/app live, relative to this .iss file.
#ifndef ArtifactsDir
  #define ArtifactsDir "artifacts"
#endif
#define Vst3Src       ArtifactsDir + "\" + AppName + ".vst3"
#define StandaloneSrc ArtifactsDir + "\" + AppExe
#define AaxSrc        ArtifactsDir + "\" + AppName + ".aaxplugin"

; Detect at compile time which optional builds were provided, so their
; component/files/icons are only emitted when the artifact is present.
#define HaveStandalone FileExists(AddBackslash(SourcePath) + StandaloneSrc)
#define HaveAax        DirExists(AddBackslash(SourcePath) + AaxSrc)

[Setup]
; AppId uniquely identifies the app for upgrades/uninstall - do NOT change it.
AppId={{7DDBC97F-CC61-4FAB-8D4B-59107465C6AF}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppCopyright=Copyright (C) 2026 Fuzzy Audio LLC
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Fuzzy Audio\{#AppName}
DefaultGroupName=Fuzzy Audio\{#AppName}
DisableProgramGroupPage=yes
; Show the standard "Select Destination Location" page (controls where the
; Standalone app + uninstaller go); a second custom page (see [Code]) lets the
; user choose the VST3 folder too.
DisableDirPage=no
LicenseFile=..\EULA.rtf
OutputDir=output
OutputBaseFilename=KeyDetector-{#AppVersion}-Windows-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; VST3 goes to the shared Common Files\VST3 folder, which requires admin rights.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName} {#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full";   Description: "Full installation"
Name: "custom"; Description: "Custom installation"; Flags: iscustom

[Components]
Name: "vst3"; Description: "VST3 plug-in (64-bit)"; Types: full custom; Flags: fixed
#if HaveStandalone
Name: "standalone"; Description: "Standalone application"; Types: full custom
#endif
#if HaveAax
Name: "aax"; Description: "AAX plug-in (Pro Tools)"; Types: full custom
#endif

[Files]
; --- VST3 bundle -> user-selected VST3 folder (default: Common Files\VST3) -----
Source: "{#Vst3Src}\*"; DestDir: "{code:GetVST3Dir}\{#AppName}.vst3"; \
    Components: vst3; Flags: recursesubdirs createallsubdirs ignoreversion
#if HaveStandalone
; --- Standalone application -> {app} -----------------------------------------
Source: "{#StandaloneSrc}"; DestDir: "{app}"; Components: standalone; Flags: ignoreversion
#endif
#if HaveAax
; --- AAX bundle -> Common Files\Avid\Audio\Plug-Ins\Key Detector.aaxplugin ----
Source: "{#AaxSrc}\*"; DestDir: "{commoncf64}\Avid\Audio\Plug-Ins\{#AppName}.aaxplugin"; \
    Components: aax; Flags: recursesubdirs createallsubdirs ignoreversion
#endif

[Icons]
#if HaveStandalone
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; Components: standalone
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
#endif

[UninstallDelete]
; The VST3 bundle may live in a user-chosen folder, so we rely on Inno's
; automatic file/dir tracking to remove it (it deletes installed files and the
; now-empty bundle folders wherever they were placed).
#if HaveAax
Type: filesandordirs; Name: "{commoncf64}\Avid\Audio\Plug-Ins\{#AppName}.aaxplugin"
#endif

[Code]
// A second wizard page (after the standard destination page) that lets the user
// choose the folder the VST3 plug-in is installed into. Defaults to the shared
// Common Files\VST3 folder that DAWs scan by default.
var
  Vst3DirPage: TInputDirWizardPage;

procedure InitializeWizard;
begin
  Vst3DirPage := CreateInputDirPage (wpSelectDir,
    'Select VST3 Location',
    'Where should the VST3 plug-in be installed?',
    'Setup will install the {#AppName} VST3 plug-in into the following folder.'
      + #13#10#13#10 +
    'Most DAWs scan the default folder shown below, so only change it if your host '
      + 'looks elsewhere. To continue, click Next. To pick a different folder, click Browse.',
    False, '');
  Vst3DirPage.Add ('');
  Vst3DirPage.Values[0] := ExpandConstant ('{commoncf64}\VST3');
end;

function GetVST3Dir (Param: String): String;
begin
  Result := Vst3DirPage.Values[0];
end;
