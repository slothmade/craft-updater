# Security

Craft Updater runs with administrator rights and installs software. This page explains what it protects you from, where its limits are, and how to report a security problem.

## Reporting a vulnerability

Please report security problems **privately**, not as a public issue:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the problem, the affected version and, if possible, how to reproduce it.

This is a one-person hobby project. Reports are handled on a best-effort basis, without guaranteed response times.

Only the latest release is supported. Please check that the problem still exists there.

### What is not a vulnerability

- **Antivirus false positives.** Some scanners are suspicious of PowerShell scripts that ask for administrator rights. Please report these as a normal [issue](../../issues/new/choose) and include the scanner's name and detection name.
- **Intended behaviour.** Installing an update you approved is what the tool is for.

## What Craft Updater checks

Before anything is installed, every installer has to pass all of these checks:

1. **Where it comes from.** The download address must be `https://github.com/storytold/<app>/releases/download/...`. The file name must be a plain file name without any path.
2. **That the file was not changed.** The SHA-256 of the downloaded file must match the digest GitHub publishes for it, and its size must match too.
3. **Who signed it.** The Windows Authenticode signature must be valid and must come from the expected publisher (`Learning Machines Inc`), issued by Microsoft, with the expected certificate profile (EKU).
4. **What is inside.** Product name, version, manufacturer and processor architecture in the MSI must match the program and the release.
5. **That it really is an upgrade.** The MSI must belong to the same product family as the installed program, its upgrade table must match the installed version and language, and it must remove the old version properly.
6. **That nothing changed in the meantime.** Right before installing, all checks run again. The checked file is then kept locked against changes until Windows Installer has finished.
7. **That it worked.** After installing, the new version is confirmed with Windows Installer.

### Fail closed

- If **any** installer fails a security check (steps 1 to 4), **nothing at all** is installed in that run.
- Problems that only concern one program (the program is running, no matching installer, the download failed) only skip that program.
- Nothing is installed without your explicit approval: the *Install* button plus *Yes* in the window, or typing `YES` / `JA` in the console.

## What it never does

- No hidden PowerShell windows, no `-EncodedCommand`, no `Unblock-File`.
- No self-deleting files, no autostart, no scheduled background tasks.
- No copy of itself to other folders.
- No telemetry. It only contacts GitHub (`api.github.com`, `github.com` and GitHub's download servers under `*.githubusercontent.com`). While checking a signature, Windows itself may contact Microsoft's certificate servers.

## Limits – what it cannot protect against

Be aware of what these checks cannot do:

- **A compromised publisher.** If the Craft developers' own signing key were stolen and used to sign a malicious release, that release would pass the checks. Craft Updater trusts what the publisher signs.
- **Malware that is already on your PC** with administrator rights can change anything, including this updater.
- **Changes to the updater's own files.** Craft Updater runs from the folder you extracted it to. Anyone who can write to that folder can change the script. Keep it in your own user folder, and download it only from this repository's releases. Craft Updater is not code-signed, so Windows cannot detect such a change for you; if in doubt, delete the folder and download it again.

## Verifying your download

Every release lists the SHA-256 of its ZIP file in `SHA256SUMS`. To check your download in PowerShell:

```powershell
Get-FileHash .\Craft-Updater-v5.9-Portable.zip -Algorithm SHA256
```

The value shown must be exactly the one in `SHA256SUMS` on the release page.
