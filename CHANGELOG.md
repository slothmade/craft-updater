# Changelog

## 5.8.1

- New: **TextureCraft** is updated as well (now 14 Craft programs). Its installer goes through exactly the same checks as all others.
- New: a notice at the bottom right of the window (and in the console) when a newer Craft Updater is on GitHub. Clicking it only opens the release page; nothing is downloaded or installed automatically. Any problem with this check is ignored quietly.
- Instructions: what to do when Windows 11 *Smart App Control* blocks the launcher (unblock the ZIP before extracting, no need to turn protection off).

## 5.8 – first public version

**Safety**
- Every installer must pass SHA-256, Windows code signature, publisher, certificate profile, MSI contents and upgrade checks; one failed security check blocks the whole run.
- The checked installer is locked against changes until Windows Installer has finished.
- Nothing is installed without explicit approval (*Install* + *Yes*, or `YES` / `JA` in the console).
- Runs straight from the extracted folder: no copy to Program Files, no shortcuts, no self-deleting files, no hidden or encoded PowerShell (these patterns trigger virus scanner heuristics).

**Window**
- List of all Craft programs with installed and new version, status colours and a progress bar; updates on top, programs that are not installed at the bottom; versions always shown with `v`.
- *What's new?* shows the release notes of the selected update (button or double-click) in a small scrollable window, with a link to the full notes that can be clicked or copied. Only links to the Craft release pages on GitHub are opened, and the browser starts without administrator rights.
- Version shown in the title bar and header; small splash screen; plum title bar; the console window starts minimised and closes together with the window.
- Tidy folder: pictures live in `assets`, and the error report folder only exists while there are reports.

**Reports**
- Warnings and problems are written to one error report, so only one file needs to be shared.
- User name and computer name are removed from the error report.

**Languages and project**
- German on a German Windows, English otherwise (`CRAFT_UPDATER_LANG=de|en` to override).
- English source code and documentation, MIT license, security policy, issue forms.
- Offline tests, code analysis and the release build run on GitHub Actions.

## Earlier versions

5.6.3 and earlier were private versions shared with friends only (console updater with a protected copy in Program Files).
