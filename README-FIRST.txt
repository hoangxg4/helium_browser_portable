Helium Portable - quick start
=============================

Double-click  "Helium Browser.bat"  to start the browser.
(The browser itself lives in the Helium\ subfolder; Chrome++ requires it there,
so this folder holds only launchers for convenience.)

Launchers in this folder
------------------------
  Helium Browser.bat        start the browser (data, cache and Crashpad stay here)
  Update Helium.bat         update to the latest Helium build (updates Helium\ only)
  Set Default Browser.bat   register Helium as a browser in Windows Settings
  Apply Debloat Policies.bat  import debloater.reg (privacy + update policies)
  Defender Exclusion.bat    add/remove a Defender exclusion for this whole folder
  Fix AppData leftovers.bat delete an old %LOCALAPPDATA%\imput folder left by a
                            pre-fix launcher/config (cleanup only)
  Block AppData folder.bat  optional: deny write access to %LOCALAPPDATA%\imput so
                            no launch path can recreate it (admin, reversible)

Folders
-------
  Helium\        browser + config + WidevineCdm (do not rename or move)
  Data\          profile, Crashpad dumps, redirected LOCALAPPDATA (first run)
  Cache\         disk cache                                        (first run)

Notes
-----
* Always start through "Helium Browser.bat". Launching Helium\chrome.exe by hand
  loses three protections it sets up: absolute profile/cache/Crashpad paths,
  --disable-crash-reporter, and a LOCALAPPDATA redirected into Data\Local.
* Chromium derives the Crashpad folder from its *default* user data directory,
  which is built from %LOCALAPPDATA% and ignores --user-data-dir. That is why a
  child process (for example the relaunch after "clear browsing data") could
  recreate %LOCALAPPDATA%\imput\Helium\User Data\Crashpad on older launchers — the
  redirect above is what prevents it now. Report: issue #9.
* DRM / Widevine: the x64 build ships the CDM at Helium\WidevineCdm and gives
  software-level playback (Widevine L3, cenc/cbcs). There is no arm64 Widevine CDM
  for Windows, so the arm64 build ships without one; neither build can offer
  hardware L1, which needs device hardware plus a licence server that grants it.
  See README.md.
* Keep the folder structure intact when moving the package to another drive.
