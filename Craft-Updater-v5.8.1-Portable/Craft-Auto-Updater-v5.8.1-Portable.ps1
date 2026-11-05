# Craft Auto-Updater v5.8.1 Portable - Windows PowerShell 5.1
# Installs updates only after every security check has passed and after one explicit
# approval (window: "Install" button plus confirmation; console: type YES / JA).
#
# Copyright (c) 2026 slothmade (slothworks) - https://github.com/slothmade/craft-updater
# MIT License:
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
# Unofficial project: not made by, affiliated with or endorsed by the developers of the Craft apps.
#
# Layout of this file:
#   1. Configuration          - all fixed values in one place
#   2. Runtime state          - everything that changes during a run
#   3. General helpers        - versions, publishers, results, files, window link
#   4. GitHub                 - release lookup, cache, rate limit, downloads
#   5. Windows Installer (MSI)- read packages, query installed products
#   6. Security checks        - package checks, registry, installation approval
#   7. Run phases             - search, preflight, install, report, maintenance
#                               (no copy to Program Files: the updater runs straight
#                               from the extracted folder until there is a signed .exe)
#   7b. Window                - user interface; the run itself happens unchanged in
#                               the background (own runspace, same process)
#   8. Start                  - mutex, choose mode, exit code
#
# Language:
#   German on a German Windows, English otherwise. Override with the environment
#   variable CRAFT_UPDATER_LANG=de or CRAFT_UPDATER_LANG=en.
#
# Window or console:
#   Normally a window opens. The console window intentionally stays visible
#   (no hidden PowerShell - virus scanners report that as a threat).
#   -Konsole, -Diagnose and -NurPruefen run in the console only.
#
# Security rule:
#   A SECURITY ERROR (hash, signature, certificate profile, publisher, download
#   address, package data) blocks ALL installations of this run.
#   A problem that only affects one program (it is running, no matching installer,
#   upgrade does not fit, download failed) skips only that program.
param(
    [Alias('Diagnostics')][switch]$Diagnose,
    [Alias('Detailed')][switch]$Ausfuehrlich,
    [Alias('CheckOnly')][switch]$NurPruefen,
    [Alias('ConsoleOnly')][switch]$Konsole,
    # Internal only: link to the window when this run happens in the background.
    [object]$GuiSync = $null
)
$ErrorActionPreference = 'Stop'
# PS 5.1: the progress bar of Invoke-WebRequest slows downloads down massively.
$ProgressPreference = 'SilentlyContinue'

# User interface language (see header). L 'German text' 'English text' returns the right one.
$UiGerman = ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de')
if ($env:CRAFT_UPDATER_LANG -eq 'de') { $UiGerman = $true } elseif ($env:CRAFT_UPDATER_LANG -eq 'en') { $UiGerman = $false }
function L([string]$de,[string]$en) {
    if ($UiGerman) { return $de }
    return $en
}

# ============================================================================
# 1. CONFIGURATION
# ============================================================================
$UpdaterVersion = '5.8.1'
# Project page (shown small at the bottom of the window).
$ProjectUrl = 'https://github.com/slothmade/craft-updater'
$ScriptPath = $PSCommandPath
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$Owner = 'storytold'
$Programs = @(
    @{Name='WordCraft';Repo='wordcraft';Pattern='^WordCraft\b'},
    @{Name='GridCraft';Repo='gridcraft';Pattern='^GridCraft\b'},
    @{Name='DeckCraft';Repo='deckcraft';Pattern='^DeckCraft\b'},
    @{Name='EffectCraft';Repo='effectcraft';Pattern='^EffectCraft\b'},
    @{Name='DesignCraft';Repo='designcraft';Pattern='^DesignCraft\b'},
    @{Name='PhotoCraft';Repo='photocraft';Pattern='^(PhotoCraft|FotoCraft)\b'},
    @{Name='VectorCraft';Repo='vectorcraft';Pattern='^VectorCraft\b'},
    @{Name='FilmCraft';Repo='filmcraft';Pattern='^FilmCraft\b'},
    @{Name='PdfCraft';Repo='pdfcraft';Pattern='^PdfCraft\b'},
    @{Name='LightCraft';Repo='lightcraft';Pattern='^LightCraft\b'},
    @{Name='FigCraft';Repo='figcraft';Pattern='^FigCraft\b'},
    @{Name='SoundCraft';Repo='soundcraft';Pattern='^SoundCraft\b'},
    @{Name='CADCraft';Repo='cadcraft';Pattern='^CADCraft\b'},
    @{Name='TextureCraft';Repo='texturecraft';Pattern='^TextureCraft\b'}
)

# Signature and publisher. The profile EKU was derived from previously approved, validly
# signed MSI files; thumbprints rotate and are not used as an anchor.
$ExpectedProfileEku = '1.3.6.1.4.1.311.97.627281783.214399755.66947568.492752054'
$CodeSigningEku = '1.3.6.1.5.5.7.3.3'
$ExpectedIssuerOrganization = 'Microsoft Corporation'
$ExpectedPublisher = 'Learning Machines Inc'
$AllowedRegistryPublishers = @('Learning Machines Inc','Learning Machines LLC')

# Network and installation.
$MaxTries = 3
$TimeoutSeconds = 120
$InstallTimeoutSeconds = 1800
$MinReserveBytes = 500MB
# 60 minutes: new releases are detected after one hour at the latest.
# 14 API requests per run stay far below the GitHub limit (60 per hour).
$CacheTtlMinutes = 60
$Headers = @{'User-Agent'=('Craft-Updater-v' + $UpdaterVersion);'Accept'='application/vnd.github+json'}

# Local data (size-limited).
$KeepRunReports = 10
$KeepMsiLogs = 5
$MaxCacheAgeDays = 7
$MaxHistoryArchives = 1
$MaxHistoryBytes = 2MB
$MutexName = 'Local\CraftAutoUpdater-Portable'

# Package files.
$LauncherName = 'Craft-Updater-STARTEN.cmd'
$ScriptFileName = 'Craft-Auto-Updater-v' + $UpdaterVersion + '-Portable.ps1'
# Pictures live in the subfolder "assets" (keeps the main folder tidy). Without them the
# updater still works, just without the sloth.
$AssetsDirectory = Join-Path $ScriptDirectory 'assets'
# Sloth icon for the window and taskbar.
$IconFileName = 'Craft-Updater.ico'
$IconPath = Join-Path $AssetsDirectory $IconFileName
# Sloth without background tile for the window header (blends into the plum colour).
$HeaderImageName = 'Craft-Updater-Header.png'
$HeaderImagePath = Join-Path $AssetsDirectory $HeaderImageName
# Header colour (plum).
$BrandColor = @(142, 59, 107)
# Just for fun: small splash screen for a few seconds (0 = off).
$SplashSeconds = 4
# Earlier versions copied themselves to Program Files. That is no longer done (Bitdefender
# rated it as suspicious behaviour); only a hint is shown if the old copy still exists.
$OldInstallDir = Join-Path $env:ProgramFiles 'Craft Updater'

# Paths. The data folder is intentionally independent of the version.
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw (L 'LOCALAPPDATA fehlt.' 'LOCALAPPDATA is missing.') }
# Full, canonical path (short 8.3 names such as RUNNER~1 written out), so that the strict
# path check before installing compares like with like.
$Root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CraftUpdater'))
$LegacyRoots = @(Join-Path $env:LOCALAPPDATA 'CraftUpdater-v5.6.2')
$Verified = Join-Path $Root 'Verified'
$Reports = Join-Path $Root 'Reports'
$InstallerLogDir = Join-Path $Reports 'MSI-Logs'
$RecoveryDir = Join-Path $Reports 'Recovery'
$CacheRoot = Join-Path $Root 'ReleaseCache'
$CooldownPath = Join-Path $CacheRoot 'RateLimit.json'
$HistoryPath = Join-Path $Reports 'History.jsonl'
# Local error folder next to the package files.
$ErrorFolder = Join-Path $ScriptDirectory (L 'Fehlermeldung' 'Error reports')
$ErrorReportPrefix = L 'Fehler-' 'Error-'
$MsiExecPath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
$RegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Marker for security errors (see security rule above).
$SecurityPrefix = L 'SICHERHEIT: ' 'SECURITY: '

# ============================================================================
# 2. RUNTIME STATE
# ============================================================================
# One hashtable that all functions read and change together.
# Status values (e.g. 'Aktuell', 'Nicht installiert') are internal keys and stay the same
# in every language; Get-FriendlyStatus turns them into readable text.
$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
$State = @{
    Results            = New-Object 'System.Collections.Generic.List[object]'
    Warnings           = New-Object 'System.Collections.Generic.List[string]'  # collected warnings for the error report
    Pending            = New-Object 'System.Collections.Generic.List[object]'  # verified downloads
    Eligible           = New-Object 'System.Collections.Generic.List[object]'  # ready to install
    Notes              = @{}                                                    # "what's new" per program (release notes)
    RateLimited        = $false
    RateLimitUntil     = [datetimeoffset]::MinValue
    SecurityBlocked    = $false
    StopInstallBatch   = $false
    PreserveInstallers = $false   # unclear MSI state: do not delete any installers
    RebootRequired     = $false
    InstallerFailures  = 0
    ErrorFolderReady   = $false
    ExitCode           = 0
}
# Also collect every warning so it ends up in the error report (nothing to copy from the console).
function Write-Warning {
    param([Parameter(Position=0, ValueFromPipeline=$true)][AllowEmptyString()][string]$Message)
    try { $State.Warnings.Add([string]$Message) } catch {}
    Microsoft.PowerShell.Utility\Write-Warning $Message
}

# ============================================================================
# 3. GENERAL HELPERS
# ============================================================================
function Parse-Version([string]$value) {
    if ($null -eq $value) { return $null }
    $s = $value.Trim() -replace '^[vV]', ''
    if ($s -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $parts = @($s.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}
function Norm-Publisher([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    # Conservative: ignore only letter case, spaces and punctuation.
    return (($s.ToLowerInvariant() -replace '[^a-z0-9]', ''))
}
function Norm-Thumbprint([string]$thumbprint) {
    # Exactly 40 hexadecimal characters must remain.
    if ([string]::IsNullOrWhiteSpace($thumbprint)) { return '' }
    $normalized = ($thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{40}$') { throw (L 'Zertifikat-Thumbprint hat kein gueltiges SHA1-Fingerabdruckformat' 'Certificate thumbprint is not a valid SHA1 fingerprint') }
    return $normalized
}
function Test-AllowedRegistryPublisher([string]$publisher) {
    $actual = Norm-Publisher $publisher
    foreach ($allowed in $AllowedRegistryPublishers) {
        if ($actual -eq (Norm-Publisher $allowed)) { return $true }
    }
    return $false
}
function Test-IsAdmin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-IsReparsePoint($item) {
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Get-SecurityMessage($errorRecord) {
    # Mark an error message as a security error (only once).
    $message=[string]$errorRecord.Exception.Message
    if ($message.StartsWith($SecurityPrefix)) { return $message }
    return ($SecurityPrefix + $message)
}
function Test-IsSecurityMessage([string]$message) {
    return $message.StartsWith($SecurityPrefix)
}
# --- Link to the window (without a window these do nothing or ask in the console) ---
function Set-GuiStatus([string]$text,[int]$value=-1,[int]$maximum=-1) {
    if ($null -eq $GuiSync) { return }
    $GuiSync.StatusText = $text
    if ($maximum -ge 0) { $GuiSync.ProgressMax = $maximum }
    if ($value -ge 0) { $GuiSync.ProgressValue = $value }
}
function Set-GuiPhase([string]$phase) {
    # Window: Suche / Warten / Installieren / Fertig (search / wait / install / done; controls the progress bar).
    if ($null -ne $GuiSync) { $GuiSync.Phase = $phase }
}
function Request-Confirmation([string]$kind,[string]$title,[string]$message,[string]$consolePrompt) {
    # The only place where an approval is requested.
    # Console: only the exact word JA (German) or YES (English) counts.
    # Window: only an explicit Yes in the confirmation dialog.
    if ($null -eq $GuiSync) {
        $answer = Read-Host $consolePrompt
        return ($answer -ceq (L 'JA' 'YES'))
    }
    $GuiSync.Answer = $null
    $GuiSync.Question = [pscustomobject]@{ Kind=$kind; Title=$title; Message=$message; Id=[guid]::NewGuid().ToString('N') }
    try {
        while ($null -eq $GuiSync.Answer) {
            if ($GuiSync.WindowClosed) { return $false }
            Start-Sleep -Milliseconds 150
        }
        return ($GuiSync.Answer -is [bool] -and $GuiSync.Answer)
    } finally {
        $GuiSync.Question = $null
    }
}
function Add-Result([string]$name,[string]$installed,[string]$available,
                    [string]$status,[string]$detail,[string]$file='',
                    [string]$hash='', [string]$signer='') {
    $obj = [pscustomobject]@{
        Time=(Get-Date).ToString('o'); RunId=$RunId; Program=$name;
        Installed=$installed; Latest=$available; Status=$status;
        Detail=$detail; File=$file; SHA256=$hash; Signer=$signer
    }
    $State.Results.Add($obj)
    # Window: last row per program (same logic as the final result).
    if ($null -ne $GuiSync) { $GuiSync.Rows[$name] = [pscustomobject]@{ Installed=$installed; Latest=$available; Status=$status; Detail=$detail } }
    try {
        if ((Test-Path -LiteralPath $HistoryPath) -and (Get-Item -LiteralPath $HistoryPath).Length -gt $MaxHistoryBytes) {
            $archive = Join-Path $Reports ('History-Archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
            Move-Item -LiteralPath $HistoryPath -Destination $archive -ErrorAction Stop
        }
        Add-Content -LiteralPath $HistoryPath -Value (ConvertTo-Json -InputObject $obj -Compress -Depth 5) -Encoding UTF8
    } catch { Write-Warning ((L 'Historie konnte nicht geschrieben werden: ' 'Could not write history: ') + $_.Exception.Message) }
    if ($Ausfuehrlich -or $status -notin @('Verifiziert','Installationsbereit')) {
        $color = if ($status -match 'Fehler|Konflikt') { 'Red' } elseif ($status -match 'Installiert|Aktuell') { 'Green' } else { 'Yellow' }
        Write-Host ('{0}: {1} - {2}' -f $name,(Get-FriendlyStatus $status),$detail) -ForegroundColor $color
    } elseif ($status -eq 'Installationsbereit') {
        Write-Host ('{0}: {1}' -f $name,(Get-FriendlyStatus $status)) -ForegroundColor Green
    }
}
function Save-CraftReport([string]$path,[string]$content) {
    $temp=$path+'.tmp-'+[guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp,$content,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $path -ErrorAction Stop
        return $true
    } catch {
        Write-Warning ((L 'Bericht konnte nicht gespeichert werden: ' 'Could not save report: ') + $path + ' - ' + $_.Exception.Message)
        Write-Host ((L 'NOTBERICHT ' 'EMERGENCY REPORT ') + $path) -ForegroundColor Red
        Write-Host $content
        return $false
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
function Remove-OldFiles([string]$directory,[string]$filter,[int]$keep,[int]$days=0) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    try {
        $files = @(Get-ChildItem -LiteralPath $directory -Filter $filter -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending)
        $threshold = [datetime]::UtcNow.AddDays(-$days)
        for ($i=0; $i -lt $files.Count; $i++) {
            $f=$files[$i]
            if ($i -lt $keep) { continue }
            if ($days -gt 0 -and $f.LastWriteTimeUtc -gt $threshold) { continue }
            # No recursive removal, never follow link targets.
            if (Test-IsReparsePoint $f) { continue }
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
    } catch { Write-Warning ((L 'Dateibereinigung: ' 'File cleanup: ') + $_.Exception.Message) }
}
function Assert-FreeDiskSpace([string]$file,[long]$reserveBytes) {
    $driveRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($file))
    $disk=New-Object IO.DriveInfo($driveRoot)
    if (-not $disk.IsReady -or $disk.AvailableFreeSpace -lt $reserveBytes) {
        throw ((L 'Zu wenig freier Speicher fuer sichere MSI-Verarbeitung. Mindestens {0} MiB Reserve erforderlich.' 'Not enough free disk space for safe MSI processing. At least {0} MiB reserve required.') -f [math]::Round($reserveBytes/1MB))
    }
}
function Initialize-DataFolder {
    # One-time takeover of the old, version-bound data folder.
    if (-not (Test-Path -LiteralPath $Root)) {
        foreach ($legacy in $LegacyRoots) {
            if (-not (Test-Path -LiteralPath $legacy -PathType Container)) { continue }
            try {
                $legacyItem=Get-Item -LiteralPath $legacy -Force -ErrorAction Stop
                if (Test-IsReparsePoint $legacyItem) { Write-Warning ((L 'Alter Datenordner ist ein Link und wird nicht uebernommen: ' 'Old data folder is a link and is not taken over: ') + $legacy); continue }
                Move-Item -LiteralPath $legacy -Destination $Root -ErrorAction Stop
                Write-Host ((L 'Datenordner uebernommen: ' 'Data folder taken over: ') + $legacy + ' -> ' + $Root) -ForegroundColor DarkGray
                break
            } catch { Write-Warning ((L 'Alter Datenordner konnte nicht uebernommen werden: ' 'Could not take over old data folder: ') + $_.Exception.Message) }
        }
    }
    foreach ($dir in @($Root,$Verified,$Reports,$InstallerLogDir,$RecoveryDir,$CacheRoot)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
}
function Initialize-ErrorFolder {
    # The error folder only exists while there are reports: it is created when a report is
    # written. On start, the updater's own reports older than three days are deleted, and the
    # folder is removed again once it is completely empty.
    try {
        if (-not (Test-Path -LiteralPath $ErrorFolder)) { return $true }
        $folderItem = Get-Item -LiteralPath $ErrorFolder -Force -ErrorAction Stop
        if (-not $folderItem.PSIsContainer -or (Test-IsReparsePoint $folderItem)) {
            throw (L 'Fehlerordner ist kein normaler Ordner' 'Error folder is not a normal folder')
        }
        $cutoff=(Get-Date).AddDays(-3)
        foreach ($old in @(Get-ChildItem -LiteralPath $ErrorFolder -Filter ($ErrorReportPrefix + '*.txt') -File -Force -ErrorAction Stop)) {
            if (-not (Test-IsReparsePoint $old) -and $old.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
            }
        }
        if (@(Get-ChildItem -LiteralPath $ErrorFolder -Force -ErrorAction Stop).Count -eq 0) {
            # Only an empty folder is removed (no -Recurse), so nothing else can ever be deleted.
            Remove-Item -LiteralPath $ErrorFolder -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Warning ((L 'Fehlerordner nicht verfuegbar: ' 'Error folder not available: ') + $_.Exception.Message)
        return $false
    }
}

# ============================================================================
# 4. GITHUB
# ============================================================================
function Get-HttpStatus($ex) {
    try { if ($ex.Response) { return [int]$ex.Response.StatusCode } } catch {}
    return 0
}
function Get-HttpHeader($ex,[string]$key) {
    try { return [string]$ex.Response.Headers[$key] } catch { return '' }
}
function Test-GitHubLimit($ex) {
    $status=Get-HttpStatus $ex
    if ($status -eq 429) { return $true }
    if ($status -ne 403) { return $false }
    if ((Get-HttpHeader $ex 'X-RateLimit-Remaining') -eq '0') { return $true }
    if (Get-HttpHeader $ex 'Retry-After') { return $true }
    # 403 without proof of a rate limit counts as an access error.
    return $false
}
function Read-RateLimitCooldown {
    if (-not (Test-Path -LiteralPath $CooldownPath -PathType Leaf)) { return }
    try {
        $cool = Get-Content -LiteralPath $CooldownPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $State.RateLimitUntil = [datetimeoffset]::Parse([string]$cool.Until)
    } catch { Write-Warning ((L 'Rate-Limit-Merker unlesbar: ' 'Rate limit marker unreadable: ') + $_.Exception.Message) }
    if ($State.RateLimitUntil -gt [datetimeoffset]::Now) {
        Write-Host ((L 'GitHub-API-Sperre bis {0} (lokaler Merker)' 'GitHub API blocked until {0} (local marker)') -f $State.RateLimitUntil.ToString('dd.MM.yyyy HH:mm:ss zzz')) -ForegroundColor Yellow
    }
}
function Set-RateLimitCooldown($ex) {
    $status = Get-HttpStatus $ex
    if (-not (Test-GitHubLimit $ex)) { return }
    $until = [datetimeoffset]::Now.AddMinutes(2)
    $remaining = Get-HttpHeader $ex 'X-RateLimit-Remaining'
    $reset = Get-HttpHeader $ex 'X-RateLimit-Reset'
    $retryAfter = Get-HttpHeader $ex 'Retry-After'
    if ($remaining -eq '0' -and $reset -match '^\d+$') {
        try { $until = [datetimeoffset]::FromUnixTimeSeconds([long]$reset).ToLocalTime().AddSeconds(3) } catch {}
    } elseif ($retryAfter -match '^\d+$') {
        $until = [datetimeoffset]::Now.AddSeconds([math]::Min(3600,[double]$retryAfter) + 3)
    } elseif ($retryAfter) {
        $parsed=[datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($retryAfter,[ref]$parsed)) { $until=$parsed.ToLocalTime().AddSeconds(3) }
    }
    if ($until -lt [datetimeoffset]::Now) { $until = [datetimeoffset]::Now.AddMinutes(2) }
    $State.RateLimitUntil = $until
    $State.RateLimited = $true
    Write-Warning ((L 'GitHub API-Limit (HTTP {0}); erneute Abfrage ab {1}' 'GitHub API limit (HTTP {0}); next request from {1}') -f $status,$until.ToString('dd.MM.yyyy HH:mm:ss zzz'))
    try {
        $tmp = $CooldownPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject @{Until=$until.ToString('o')} -Compress), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $CooldownPath -Force -ErrorAction Stop
    } catch { Write-Warning ((L 'Rate-Limit-Merker konnte nicht gespeichert werden: ' 'Could not save rate limit marker: ') + $_.Exception.Message) }
}
function Get-RetryDelay($ex,[int]$attempt) {
    $retryAfter = Get-HttpHeader $ex 'Retry-After'
    $seconds=0
    if ($retryAfter -match '^\d+$') {
        $seconds=[int][math]::Min([double]$retryAfter,120)
    } elseif ($retryAfter) {
        $date=[datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($retryAfter,[ref]$date)) {
            $seconds=[int][math]::Max(0,[math]::Min(120,($date - [datetimeoffset]::UtcNow).TotalSeconds))
        }
    }
    $exp=[math]::Min(60,[math]::Pow(2,$attempt))
    $jitter=Get-Random -Minimum 0 -Maximum 1500
    return [int][math]::Min(120,[math]::Max($seconds,$exp + $jitter / 1000.0))
}
function Invoke-Retry([string]$uri,[string]$outFile='') {
    for ($n=1; $n -le $MaxTries; $n++) {
        try {
            if ($outFile) {
                # Never reuse a partially downloaded file on retry.
                if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
                Invoke-WebRequest -Uri $uri -Headers $Headers -OutFile $outFile -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop | Out-Null
                return $null
            }
            return Invoke-RestMethod -Uri $uri -Headers $Headers -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        } catch {
            $ex=$_.Exception
            $status=Get-HttpStatus $ex
            if (Test-GitHubLimit $ex) {
                Set-RateLimitCooldown $ex
                throw ('GitHub rate limit: ' + $ex.Message)
            }
            if ($status -eq 403) { throw }
            $retry=($status -in @(0,408,425,500,502,503,504))
            if (-not $retry -or $n -eq $MaxTries) { throw }
            $seconds=Get-RetryDelay $ex $n
            Write-Warning ((L 'Anfrage fehlgeschlagen (HTTP {0}); neuer Versuch {1}/{2} in {3} Sekunden' 'Request failed (HTTP {0}); retry {1}/{2} in {3} seconds') -f $status,($n+1),$MaxTries,$seconds)
            Start-Sleep -Seconds $seconds
        }
    }
}
function Get-ReleaseCached([string]$repo) {
    if ($repo -notmatch '^[a-z0-9-]+$') { throw (L 'Ungueltiger Repository-Name' 'Invalid repository name') }
    $cacheFile = Join-Path $CacheRoot ($repo + '.json')
    if (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
        try {
            $cache = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved = [datetimeoffset]::Parse([string]$cache.SavedAt)
            $age = ([datetimeoffset]::Now - $saved).TotalMinutes
            if ($age -ge 0 -and $age -le $CacheTtlMinutes -and $cache.Release -and $cache.Release.tag_name) {
                Write-Host ((L '{0}: GitHub-Release aus lokalem Cache ({1} Min.)' '{0}: GitHub release from local cache ({1} min)') -f $repo,[math]::Round($age,1)) -ForegroundColor DarkGray
                return $cache.Release
            }
        } catch { Write-Warning (((L '{0}: Cache unlesbar, verworfen: ' '{0}: cache unreadable, discarded: ') -f $repo) + $_.Exception.Message) }
    }
    if ($State.RateLimited -or $State.RateLimitUntil -gt [datetimeoffset]::Now) {
        throw ((L 'GitHub-Rate-Limit aktiv bis {0}; kein gueltiger Cache fuer {1}' 'GitHub rate limit active until {0}; no valid cache for {1}') -f $State.RateLimitUntil.ToString('dd.MM.yyyy HH:mm:ss zzz'),$repo)
    }
    $api = 'https://api.github.com/repos/' + $Owner + '/' + $repo + '/releases/latest'
    $release = Invoke-Retry $api
    if ($null -eq $release -or -not $release.tag_name) { throw (L 'GitHub-Release ohne Tag' 'GitHub release without tag') }
    try {
        $tmp = $cacheFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $data = @{SavedAt=[datetimeoffset]::Now.ToString('o');Release=$release}
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $data -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $cacheFile -Force -ErrorAction Stop
    } catch { Write-Warning (((L '{0}: Release-Cache konnte nicht gespeichert werden: ' '{0}: could not save release cache: ') -f $repo) + $_.Exception.Message) }
    return $release
}

# ============================================================================
# 5. WINDOWS INSTALLER (MSI)
# ============================================================================
# Note PS 5.1: COM calls can write objects to the output. Suppress return values
# with [void] and return collections with ',' as ONE object.
function Release-ComObject($obj) {
    if ($null -ne $obj) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) } catch {} }
}
function Invoke-MsiQuery($database,[string]$sql,[int]$columns) {
    # Returns a list of string[] rows.
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $view=$null; $record=$null
    try {
        $view=$database.OpenView($sql)
        [void]$view.Execute()
        while ($null -ne ($record=$view.Fetch())) {
            $values=New-Object 'string[]' $columns
            for ($i=1; $i -le $columns; $i++) { $values[$i-1]=[string]$record.StringData($i) }
            [void]$rows.Add($values)
            Release-ComObject $record
            $record=$null
        }
        return ,$rows
    } finally {
        Release-ComObject $record
        if ($null -ne $view) { try { [void]$view.Close() } catch {}; Release-ComObject $view }
    }
}
function Read-MsiPackage([string]$path) {
    # Opens the MSI exactly once and reads everything the checks need.
    $installer=$null; $db=$null; $summary=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $db=$installer.OpenDatabase($path,0)
        $properties=@{}
        foreach ($row in (Invoke-MsiQuery $db 'SELECT `Property`, `Value` FROM `Property`' 2)) {
            if (-not [string]::IsNullOrWhiteSpace($row[0])) { $properties[$row[0]]=$row[1] }
        }
        $summary=$db.SummaryInformation(0)
        $properties['Template']=[string]$summary.Property(7)
        # Upgrade table: if it is missing this is not a package error, it only prevents the upgrade.
        $upgradeRows=$null; $upgradeError=''
        try {
            $upgradeRows=New-Object 'System.Collections.Generic.List[object]'
            foreach ($row in (Invoke-MsiQuery $db 'SELECT `UpgradeCode`,`VersionMin`,`VersionMax`,`Language`,`Attributes`,`Remove`,`ActionProperty` FROM `Upgrade`' 7)) {
                [void]$upgradeRows.Add([pscustomobject]@{UpgradeCode=$row[0];Min=$row[1];Max=$row[2];Language=$row[3];Attributes=[int]$row[4];Remove=$row[5];ActionProperty=$row[6]})
            }
        } catch { $upgradeRows=$null; $upgradeError=$_.Exception.Message }
        $hasRemoveExisting=$false
        try {
            $hasRemoveExisting=((Invoke-MsiQuery $db 'SELECT `Action` FROM `InstallExecuteSequence` WHERE `Action`=''RemoveExistingProducts''' 1).Count -gt 0)
        } catch { $hasRemoveExisting=$false }
        return [pscustomobject]@{ Properties=$properties; UpgradeRows=$upgradeRows; UpgradeError=$upgradeError; HasRemoveExistingProducts=$hasRemoveExisting }
    } finally {
        Release-ComObject $summary
        Release-ComObject $db
        Release-ComObject $installer
    }
}
function Get-MsiProductState([string]$productCode) {
    $installer=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        return [int]$installer.ProductState($productCode)
    } finally { Release-ComObject $installer }
}
function Get-MsiProductInfo([string]$productCode,[string]$property) {
    $installer=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        return [string]$installer.ProductInfo($productCode,$property)
    } finally { Release-ComObject $installer }
}
function Test-MsiUpgradeRelation([string]$upgradeCode,[string]$installedCode) {
    $installer=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $related=@($installer.RelatedProducts($upgradeCode))
        return (@($related | Where-Object { ([string]$_).Trim('{}').ToUpperInvariant() -eq $installedCode.Trim('{}').ToUpperInvariant() }).Count -gt 0)
    } finally { Release-ComObject $installer }
}
function Get-FriendlyMsiError([int]$code) {
    switch ($code) {
        1603 { return (L 'Allgemeiner MSI-Installationsfehler; MSI-Log kontrollieren, keine automatische Reparatur.' 'General MSI installation error; check the MSI log, no automatic repair.') }
        1618 { return (L 'Andere Windows-Installer-Installation laeuft; keine weiteren Installationen starten.' 'Another Windows Installer installation is running; no further installations started.') }
        1619 { return (L 'MSI-Paket konnte nicht geoeffnet werden; Paket und Pfad kontrollieren.' 'MSI package could not be opened; check package and path.') }
        1620 { return (L 'MSI-Paket ist ungueltig; Installationslauf untersuchen.' 'MSI package is invalid; investigate the installation run.') }
        1638 { return (L 'Andere Version/Installation steht im Konflikt; MSI-Log kontrollieren.' 'Another version/installation conflicts; check the MSI log.') }
        1641 { return (L 'Installer hat Neustart ausgeloest; Zustand vor weiteren Updates pruefen.' 'Installer triggered a restart; check the state before further updates.') }
        3010 { return (L 'Installation meldet Neustart erforderlich.' 'Installation reports that a restart is required.') }
        default { return ((L 'MSI-Code {0}; MSI-Log fuer Einzelheiten kontrollieren.' 'MSI code {0}; check the MSI log for details.') -f $code) }
    }
}

# ============================================================================
# 6. SECURITY CHECKS
# ============================================================================
function Assert-SafeMsiPath([string]$path) {
    $full=[IO.Path]::GetFullPath($path)
    if ($full -ne $path) { throw (L 'MSI-Dateipfad nicht kanonisch' 'MSI file path is not canonical') }
    if (-not $full.EndsWith('.msi',[StringComparison]::OrdinalIgnoreCase)) { throw (L 'Nicht-MSI-Datei' 'Not an MSI file') }
    if ($full -match '["`\r\n]') { throw (L 'Unsichere Zeichen im MSI-Pfad' 'Unsafe characters in MSI path') }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw (L 'MSI-Datei fehlt' 'MSI file is missing') }
    $rootFull=[IO.Path]::GetFullPath($Verified).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) { throw (L 'MSI liegt nicht im Verified-Verzeichnis' 'MSI is not inside the Verified folder') }
    # Neither the installer nor any folder on its path may be a reparse point.
    $cursor = $full
    while ($cursor.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $cursor.TrimEnd('\') -eq $rootFull.TrimEnd('\')) {
        $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (Test-IsReparsePoint $entry) { throw (L 'MSI-Pfad enthaelt Reparse Point / Symlink' 'MSI path contains a reparse point / symlink') }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Assert-TrustedMsi([string]$path,[string]$expectedHash,$program,$registryApp,[version]$expectedVersion) {
    # Every deviation here is a SECURITY ERROR and blocks the whole run.
    try {
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expectedHash) { throw (L 'SHA256-Pruefung fehlgeschlagen' 'SHA256 check failed') }
        $sig = Get-AuthenticodeSignature -LiteralPath $path
        if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) { throw ((L 'Signatur nicht gueltig: ' 'Signature not valid: ') + $sig.Status) }
        $cert = $sig.SignerCertificate
        $actualPin = Norm-Thumbprint ([string]$cert.Thumbprint)
        $allEkus = @(foreach ($extension in $cert.Extensions) {
            if ($extension -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
                foreach ($oid in $extension.EnhancedKeyUsages) { [string]$oid.Value }
            }
        })
        $profileEkus = @($allEkus | Where-Object { $_ -match '^1\.3\.6\.1\.4\.1\.311\.97\.' })
        if ($profileEkus -notcontains $ExpectedProfileEku) {
            throw ((L 'Zertifikatsprofil nicht freigegeben. Ist: {0}; Soll: {1}' 'Certificate profile not approved. Found: {0}; expected: {1}') -f ($profileEkus -join ', '),$ExpectedProfileEku)
        }
        if ($allEkus -notcontains $CodeSigningEku) { throw (L 'CodeSigning-EKU fehlt' 'Code signing EKU is missing') }
        $issuer = [string]$cert.Issuer
        if ($issuer -notmatch ('(?:^|,\s*)O\s*=\s*' + [regex]::Escape($ExpectedIssuerOrganization) + '(?:,|$)')) {
            throw ((L 'Unerwartete Zertifikatsaussteller-Organisation: ' 'Unexpected certificate issuer organisation: ') + $issuer)
        }
        $ekuText = if ($profileEkus.Count -gt 0) { $profileEkus -join ', ' } else { (L 'NICHT GEFUNDEN' 'NOT FOUND') }
        if ($Ausfuehrlich) { Write-Host ((L 'PROFIL-PRUEFUNG {0}: Thumbprint={1}; Profil-EKU={2}; Signatur={3}' 'PROFILE CHECK {0}: thumbprint={1}; profile EKU={2}; signature={3}') -f $program.Name,$actualPin,$ekuText,$sig.Status) -ForegroundColor Cyan }
        $subject = [string]$cert.Subject
        $orgMatch = [regex]::Match($subject, '(?:^|,\s*)O\s*=\s*([^,]+)')
        if (-not $orgMatch.Success) { throw (L 'Zertifikat enthaelt keine auswertbare Organisation' 'Certificate contains no readable organisation') }
        $org = $orgMatch.Groups[1].Value.Trim()
        $package = Read-MsiPackage $path
        $metadata = $package.Properties
        foreach ($field in @('ProductName','ProductVersion','Manufacturer','Template','ProductCode','UpgradeCode')) {
            if ([string]::IsNullOrWhiteSpace([string]$metadata[$field])) { throw ((L 'MSI-Eigenschaft fehlt: {0}; Datei: {1}; Gefunden: {2}' 'MSI property missing: {0}; file: {1}; found: {2}') -f $field,$path,((@($metadata.Keys) | Sort-Object) -join ', ')) }
        }
        if ([string]$metadata['ProductName'] -notmatch $program.Pattern) { throw (L 'MSI-Produktname passt nicht zum Programm' 'MSI product name does not match the program') }
        $msiVersion = Parse-Version ([string]$metadata['ProductVersion'])
        if ($null -eq $msiVersion -or $msiVersion -ne $expectedVersion) { throw (L 'MSI-Produktversion weicht vom Release-Tag ab' 'MSI product version differs from the release tag') }
        if ((Norm-Publisher $org) -ne (Norm-Publisher $ExpectedPublisher)) { throw (L 'Zertifikat-Herausgeber entspricht nicht dem erwarteten Publisher' 'Certificate publisher does not match the expected publisher') }
        if (-not (Test-AllowedRegistryPublisher ([string]$registryApp.Publisher))) { throw ((L 'Registry-Publisher ist nicht erlaubt: ' 'Registry publisher is not allowed: ') + [string]$registryApp.Publisher) }
        # The signer is Inc, the MSI manufacturer may still be LLC. Any other value is rejected.
        if (-not (Test-AllowedRegistryPublisher ([string]$metadata['Manufacturer']))) {
            throw ((L 'MSI-Hersteller nicht freigegeben: ' 'MSI manufacturer not approved: ') + [string]$metadata['Manufacturer'])
        }
        $templateArch = (([string]$metadata['Template']).Split(';')[0]).Trim().ToLowerInvariant()
        $valid = switch ($Platform) {
            'x64' { $templateArch -in @('x64','intel64') }
            'x86' { $templateArch -eq 'intel' }
            'arm64' { $templateArch -in @('arm64','aarch64') }
            default { $false }
        }
        if (-not $valid) { throw ((L 'MSI-Architektur nicht kompatibel oder nicht eindeutig: ' 'MSI architecture not compatible or ambiguous: ') + $metadata['Template']) }
        foreach ($code in @('ProductCode','UpgradeCode')) {
            $guidOut = [guid]::Empty
            if (-not [guid]::TryParse([string]$metadata[$code],[ref]$guidOut)) { throw ((L 'Ungueltiger MSI-Code: ' 'Invalid MSI code: ') + $code) }
        }
        return [pscustomobject]@{ Hash=$actual; Signer=$org; Thumbprint=$actualPin; ProfileEkus=$profileEkus; MsiVersion=$metadata['ProductVersion']; Metadata=$metadata; Package=$package }
    } catch {
        throw (Get-SecurityMessage $_)
    }
}
function Resolve-RegistryApp([object[]]$entries,[string]$programName) {
    # Include SystemComponent=1 too: Windows Installer can hide the real MSI entry.
    # Merge duplicate entries only if they clearly belong to the same MSI product.
    $rows=@($entries)
    if ($rows.Count -eq 0) { return $null }
    if ($rows.Count -eq 1) { return $rows[0] }
    $msi=@($rows | Where-Object {
        $id=[guid]::Empty
        $_.WindowsInstaller -eq 1 -and [guid]::TryParse([string]$_.PSChildName,[ref]$id)
    })
    if ($msi.Count -ne 1) { throw ((L 'Mehrdeutige Registry-Eintraege fuer {0}: {1} Eintraege, {2} MSI-Produkte' 'Ambiguous registry entries for {0}: {1} entries, {2} MSI products') -f $programName,$rows.Count,$msi.Count) }
    $chosen=$msi[0]
    $productCode=([guid]([string]$chosen.PSChildName)).ToString('B').ToUpperInvariant()
    $version=Parse-Version ([string]$chosen.DisplayVersion)
    if ($null -eq $version -or -not (Test-AllowedRegistryPublisher ([string]$chosen.Publisher))) {
        throw ((L 'MSI-Eintrag fuer {0} ohne gueltige Version oder erwarteten Hersteller' 'MSI entry for {0} without a valid version or the expected manufacturer') -f $programName)
    }
    if ((Get-MsiProductState $productCode) -ne 5) {
        throw ((L 'MSI-Eintrag fuer {0} nicht als installiert bestaetigt' 'MSI entry for {0} not confirmed as installed') -f $programName)
    }
    foreach ($other in $rows) {
        if ($other.PSPath -eq $chosen.PSPath) { continue }
        if ($other.WindowsInstaller -eq 1) { throw ((L 'Zweites MSI-Produkt fuer {0}' 'Second MSI product for {0}') -f $programName) }
        if (-not (Test-AllowedRegistryPublisher ([string]$other.Publisher))) { throw ((L 'Abweichender Hersteller im zweiten Eintrag fuer {0}' 'Different manufacturer in the second entry for {0}') -f $programName) }
        $otherVersion=Parse-Version ([string]$other.DisplayVersion)
        if ($null -eq $otherVersion -or $otherVersion -ne $version) { throw ((L 'Widerspruechliche Versionen fuer {0}' 'Conflicting versions for {0}') -f $programName) }
        $uninstall=[string]$other.UninstallString
        if ($uninstall -notmatch '(?i)msiexec(\.exe)?[" ]') { throw ((L 'Zweiter Eintrag ohne MSI-Deinstallationsbefehl fuer {0}' 'Second entry without an MSI uninstall command for {0}') -f $programName) }
        $codes=@([regex]::Matches($uninstall,'\{[0-9a-fA-F-]{36}\}') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
        if ($codes.Count -ne 1 -or $codes[0] -ne $productCode) { throw ((L 'Abweichender MSI-ProductCode im zweiten Eintrag fuer {0}' 'Different MSI ProductCode in the second entry for {0}') -f $programName) }
    }
    if ($Ausfuehrlich) { Write-Host ((L '{0}: {1} Registry-Eintraege eindeutig demselben MSI-Produkt zugeordnet' '{0}: {1} registry entries clearly belong to the same MSI product') -f $programName,$rows.Count) -ForegroundColor DarkGray }
    return $chosen
}
function Find-RegistryEntries($source,[string]$pattern) {
    # ',' stops PowerShell from unrolling an array with 0 or 1 element.
    return ,@($source | Where-Object { $_.DisplayName -and ([string]$_.DisplayName -match $pattern) })
}
function Get-RegistryApp([string]$pattern,[string]$programName) {
    # Read fresh from the registry (not from the snapshot taken at start).
    $entries=Find-RegistryEntries @(Get-ItemProperty -Path $RegPaths -ErrorAction SilentlyContinue) $pattern
    return Resolve-RegistryApp $entries $programName
}
function Test-CraftProcessRunning($item,$app) {
    $namePattern = $item.Program.Pattern
    $installFolder = [string]$app.InstallLocation
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $matched = $_.ProcessName -match $namePattern
        if (-not $matched -and -not [string]::IsNullOrWhiteSpace($installFolder)) {
            try {
                $exe = [string]$_.Path
                if ($exe -and $exe.StartsWith(($installFolder.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { $matched = $true }
            } catch {}
        }
        $matched
    })
    return ($running.Count -gt 0)
}
function Test-MsiUpgradeTable($package,[string]$upgradeCode,[version]$oldVersion,[string]$installedCode) {
    # Language of the INSTALLED product, not of the new package.
    $installedLanguage=Get-MsiProductInfo $installedCode 'Language'
    if ($installedLanguage -notmatch '^[0-9]+$') { throw ((L 'Installierte MSI-Sprache nicht lesbar: ' 'Installed MSI language not readable: ') + $installedLanguage) }
    if ($null -eq $package.UpgradeRows) { throw ((L 'MSI-Upgrade-Tabelle nicht lesbar oder fehlt: ' 'MSI upgrade table not readable or missing: ') + $package.UpgradeError) }
    $matched=@()
    foreach ($row in $package.UpgradeRows) {
        if ($row.UpgradeCode.Trim('{}').ToUpperInvariant() -ne $upgradeCode.Trim('{}').ToUpperInvariant()) { continue }
        $flags=[int]$row.Attributes
        if (($flags -band 2) -ne 0) { continue } # msidbUpgradeAttributesOnlyDetect
        # The language list is comma-separated. Flag 1024 inverts the selection.
        $languageText=[string]$row.Language
        if (-not [string]::IsNullOrWhiteSpace($languageText)) {
            $languages=@($languageText -split ',' | ForEach-Object { $_.Trim() })
            if (@($languages | Where-Object { $_ -notmatch '^[0-9]+$' }).Count -ne 0) {
                throw ((L 'Ungueltiger MSI-Sprachfilter: ' 'Invalid MSI language filter: ') + $languageText)
            }
            $inList=($languages -contains $installedLanguage)
            $exclusive=(($flags -band 1024) -ne 0)
            if (($exclusive -and $inList) -or ((-not $exclusive) -and (-not $inList))) { continue }
        }
        if ([string]::IsNullOrWhiteSpace($row.ActionProperty)) { continue }
        $within=$true
        if ($row.Min) {
            $v=Parse-Version $row.Min
            if ($null -eq $v -or $oldVersion -lt $v -or ($oldVersion -eq $v -and ($flags -band 256) -eq 0)) { $within=$false }
        }
        if ($row.Max) {
            $v=Parse-Version $row.Max
            if ($null -eq $v -or $oldVersion -gt $v -or ($oldVersion -eq $v -and ($flags -band 512) -eq 0)) { $within=$false }
        }
        if ($within) { $matched += $row }
    }
    if ($matched.Count -ne 1) { throw ((L 'Keine eindeutige passende Upgrade-Tabellenzeile (Anzahl: {0})' 'No single matching upgrade table row (count: {0})') -f $matched.Count) }
    # An upgrade entry alone does not guarantee a major upgrade sequence.
    if (-not $package.HasRemoveExistingProducts) { throw (L 'RemoveExistingProducts fehlt in InstallExecuteSequence' 'RemoveExistingProducts is missing in InstallExecuteSequence') }
}
function Test-InstallationCandidate($item) {
    # Package and path checks: deviations are security errors.
    # All other reasons only affect this one program.
    $app=Get-RegistryApp $item.Program.Pattern $item.Program.Name
    if ($null -eq $app) { throw (L 'Registry-Eintrag fehlt oder mehrdeutig' 'Registry entry missing or ambiguous') }
    $localVersion=Parse-Version ([string]$app.DisplayVersion)
    if ($null -eq $localVersion -or $localVersion -ge $item.Version) { throw (L 'Installierte Version hat sich geaendert oder ist nicht vergleichbar' 'Installed version has changed or is not comparable') }
    if ($app.WindowsInstaller -ne 1) { throw (L 'Bestehende Installation ist nicht als Windows-Installer-Produkt registriert' 'Existing installation is not registered as a Windows Installer product') }
    $installedCode=[string]$app.PSChildName
    $guid=[guid]::Empty
    if (-not [guid]::TryParse($installedCode,[ref]$guid)) { throw (L 'Installierter MSI-ProductCode nicht eindeutig' 'Installed MSI ProductCode is ambiguous') }
    if ((Get-MsiProductState $installedCode) -ne 5) { throw (L 'Bestehendes MSI-Produkt ist nicht lokal installiert (ProductState)' 'Existing MSI product is not installed locally (ProductState)') }
    try { Assert-SafeMsiPath $item.File } catch { throw (Get-SecurityMessage $_) }
    $check=Assert-TrustedMsi $item.File $item.ExpectedHash $item.Program $app $item.Version
    $md=$check.Metadata
    if (-not (Test-MsiUpgradeRelation ([string]$md.UpgradeCode) $installedCode)) {
        throw (L 'UpgradeCode ist nicht mit installierter MSI-Produktfamilie verknuepft' 'UpgradeCode is not linked to the installed MSI product family')
    }
    Test-MsiUpgradeTable $check.Package ([string]$md.UpgradeCode) $localVersion $installedCode
    # The same ProductCode with a new version would be a small/minor update: never automatic.
    if (([string]$md.ProductCode).Trim('{}').ToUpperInvariant() -eq $installedCode.Trim('{}').ToUpperInvariant()) {
        throw (L 'Gleicher ProductCode bei neuer Version: Small/Minor-Update muss separat geprueft werden' 'Same ProductCode for a new version: a small/minor update must be checked separately')
    }
    if (Test-CraftProcessRunning $item $app) { throw (L 'Programm laeuft oder Prozess im Installationsverzeichnis gefunden' 'Program is running or a process was found in the installation folder') }
    # Never change the MSI context silently. Only confirmed HKLM MSI products.
    $registryPath=[string]$app.PSPath
    if ($registryPath -notmatch 'HKEY_LOCAL_MACHINE|HKLM:') { throw (L 'Bestehende Installation ist nicht eindeutig per-machine (HKLM)' 'Existing installation is not clearly per-machine (HKLM)') }
    $allUsers=[string]$md.ALLUSERS
    $perUser=[string]$md.MSIINSTALLPERUSER
    $machineOnly=($allUsers -eq '1' -and $perUser -ne '1')
    $dualPurpose=($allUsers -eq '2' -and $perUser -eq '1')
    if (-not ($machineOnly -or $dualPurpose)) {
        throw ((L 'MSI-Installationskontext nicht freigegeben (ALLUSERS={0}; MSIINSTALLPERUSER={1})' 'MSI installation context not approved (ALLUSERS={0}; MSIINSTALLPERUSER={1})') -f $allUsers,$perUser)
    }
    # Dual-purpose MSI: request per-machine only, via the command line.
    $scopeArgs=if ($dualPurpose) { ' ALLUSERS=2 MSIINSTALLPERUSER=""' } else { '' }
    return [pscustomobject]@{Item=$item; RegistryApp=$app; Check=$check; CurrentProductCode=$installedCode; ScopeArguments=$scopeArgs}
}
function Test-InstalledProductIdentity([string]$productCode,[version]$expectedVersion) {
    $state=Get-MsiProductState $productCode
    if ($state -ne 5) { throw ((L 'Neuer ProductCode ist nicht installiert; ProductState=' 'New ProductCode is not installed; ProductState=') + $state) }
    $versionString=Get-MsiProductInfo $productCode 'VersionString'
    $version=Parse-Version $versionString
    if ($null -eq $version -or $version -ne $expectedVersion) { throw ((L 'Windows Installer meldet unerwartete Produktversion: ' 'Windows Installer reports an unexpected product version: ') + $versionString) }
}

# ============================================================================
# 7. RUN PHASES
# ============================================================================
# (Removed: the copy to Program Files and the start-folder cleanup. The package files simply stay.)
function Add-PendingUpdate($program,$app,[string]$localText,[string]$remoteText,[version]$remote,[string]$file,[string]$expectedHash,$check) {
    $State.Pending.Add([pscustomobject]@{Program=$program; RegistryApp=$app; Local=$localText; Latest=$remoteText; Version=$remote; File=$file; ExpectedHash=$expectedHash; Check=$check})
}
function Find-ProgramUpdate($program) {
    # Phase 1 for one program: compare versions, download or reuse the MSI, check it.
    $localText=''; $remoteText=''; $tempDir=$null
    try {
        $regEntries = Find-RegistryEntries $InstalledSnapshot $program.Pattern
        if ($regEntries.Count -eq 0) { Add-Result $program.Name '' '' 'Nicht installiert' (L 'Registry-Eintrag fehlt' 'No registry entry'); return }
        $app=Resolve-RegistryApp $regEntries $program.Name
        $localText=[string]$app.DisplayVersion
        $local=Parse-Version $localText
        if ($null -eq $local) { Add-Result $program.Name $localText '' 'Uebersprungen' (L 'Lokale Version nicht vergleichbar' 'Local version not comparable'); return }
        $running=@($ProcessSnapshot | Where-Object { $_.ProcessName -match $program.Pattern })
        if ($running.Count -gt 0) { Write-Host ((L '{0}: laeuft ({1} Prozess/e); keine Beendigung' '{0}: running ({1} process(es)); not stopped') -f $program.Name,$running.Count) -ForegroundColor Yellow }
        $release=Get-ReleaseCached $program.Repo
        if ($release.draft -or $release.prerelease) { Add-Result $program.Name $localText '' 'Uebersprungen' (L 'Nicht stabiles Release' 'Not a stable release'); return }
        $remoteText=[string]$release.tag_name
        $remote=Parse-Version $remoteText
        if ($null -eq $remote) { Add-Result $program.Name $localText $remoteText 'Uebersprungen' (L 'Release-Tag nicht vergleichbar' 'Release tag not comparable'); return }
        if ($remote -le $local) { Add-Result $program.Name $localText $remoteText 'Aktuell' (L 'Kein Download erforderlich' 'No download needed'); return }
        # "What's new": keep the release notes of the newer version for the window and the console.
        $note = [pscustomobject]@{ Version=$remoteText; Text=(Format-ReleaseNotes ([string]$release.body)); Url=[string]$release.html_url }
        $State.Notes[$program.Name] = $note
        if ($null -ne $GuiSync) { $GuiSync.Notes[$program.Name] = $note }
        $assets=@($release.assets | Where-Object { $_.state -eq 'uploaded' -and $_.name -match '(?i)\.msi$' -and $_.name -match $ArchPattern -and $_.name -notmatch '(?i)(^|[._-])(debug|test|symbols)([._-]|$)' })
        if ($assets.Count -ne 1) { Add-Result $program.Name $localText $remoteText 'Uebersprungen' (L 'Kein eindeutiger MSI-Installer' 'No single matching MSI installer'); return }
        $asset=$assets[0]
        $name=[string]$asset.name
        if ($name -ne [IO.Path]::GetFileName($name) -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw ($SecurityPrefix + (L 'Unsicherer Dateiname' 'Unsafe file name')) }
        $digestMatch=[regex]::Match([string]$asset.digest,'(?i)^sha256:([a-f0-9]{64})$')
        if (-not $digestMatch.Success) { Add-Result $program.Name $localText $remoteText 'Uebersprungen' (L 'GitHub-Asset enthaelt keinen SHA256-Digest' 'GitHub asset has no SHA256 digest'); return }
        $expectedHash=$digestMatch.Groups[1].Value.ToUpperInvariant()
        $uri=[uri]$asset.browser_download_url
        $required="/$Owner/$($program.Repo)/releases/download/"
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.AbsolutePath.StartsWith($required,[StringComparison]::OrdinalIgnoreCase)) { throw ($SecurityPrefix + (L 'Unerwartete Download-URL' 'Unexpected download URL')) }
        # The folder name comes exclusively from a verified .NET version.
        $destinationDir=Join-Path (Join-Path $Verified $program.Name) ($remote.ToString())
        [void](New-Item -ItemType Directory -Force -Path $destinationDir)
        $destination=Join-Path $destinationDir $name

        # File already downloaded (e.g. after NO): check it fully again instead of downloading again.
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            try {
                $check=Assert-TrustedMsi $destination $expectedHash $program $app $remote
                Write-Host ((L '{0}: MSI bereits vorhanden, erneut vollstaendig geprueft (kein Download)' '{0}: MSI already present, fully checked again (no download)') -f $program.Name) -ForegroundColor DarkGray
                Add-Result $program.Name $localText $remoteText 'Verifiziert' (L 'Vorhandene Datei: Hash, Signatur, Profil-EKU und MSI erneut geprueft' 'Existing file: hash, signature, profile EKU and MSI checked again') $destination $check.Hash $check.Signer
                Add-PendingUpdate $program $app $localText $remoteText $remote $destination $expectedHash $check
                return
            } catch {
                # Never install it - discard and download fresh. The new file is fully checked.
                Write-Host ((L '{0}: vorhandene MSI-Datei verworfen ({1}); lade neu' '{0}: existing MSI file discarded ({1}); downloading again') -f $program.Name,$_.Exception.Message) -ForegroundColor Yellow
                $existing=Get-Item -LiteralPath $destination -Force -ErrorAction Stop
                if (Test-IsReparsePoint $existing) { throw ($SecurityPrefix + (L 'Vorhandene MSI-Datei ist ein Link' 'Existing MSI file is a link')) }
                Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
            }
        }

        $size=[long]$asset.size
        if ($size -le 0) { throw ($SecurityPrefix + (L 'Ungueltige Asset-Groesse' 'Invalid asset size')) }
        $disk=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Root))
        if ($disk.AvailableFreeSpace -lt ($size + $MinReserveBytes)) { Add-Result $program.Name $localText $remoteText 'Uebersprungen' (L 'Nicht genug freier Speicher' 'Not enough free disk space'); return }
        $tempDir=Join-Path $Root ('stage-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $tempDir)
        $tempFile=Join-Path $tempDir $name
        Invoke-Retry $uri.AbsoluteUri $tempFile | Out-Null
        if ((Get-Item -LiteralPath $tempFile).Length -ne $size) { throw ($SecurityPrefix + (L 'Downloadgroesse weicht von GitHub ab' 'Download size differs from GitHub')) }
        $check=Assert-TrustedMsi $tempFile $expectedHash $program $app $remote
        # The hash is checked again before installation in Test-InstallationCandidate.
        Move-Item -LiteralPath $tempFile -Destination $destination -ErrorAction Stop
        Add-Result $program.Name $localText $remoteText 'Verifiziert' (L 'SHA256, Authenticode, Herausgeber, Profil-EKU und MSI-Metadaten OK; Profilpruefung bestanden' 'SHA256, Authenticode, publisher, profile EKU and MSI metadata OK; profile check passed') $destination $check.Hash $check.Signer
        Add-PendingUpdate $program $app $localText $remoteText $remote $destination $expectedHash $check
    } catch {
        $detail=$_.Exception.Message
        $status=if (Test-IsSecurityMessage $detail) { 'Sicherheitsfehler' } else { 'Fehler' }
        Add-Result $program.Name $localText $remoteText $status $detail
    } finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Invoke-Preflight {
    # Phase 2: check every verified download for installability.
    foreach ($item in $State.Pending) {
        try {
            $elig=Test-InstallationCandidate $item
            [void]$State.Eligible.Add($elig)
            Add-Result $item.Program.Name $item.Local $item.Latest 'Installationsbereit' (L 'Profil-EKU und MSI-Upgrade kompatibel; Profilpruefung bestanden' 'Profile EKU and MSI upgrade compatible; profile check passed') $item.File $item.ExpectedHash $elig.Check.Signer
        } catch {
            $message=$_.Exception.Message
            if (Test-IsSecurityMessage $message) {
                Add-Result $item.Program.Name $item.Local $item.Latest 'Sicherheitsfehler' $message $item.File $item.ExpectedHash
            } else {
                Add-Result $item.Program.Name $item.Local $item.Latest 'Nur Download' ((L 'Keine Installation: ' 'Not installed: ') + $message) $item.File $item.ExpectedHash
            }
        }
    }
    # Fail closed on security errors: no approval question, no installation.
    $securityErrors=@($State.Results | Where-Object { $_.Status -eq 'Sicherheitsfehler' })
    if ($securityErrors.Count -gt 0) {
        $State.SecurityBlocked=$true
        Write-Warning ((L 'SICHERHEITSFEHLER: {0} Fall/Faelle. KEINE FREIGABE-ABFRAGE, KEINE INSTALLATION.' 'SECURITY ERROR: {0} case(s). NO APPROVAL QUESTION, NO INSTALLATION.') -f $securityErrors.Count)
        foreach ($b in $securityErrors) { Write-Warning ('  {0}: {1}' -f $b.Program,$b.Detail) }
        foreach ($e in $State.Eligible) {
            Add-Result $e.Item.Program.Name $e.Item.Local $e.Item.Latest 'Gesperrt' (L 'Gesamter Installationslauf wegen Sicherheitsfehler gesperrt' 'Whole installation run blocked because of a security error') $e.Item.File
        }
    }
}
function Install-EligibleUpdate($e) {
    # Install one update and verify it afterwards. The checked installer is opened so that
    # others may still read it, but nobody can change, replace or delete it until Windows
    # Installer has finished. Only then is it unlocked and, after a confirmed success, deleted.
    $item=$e.Item
    $guard=$null
    try {
        $guard=[IO.File]::Open($item.File,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    } catch {
        Add-Result $item.Program.Name $item.Local $item.Latest 'Nur Download' ((L 'Keine Installation: Installer-Datei konnte nicht gesperrt werden: ' 'Not installed: the installer file could not be locked: ') + $_.Exception.Message) $item.File $item.ExpectedHash
        return
    }
    $removeInstaller=$false
    try { $removeInstaller = [bool](Install-LockedUpdate $e) }
    finally { $guard.Dispose() }
    if ($removeInstaller) {
        # Delete the installer after confirmed success (now that it is unlocked).
        try { Remove-Item -LiteralPath $item.File -Force -ErrorAction Stop }
        catch { Write-Warning ((L 'Installer konnte nicht entfernt werden: ' 'Could not remove installer: ')+$_.Exception.Message) }
    }
}
function Install-LockedUpdate($e) {
    # Runs while the installer is locked. Returns $true only after a confirmed installation.
    $item=$e.Item
    $name=$item.Program.Name
    # Repeat ALL checks right before the installation.
    try { $recheck=Test-InstallationCandidate $item }
    catch {
        $message=$_.Exception.Message
        if (Test-IsSecurityMessage $message) {
            $State.StopInstallBatch=$true
            $State.InstallerFailures++
            Add-Result $name $item.Local $item.Latest 'Sicherheitsfehler' ($message + (L '; weitere Installationen gestoppt' '; further installations stopped')) $item.File $item.ExpectedHash
        } else {
            # E.g. the program was opened in the meantime: skip only this program.
            Add-Result $name $item.Local $item.Latest 'Nur Download' ((L 'Keine Installation: ' 'Not installed: ') + $message) $item.File $item.ExpectedHash
        }
        return $false
    }
    try {
        $msiLog=Join-Path $InstallerLogDir ($name+'-'+$RunId+'.log')
        $recovery=Join-Path $RecoveryDir ($name+'-'+$RunId+'.json')
        $restoreInfo=[pscustomobject]@{
            Program=$name; Timestamp=(Get-Date).ToString('o')
            PreviousVersion=[string]$recheck.RegistryApp.DisplayVersion
            PreviousProductCode=$recheck.CurrentProductCode
            PreviousPublisher=[string]$recheck.RegistryApp.Publisher
            NewVersion=$item.Latest; NewInstaller=$item.File
            NewSHA256=$item.ExpectedHash; Signer=$recheck.Check.Signer
            CertificateThumbprint=$recheck.Check.Thumbprint
            CertificateProfileEku=$ExpectedProfileEku
            Log=$msiLog
            Notice='Documentation only, NOT a guaranteed backup or rollback. Back up old installers/application data separately.'
        }
        ConvertTo-Json -InputObject $restoreInfo -Depth 6 | Set-Content -LiteralPath $recovery -Encoding UTF8
        Assert-FreeDiskSpace $item.File $MinReserveBytes
        Assert-SafeMsiPath $item.File
        if ($msiLog -match '["`\r\n]') { throw (L 'Unzulaessiger MSI-Logpfad' 'Invalid MSI log path') }
        $msiArgs='/i "'+$item.File+'" /qn /norestart REBOOT=ReallySuppress'+[string]$recheck.ScopeArguments+' /L*v "'+$msiLog+'"'
        $proc=Start-Process -FilePath $MsiExecPath -ArgumentList $msiArgs -PassThru -ErrorAction Stop
        # Get the handle right away, otherwise ExitCode is often $null (= 0) after WaitForExit(timeout).
        $null=$proc.Handle
        if (-not $proc.WaitForExit($InstallTimeoutSeconds * 1000)) {
            $State.StopInstallBatch=$true
            $State.PreserveInstallers=$true
            throw ((L 'MSI-Zeitlimit erreicht; Prozess NICHT beendet. Weitere Installationen gestoppt. PID: {0}; Log: {1}' 'MSI time limit reached; process NOT stopped. Further installations stopped. PID: {0}; log: {1}') -f $proc.Id,$msiLog)
        }
        if ($null -eq $proc.ExitCode) { throw ((L 'MSI-ExitCode nicht lesbar; Zustand unklar. Log: ' 'MSI exit code not readable; state unclear. Log: ')+$msiLog) }
        $code=[int]$proc.ExitCode
        if ($code -notin @(0,3010)) {
            $State.InstallerFailures++
            Add-Result $name $item.Local $item.Latest 'Installationsfehler' ((Get-FriendlyMsiError $code)+'; ExitCode '+$code+'; Log: '+$msiLog) $item.File $item.ExpectedHash
            # 1618 = concurrent MSI installation, 1641 = restart triggered: situation unclear.
            if ($code -in @(1618,1641)) { $State.StopInstallBatch=$true; Write-Warning ((L 'MSI-Code {0}: Batch aus Sicherheitsgruenden gestoppt.' 'MSI code {0}: batch stopped for safety reasons.') -f $code) }
            return $false
        }
        # Verification afterwards.
        $afterApp=Get-RegistryApp $item.Program.Pattern $item.Program.Name
        if ($null -eq $afterApp) { throw ((L 'Nachkontrolle unklar: Registry-Eintrag fehlt/mehrdeutig; Log: ' 'Verification unclear: registry entry missing/ambiguous; log: ')+$msiLog) }
        if ([string]$afterApp.PSPath -notmatch 'HKEY_LOCAL_MACHINE|HKLM:') { throw ((L 'Nachkontrolle: MSI nicht als per-machine registriert; Log: ' 'Verification: MSI not registered per-machine; log: ')+$msiLog) }
        if ($afterApp.WindowsInstaller -ne 1) { throw ((L 'Nachkontrolle: MSI-Registry-Eintrag fehlt; Log: ' 'Verification: MSI registry entry missing; log: ')+$msiLog) }
        $afterVersion=Parse-Version ([string]$afterApp.DisplayVersion)
        if ($null -eq $afterVersion -or $afterVersion -ne $item.Version) { throw ((L 'Nachkontrolle: installierte Version stimmt nicht mit Zielversion ueberein; Log: ' 'Verification: installed version does not match the target version; log: ')+$msiLog) }
        Test-InstalledProductIdentity ([string]$recheck.Check.Metadata.ProductCode) $item.Version
        if ($code -eq 3010) { $State.RebootRequired=$true }
        $status= if ($code -eq 3010) { 'Installiert - Neustart erforderlich' } else { 'Installiert - nachgeprueft' }
        Add-Result $name $item.Local $item.Latest $status ('ExitCode '+$code+'; Log: '+$msiLog+'; Restore-Info: '+$recovery) $item.File $item.ExpectedHash $recheck.Check.Signer
        return $true
    } catch {
        # Unclear state (timeout, verification): stop to be safe.
        $State.StopInstallBatch=$true
        $State.InstallerFailures++
        Add-Result $name $item.Local $item.Latest 'Installationsfehler' $_.Exception.Message $item.File $item.ExpectedHash
    }
    return $false
}
function Invoke-Installation {
    # Phase 3: show the list, ask for approval once, install.
    if ($State.SecurityBlocked) { return }
    if ($State.Eligible.Count -eq 0) {
        Write-Host (L 'Keine Updates fuer eine sichere Installation freigegeben.' 'No updates cleared for a safe installation.') -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host $(if ($NurPruefen) { (L 'FOLGENDE UPDATES SIND GEPRUEFT (KEINE INSTALLATION):' 'THE FOLLOWING UPDATES ARE VERIFIED (NO INSTALLATION):') } else { (L 'FOLGENDE UPDATES SIND ZUR INSTALLATION BEREIT:' 'THE FOLLOWING UPDATES ARE READY TO INSTALL:') }) -ForegroundColor Yellow
    foreach ($e in $State.Eligible) {
        Write-Host ('  {0}: {1} -> {2} | Signer: {3} | MSI: {4}' -f $e.Item.Program.Name,$e.Item.Local,$e.Item.Latest,$e.Check.Signer,$e.Item.File)
        $note = $State.Notes[$e.Item.Program.Name]
        if ($null -ne $note -and $note.Url) { Write-Host ('    ' + (L 'Was ist neu: ' "What's new: ") + $note.Url) -ForegroundColor DarkGray }
    }
    # Show individually skipped programs before the approval.
    $skipped=@($State.Results | Where-Object { $_.Status -in @('Fehler','Uebersprungen','Nur Download') })
    if ($skipped.Count -gt 0) {
        Write-Host (L 'NICHT ENTHALTEN (werden einzeln uebersprungen):' 'NOT INCLUDED (skipped individually):') -ForegroundColor Yellow
        foreach ($s in $skipped) { Write-Host ('  {0}: {1}' -f $s.Program,$s.Detail) -ForegroundColor Yellow }
    }
    Write-Host (L 'ACHTUNG: Ein signiertes MSI kann Systemaenderungen ausfuehren. Ein automatischer Rollback ist nicht garantiert.' 'NOTE: A signed MSI can make system changes. An automatic rollback is not guaranteed.') -ForegroundColor Yellow
    if (-not $NurPruefen -and -not (Test-IsAdmin)) { Write-Warning (L 'Keine Administratorrechte: Die Installation kann nur mit erhoehter PowerShell erfolgen. Es wird NICHT automatisch erhoeht.' 'No administrator rights: installation needs an elevated PowerShell. It is NOT elevated automatically.') }
    if (-not $NurPruefen) {
        if ($null -ne $GuiSync) { Write-Host (L 'Freigabe im Fenster: Knopf "Installieren" und Rueckfrage mit Ja. Sie gilt fuer ALLE oben gezeigten Updates.' 'Approval in the window: "Install" button and Yes in the confirmation. It applies to ALL updates shown above.') -ForegroundColor Yellow }
        else { Write-Host (L 'Ein einmaliges JA autorisiert ALLE oben gezeigten Updates.' 'A single YES authorises ALL updates shown above.') -ForegroundColor Yellow }
    }
    $approved = $false
    if (-not $NurPruefen) {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add((L 'Folgende Updates sind geprüft und bereit:' 'These updates are verified and ready:'))
        foreach ($e in $State.Eligible) { $lines.Add(('   {0}:  {1}  ->  {2}' -f $e.Item.Program.Name,(Format-VersionText $e.Item.Local),(Format-VersionText $e.Item.Latest))) }
        if ($skipped.Count -gt 0) {
            $lines.Add('')
            $lines.Add((L 'Diesmal nicht dabei:' 'Not included this time:'))
            foreach ($s in $skipped) { $lines.Add(('   {0}' -f $s.Program)) }
        }
        $lines.Add('')
        $lines.Add((L 'Ein automatisches Zurücksetzen gibt es nicht.' 'There is no automatic rollback.'))
        $lines.Add('')
        $lines.Add(((L 'Jetzt {0} Update(s) installieren?' 'Install {0} update(s) now?') -f $State.Eligible.Count))
        Set-GuiStatus ((L '{0} Update(s) bereit. Zum Installieren auf "Installieren" klicken.' '{0} update(s) ready. Click "Install" to install.') -f $State.Eligible.Count)
        Set-GuiPhase 'Warten'
        $approved = Request-Confirmation 'Updates' (L 'Updates installieren' 'Install updates') ($lines -join "`r`n") (L 'Alle gelisteten Updates installieren? Bitte JA eingeben (sonst Abbruch)' 'Install all listed updates? Type YES (anything else cancels)')
    }
    if (-not $approved) {
        foreach ($e in $State.Eligible) {
            if ($NurPruefen) { Add-Result $e.Item.Program.Name $e.Item.Local $e.Item.Latest 'Update bereit (Pruefmodus)' (L 'Sicherheitspruefungen bestanden; keine Installation im Pruefmodus' 'Security checks passed; no installation in check-only mode') $e.Item.File }
            else { Add-Result $e.Item.Program.Name $e.Item.Local $e.Item.Latest 'Update abgelehnt' (L 'Einmalige Freigabe nicht erteilt' 'Approval not given') $e.Item.File }
        }
        return
    }
    if (-not (Test-IsAdmin)) {
        Write-Host (L 'Keine Administratorrechte: Keine Installation. Skript ggf. erhoeht erneut starten.' 'No administrator rights: nothing installed. Start the script again elevated if needed.') -ForegroundColor Red
        foreach ($e in $State.Eligible) { Add-Result $e.Item.Program.Name $e.Item.Local $e.Item.Latest 'Gesperrt' (L 'Administratorrechte fehlen' 'Administrator rights missing') $e.Item.File }
        return
    }
    Set-GuiPhase 'Installieren'
    $installIndex = 0
    foreach ($e in $State.Eligible) {
        $installIndex++
        if ($State.StopInstallBatch) { Add-Result $e.Item.Program.Name $e.Item.Local $e.Item.Latest 'Gesperrt' (L 'Vorheriger MSI-Fehler; weitere Installationen ausgesetzt' 'Previous MSI error; further installations suspended') $e.Item.File; continue }
        Set-GuiStatus ((L 'Installiere {0} ({1} von {2}) - bitte warten ...' 'Installing {0} ({1} of {2}) - please wait ...') -f $e.Item.Program.Name,$installIndex,$State.Eligible.Count) ($installIndex - 1) $State.Eligible.Count
        Install-EligibleUpdate $e
    }
    Set-GuiStatus (L 'Installation abgeschlossen.' 'Installation finished.') $State.Eligible.Count $State.Eligible.Count
    Set-GuiPhase 'Fertig'
}
function Protect-ReportText([string]$text,[string]$userName=$env:USERNAME,[string]$computerName=$env:COMPUTERNAME,[string]$userProfile=$env:USERPROFILE) {
    # Error report only: replace the user's profile path, user name and computer name so the
    # report can be shared. The detailed logs in %LOCALAPPDATA% stay unchanged and local.
    $out = [string]$text
    $userTag = L '<Benutzer>' '<user>'
    $computerTag = L '<Computer>' '<computer>'
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $profileFull = $userProfile.TrimEnd('\')
        $cut = $profileFull.LastIndexOf('\')
        if ($cut -gt 0) {
            $replacement = $profileFull.Substring(0, $cut) + '\' + $userTag
            $out = [regex]::Replace($out, [regex]::Escape($profileFull), ({ param($m) $replacement }.GetNewClosure()), 'IgnoreCase')
        }
    }
    foreach ($pair in @(@($userName,$userTag), @($computerName,$computerTag))) {
        $value = [string]$pair[0]
        if ($value.Trim().Length -ge 2) {
            $tag = $pair[1]
            $out = [regex]::Replace($out, '(?<![A-Za-z0-9<])' + [regex]::Escape($value.Trim()) + '(?![A-Za-z0-9>])', ({ param($m) $tag }.GetNewClosure()), 'IgnoreCase')
        }
    }
    return $out
}
function Write-ErrorReport($errorRows,[string]$csv,[string]$json) {
    # Error report next to the updater; not written for success or a deliberate NO.
    try {
        if (-not (Test-Path -LiteralPath $ErrorFolder)) { [void](New-Item -ItemType Directory -Path $ErrorFolder -ErrorAction Stop) }
        $folderNow=Get-Item -LiteralPath $ErrorFolder -Force -ErrorAction Stop
        if (-not $folderNow.PSIsContainer -or (Test-IsReparsePoint $folderNow)) { throw (L 'Fehlerordner ist kein normaler Ordner' 'Error folder is not a normal folder') }
        $errorFile=Join-Path $ErrorFolder ($ErrorReportPrefix + $RunId + '.txt')
        $errorLines=New-Object 'System.Collections.Generic.List[string]'
        $errorLines.Add('CRAFT UPDATER v' + $UpdaterVersion + (L ' - FEHLERMELDUNG' ' - ERROR REPORT'))
        $errorLines.Add((L 'Zeit: ' 'Time: ')+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $errorLines.Add('')
        foreach ($entry in $errorRows) {
            $errorLines.Add(((L 'Programm: {0}' 'Program: {0}') -f $entry.Program))
            $errorLines.Add(('Status: {0}' -f (Get-FriendlyStatus ([string]$entry.Status))))
            $errorLines.Add(((L 'Installiert: {0}; Ziel: {1}' 'Installed: {0}; target: {1}') -f $entry.Installed,$entry.Latest))
            $errorLines.Add(((L 'Grund: {0}' 'Reason: {0}') -f $entry.Detail))
            $errorLines.Add('')
        }
        if ($State.Warnings.Count -gt 0) {
            $errorLines.Add((L 'WARNUNGEN / HINWEISE:' 'WARNINGS / NOTES:'))
            foreach ($w in @($State.Warnings)) { $errorLines.Add('  - ' + $w) }
            $errorLines.Add('')
        }
        if ($State.StopInstallBatch) { $errorLines.Add((L 'WARNUNG: Weitere Installationen wurden gestoppt.' 'WARNING: Further installations were stopped.')) }
        $errorLines.Add((L 'Vollstaendiger CSV-Bericht: ' 'Full CSV report: ')+$csv)
        $errorLines.Add((L 'Vollstaendiger JSON-Bericht: ' 'Full JSON report: ')+$json)
        $errorLines.Add((L 'MSI-Logs (falls erstellt): ' 'MSI logs (if created): ')+$InstallerLogDir)
        $errorLines.Add((L 'HINWEIS: Benutzername und Computername wurden in diesem Bericht unkenntlich gemacht.' 'NOTE: User name and computer name have been removed from this report.'))
        # CreateNew prevents overwriting existing files by accident.
        $fs=[System.IO.FileStream]::new($errorFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $writer=[System.IO.StreamWriter]::new($fs,[System.Text.UTF8Encoding]::new($false))
            try { foreach ($line in $errorLines) { $writer.WriteLine((Protect-ReportText $line)) } }
            finally { $writer.Dispose() }
        } finally { $fs.Dispose() }
        Write-Warning ((L 'Fehlerbericht gespeichert: ' 'Error report saved: ') + $errorFile)
        if ($null -ne $GuiSync) { $GuiSync.ErrorReport = $errorFile }
        Write-Host (L 'Fehlerberichte werden beim naechsten Updater-Start nach 3 Tagen automatisch entfernt.' 'Error reports are removed automatically after 3 days on the next start.') -ForegroundColor Yellow
    } catch {
        Write-Warning ((L 'Lokaler Fehlerbericht konnte nicht gespeichert werden: ' 'Could not save local error report: ') + $_.Exception.Message)
    }
}
function Write-RunSummary {
    # Phase 4: reports, final result, exit code, error report.
    $csv=Join-Path $Reports ("Run-$RunId.csv")
    $json=Join-Path $Reports ("Run-$RunId.json")
    try {
        $csvText=@($State.Results.ToArray()) | ConvertTo-Csv -NoTypeInformation -Delimiter ';'
        [void](Save-CraftReport $csv (($csvText -join [Environment]::NewLine) + [Environment]::NewLine))
    } catch { Write-Warning ((L 'CSV-Bericht fehlgeschlagen: ' 'CSV report failed: ') + $_.Exception.Message) }
    try { [void](Save-CraftReport $json (ConvertTo-Json -InputObject @($State.Results.ToArray()) -Depth 5)) } catch { Write-Warning ((L 'JSON-Bericht fehlgeschlagen: ' 'JSON report failed: ') + $_.Exception.Message) }
    # Only the last status per program.
    $lastByName=@{}
    foreach ($result in $State.Results) { $lastByName[[string]$result.Program]=$result }
    $summary=@(foreach ($program in $Programs) { if ($lastByName.ContainsKey([string]$program.Name)) { $lastByName[[string]$program.Name] } })
    Write-Host ("`n" + (L '=== ENDERGEBNIS ===' '=== FINAL RESULT ===')) -ForegroundColor Cyan
    $summary | Select-Object Program,Installed,Latest,@{Name='Status';Expression={ Get-FriendlyStatus ([string]$_.Status) }} | Format-Table -AutoSize
    # Problems = real errors. Skipped = single programs without installation.
    # Up to date, not installed and a deliberate NO are not problems.
    $failed=@($summary | Where-Object { $_.Status -match 'Fehler' })
    $skipped=@($summary | Where-Object { $_.Status -in @('Nur Download','Uebersprungen','Gesperrt') })
    $updatedCount=@($summary | Where-Object { $_.Status -match '^Installiert' }).Count
    $currentCount=@($summary | Where-Object { $_.Status -eq 'Aktuell' }).Count
    $missingCount=@($summary | Where-Object { $_.Status -eq 'Nicht installiert' }).Count
    $readyCount=@($summary | Where-Object { $_.Status -eq 'Update bereit (Pruefmodus)' }).Count
    $rejectedCount=@($summary | Where-Object { $_.Status -eq 'Update abgelehnt' }).Count
    if ($failed.Count -gt 0 -or $skipped.Count -gt 0 -or $State.InstallerFailures -gt 0) { $State.ExitCode = 1 }
    Write-Host ((L 'Erfolgreich aktualisiert: {0} | Bereits aktuell: {1} | Nicht installiert: {2} | Bewusst abgelehnt: {3} | Probleme: {4}' 'Updated: {0} | Already up to date: {1} | Not installed: {2} | Declined: {3} | Problems: {4}') -f $updatedCount,$currentCount,$missingCount,$rejectedCount,$failed.Count)
    if ($readyCount -gt 0) { Write-Host ((L 'Im Pruefmodus bereit: {0}' 'Ready in check-only mode: {0}') -f $readyCount) }
    if ($skipped.Count -gt 0) { Write-Host ((L 'Weitere blockierte/uebersprungene Updates: {0}' 'Other blocked/skipped updates: {0}') -f $skipped.Count) -ForegroundColor Yellow }
    if ($rejectedCount -gt 0) { Write-Host ((L 'Installationsfreigabe nicht erteilt: {0} Update(s) bewusst abgelehnt; keine Installation dieser Updates.' 'Approval not given: {0} update(s) declined; these updates were not installed.') -f $rejectedCount) -ForegroundColor Yellow }
    if ($missingCount -gt 0) { Write-Host ((L 'Information: {0} Craft-Programm(e) sind auf diesem PC nicht installiert und wurden korrekt uebersprungen.' 'Info: {0} Craft program(s) are not installed on this PC and were skipped correctly.') -f $missingCount) -ForegroundColor Cyan }
    $attention=@($failed + $skipped)
    if ($null -ne $GuiSync) {
        $GuiSync.Summary = [pscustomobject]@{
            Updated=$updatedCount; Current=$currentCount; Missing=$missingCount; Rejected=$rejectedCount
            Problems=$failed.Count; Skipped=$skipped.Count; Reboot=[bool]$State.RebootRequired
            SecurityBlocked=[bool]$State.SecurityBlocked; BatchStopped=[bool]$State.StopInstallBatch
        }
    }
    if ($attention.Count -gt 0) {
        Write-Warning ((L '{0} Programm(e) konnten nicht wie vorgesehen aktualisiert werden; Details in den Berichten.' '{0} program(s) could not be updated as planned; details in the reports.') -f $attention.Count)
        $attention | Select-Object Program,@{Name='Status';Expression={ Get-FriendlyStatus ([string]$_.Status) }},Detail | Format-Table -AutoSize -Wrap
    }
    # On problems OR warnings (e.g. cleanup or cache problems) write a report, so that
    # only the file has to be sent and nothing needs to be copied from the window.
    if (($attention.Count -gt 0 -or $State.Warnings.Count -gt 0) -and $State.ErrorFolderReady) {
        Write-ErrorReport $attention $csv $json
    }
    if ($State.RebootRequired) { Write-Warning (L 'MINDESTENS EIN UPDATE BENOETIGT EINEN WINDOWS-NEUSTART. Bitte geoeffnete Arbeit sichern.' 'AT LEAST ONE UPDATE NEEDS A WINDOWS RESTART. Please save open work.') }
    if ($State.StopInstallBatch) { Write-Warning (L 'Weitere MSI-Installationen aus Sicherheitsgruenden ausgesetzt. Details in den Logs.' 'Further MSI installations suspended for safety reasons. Details in the logs.') }
    if ($failed.Count -gt 0) { Write-Warning (L 'Mindestens ein Programm benoetigt Aufmerksamkeit; Details in CSV/JSON und MSI-Logs.' 'At least one program needs attention; details in CSV/JSON and MSI logs.') }
    Write-Host ("CSV: $csv`nJSON: $json`n" + (L 'Historie: ' 'History: ') + "$HistoryPath`nDownloads: $Verified") -ForegroundColor Cyan
    Write-Host (L 'Installationsmodus: Nur nach Freigabe und exakter Profil-EKU sowie allen Sicherheitspruefungen.' 'Installation mode: only after approval, exact profile EKU and all security checks.') -ForegroundColor Green
}
function Invoke-CraftMaintenance {
    # Only exactly known file patterns; never follow link targets.
    Remove-OldFiles $Reports 'Run-*.csv' $KeepRunReports
    Remove-OldFiles $Reports 'Run-*.json' $KeepRunReports
    Remove-OldFiles $Reports 'Diagnosis-*.csv' 3
    Remove-OldFiles $Reports 'Diagnosis-*.json' 3
    Remove-OldFiles $Reports 'History-Archive-*.jsonl' $MaxHistoryArchives
    Remove-OldFiles $InstallerLogDir '*.log' $KeepMsiLogs 7
    Remove-OldFiles $RecoveryDir '*.json' $KeepMsiLogs 7
    # Aborted downloads (stage-<GUID>) older than 1 day; not recursive.
    foreach ($stageDir in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'stage-*' -ErrorAction SilentlyContinue)) {
        try {
            if ($stageDir.Name -match '^stage-[0-9a-f]{32}$' -and -not (Test-IsReparsePoint $stageDir) -and
                $stageDir.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-1)) {
                foreach ($stageFile in @(Get-ChildItem -LiteralPath $stageDir.FullName -File -Force -ErrorAction Stop)) {
                    if (-not (Test-IsReparsePoint $stageFile)) { Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction Stop }
                }
                if (@(Get-ChildItem -LiteralPath $stageDir.FullName -Force -ErrorAction Stop).Count -eq 0) {
                    Remove-Item -LiteralPath $stageDir.FullName -Force -ErrorAction Stop
                }
            }
        } catch { Write-Warning ((L 'Stage-Bereinigung: ' 'Stage cleanup: ')+$_.Exception.Message) }
    }
    # Release cache: can be fetched again after it expires, so it is not needed.
    foreach ($prog in $Programs) {
        $cf = Join-Path $CacheRoot ($prog.Repo + '.json')
        try {
            if (Test-Path -LiteralPath $cf -PathType Leaf) {
                $cfItem=Get-Item -LiteralPath $cf -Force -ErrorAction Stop
                if (-not (Test-IsReparsePoint $cfItem) -and $cfItem.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-$MaxCacheAgeDays)) {
                    Remove-Item -LiteralPath $cf -Force -ErrorAction Stop
                }
            }
        } catch { Write-Warning ((L 'Cache-Bereinigung: ' 'Cache cleanup: ')+$_.Exception.Message) }
    }
    # MSI files: updates verified but not installed in this run stay (e.g. after NO)
    # and are fully checked again on the next start.
    # Everything else (outdated, installed, discarded) is removed.
    if ($State.PreserveInstallers) {
        Write-Warning (L 'MSI-Prozesszustand unklar: Installer-Bereinigung aus Sicherheitsgruenden ausgesetzt.' 'MSI process state unclear: installer cleanup suspended for safety reasons.')
        return
    }
    $keepInstallers=@{}
    foreach ($p in $State.Pending) { $keepInstallers[[IO.Path]::GetFullPath([string]$p.File).ToUpperInvariant()]=$true }
    foreach ($prog in $Programs) {
        $pd=Join-Path $Verified $prog.Name
        if (-not (Test-Path -LiteralPath $pd -PathType Container)) { continue }
        foreach ($versionDir in @(Get-ChildItem -LiteralPath $pd -Directory -ErrorAction SilentlyContinue)) {
            if (Test-IsReparsePoint $versionDir) { continue }
            if ($versionDir.Name -notmatch '^\d+(\.\d+){1,3}$') { continue }
            foreach ($msiFile in @(Get-ChildItem -LiteralPath $versionDir.FullName -Filter '*.msi' -File -ErrorAction SilentlyContinue)) {
                try {
                    if (-not (Test-IsReparsePoint $msiFile) -and -not $keepInstallers.ContainsKey($msiFile.FullName.ToUpperInvariant())) {
                        Remove-Item -LiteralPath $msiFile.FullName -Force -ErrorAction Stop
                    }
                } catch { Write-Warning ((L 'Installer-Bereinigung: ' 'Installer cleanup: ')+$_.Exception.Message) }
            }
            try {
                if (@(Get-ChildItem -LiteralPath $versionDir.FullName -Force -ErrorAction Stop).Count -eq 0) {
                    Remove-Item -LiteralPath $versionDir.FullName -Force -ErrorAction Stop
                }
            } catch { Write-Warning ((L 'Ordner-Bereinigung: ' 'Folder cleanup: ')+$_.Exception.Message) }
        }
    }
}
function Invoke-UpdateRun {
    try {
        $searchIndex = 0
        foreach ($program in $Programs) {
            Set-GuiStatus ((L 'Suche Updates: {0} ({1} von {2}) ...' 'Checking for updates: {0} ({1} of {2}) ...') -f $program.Name,($searchIndex + 1),$Programs.Count) $searchIndex $Programs.Count
            Find-ProgramUpdate $program
            $searchIndex++
        }
        Set-GuiStatus (L 'Prüfe die Updates vor der Installation ...' 'Checking the updates before installation ...') $Programs.Count $Programs.Count
        Invoke-Preflight
        Invoke-Installation
    } finally {
        Write-RunSummary
        Invoke-CraftMaintenance
    }
}
function Invoke-DiagnoseRun {
    Write-Host (L 'DIAGNOSEMODUS: Keine Downloads, keine Installation, nur lokale Pruefung.' 'DIAGNOSTICS MODE: no downloads, no installation, local checks only.') -ForegroundColor Yellow
    foreach ($program in $Programs) {
        try {
            $apps=Find-RegistryEntries $InstalledSnapshot $program.Pattern
            if ($apps.Count -eq 0) { Add-Result $program.Name '' '' 'Diagnose' (L 'Nicht installiert' 'Not installed'); continue }
            $a=Resolve-RegistryApp $apps $program.Name
            $issues=New-Object 'System.Collections.Generic.List[string]'
            if (-not (Parse-Version ([string]$a.DisplayVersion))) { $issues.Add((L 'Version nicht eindeutig' 'Version ambiguous')) }
            if ($a.WindowsInstaller -ne 1) { $issues.Add((L 'Keine MSI-Registry-Installation' 'Not an MSI registry installation')) }
            elseif ([string]$a.PSPath -notmatch 'HKEY_LOCAL_MACHINE') { $issues.Add((L 'MSI nicht per-machine (HKLM) registriert' 'MSI not registered per-machine (HKLM)')) }
            if (-not (Test-AllowedRegistryPublisher ([string]$a.Publisher))) { $issues.Add((L 'Registry-Publisher ist weder Learning Machines Inc noch LLC' 'Registry publisher is neither Learning Machines Inc nor LLC')) }
            $running=@($ProcessSnapshot | Where-Object { $_.ProcessName -match $program.Pattern })
            if ($running.Count -gt 0) { $issues.Add((L 'Programm laeuft' 'Program is running')) }
            if ($issues.Count -eq 0) { Add-Result $program.Name ([string]$a.DisplayVersion) '' 'Diagnose-OK' (L 'Grundvoraussetzungen vorhanden; Upgrade-MSI noch nicht untersucht' 'Basic requirements met; upgrade MSI not examined yet') }
            else { Add-Result $program.Name ([string]$a.DisplayVersion) '' 'Diagnose-Hinweis' ($issues -join '; ') }
        } catch { Add-Result $program.Name '' '' 'Diagnose-Fehler' $_.Exception.Message }
    }
    if (-not (Test-IsAdmin)) { Write-Warning (L 'Kein Administrator: spaetere per-machine Installation erfordert Erhoehung.' 'Not an administrator: a later per-machine installation needs elevation.') }
    try {
        $disk=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Root))
        if ($disk.AvailableFreeSpace -lt $MinReserveBytes) { Write-Warning (L 'Freier Speicher unter Mindestreserve.' 'Free disk space below the minimum reserve.') }
    } catch { Write-Warning ((L 'Speicherpruefung: ' 'Disk space check: ') + $_.Exception.Message) }
    $csv=Join-Path $Reports ('Diagnosis-'+$RunId+'.csv')
    $json=Join-Path $Reports ('Diagnosis-'+$RunId+'.json')
    try { $lines=@($State.Results.ToArray()) | ConvertTo-Csv -NoTypeInformation -Delimiter ';'; [void](Save-CraftReport $csv ($lines -join [Environment]::NewLine)) } catch { Write-Warning $_.Exception.Message }
    try { [void](Save-CraftReport $json (ConvertTo-Json -InputObject @($State.Results.ToArray()) -Depth 5)) } catch { Write-Warning $_.Exception.Message }
    $State.Results | Select-Object Program,Installed,@{Name='Status';Expression={ Get-FriendlyStatus ([string]$_.Status) }},Detail | Format-Table -AutoSize
    # Diagnostics mode never deletes files.
}

# ============================================================================
# 7b. WINDOW
# ============================================================================
# The window only displays and asks for approval. The actual run (all checks,
# downloads, installations) happens unchanged in a second runspace of the same
# process and reports through $GuiSync. No second, hidden process.
function Format-VersionText([string]$version) {
    # Window: always show versions with "v" (display only, comparison unchanged).
    $v = ([string]$version).Trim()
    if ([string]::IsNullOrEmpty($v)) { return '' }
    if ($v -match '^[vV]\d') { return 'v' + $v.Substring(1) }
    if ($v -match '^\d') { return 'v' + $v }
    return $v
}
function Test-ReleaseNotesUrl([string]$url) {
    # Only the release page of a Craft program on GitHub may be opened or copied.
    return ($url -match '^https://github\.com/storytold/[A-Za-z0-9._-]+/releases/tag/[A-Za-z0-9._%+-]+$')
}
function Open-ReleaseNotesUrl([string]$url) {
    # Opened through Explorer, so the browser starts with normal user rights and not with the
    # updater's administrator rights.
    if (-not (Test-ReleaseNotesUrl $url)) { return $false }
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $url; return $true } catch { return $false }
}
function Open-ProjectPage {
    # Same as the release notes link: only this one fixed address, opened without admin rights.
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $ProjectUrl; return $true } catch { return $false }
}
function Show-ReleaseNotesDialog($owner,[string]$title,[string]$body,[string]$url,[string]$footer) {
    # Small window instead of a message box: the text can be scrolled and selected, and the
    # link to the full notes can be clicked or copied.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI',9)
    $dlg.ClientSize = New-Object System.Drawing.Size(540,450)   # height is set below from the content
    if ($null -ne $owner -and $null -ne $owner.Icon) { $dlg.Icon = $owner.Icon }
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.WordWrap = $true
    $box.ScrollBars = 'Vertical'
    $box.BackColor = [System.Drawing.Color]::White
    $box.Location = New-Object System.Drawing.Point(12,12)
    # Short text gets a small box, long text a bigger box with a scroll bar.
    $bodySize = [System.Windows.Forms.TextRenderer]::MeasureText($body,$dlg.Font,(New-Object System.Drawing.Size(490,0)),[System.Windows.Forms.TextFormatFlags]::WordBreak)
    $boxHeight = [Math]::Min(320,[Math]::Max(70,$bodySize.Height + 14))
    $box.Size = New-Object System.Drawing.Size(516,$boxHeight)
    $box.Text = $body
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(90,100,110)
    $hint.Text = $footer
    # The hint gets exactly as many lines as it needs, so nothing is cut off.
    $hintHeight = 0
    if ($footer) {
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($footer,$dlg.Font,(New-Object System.Drawing.Size(516,0)),[System.Windows.Forms.TextFormatFlags]::WordBreak)
        $hintHeight = $measured.Height + 6
    }
    $y = 12 + $boxHeight + 10
    $hint.Location = New-Object System.Drawing.Point(12,$y)
    $hint.Size = New-Object System.Drawing.Size(516,$hintHeight)
    $hint.Visible = [bool]$footer
    if ($footer) { $y += $hintHeight + 6 }
    $linkTitle = New-Object System.Windows.Forms.Label
    $linkTitle.AutoSize = $true
    $linkTitle.Location = New-Object System.Drawing.Point(12,$y)
    $linkTitle.Text = (L 'Alle Neuerungen auf GitHub:' 'Full release notes on GitHub:')
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.AutoSize = $false
    $link.AutoEllipsis = $true
    $link.Location = New-Object System.Drawing.Point(12,($y + 19))
    $link.Size = New-Object System.Drawing.Size(516,20)
    $link.Text = $url
    $link.Add_LinkClicked({ [void](Open-ReleaseNotesUrl $url) })
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = (L 'Link kopieren' 'Copy link')
    if (Test-ReleaseNotesUrl $url) { $y += 52 }
    $btnCopy.Location = New-Object System.Drawing.Point(316,$y)
    $btnCopy.Size = New-Object System.Drawing.Size(104,30)
    $btnCopy.Add_Click({
        try { [System.Windows.Forms.Clipboard]::SetText($url); $btnCopy.Text = (L 'Kopiert' 'Copied') } catch {}
    })
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(428,$y)
    $dlg.ClientSize = New-Object System.Drawing.Size(540,($y + 42))
    $btnOk.Size = New-Object System.Drawing.Size(100,30)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnOk
    if (-not (Test-ReleaseNotesUrl $url)) { $linkTitle.Visible = $false; $link.Visible = $false; $btnCopy.Visible = $false }
    $dlg.Controls.AddRange(@($box,$hint,$linkTitle,$link,$btnCopy,$btnOk))
    $dlg.Add_Shown({ $box.SelectionStart = 0; $box.SelectionLength = 0; [void]$btnOk.Focus() })
    try { [void]$dlg.ShowDialog($owner) } finally { $dlg.Dispose() }
}
function Format-ReleaseNotes([string]$markdown,[int]$maxLength=4000,[int]$maxLines=60) {
    # Turns GitHub release notes (Markdown) into short plain text for the "What's new" window.
    # The full notes are always linked below the text.
    if ([string]::IsNullOrWhiteSpace($markdown)) { return '' }
    $t = $markdown -replace "`r`n","`n"
    $t = [regex]::Replace($t, '(?s)<!--.*?-->', '')
    # GitHub's generated notes: drop "New Contributors" and "Full Changelog", shorten
    # "... by @name in https://github.com/.../pull/123" to "... (#123)".
    $t = [regex]::Replace($t, '(?ms)^\s{0,3}#{1,6}\s*New Contributors\s*$.*?(?=^\s{0,3}#{1,6}\s|\z)', '')
    $t = [regex]::Replace($t, '(?m)^.*\bmade their first contribution\b.*$', '')
    $t = [regex]::Replace($t, '(?m)^\s*\*{0,2}Full Changelog\*{0,2}:.*$', '')
    $t = [regex]::Replace($t, '\s+by\s+@[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?(\s+in\s+https://github\.com/\S+?/pull/(\d+))?', { param($m) if ($m.Groups[3].Success) { ' (#' + $m.Groups[3].Value + ')' } else { '' } })
    $t = [regex]::Replace($t, '\s+in\s+https://github\.com/\S+?/pull/(\d+)', ' (#$1)')
    $t = [regex]::Replace($t, '!\[[^\]]*\]\([^)]*\)', '')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]*\)', '$1')
    $t = [regex]::Replace($t, '(?m)^\s{0,3}#{1,6}\s*', '')
    $t = [regex]::Replace($t, '(?m)^(\s*)[-*+]\s+', '$1- ')
    $t = $t -replace '\*\*','' -replace '__','' -replace '`',''
    $t = [regex]::Replace($t, '<[^>]+>', '')
    $t = [regex]::Replace($t, "\n{3,}", "`n`n").Trim()
    $lines = $t -split "`n"
    if ($lines.Count -gt $maxLines) { $t = (($lines[0..($maxLines-1)]) -join "`n").TrimEnd() + "`n..." }
    if ($t.Length -gt $maxLength) { $t = $t.Substring(0,$maxLength).TrimEnd() + ' ...' }
    return ($t -replace "`n","`r`n")
}
function Get-FriendlyStatus([string]$status) {
    # Internal status key -> readable text in the current language.
    switch -Regex ($status) {
        '^Aktuell$'                            { return (L 'Aktuell' 'Up to date') }
        '^Nicht installiert$'                  { return (L 'Nicht installiert' 'Not installed') }
        '^Verifiziert$'                        { return (L 'Geladen und geprüft' 'Downloaded and verified') }
        '^Installationsbereit$'                { return (L 'Bereit zur Installation' 'Ready to install') }
        '^Update bereit \(Pruefmodus\)$'       { return (L 'Bereit (nur geprüft)' 'Ready (check only)') }
        '^Installiert - nachgeprueft$'         { return (L 'Aktualisiert' 'Updated') }
        '^Installiert - Neustart erforderlich$' { return (L 'Aktualisiert - Neustart nötig' 'Updated - restart needed') }
        '^Update abgelehnt$'                   { return (L 'Update nicht installiert' 'Update not installed') }
        '^(Nur Download|Uebersprungen)$'       { return (L 'Diesmal übersprungen' 'Skipped this time') }
        '^Gesperrt$'                           { return (L 'Gesperrt' 'Blocked') }
        '^Sicherheitsfehler$'                  { return (L 'Sicherheitsfehler' 'Security error') }
        '^Diagnose$'                           { return (L 'Diagnose' 'Diagnostics') }
        '^Diagnose-OK$'                        { return (L 'Diagnose OK' 'Diagnostics OK') }
        '^Diagnose-Hinweis$'                   { return (L 'Diagnose-Hinweis' 'Diagnostics note') }
        'Fehler'                               { return (L 'Fehler' 'Error') }
        default                                { return $status }
    }
}
function Get-StatusColor([string]$status) {
    if ($status -match 'Sicherheitsfehler|Fehler') { return [System.Drawing.Color]::Firebrick }
    if ($status -match '^Installiert') { return [System.Drawing.Color]::ForestGreen }
    if ($status -in @('Installationsbereit','Verifiziert','Update bereit (Pruefmodus)')) { return [System.Drawing.Color]::FromArgb(37,99,235) }
    if ($status -in @('Nur Download','Uebersprungen','Gesperrt','Update abgelehnt')) { return [System.Drawing.Color]::DarkOrange }
    if ($status -eq 'Nicht installiert') { return [System.Drawing.Color]::SlateGray }
    return [System.Drawing.Color]::Black
}
function Get-SummaryText($summary,[string]$crash) {
    # One sentence for the window, plus colour and symbol.
    if ($crash) { return @(((L 'Der Updater wurde mit einem Fehler beendet: ' 'The updater stopped with an error: ') + $crash), [System.Drawing.Color]::Firebrick, [char]0x2716) }
    if ($null -eq $summary) { return @((L 'Der Updater wurde unerwartet beendet. Details stehen im Konsolenfenster.' 'The updater stopped unexpectedly. Details are in the console window.'), [System.Drawing.Color]::Firebrick, [char]0x2716) }
    if ($summary.SecurityBlocked) { return @((L 'Sicherheitsfehler gefunden - es wurde nichts installiert. Bitte nichts erzwingen.' 'Security error found - nothing was installed. Please do not force anything.'), [System.Drawing.Color]::Firebrick, [char]0x2716) }
    $text = ''
    $symbol = ''
    if ($summary.Updated -gt 0) { $text = ((L '{0} Programm(e) aktualisiert. ' '{0} program(s) updated. ') -f $summary.Updated) }
    if ($summary.Problems -gt 0 -or $summary.Skipped -gt 0) {
        $text += ((L 'Bei {0} Programm(en) hat es nicht geklappt - siehe Fehlerbericht.' '{0} program(s) did not work out - see the error report.') -f ($summary.Problems + $summary.Skipped))
        $color = [System.Drawing.Color]::DarkOrange
    } elseif ($summary.Rejected -gt 0) {
        $text += (L 'Die Updates wurden nicht installiert. Beim nächsten Start werden sie wieder angeboten.' 'The updates were not installed. They will be offered again next time.')
        $color = [System.Drawing.Color]::DarkOrange
    } elseif ($summary.Updated -gt 0) {
        $text = (L 'Fertig! ' 'Done! ') + $text
        $color = [System.Drawing.Color]::ForestGreen
        $symbol = [string][char]0x2713
    } else {
        $text = (L 'Alles aktuell - es gibt nichts zu tun.' 'Everything is up to date - nothing to do.')
        $color = [System.Drawing.Color]::ForestGreen
        $symbol = [string][char]0x2713
    }
    if ($summary.Reboot) { $text += (L ' Bitte Windows neu starten.' ' Please restart Windows.') }
    return @($text.Trim(), $color, $symbol)
}
function Get-SortRank([string]$status) {
    # Order in the list: 0 = updates/notes on top, 1 = up to date, 2 = not installed at the bottom.
    if ($status -eq 'Nicht installiert') { return 2 }
    if ([string]::IsNullOrEmpty($status) -or $status -eq 'Aktuell') { return 1 }
    return 0
}
function Test-UseWindow {
    if ($Konsole -or $Diagnose -or $NurPruefen -or ($null -ne $GuiSync)) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop; return $true }
    catch { Write-Warning ((L 'Fenster nicht verfuegbar, es geht in der Konsole weiter: ' 'Window not available, continuing in the console: ') + $_.Exception.Message); return $false }
}
function Write-WorkerOutput($worker,$ui) {
    # Print the background run's messages in the visible console window.
    $info = $worker.Streams.Information
    while ($ui.InfoIndex -lt $info.Count) {
        $message = $info[$ui.InfoIndex].MessageData
        $ui.InfoIndex++
        if ($message -is [System.Management.Automation.HostInformationMessage]) {
            if ($null -ne $message.ForegroundColor) { Write-Host $message.Message -ForegroundColor $message.ForegroundColor -NoNewline:([bool]$message.NoNewLine) }
            else { Write-Host $message.Message -NoNewline:([bool]$message.NoNewLine) }
        } else { Write-Host ([string]$message) }
    }
    $warnings = $worker.Streams.Warning
    while ($ui.WarnIndex -lt $warnings.Count) {
        Write-Host ((L 'WARNUNG: ' 'WARNING: ') + $warnings[$ui.WarnIndex].Message) -ForegroundColor Yellow
        $ui.WarnIndex++
    }
    $errors = $worker.Streams.Error
    while ($ui.ErrIndex -lt $errors.Count) {
        Write-Host ((L 'FEHLER: ' 'ERROR: ') + $errors[$ui.ErrIndex].Exception.Message) -ForegroundColor Red
        $ui.ErrIndex++
    }
}
function New-GuiSync {
    return [hashtable]::Synchronized(@{
        Rows = [hashtable]::Synchronized(@{}); StatusText = (L 'Craft Updater startet ...' 'Craft Updater is starting ...')
        ProgressValue = 0; ProgressMax = $Programs.Count
        Question = $null; Answer = $null; WindowClosed = $false; Phase = 'Suche'
        Summary = $null; ErrorReport = ''; ExitCode = 0; Notes = [hashtable]::Synchronized(@{})
    })
}
function Set-CraftTitleBar($form) {
    # Set the title bar to the header's plum colour (Windows 11), so it does not clash
    # with the Windows accent colour. No effect on older Windows.
    try {
        if (-not ([System.Management.Automation.PSTypeName]'CraftNative.Dwm').Type) {
            Add-Type -Namespace CraftNative -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@
        }
        # COLORREF = 0x00BBGGRR
        $caption = [int](($BrandColor[2] -shl 16) -bor ($BrandColor[1] -shl 8) -bor $BrandColor[0])
        $text = [int]0xFFFFFF
        [void][CraftNative.Dwm]::DwmSetWindowAttribute($form.Handle, 35, [ref]$caption, 4)  # DWMWA_CAPTION_COLOR
        [void][CraftNative.Dwm]::DwmSetWindowAttribute($form.Handle, 36, [ref]$text, 4)      # DWMWA_TEXT_COLOR
    } catch {}
}

function Show-CraftSplash {
    # Just for fun: a small splash screen that "loads" for a few seconds, then the main window appears.
    if ($SplashSeconds -le 0) { return }
    try {
        $splash = New-Object System.Windows.Forms.Form
        $splash.FormBorderStyle = 'None'
        $splash.StartPosition = 'CenterScreen'
        $splash.Size = New-Object System.Drawing.Size(440,240)
        $splash.BackColor = [System.Drawing.Color]::White
        $splash.TopMost = $true
        $splash.ShowInTaskbar = $false
        $splash.Add_Paint({ param($snd,$e) $e.Graphics.DrawRectangle([System.Drawing.Pens]::LightGray, 0, 0, $snd.Width - 1, $snd.Height - 1) })
        $strip = New-Object System.Windows.Forms.Panel
        $strip.BackColor = [System.Drawing.Color]::FromArgb($BrandColor[0],$BrandColor[1],$BrandColor[2])
        $strip.Size = New-Object System.Drawing.Size(8,240)
        $strip.Location = New-Object System.Drawing.Point(0,0)
        $pic = New-Object System.Windows.Forms.PictureBox
        if (Test-Path -LiteralPath $IconPath -PathType Leaf) { try { $pic.Image = (New-Object System.Drawing.Icon($IconPath,72,72)).ToBitmap() } catch {} }
        $pic.SizeMode = 'Zoom'
        $pic.Size = New-Object System.Drawing.Size(84,84)
        $pic.Location = New-Object System.Drawing.Point(48,48)
        $pic.BackColor = [System.Drawing.Color]::Transparent
        $t = New-Object System.Windows.Forms.Label
        $t.Text = 'Craft Updater'
        $t.AutoSize = $true
        $t.Font = New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold)
        $t.ForeColor = [System.Drawing.Color]::FromArgb(31,45,61)
        $t.Location = New-Object System.Drawing.Point(150,54)
        $t.BackColor = [System.Drawing.Color]::Transparent
        $sub = New-Object System.Windows.Forms.Label
        $sub.Text = (L 'wird gestartet ...' 'starting ...')
        $sub.AutoSize = $true
        $sub.Font = New-Object System.Drawing.Font('Segoe UI',11)
        $sub.ForeColor = [System.Drawing.Color]::FromArgb(90,100,110)
        $sub.Location = New-Object System.Drawing.Point(153,93)
        $sub.BackColor = [System.Drawing.Color]::Transparent
        $ver = New-Object System.Windows.Forms.Label
        $ver.Text = 'Version v' + $UpdaterVersion
        $ver.AutoSize = $true
        $ver.ForeColor = [System.Drawing.Color]::FromArgb(150,158,166)
        $ver.Location = New-Object System.Drawing.Point(154,122)
        $ver.BackColor = [System.Drawing.Color]::Transparent
        $pb = New-Object System.Windows.Forms.ProgressBar
        $pb.Style = 'Marquee'
        $pb.MarqueeAnimationSpeed = 30
        $pb.Size = New-Object System.Drawing.Size(344,10)
        $pb.Location = New-Object System.Drawing.Point(52,180)
        $splash.Controls.AddRange(@($pic,$t,$sub,$ver,$pb,$strip))
        $splashTimer = New-Object System.Windows.Forms.Timer
        $splashTimer.Interval = [int]($SplashSeconds * 1000)
        $splashTimer.Add_Tick({ $splashTimer.Stop(); $splash.Close() })
        $splash.Add_Shown({ $splash.Activate(); $splashTimer.Start() })
        [void]$splash.ShowDialog()
        $splashTimer.Dispose()
        $splash.Dispose()
    } catch {}
}

function Start-CraftWindow {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Show-CraftSplash
    $sync = New-GuiSync
    $ui = @{ InfoIndex=0; WarnIndex=0; ErrIndex=0; ShownQuestion=''; PendingQuestion=$null
             Busy=$false; Finished=$false; CloseWhenDone=$false; Items=@{}; Rank=@{}; Index=@{} }
    Write-Host ((L 'Craft Updater {0} laeuft im Fenster. Dieses Konsolenfenster bitte offen lassen - es zeigt die Einzelheiten.' 'Craft Updater {0} is running in its window. Please leave this console window open - it shows the details.') -f $UpdaterVersion) -ForegroundColor Cyan

    # --- Background run: the same file in the same process, linked to the window ---
    # The background run uses the same language as the window.
    $env:CRAFT_UPDATER_LANG = $(if ($UiGerman) { 'de' } else { 'en' })
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $sessionState.ExecutionPolicy = Get-ExecutionPolicy
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    [void]$worker.AddCommand($ScriptPath).AddParameter('GuiSync',$sync)
    if ($Ausfuehrlich) { [void]$worker.AddParameter('Ausfuehrlich',$true) }
    $inputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputData.Complete()
    $outputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

    # --- Window ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Craft Updater v' + $UpdaterVersion
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(640,548)
    $form.MinimumSize = New-Object System.Drawing.Size(560,508)
    $form.Font = New-Object System.Drawing.Font('Segoe UI',9)
    $form.BackColor = [System.Drawing.Color]::White
    # Sloth icon for the window; falls back to the system icon if the file is missing.
    try {
        if (Test-Path -LiteralPath $IconPath -PathType Leaf) { $form.Icon = New-Object System.Drawing.Icon($IconPath) }
        else { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($MsiExecPath) }
    } catch { try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($MsiExecPath) } catch {} }

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 66
    $header.BackColor = [System.Drawing.Color]::FromArgb($BrandColor[0],$BrandColor[1],$BrandColor[2])
    # Sloth picture in the header (left).
    $headerIcon = $null
    try {
        $headerImg = $null
        if (Test-Path -LiteralPath $HeaderImagePath -PathType Leaf) {
            # Load from memory so the file is not locked.
            $hb = [IO.File]::ReadAllBytes($HeaderImagePath)
            $headerImg = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,$hb)))
        } elseif (Test-Path -LiteralPath $IconPath -PathType Leaf) {
            $headerImg = (New-Object System.Drawing.Icon($IconPath,48,48)).ToBitmap()
        }
        if ($null -ne $headerImg) {
            $headerIcon = New-Object System.Windows.Forms.PictureBox
            $headerIcon.Image = $headerImg
            $headerIcon.SizeMode = 'Zoom'
            $headerIcon.Size = New-Object System.Drawing.Size(50,46)
            $headerIcon.Location = New-Object System.Drawing.Point(12,10)
            $headerIcon.BackColor = [System.Drawing.Color]::Transparent
        }
    } catch { $headerIcon = $null }
    $textLeft = if ($null -ne $headerIcon) { 70 } else { 16 }
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Craft Updater'
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point($textLeft,8)
    $titleVersion = New-Object System.Windows.Forms.Label
    $titleVersion.Text = 'v' + $UpdaterVersion
    $titleVersion.ForeColor = [System.Drawing.Color]::FromArgb(236,217,230)
    $titleVersion.Font = New-Object System.Drawing.Font('Segoe UI',10)
    $titleVersion.AutoSize = $true
    $titleVersion.Location = New-Object System.Drawing.Point(($textLeft + $title.PreferredWidth + 2),17)
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = (L 'Hält deine Craft-Programme sicher und aktuell' 'Keeps your Craft programs safe and up to date')
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(236,217,230)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(($textLeft + 2),40)
    if ($null -ne $headerIcon) { $header.Controls.Add($headerIcon) }
    $header.Controls.AddRange(@($title,$titleVersion,$subtitle))

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.HeaderStyle = 'Nonclickable'
    # Double buffering against flicker (ListView only exposes the property as protected -> reflection).
    try { $list.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($list, $true, $null) } catch {}
    $list.Location = New-Object System.Drawing.Point(16,82)
    $list.Size = New-Object System.Drawing.Size(608,312)
    $list.Anchor = 'Top,Bottom,Left,Right'
    [void]$list.Columns.Add((L 'Programm' 'Program'),130)
    [void]$list.Columns.Add((L 'Installiert' 'Installed'),95)
    [void]$list.Columns.Add((L 'Neu' 'New'),95)
    [void]$list.Columns.Add('Status',260)
    foreach ($program in $Programs) {
        $item = New-Object System.Windows.Forms.ListViewItem($program.Name)
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add((L 'Wartet ...' 'Waiting ...'))
        $item.ForeColor = [System.Drawing.Color]::Gray
        $item.UseItemStyleForSubItems = $true
        [void]$list.Items.Add($item)
        $ui.Index[$program.Name] = $ui.Index.Count
        $ui.Rank[$program.Name] = 1
        $ui.Items[$program.Name] = $item
    }

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(16,404)
    $status.Size = New-Object System.Drawing.Size(608,38)
    $status.Anchor = 'Bottom,Left,Right'
    $status.Text = [string]$sync.StatusText
    $status.Padding = New-Object System.Windows.Forms.Padding(0,2,0,0)

    # Tick/cross at the end as its own label, in a font that contains the character itself
    # (inside the text it came from a fallback font and was clipped on the left).
    $mark = New-Object System.Windows.Forms.Label
    $mark.Location = New-Object System.Drawing.Point(14,400)
    $mark.Size = New-Object System.Drawing.Size(30,30)
    $mark.Anchor = 'Bottom,Left'
    $mark.TextAlign = 'MiddleCenter'
    $mark.Font = New-Object System.Drawing.Font('Segoe UI Symbol',14,[System.Drawing.FontStyle]::Bold)
    $mark.Visible = $false

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(16,446)
    $progress.Size = New-Object System.Drawing.Size(608,18)
    $progress.Anchor = 'Bottom,Left,Right'
    $progress.Maximum = [math]::Max(1,$Programs.Count)

    # Small copyright line at the bottom left; the address opens the project page.
    $footerText = [char]0x00A9 + ' 2026 slothworks ' + [char]0x00B7 + ' '
    $footerLink = New-Object System.Windows.Forms.LinkLabel
    $footerLink.AutoSize = $true
    $footerLink.Font = New-Object System.Drawing.Font('Segoe UI',8)
    $footerLink.ForeColor = [System.Drawing.Color]::FromArgb(130,138,146)
    $footerLink.LinkColor = [System.Drawing.Color]::FromArgb(110,118,126)
    $footerLink.ActiveLinkColor = [System.Drawing.Color]::FromArgb($BrandColor[0],$BrandColor[1],$BrandColor[2])
    $footerLink.LinkBehavior = 'HoverUnderline'
    $footerLink.Text = $footerText + ($ProjectUrl -replace '^https://','')
    $footerLink.LinkArea = New-Object System.Windows.Forms.LinkArea($footerText.Length, ($footerLink.Text.Length - $footerText.Length))
    $footerLink.Location = New-Object System.Drawing.Point(14,522)
    $footerLink.Anchor = 'Bottom,Left'
    $footerLink.Add_LinkClicked({ [void](Open-ProjectPage) })

    $btnReport = New-Object System.Windows.Forms.Button
    $btnReport.Text = (L 'Fehlerbericht öffnen' 'Open error report')
    $btnReport.Location = New-Object System.Drawing.Point(16,480)
    $btnReport.Size = New-Object System.Drawing.Size(150,32)
    $btnReport.Anchor = 'Bottom,Left'
    $btnReport.Visible = $false

    $btnNotes = New-Object System.Windows.Forms.Button
    $btnNotes.Text = (L 'Was ist neu?' "What's new?")
    $btnNotes.Location = New-Object System.Drawing.Point(176,480)
    $btnNotes.Size = New-Object System.Drawing.Size(124,32)
    $btnNotes.Anchor = 'Bottom,Left'
    $btnNotes.Visible = $false
    $notesTip = New-Object System.Windows.Forms.ToolTip
    $notesTip.SetToolTip($btnNotes,(L 'Zeigt die Neuerungen des angeklickten Programms (oder Doppelklick auf ein Programm).' 'Shows what is new in the selected program (or double-click a program).'))

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = (L 'Installieren' 'Install')
    $btnInstall.Location = New-Object System.Drawing.Point(366,480)
    $btnInstall.Size = New-Object System.Drawing.Size(124,32)
    $btnInstall.Anchor = 'Bottom,Right'
    $btnInstall.Enabled = $false

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = (L 'Schließen' 'Close')
    $btnClose.Location = New-Object System.Drawing.Point(500,480)
    $btnClose.Size = New-Object System.Drawing.Size(124,32)
    $btnClose.Anchor = 'Bottom,Right'
    $btnClose.Enabled = $false

    $form.Controls.AddRange(@($list,$mark,$status,$progress,$btnReport,$btnNotes,$btnInstall,$btnClose,$footerLink,$header))

    # --- Finish when the background run is done ---
    $finish = {
        Write-WorkerOutput $worker $ui
        $crash = ''
        try { [void]$worker.EndInvoke($async) }
        catch {
            $ex = $_.Exception
            while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
            $crash = $ex.Message
        }
        if ($crash -eq '' -and $worker.InvocationStateInfo.State -eq 'Failed') { $crash = [string]$worker.InvocationStateInfo.Reason.Message }
        Write-WorkerOutput $worker $ui
        if ($outputData.Count -gt 0) { Write-Host (@($outputData) | Out-String) }
        $ui.Finished = $true
        $ui.PendingQuestion = $null
        $ui.ExitCode = if ($crash) { 1 } else { [int]$sync.ExitCode }
        $result = Get-SummaryText $sync.Summary $crash
        $doneMark = if ($result.Count -ge 3 -and $result[2]) { [string]$result[2] } else { '' }
        if ($doneMark) {
            $mark.Text = $doneMark
            $mark.ForeColor = $result[1]
            $mark.Visible = $true
            $status.Left = 46
            $status.Width = $form.ClientSize.Width - 46 - 16
        }
        $status.Text = [string]$result[0]
        $status.ForeColor = $result[1]
        $status.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
        $progress.Visible = $false
        $btnInstall.Enabled = $false
        $btnClose.Text = (L 'Schließen' 'Close')
        $btnClose.Enabled = $true
        if ($sync.ErrorReport) { $btnReport.Visible = $true }
        Write-Host ''
        Write-Host ((L 'Fertig. Rueckgabecode: ' 'Done. Exit code: ') + $ui.ExitCode) -ForegroundColor Cyan
        if ($ui.CloseWhenDone) { $form.Close() }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        if ($ui.Busy -or $ui.Finished) { return }
        $ui.Busy = $true
        try {
            Write-WorkerOutput $worker $ui
            $rowsChanged = $false
            foreach ($key in @($sync.Rows.Keys)) {
                $row = $sync.Rows[$key]
                $item = $ui.Items[[string]$key]
                if ($null -eq $row -or $null -eq $item) { continue }
                $inst = Format-VersionText ([string]$row.Installed)
                $newText = $(if ($row.Status -eq 'Aktuell' -or $row.Status -eq 'Nicht installiert') { '' } else { Format-VersionText ([string]$row.Latest) })
                $stText = Get-FriendlyStatus ([string]$row.Status)
                $stCol = Get-StatusColor ([string]$row.Status)
                $ui.Rank[[string]$key] = Get-SortRank ([string]$row.Status)
                # Only touch rows that really changed, otherwise the list flickers on every tick.
                if (($item.SubItems[1].Text -ne $inst) -or ($item.SubItems[2].Text -ne $newText) -or ($item.SubItems[3].Text -ne $stText) -or ($item.ForeColor.ToArgb() -ne $stCol.ToArgb())) {
                    if (-not $rowsChanged) { $list.BeginUpdate(); $rowsChanged = $true }
                    if ($item.SubItems[1].Text -ne $inst) { $item.SubItems[1].Text = $inst }
                    if ($item.SubItems[2].Text -ne $newText) { $item.SubItems[2].Text = $newText }
                    if ($item.SubItems[3].Text -ne $stText) { $item.SubItems[3].Text = $stText }
                    if ($item.ForeColor.ToArgb() -ne $stCol.ToArgb()) { $item.ForeColor = $stCol }
                }
            }
            if ($rowsChanged) {
                $list.EndUpdate()
                # Sort: updates on top, not installed at the bottom (only when the order changes).
                $order = @($Programs | ForEach-Object { [string]$_.Name } | Sort-Object @{Expression={ $ui.Rank[$_] }}, @{Expression={ $ui.Index[$_] }})
                $current = @($list.Items | ForEach-Object { $_.Text })
                if (($current -join '|') -ne ($order -join '|')) {
                    $list.BeginUpdate()
                    $list.Items.Clear()
                    foreach ($n in $order) { [void]$list.Items.Add($ui.Items[$n]) }
                    $list.EndUpdate()
                }
            }
            if ($status.Text -ne [string]$sync.StatusText) { $status.Text = [string]$sync.StatusText }
            if (-not $btnNotes.Visible -and $sync.Notes.Count -gt 0) { $btnNotes.Visible = $true }
            $max = [math]::Max(1,[int]$sync.ProgressMax)
            if ($progress.Maximum -ne $max) { $progress.Maximum = $max }
            $pval = [math]::Min($max,[math]::Max(0,[int]$sync.ProgressValue))
            if ($progress.Value -ne $pval) { $progress.Value = $pval }
            # Show the bar only while searching and installing, not while waiting for approval.
            $wantBar = ($null -eq $ui.PendingQuestion) -and ([string]$sync.Phase -in @('Suche','Installieren'))
            if ($progress.Visible -ne $wantBar) { $progress.Visible = $wantBar }

            $question = $sync.Question
            if ($null -ne $question -and $ui.ShownQuestion -ne $question.Id) {
                $ui.ShownQuestion = $question.Id
                if ($question.Kind -eq 'Updates') {
                    # Approval only through the "Install" button and the confirmation.
                    $ui.PendingQuestion = $question
                    $btnInstall.Enabled = $true
                    $btnClose.Text = (L 'Nicht installieren' 'Do not install')
                    $btnClose.Enabled = $true
                    [void]$btnInstall.Focus()
                } else {
                    $timer.Stop()
                    try {
                        $answer = [System.Windows.Forms.MessageBox]::Show($form,[string]$question.Message,[string]$question.Title,
                            [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question,
                            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                        $sync.Answer = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
                    } finally { $timer.Start() }
                }
            }
            if ($async.IsCompleted) { & $finish }
        } finally { $ui.Busy = $false }
    })

    $btnInstall.Add_Click({
        $question = $ui.PendingQuestion
        if ($null -eq $question) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show($form,[string]$question.Message,[string]$question.Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if ($null -eq $ui.PendingQuestion) { return }
        $ui.PendingQuestion = $null
        $btnInstall.Enabled = $false
        $btnClose.Text = (L 'Schließen' 'Close')
        $btnClose.Enabled = $false
        $sync.Answer = $true
    })
    $btnClose.Add_Click({
        if ($null -ne $ui.PendingQuestion) {
            $ui.PendingQuestion = $null
            $btnInstall.Enabled = $false
            $btnClose.Text = (L 'Schließen' 'Close')
            $btnClose.Enabled = $false
            $sync.Answer = $false
            return
        }
        if ($ui.Finished) { $form.Close() }
    })
    # "What's new?": release notes of the selected program, or of the first one with notes.
    $showNotes = {
        $name = $null
        if ($list.SelectedItems.Count -gt 0) {
            $picked = [string]$list.SelectedItems[0].Text
            if (-not $sync.Notes.ContainsKey($picked)) {
                # A program without an update was clicked: say so instead of showing another program.
                $withNotes = @(foreach ($it in $list.Items) { $n = [string]$it.Text; if ($sync.Notes.ContainsKey($n)) { $n } })
                $msg = (L 'Für {0} gibt es kein Update, also auch nichts Neues.' 'There is no update for {0}, so there is nothing new.') -f $picked
                if ($withNotes.Count -gt 0) { $msg += "`r`n`r`n" + ((L 'Neuerungen gibt es für: {0}. Doppelklick auf das Programm zeigt die Änderungen an.' 'What is new is available for: {0}. Double-click the program to show the changes.') -f ($withNotes -join ', ')) }
                [void][System.Windows.Forms.MessageBox]::Show($form,$msg,(L 'Was ist neu?' "What's new?"),[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $name = $picked
        }
        if (-not $name) { foreach ($it in $list.Items) { if ($sync.Notes.ContainsKey([string]$it.Text)) { $name = [string]$it.Text; break } } }
        if (-not $name) { return }
        $note = $sync.Notes[$name]
        $body = [string]$note.Text
        if (-not $body) { $body = (L 'Zu diesem Update haben die Entwickler keine Beschreibung geschrieben (oft steht auf GitHub nur ein Link zur Code-Übersicht). Alle Änderungen findest du über den Link unten.' 'The developers did not write a description for this update (often GitHub only shows a link to the code comparison). You can find all changes via the link below.') }
        $others = @(foreach ($it in $list.Items) { $n = [string]$it.Text; if ($n -ne $name -and $sync.Notes.ContainsKey($n)) { $n } })
        $footer = ''
        if ($others.Count -gt 0) {
            $footer = (L 'Weitere Updates: {0}. Doppelklick auf ein Programm in der Liste zeigt die Änderungen an.' 'More updates: {0}. Double-click a program in the list to show the changes.') -f ($others -join ', ')
        }
        Show-ReleaseNotesDialog $form ((L 'Was ist neu in {0} {1}?' "What's new in {0} {1}?") -f $name,(Format-VersionText ([string]$note.Version))) $body ([string]$note.Url) $footer
    }
    $btnNotes.Add_Click({ & $showNotes })
    $list.Add_DoubleClick({ & $showNotes })
    $btnReport.Add_Click({
        try { Start-Process -FilePath (Join-Path $env:SystemRoot 'notepad.exe') -ArgumentList ('"' + [string]$sync.ErrorReport + '"') }
        catch { [void][System.Windows.Forms.MessageBox]::Show($form,((L 'Bericht liegt hier: ' 'Report location: ') + [string]$sync.ErrorReport),(L 'Fehlerbericht' 'Error report')) }
    })
    $form.Add_FormClosing({
        param($closingForm,$closeArgs)
        if ($ui.Finished) { return }
        if ($closeArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) { $sync.WindowClosed = $true; return }
        $closeArgs.Cancel = $true
        if ($null -ne $ui.PendingQuestion) {
            # Closing during the approval = do not install; the window closes afterwards.
            $ui.PendingQuestion = $null
            $ui.CloseWhenDone = $true
            $btnInstall.Enabled = $false
            $btnClose.Enabled = $false
            $sync.Answer = $false
            return
        }
        [void][System.Windows.Forms.MessageBox]::Show($form,(L 'Der Updater arbeitet gerade. Bitte warte kurz - danach lässt sich das Fenster schließen.' 'The updater is busy. Please wait a moment - then the window can be closed.'),'Craft Updater',
            [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $form.Add_Shown({ Set-CraftTitleBar $form; $form.Activate(); $timer.Start() })

    $async = $worker.BeginInvoke($inputData,$outputData)
    try {
        [void]$form.ShowDialog()
    } finally {
        $sync.WindowClosed = $true
        $timer.Stop()
        $timer.Dispose()
        # When the run is finished, PowerShell ends right after this (Environment.Exit), which
        # frees everything at once. Closing the background runspace first only delayed the exit.
        if (-not $ui.Finished) { $form.Dispose() }
    }
    $script:CraftWindowFinished = [bool]$ui.Finished
    return [int]$ui.ExitCode
}

# ============================================================================
# 8. START
# ============================================================================
$SingleRunMutex = New-Object System.Threading.Mutex($false, $MutexName)
# Normal start: open the window. The run starts again inside it in the background
# (with -GuiSync) and takes the mutex there.
if (Test-UseWindow) {
    $SingleRunMutex.Dispose()
    $windowExitCode = Start-CraftWindow
    # The run is finished and the window is closed: end PowerShell for sure, so that the
    # console window closes too (otherwise it sometimes stayed open after installations).
    # Everything is already written (logs, reports). A normal shutdown of PowerShell with the
    # window libraries loaded still takes a moment, during which the console lingers in the
    # taskbar - so the process is ended at once. (The launcher only shows the exit code.)
    if ($script:CraftWindowFinished) {
        try { [System.Diagnostics.Process]::GetCurrentProcess().Kill() } catch {}
        [Environment]::Exit([int]$windowExitCode)
    }
    if ($windowExitCode -ne 0) { exit $windowExitCode }
    return
}
$OwnMutex = $false
try { $OwnMutex = $SingleRunMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $OwnMutex = $true }
if (-not $OwnMutex) { $SingleRunMutex.Dispose(); throw (L 'Craft-Updater laeuft bereits in einer anderen Sitzung.' 'Craft Updater is already running in another session.') }
try {
    Initialize-DataFolder
    $State.ErrorFolderReady = Initialize-ErrorFolder
    Read-RateLimitCooldown
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Detect the platform (handle 32-bit PowerShell on 64-bit Windows correctly).
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToLowerInvariant()) {
        'amd64' { $Platform='x64'; $ArchPattern='(?i)(^|[._-])(x64|amd64|x86_64)([._-]|$)' }
        'arm64' { $Platform='arm64'; $ArchPattern='(?i)(^|[._-])(arm64|aarch64)([._-]|$)' }
        'x86'   { $Platform='x86'; $ArchPattern='(?i)(^|[._-])(x86(?!_64)|i386|i686)([._-]|$)' }
        default { throw ((L 'Nicht unterstuetzte Architektur: ' 'Unsupported architecture: ') + $arch) }
    }
    # Snapshots for the search; everything is read fresh again before each installation.
    $InstalledSnapshot = @(Get-ItemProperty -Path $RegPaths -ErrorAction SilentlyContinue)
    $ProcessSnapshot = @(Get-Process -ErrorAction SilentlyContinue)

    Write-Host ((L 'Craft Updater v{0} | {1} | {2} Programme | sichere Downloads + eine Freigabe' 'Craft Updater v{0} | {1} | {2} programs | verified downloads + one approval') -f $UpdaterVersion,$Platform,$Programs.Count) -ForegroundColor Cyan
    if ($NurPruefen) { Write-Host (L 'NUR PRUEFEN: keine MSI-Installation, keine Freigabe-Abfrage.' 'CHECK ONLY: no MSI installation, no approval question.') -ForegroundColor Yellow }
    if (-not (Test-Path -LiteralPath $MsiExecPath -PathType Leaf)) { throw (L 'Windows Installer nicht gefunden' 'Windows Installer not found') }
    if (Test-Path -LiteralPath (Join-Path $OldInstallDir 'Craft-Updater-STARTEN.cmd') -PathType Leaf) {
        Write-Host ((L 'Hinweis: Die alte Kopie in {0} wird nicht mehr gebraucht und kann geloescht werden (siehe ANLEITUNG).' 'Note: the old copy in {0} is no longer needed and can be deleted (see INSTRUCTIONS).') -f $OldInstallDir) -ForegroundColor DarkGray
    }

    if ($Diagnose) { Invoke-DiagnoseRun } else { Invoke-UpdateRun }
} finally {
    if ($OwnMutex) { try { $SingleRunMutex.ReleaseMutex() } catch {} }
    $SingleRunMutex.Dispose()
}

# No self-deletion and no copy to Program Files: the updater runs from the extracted
# folder (friendly to virus scanners). To be replaced later by a signed .exe.

# Publish the exit code for the CMD launcher (or for the window).
if ($null -ne $GuiSync) { $GuiSync.ExitCode = $State.ExitCode; return }
if ($State.ExitCode -ne 0) { exit $State.ExitCode }
