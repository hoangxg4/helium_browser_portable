Helium Portable - quick start

=============================



Double-click  "Helium Browser.bat"  to start the browser.

(The browser itself lives in the Helium\ subfolder; Chrome++ requires it there,

so this folder holds only launchers for convenience.)



Launchers in this folder

------------------------

  Helium Browser.bat        start the browser (data + cache stay in this folder)

  Update Helium.bat         update to the latest Helium build (updates Helium\ only)

  Set Default Browser.bat   register Helium as a browser in Windows Settings

  Apply Debloat Policies.bat  import debloater.reg (privacy + update policies)

  Defender Exclusion.bat    add/remove a Defender exclusion for this whole folder
  Fix AppData leftovers.bat delete an old %LOCALAPPDATA%\imput folder left by a
                            pre-fix launcher/config (cleanup only)



Folders

-------

  Helium\        browser + config + WidevineCdm (do not rename or move)

  Data\          profile + Crashpad dumps      (created on first run)

  Cache\         disk cache                    (created on first run)



Notes

-----

* Starting through "Helium Browser.bat" also keeps %LOCALAPPDATA% inside the
  package (Data\Local). That is what stops Chromium from recreating
  %LOCALAPPDATA%\imput\Helium\User Data\Crashpad through a child process, so
  launching chrome.exe by hand loses that protection.
* Always start the browser through "Helium Browser.bat" or a shortcut whose

  "Start in" is the Helium\ folder. Launching Helium\chrome.exe from an

  arbitrary working directory can make relative paths (profile, cache, Crashpad)

  resolve somewhere else.

* DRM / Widevine: the x64 build ships the CDM at Helium\WidevineCdm. There is no

  arm64 Widevine CDM available for Windows, so the arm64 build ships without it

  and cannot play DRM-protected streams - see README.md.

* Keep the folder structure intact when moving the package to another drive.

