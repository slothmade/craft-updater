# Craft Updater - offline tests (Windows PowerShell 5.1)
# Loads only the FUNCTIONS of the updater and checks them with made-up data.
# No downloads, no installation, no administrator rights needed.
# The updater's own data (%LOCALAPPDATA%\CraftUpdater) is NOT touched;
# everything runs in a temporary folder that is deleted at the end.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Craft-Updater-Tests.ps1"
# Without arguments the highest version in .\Craft-Updater-v*-Portable\ is tested.
# A specific file:  ... -File ".\Craft-Updater-Tests.ps1" -UpdaterPath "path\to\file.ps1"
#
# The tests run the updater in German (its internal texts are checked word by word);
# section [13] checks the English texts separately.
param([string]$UpdaterPath = '')
$ErrorActionPreference = 'Stop'
if (-not $UpdaterPath) {
    $candidates = @(foreach ($dir in @(Get-ChildItem -LiteralPath $PSScriptRoot -Directory -Filter 'Craft-Updater-v*-Portable')) {
        Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'Craft-Auto-Updater-v*-Portable.ps1'
    })
    $candidates = @($candidates | Where-Object { $_.Name -match '^Craft-Auto-Updater-v(\d+(\.\d+){1,3})-Portable\.ps1$' })
    if ($candidates.Count -eq 0) { throw ('No updater found in ' + $PSScriptRoot + '\Craft-Updater-v*-Portable.') }
    $UpdaterPath = ($candidates | Sort-Object { [version](($_.Name -replace '^Craft-Auto-Updater-v','') -replace '-Portable\.ps1$','') } -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path -LiteralPath $UpdaterPath)) { throw ('Updater not found: ' + $UpdaterPath) }
# Full path: on some PCs (and on GitHub's test machines) TEMP is a short 8.3 path like RUNNER~1.
$TestDir = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('CraftUpdaterTest-' + [guid]::NewGuid().ToString('N'))))
[void](New-Item -ItemType Directory -Path $TestDir)

# --- Load the updater: everything BEFORE the start section (configuration + functions only) ---
$UpdaterText = Get-Content -LiteralPath $UpdaterPath -Raw -Encoding UTF8
$cut = $UpdaterText.IndexOf('$SingleRunMutex = New-Object System.Threading.Mutex')
$dirLine = '$ScriptDirectory = Split-Path -Parent $PSCommandPath'
if ($cut -lt 0 -or $UpdaterText.IndexOf($dirLine) -lt 0) { throw 'Unexpected updater layout; the tests cannot be loaded.' }
$loadText = $UpdaterText.Substring(0,$cut).Replace($dirLine, '$ScriptDirectory = $TestDir')
$savedLang = $env:CRAFT_UPDATER_LANG
$env:CRAFT_UPDATER_LANG = 'de'
try { . ([scriptblock]::Create($loadText)) } finally { $env:CRAFT_UPDATER_LANG = $savedLang }

# Point all paths to the test folder.
$Root = Join-Path $TestDir 'Data'
$LegacyRoots = @(Join-Path $TestDir 'Legacy')
$Verified = Join-Path $Root 'Verified'
$Reports = Join-Path $Root 'Reports'
$InstallerLogDir = Join-Path $Reports 'MSI-Logs'
$RecoveryDir = Join-Path $Reports 'Recovery'
$CacheRoot = Join-Path $Root 'ReleaseCache'
$CooldownPath = Join-Path $CacheRoot 'RateLimit.json'
$HistoryPath = Join-Path $Reports 'History.jsonl'
$ErrorFolder = Join-Path $TestDir 'Fehlermeldung'
$OldInstallDir = Join-Path $TestDir 'Programme\Craft Updater'
# Take the real architecture patterns from the updater.
$X64Pattern = [regex]::Match($UpdaterText,"'amd64' \{ \`$Platform='x64'; \`$ArchPattern='([^']+)'").Groups[1].Value
$X86Pattern = [regex]::Match($UpdaterText,"'x86'   \{ \`$Platform='x86'; \`$ArchPattern='([^']+)'").Groups[1].Value
if (-not $X64Pattern -or -not $X86Pattern) { throw 'Architecture patterns not found in the updater.' }
$Platform = 'x64'; $ArchPattern = $X64Pattern

# --- Replacements for functions that need the network, registry or Windows Installer ---
$Fake = @{ Release = $null; CandidateError = @{}; Language = '1033'; Answer = ''; Asked = 0; ProbeLock = $false; LockSeen = $false }
function Test-IsAdmin { return $true }
# Replaces user input; counts how often it was asked.
function Read-Host([string]$Prompt) { $Fake.Asked++; return $Fake.Answer }
function Get-ReleaseCached([string]$repo) { return $Fake.Release }
function Get-MsiProductInfo([string]$productCode,[string]$property) { return $Fake.Language }
function Test-InstallationCandidate($item) {
    if ($Fake.ProbeLock) {
        # Try to change the installer while the updater holds it: this must fail.
        try { $w = [IO.File]::Open($item.File,'Open','ReadWrite','ReadWrite'); $w.Dispose() } catch { $Fake.LockSeen = $true }
    }
    $message = $Fake.CandidateError[$item.Program.Name]
    if ($message) { throw $message }
    return [pscustomobject]@{ Item=$item; Check=[pscustomobject]@{ Signer='Learning Machines Inc' } }
}

# --- Test framework ---
$Passed = 0
$Failures = New-Object 'System.Collections.Generic.List[string]'
function Test-Case([string]$Name,[scriptblock]$Body) {
    try {
        $result = & $Body 6>$null 3>$null
        if ($result -is [bool] -and $result) { $script:Passed++; Write-Host ('  OK      ' + $Name) -ForegroundColor Green }
        else { $Failures.Add($Name + ' -> result: ' + ($result -join ' | ')); Write-Host ('  FAILED  ' + $Name + ' -> ' + ($result -join ' | ')) -ForegroundColor Red }
    } catch {
        $Failures.Add($Name + ' -> exception: ' + $_.Exception.Message)
        Write-Host ('  FAILED  ' + $Name + ' -> exception: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
function Get-ThrowMessage([scriptblock]$Body) {
    try { $null = & $Body 6>$null 3>$null; return '' } catch { return $_.Exception.Message }
}
function Reset-State {
    $State.Results.Clear(); $State.Pending.Clear(); $State.Eligible.Clear()
    $State.SecurityBlocked=$false; $State.StopInstallBatch=$false; $State.PreserveInstallers=$false
    $State.RebootRequired=$false; $State.InstallerFailures=0; $State.ExitCode=0; $State.ErrorFolderReady=$false
    $State.RateLimited=$false; $State.RateLimitUntil=[datetimeoffset]::MinValue
    $Fake.CandidateError = @{}; $Fake.Release = $null; $Fake.Language = '1033'
    $State.Warnings.Clear()
    $State.Notes.Clear()
    $Fake.ProbeLock = $false; $Fake.LockSeen = $false
}
function Get-LastResult { return $State.Results[$State.Results.Count-1] }
function New-FakeItem([string]$name) {
    $program = $Programs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    return [pscustomobject]@{ Program=$program; Local='0.12.0'; Latest='v0.14.0'; Version=[version]'0.14.0.0'
        File=(Join-Path $Verified ($name + '\0.14.0.0\' + $name.ToLower() + '.msi')); ExpectedHash=('A'*64); Check=$null; RegistryApp=$null }
}
function New-FakeInstaller($item) {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $item.File))
    Set-Content -LiteralPath $item.File -Value 'fake msi'
    return $item
}
function New-FakeRelease([string]$tag,$assets) {
    return [pscustomobject]@{ tag_name=$tag; draft=$false; prerelease=$false; assets=@($assets) }
}
function New-FakeAsset([string]$name,[string]$url,[string]$digest=('sha256:' + ('a'*64))) {
    return [pscustomobject]@{ state='uploaded'; name=$name; digest=$digest; browser_download_url=$url; size=100 }
}
$WordCraftInstalled = @([pscustomobject]@{ DisplayName='WordCraft'; DisplayVersion='0.12.0'; Publisher='Learning Machines Inc'
    PSChildName='{0B51F5A0-FCCB-4901-8D3E-D05872798D69}'; WindowsInstaller=1
    PSPath='Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0B51F5A0-FCCB-4901-8D3E-D05872798D69}' })
$GoodUrl = 'https://github.com/storytold/wordcraft/releases/download/v0.14.0/wordcraft-0.14.0-windows-x64.msi'

try {
    Write-Host ('Craft Updater offline tests | updater: ' + $UpdaterPath) -ForegroundColor Cyan

    Write-Host "`n[1] Data folder"
    Test-Case 'Old data folder is taken over once' {
        $legacy = $LegacyRoots[0]
        [void](New-Item -ItemType Directory -Path (Join-Path $legacy 'Reports') -Force)
        Set-Content -LiteralPath (Join-Path $legacy 'Reports\alt.txt') -Value 'x'
        Initialize-DataFolder
        (Test-Path (Join-Path $Root 'Reports\alt.txt')) -and -not (Test-Path $legacy) -and (Test-Path $Verified) -and (Test-Path $CacheRoot)
    }
    Test-Case 'Error folder only exists while there are reports' {
        if (Test-Path $ErrorFolder) { Remove-Item -LiteralPath $ErrorFolder -Recurse -Force }
        $ok = (Initialize-ErrorFolder) -and -not (Test-Path $ErrorFolder)
        [void](New-Item -ItemType Directory -Path $ErrorFolder)
        $ok = $ok -and (Initialize-ErrorFolder) -and -not (Test-Path $ErrorFolder)
        [void](New-Item -ItemType Directory -Path $ErrorFolder); Set-Content -LiteralPath (Join-Path $ErrorFolder 'notiz.txt') -Value 'x'
        $ok = $ok -and (Initialize-ErrorFolder) -and (Test-Path (Join-Path $ErrorFolder 'notiz.txt'))
        Remove-Item -LiteralPath $ErrorFolder -Recurse -Force
        $ok
    }

    Write-Host "`n[2] Versions and publishers"
    Test-Case 'v0.14.1 is newer than 0.14.0' { (Parse-Version 'v0.14.1') -gt (Parse-Version '0.14.0') }
    Test-Case '0.14 equals 0.14.0.0' { (Parse-Version '0.14') -eq [version]'0.14.0.0' }
    Test-Case 'Invalid version gives nothing' { ($null -eq (Parse-Version 'abc')) -and ($null -eq (Parse-Version '1.2.3.4.5')) }
    Test-Case 'Publisher Inc and LLC allowed' { (Test-AllowedRegistryPublisher 'Learning Machines Inc') -and (Test-AllowedRegistryPublisher 'Learning Machines, LLC') }
    Test-Case 'Foreign publisher rejected' { -not (Test-AllowedRegistryPublisher 'Learning Machine Inc') -and -not (Test-AllowedRegistryPublisher '') }
    Test-Case 'Thumbprint with spaces is normalised' { (Norm-Thumbprint 'ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01') -eq 'ABCDEF0123456789ABCDEF0123456789ABCDEF01' }
    Test-Case 'Invalid thumbprint is rejected' { (Get-ThrowMessage { Norm-Thumbprint '1234' }) -like '*Thumbprint*' }

    Write-Host "`n[3] Program and architecture detection"
    $wordPattern = ($Programs | Where-Object { $_.Name -eq 'WordCraft' }).Pattern
    $photoPattern = ($Programs | Where-Object { $_.Name -eq 'PhotoCraft' }).Pattern
    Test-Case 'WordCraft pattern matches "WordCraft", not "WordCraftX"' { ('WordCraft' -match $wordPattern) -and -not ('WordCraftX' -match $wordPattern) }
    Test-Case 'PhotoCraft pattern also matches "FotoCraft"' { 'FotoCraft 0.19' -match $photoPattern }
    Test-Case 'x64 pattern: x64 MSI yes, arm64/x86 no' { ('wordcraft-0.14.0-windows-x64.msi' -match $X64Pattern) -and -not ('wordcraft-0.14.0-windows-arm64.msi' -match $X64Pattern) -and -not ('wordcraft-0.14.0-windows-x86.msi' -match $X64Pattern) }
    Test-Case 'x86 pattern does not match x86_64' { ('app-x86.msi' -match $X86Pattern) -and -not ('app-x86_64.msi' -match $X86Pattern) }
    Test-Case 'Registry search always returns a list (0 and 1 hits)' { ((Find-RegistryEntries @() $wordPattern).Count -eq 0) -and ((Find-RegistryEntries $WordCraftInstalled $wordPattern).Count -eq 1) }
    Test-Case 'Two non-MSI entries count as ambiguous' {
        $two = @([pscustomobject]@{DisplayName='WordCraft';WindowsInstaller=0;PSChildName='a';PSPath='a'},[pscustomobject]@{DisplayName='WordCraft';WindowsInstaller=0;PSChildName='b';PSPath='b'})
        (Get-ThrowMessage { Resolve-RegistryApp $two 'WordCraft' }) -like 'Mehrdeutige*'
    }

    Write-Host "`n[4] Security check of the MSI package"
    $dummy = Join-Path $TestDir 'dummy.msi'
    [IO.File]::WriteAllBytes($dummy, [byte[]](1..200))
    $dummyHash = (Get-FileHash -LiteralPath $dummy -Algorithm SHA256).Hash
    $wordProgram = $Programs | Where-Object { $_.Name -eq 'WordCraft' }
    Test-Case 'Wrong SHA256 = security error' {
        (Get-ThrowMessage { Assert-TrustedMsi $dummy ('B'*64) $wordProgram $WordCraftInstalled[0] ([version]'0.14.0.0') }) -eq ($SecurityPrefix + 'SHA256-Pruefung fehlgeschlagen')
    }
    Test-Case 'Unsigned package = security error' {
        $m = Get-ThrowMessage { Assert-TrustedMsi $dummy $dummyHash $wordProgram $WordCraftInstalled[0] ([version]'0.14.0.0') }
        $m.StartsWith($SecurityPrefix)
    }
    Test-Case 'MSI outside the Verified folder is rejected' { (Get-ThrowMessage { Assert-SafeMsiPath $dummy }) -like '*Verified*' }
    Test-Case 'Security marker is not added twice' {
        $m = Get-ThrowMessage { try { throw ($SecurityPrefix + 'X') } catch { throw (Get-SecurityMessage $_) } }
        ($m -eq ($SecurityPrefix + 'X')) -and (Test-IsSecurityMessage $m) -and -not (Test-IsSecurityMessage 'Programm laeuft')
    }

    Write-Host "`n[5] Update search (without download)"
    Test-Case 'Program not installed = "Nicht installiert"' {
        Reset-State; $InstalledSnapshot=@(); $ProcessSnapshot=@()
        Find-ProgramUpdate $wordProgram
        (Get-LastResult).Status -eq 'Nicht installiert'
    }
    Test-Case 'Same version = "Aktuell"' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.12.0' @(New-FakeAsset 'wordcraft-0.12.0-windows-x64.msi' $GoodUrl)
        Find-ProgramUpdate $wordProgram
        (Get-LastResult).Status -eq 'Aktuell'
    }
    Test-Case 'Foreign download address = security error' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @(New-FakeAsset 'wordcraft-0.14.0-windows-x64.msi' 'https://evil.example.com/wordcraft-0.14.0-windows-x64.msi')
        Find-ProgramUpdate $wordProgram
        ((Get-LastResult).Status -eq 'Sicherheitsfehler') -and ((Get-LastResult).Detail -like '*Download-URL*')
    }
    Test-Case 'Foreign repository in the address = security error' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @(New-FakeAsset 'wordcraft-0.14.0-windows-x64.msi' 'https://github.com/someone/wordcraft/releases/download/v0.14.0/wordcraft-0.14.0-windows-x64.msi')
        Find-ProgramUpdate $wordProgram
        (Get-LastResult).Status -eq 'Sicherheitsfehler'
    }
    Test-Case 'File name with a path part = security error' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @(New-FakeAsset '..\wordcraft-0.14.0-windows-x64.msi' $GoodUrl)
        Find-ProgramUpdate $wordProgram
        ((Get-LastResult).Status -eq 'Sicherheitsfehler') -and ((Get-LastResult).Detail -like '*Dateiname*')
    }
    Test-Case 'Missing SHA256 digest = only skipped' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @(New-FakeAsset 'wordcraft-0.14.0-windows-x64.msi' $GoodUrl '')
        Find-ProgramUpdate $wordProgram
        (Get-LastResult).Status -eq 'Uebersprungen'
    }
    Test-Case 'Two matching MSIs = only skipped' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @((New-FakeAsset 'wordcraft-0.14.0-windows-x64.msi' $GoodUrl),(New-FakeAsset 'wordcraft-0.14.0-x64.msi' $GoodUrl))
        Find-ProgramUpdate $wordProgram
        ((Get-LastResult).Status -eq 'Uebersprungen') -and ((Get-LastResult).Detail -like 'Kein eindeutiger*')
    }
    Test-Case 'Only an arm64 MSI available = only skipped' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @(New-FakeAsset 'wordcraft-0.14.0-windows-arm64.msi' $GoodUrl)
        Find-ProgramUpdate $wordProgram
        (Get-LastResult).Status -eq 'Uebersprungen'
    }

    Write-Host "`n[6] Upgrade table"
    $upCode = '{11111111-2222-3333-4444-555555555555}'
    function New-Row([string]$min='0.0.1',[string]$max='',[string]$lang='',[int]$attr=256,[string]$action='WIX_UPGRADE_DETECTED') {
        return [pscustomobject]@{UpgradeCode=$upCode;Min=$min;Max=$max;Language=$lang;Attributes=$attr;Remove='';ActionProperty=$action}
    }
    function New-Package($rows,[bool]$rep=$true) { return [pscustomobject]@{UpgradeRows=$rows;UpgradeError='missing';HasRemoveExistingProducts=$rep} }
    $old = [version]'0.12.0.0'
    Test-Case 'Matching upgrade row is accepted' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row)) $upCode $old '{X}' }) -eq '' }
    Test-Case 'Installed version above VersionMax is rejected' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row '0.0.1' '0.11.0')) $upCode $old '{X}' }) -like 'Keine eindeutige*' }
    Test-Case 'Detect-only row (flag 2) does not count' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row '0.0.1' '' '' 258)) $upCode $old '{X}' }) -like 'Keine eindeutige*' }
    Test-Case 'Foreign language is rejected' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row '0.0.1' '' '1031')) $upCode $old '{X}' }) -like 'Keine eindeutige*' }
    Test-Case 'Language with exclusion flag 1024 is accepted' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row '0.0.1' '' '1031' (256+1024))) $upCode $old '{X}' }) -eq '' }
    Test-Case 'Missing RemoveExistingProducts is rejected' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package @(New-Row) $false) $upCode $old '{X}' }) -like 'RemoveExistingProducts*' }
    Test-Case 'Missing upgrade table is rejected' { (Get-ThrowMessage { Test-MsiUpgradeTable (New-Package $null) $upCode $old '{X}' }) -like '*nicht lesbar oder fehlt*' }

    Write-Host "`n[7] Security errors block everything, single problems only one program"
    Test-Case 'Single problem: only GridCraft skipped, WordCraft ready' {
        Reset-State
        $State.Pending.Add((New-FakeItem 'WordCraft')); $State.Pending.Add((New-FakeItem 'GridCraft'))
        $Fake.CandidateError['GridCraft'] = 'Programm laeuft oder Prozess im Installationsverzeichnis gefunden'
        Invoke-Preflight
        (-not $State.SecurityBlocked) -and ($State.Eligible.Count -eq 1) -and ((Get-LastResult).Status -eq 'Nur Download')
    }
    Test-Case 'Security error at DeckCraft also blocks WordCraft' {
        Reset-State
        $State.Pending.Add((New-FakeItem 'WordCraft')); $State.Pending.Add((New-FakeItem 'DeckCraft'))
        $Fake.CandidateError['DeckCraft'] = $SecurityPrefix + 'SHA256-Pruefung fehlgeschlagen'
        Invoke-Preflight
        $word = @($State.Results | Where-Object { $_.Program -eq 'WordCraft' })[-1]
        $State.SecurityBlocked -and ($word.Status -eq 'Gesperrt')
    }
    Test-Case 'After approval: a program opened meanwhile is only skipped' {
        Reset-State
        $Fake.CandidateError['WordCraft'] = 'Programm laeuft oder Prozess im Installationsverzeichnis gefunden'
        Install-EligibleUpdate ([pscustomobject]@{ Item=(New-FakeInstaller (New-FakeItem 'WordCraft')) })
        ((Get-LastResult).Status -eq 'Nur Download') -and ((Get-LastResult).Detail -like '*Programm laeuft*') -and -not $State.StopInstallBatch
    }
    Test-Case 'After approval: a security error stops all further installations' {
        Reset-State
        $Fake.CandidateError['WordCraft'] = $SecurityPrefix + 'Signatur nicht gueltig: HashMismatch'
        Install-EligibleUpdate ([pscustomobject]@{ Item=(New-FakeInstaller (New-FakeItem 'WordCraft')) })
        ((Get-LastResult).Status -eq 'Sicherheitsfehler') -and $State.StopInstallBatch
    }
    Test-Case 'Check-only mode installs nothing' {
        Reset-State; $NurPruefen = $true
        $State.Eligible.Add([pscustomobject]@{ Item=(New-FakeItem 'WordCraft'); Check=[pscustomobject]@{Signer='Learning Machines Inc'} })
        Invoke-Installation
        (Get-LastResult).Status -eq 'Update bereit (Pruefmodus)'
    }

    Write-Host "`n[8] Final statistics and exit code"
    function Get-ExitCodeFor($rows) {
        Reset-State
        foreach ($r in $rows) { Add-Result $r[0] '' '' $r[1] 'Test' }
        $null = Write-RunSummary
        return $State.ExitCode
    }
    Test-Case 'Up to date + not installed = 0' { (Get-ExitCodeFor @(,@('WordCraft','Aktuell')) ) -eq 0 -and (Get-ExitCodeFor @(@('WordCraft','Aktuell'),@('FigCraft','Nicht installiert'))) -eq 0 }
    Test-Case 'Deliberately declined = 0' { (Get-ExitCodeFor @(@('WordCraft','Update abgelehnt'),@('FigCraft','Nicht installiert'))) -eq 0 }
    Test-Case 'Skipped individually = 1' { (Get-ExitCodeFor @(@('WordCraft','Aktuell'),@('GridCraft','Nur Download'))) -eq 1 }
    Test-Case 'Security error = 1' { (Get-ExitCodeFor @(,@('WordCraft','Sicherheitsfehler'))) -eq 1 }
    Test-Case 'Blocked = 1' { (Get-ExitCodeFor @(,@('WordCraft','Gesperrt'))) -eq 1 }

    Write-Host "`n[9] Cleanup"
    Test-Case 'Verified MSI stays, outdated MSI and empty folder disappear' {
        Reset-State
        $keep = Join-Path $Verified 'WordCraft\0.14.0.0\wordcraft-0.14.0-windows-x64.msi'
        $oldMsi = Join-Path $Verified 'WordCraft\0.13.0.0\wordcraft-0.13.0-windows-x64.msi'
        foreach ($f in @($keep,$oldMsi)) { [void](New-Item -ItemType Directory -Force -Path (Split-Path $f)); Set-Content -LiteralPath $f -Value 'x' }
        $item = New-FakeItem 'WordCraft'; $item.File = $keep; $State.Pending.Add($item)
        Invoke-CraftMaintenance
        (Test-Path $keep) -and -not (Test-Path $oldMsi) -and -not (Test-Path (Split-Path $oldMsi))
    }
    Test-Case 'Unclear MSI state: no installers are deleted' {
        Reset-State; $State.PreserveInstallers = $true
        $f = Join-Path $Verified 'GridCraft\0.15.0.0\gridcraft.msi'
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $f)); Set-Content -LiteralPath $f -Value 'x'
        Invoke-CraftMaintenance
        Test-Path $f
    }
    Test-Case 'Old aborted download is removed, a fresh one stays' {
        Reset-State
        $oldStage = Join-Path $Root ('stage-' + [guid]::NewGuid().ToString('N'))
        $newStage = Join-Path $Root ('stage-' + [guid]::NewGuid().ToString('N'))
        foreach ($d in @($oldStage,$newStage)) { [void](New-Item -ItemType Directory -Path $d); Set-Content -LiteralPath (Join-Path $d 'part.msi') -Value 'x' }
        (Get-Item -LiteralPath $oldStage).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-2)
        Invoke-CraftMaintenance
        -not (Test-Path $oldStage) -and (Test-Path $newStage)
    }

    Write-Host "`n[10] Runs from the extracted folder (no copy to Program Files)"
    Test-Case 'No copy to Program Files, no shortcut, no start-folder file' {
        ($UpdaterText -notmatch 'Invoke-ProtectedInstall') -and ($UpdaterText -notmatch 'WScript\.Shell') -and
        ($UpdaterText -notmatch 'CreateShortcut') -and ($UpdaterText -notmatch 'Startordner\.txt') -and
        ($UpdaterText -notmatch 'WriteAllBytes')
    }
    Test-Case 'Error reports go to the folder next to the launcher' {
        ($UpdaterText -match [regex]::Escape("`$ErrorFolder = Join-Path `$ScriptDirectory (L 'Fehlermeldung' 'Error reports')")) -and
        ($UpdaterText -notmatch 'Resolve-ErrorFolder')
    }
    Test-Case 'Old Program Files copy is only mentioned, never changed' {
        $line = @($UpdaterText -split "`n" | Where-Object { $_ -match 'OldInstallDir' })
        ($line.Count -ge 2) -and (@($line | Where-Object { $_ -match 'Remove-Item|Move-Item|Set-Content|New-Item|Copy-Item' }).Count -eq 0)
    }
    Test-Case 'No self-deletion, no hiding; console only minimised' {
        $cmdText = Get-Content -LiteralPath (Join-Path (Split-Path $UpdaterPath) $LauncherName) -Raw
        ($cmdText -notmatch [regex]::Escape('del /f /q "%~f0"')) -and
        ($cmdText -match 'WindowStyle Minimized') -and
        ($UpdaterText -notmatch 'Remove-StartFolderScript') -and
        ($UpdaterText -notmatch 'WindowStyle\s+Hidden') -and ($UpdaterText -notmatch 'SW_HIDE') -and
        ($UpdaterText -notmatch 'GetConsoleWindow') -and
        ($UpdaterText -notmatch 'EncodedCommand') -and ($UpdaterText -notmatch 'Unblock-File')
    }

    Write-Host "`n[11] Window (link to the background run)"
    # A helper runspace answers the question like a click in the window; after 5 s the window counts as closed.
    function Invoke-WithWindowAnswer($answer,[scriptblock]$Body) {
        $sync = New-GuiSync
        $helper = [powershell]::Create()
        [void]$helper.AddScript({
            param($s,$a)
            $until = [datetime]::UtcNow.AddSeconds(5)
            while ($null -eq $s.Question -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
            if ($null -ne $s.Question) { $s.LastQuestion = $s.Question; $s.Answer = $a } else { $s.WindowClosed = $true }
        }).AddArgument($sync).AddArgument($answer)
        $handle = $helper.BeginInvoke()
        try {
            $script:GuiSync = $sync
            $value = & $Body
        } finally {
            $script:GuiSync = $null
            [void]$helper.EndInvoke($handle); $helper.Dispose()
        }
        return @{ Value = $value; Sync = $sync }
    }
    Test-Case 'Window: Yes in the confirmation approves, without asking in the console' {
        $Fake.Asked = 0
        $r = Invoke-WithWindowAnswer $true { Request-Confirmation 'Updates' 'Title' 'Text' 'Console' }
        ($r.Value -eq $true) -and ($Fake.Asked -eq 0) -and ($r.Sync.LastQuestion.Kind -eq 'Updates') -and ($null -eq $r.Sync.Question)
    }
    Test-Case 'Window: No or an unclear answer does not approve' {
        $no = Invoke-WithWindowAnswer $false { Request-Confirmation 'Updates' 'Title' 'Text' 'Console' }
        $text = Invoke-WithWindowAnswer 'JA' { Request-Confirmation 'Updates' 'Title' 'Text' 'Console' }
        ($no.Value -eq $false) -and ($text.Value -eq $false)
    }
    Test-Case 'Window closed during the question = no approval' {
        $sync = New-GuiSync; $sync.WindowClosed = $true
        $script:GuiSync = $sync
        try { $value = Request-Confirmation 'Updates' 'Title' 'Text' 'Console' } finally { $script:GuiSync = $null }
        ($value -eq $false) -and ($null -eq $sync.Question)
    }
    Test-Case 'Window: "Do not install" declines all updates' {
        Reset-State
        $State.Eligible.Add([pscustomobject]@{ Item=(New-FakeItem 'WordCraft'); Check=[pscustomobject]@{Signer='Learning Machines Inc'} })
        $State.Eligible.Add([pscustomobject]@{ Item=(New-FakeItem 'GridCraft'); Check=[pscustomobject]@{Signer='Learning Machines Inc'} })
        $r = Invoke-WithWindowAnswer $false { Invoke-Installation }
        $last = @{}; foreach ($x in $State.Results) { $last[$x.Program] = $x.Status }
        ($last['WordCraft'] -eq 'Update abgelehnt') -and ($last['GridCraft'] -eq 'Update abgelehnt') -and
        ($r.Sync.LastQuestion.Message -match 'WordCraft') -and ($r.Sync.LastQuestion.Message -match '2 Update')
    }
    Test-Case 'Window: table shows the latest state per program' {
        Reset-State
        $sync = New-GuiSync; $script:GuiSync = $sync
        try { Add-Result 'WordCraft' '0.12.0' 'v0.14.0' 'Verifiziert' 'x'; Add-Result 'WordCraft' '0.12.0' 'v0.14.0' 'Installiert - nachgeprueft' 'y' }
        finally { $script:GuiSync = $null }
        ($sync.Rows['WordCraft'].Status -eq 'Installiert - nachgeprueft') -and ((Get-FriendlyStatus $sync.Rows['WordCraft'].Status) -eq 'Aktualisiert')
    }
    Test-Case 'Window: updates on top, not installed at the bottom' {
        ((Get-SortRank 'Installationsbereit') -eq 0) -and ((Get-SortRank 'Installiert - nachgeprueft') -eq 0) -and
        ((Get-SortRank 'Aktuell') -eq 1) -and ((Get-SortRank '') -eq 1) -and ((Get-SortRank 'Nicht installiert') -eq 2)
    }
    Test-Case 'Window: versions always shown with v' {
        ((Format-VersionText '0.15.0') -eq 'v0.15.0') -and ((Format-VersionText 'v0.15.1') -eq 'v0.15.1') -and
        ((Format-VersionText 'V0.18.1') -eq 'v0.18.1') -and ((Format-VersionText '') -eq '') -and ((Format-VersionText 'unbekannt') -eq 'unbekannt')
    }
    Test-Case 'Window: readable status texts' {
        ((Get-FriendlyStatus 'Nur Download') -eq 'Diesmal übersprungen') -and ((Get-FriendlyStatus 'Sicherheitsfehler') -eq 'Sicherheitsfehler') -and
        ((Get-FriendlyStatus 'Installationsfehler') -eq 'Fehler') -and ((Get-FriendlyStatus 'Aktuell') -eq 'Aktuell')
    }
    Test-Case 'Window: final sentence matches the result' {
        Add-Type -AssemblyName System.Drawing
        $base = @{ Updated=0; Current=3; Missing=10; Rejected=0; Problems=0; Skipped=0; Reboot=$false; SecurityBlocked=$false; BatchStopped=$false }
        $ok = (Get-SummaryText ([pscustomobject]$base) '')[0] -match 'Alles aktuell'
        $b = $base.Clone(); $b.Updated = 2; $ok = $ok -and ((Get-SummaryText ([pscustomobject]$b) '')[0] -match '^Fertig! 2 Programm')
        $b = $base.Clone(); $b.SecurityBlocked = $true; $ok = $ok -and ((Get-SummaryText ([pscustomobject]$b) '')[0] -match 'nichts installiert')
        $b = $base.Clone(); $b.Skipped = 1; $ok = $ok -and ((Get-SummaryText ([pscustomobject]$b) '')[0] -match 'nicht geklappt')
        $ok -and ((Get-SummaryText $null 'Absturz')[0] -match 'Absturz')
    }
    Test-Case 'Sloth icon belongs to the package and is wired up' {
        ($IconFileName -eq 'Craft-Updater.ico') -and ($HeaderImageName -eq 'Craft-Updater-Header.png') -and
        ((Split-Path -Leaf (Split-Path -Parent $IconPath)) -eq 'assets') -and ((Split-Path -Leaf (Split-Path -Parent $HeaderImagePath)) -eq 'assets') -and
        ($UpdaterText -match [regex]::Escape('New-Object System.Drawing.Icon($IconPath')) -and
        ($UpdaterText -match [regex]::Escape('$BrandColor'))
    }
    Test-Case 'Window only on normal start; no hidden window, no second process' {
        $Konsole = $true; $a = Test-UseWindow; $Konsole = $false
        $NurPruefen = $true; $b = Test-UseWindow; $NurPruefen = $false
        (-not $a) -and (-not $b) -and ($UpdaterText -notmatch 'WindowStyle\s+Hidden') -and ($UpdaterText -notmatch 'CreateNoWindow') -and
        ($UpdaterText -match [regex]::Escape("AddCommand(`$ScriptPath).AddParameter('GuiSync',`$sync)"))
    }
    Test-Case 'Window closed: PowerShell exits for sure (only when the run is finished)' {
        ($UpdaterText -match '(?s)if \(\$script:CraftWindowFinished\) \{\s*try \{ \[System\.Diagnostics\.Process\]::GetCurrentProcess\(\)\.Kill\(\) \} catch \{\}\s*\[Environment\]::Exit\(\[int\]\$windowExitCode\)\s*\}') -and
        ($UpdaterText -match [regex]::Escape('$script:CraftWindowFinished = [bool]$ui.Finished'))
    }

    Write-Host "`n[12] Error logging (warnings go to the error folder)"
    Test-Case 'Warnings are collected' {
        Reset-State
        Write-Warning 'Hello warning'
        ($State.Warnings.Count -ge 1) -and ($State.Warnings[-1] -eq 'Hello warning')
    }
    Test-Case 'A warning creates an error report (just send the file)' {
        Reset-State
        $script:Reports = Join-Path $TestDir ('Rep-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $Reports -Force)
        $script:ErrorFolder = Join-Path $TestDir ('WarnFolder-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $ErrorFolder -Force)
        $State.ErrorFolderReady = $true
        Write-Warning 'Test warning: something went wrong'
        $null = Write-RunSummary 6>$null 3>$null
        $files = @(Get-ChildItem -LiteralPath $ErrorFolder -Filter ($ErrorReportPrefix + '*.txt') -File -ErrorAction SilentlyContinue)
        ($files.Count -ge 1) -and (((Get-Content -LiteralPath $files[0].FullName -Raw) -match 'Test warning'))
    }
    Test-Case 'A clean run without warnings creates no error report' {
        Reset-State
        $script:Reports = Join-Path $TestDir ('Rep-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $Reports -Force)
        $script:ErrorFolder = Join-Path $TestDir ('EmptyFolder-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $ErrorFolder -Force)
        $State.ErrorFolderReady = $true
        Add-Result 'WordCraft' '0.15.0' 'v0.15.0' 'Aktuell' 'Kein Download erforderlich'
        $null = Write-RunSummary 6>$null 3>$null
        @(Get-ChildItem -LiteralPath $ErrorFolder -Filter ($ErrorReportPrefix + '*.txt') -File -ErrorAction SilentlyContinue).Count -eq 0
    }

    Write-Host "`n[13] Language (German on German Windows, English otherwise)"
    Test-Case 'Every text call has a German and an English text' {
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($UpdaterText, [ref]$tok, [ref]$err)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'L' }, $true))
        $bad = @($calls | Where-Object { $_.CommandElements.Count -ne 3 -or
            @($_.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] }).Count -ne 0 })
        ($calls.Count -gt 100) -and ($bad.Count -eq 0)
    }
    Test-Case 'English: status texts, final sentence and buttons' {
        $script:UiGerman = $false
        try {
            $base = @{ Updated=0; Current=3; Missing=10; Rejected=0; Problems=0; Skipped=0; Reboot=$false; SecurityBlocked=$false; BatchStopped=$false }
            $b = $base.Clone(); $b.Updated = 2
            ((Get-FriendlyStatus 'Aktuell') -eq 'Up to date') -and ((Get-FriendlyStatus 'Nicht installiert') -eq 'Not installed') -and
            ((Get-FriendlyStatus 'Installiert - nachgeprueft') -eq 'Updated') -and ((Get-FriendlyStatus 'Nur Download') -eq 'Skipped this time') -and
            ((Get-SummaryText ([pscustomobject]$base) '')[0] -match 'Everything is up to date') -and
            ((Get-SummaryText ([pscustomobject]$b) '')[0] -match '^Done! 2 program') -and
            ((L 'Installieren' 'Install') -eq 'Install')
        } finally { $script:UiGerman = $true }
    }
    Test-Case 'English console: only the exact YES approves' {
        $script:UiGerman = $false
        try {
            $Fake.Answer = 'YES'; $yes = Request-Confirmation 'Updates' 'Title' 'Text' 'Console'
            $Fake.Answer = 'yes'; $lower = Request-Confirmation 'Updates' 'Title' 'Text' 'Console'
            $Fake.Answer = 'JA';  $ja = Request-Confirmation 'Updates' 'Title' 'Text' 'Console'
            $yes -and -not $lower -and -not $ja
        } finally { $script:UiGerman = $true; $Fake.Answer = '' }
    }
    Test-Case 'German console: only the exact JA approves' {
        $Fake.Answer = 'JA'; $ja = Request-Confirmation 'Updates' 'Titel' 'Text' 'Konsole'
        $Fake.Answer = 'ja'; $lower = Request-Confirmation 'Updates' 'Titel' 'Text' 'Konsole'
        $Fake.Answer = 'YES'; $yes = Request-Confirmation 'Updates' 'Titel' 'Text' 'Konsole'
        $Fake.Answer = ''
        $ja -and -not $lower -and -not $yes
    }

    Write-Host "`n[14] New in 5.8: locked installer, anonymous error report, what's new"
    Test-Case 'Installer is locked while the last checks run, and unlocked afterwards' {
        Reset-State
        $item = New-FakeInstaller (New-FakeItem 'GridCraft')
        $Fake.ProbeLock = $true
        $Fake.CandidateError['GridCraft'] = 'Programm laeuft oder Prozess im Installationsverzeichnis gefunden'
        Install-EligibleUpdate ([pscustomobject]@{ Item=$item })
        $free = $false
        try { $w = [IO.File]::Open($item.File,'Open','ReadWrite','None'); $w.Dispose(); $free = $true } catch {}
        $Fake.LockSeen -and $free -and (Test-Path -LiteralPath $item.File)
    }
    Test-Case 'Missing installer file: nothing is installed, no crash' {
        Reset-State
        $item = New-FakeItem 'DeckCraft'
        if (Test-Path -LiteralPath $item.File) { Remove-Item -LiteralPath $item.File -Force }
        Install-EligibleUpdate ([pscustomobject]@{ Item=$item })
        ((Get-LastResult).Status -eq 'Nur Download') -and ((Get-LastResult).Detail -like '*gesperrt*') -and -not $State.StopInstallBatch
    }
    Test-Case 'Error report text: profile path, user name and computer name are replaced' {
        $in = 'Datei C:\Users\Maple\AppData\Local\x.log auf DESKTOP-42 von maple; Maplesirup bleibt'
        $out = Protect-ReportText $in 'Maple' 'DESKTOP-42' 'C:\Users\Maple'
        ($out -eq 'Datei C:\Users\<Benutzer>\AppData\Local\x.log auf <Computer> von <Benutzer>; Maplesirup bleibt')
    }
    Test-Case 'Error report text: a user named "user" does not break the placeholder' {
        $script:UiGerman = $false
        try { $out = Protect-ReportText 'C:\Users\user\a and user' 'user' 'PC-1' 'C:\Users\user' }
        finally { $script:UiGerman = $true }
        $out -eq 'C:\Users\<user>\a and <user>'
    }
    Test-Case 'Written error report contains neither user name nor computer name' {
        Reset-State
        $saved = @($env:USERNAME, $env:COMPUTERNAME, $env:USERPROFILE)
        try {
            $env:USERNAME = 'TestUserXy'; $env:COMPUTERNAME = 'TESTPC-77'; $env:USERPROFILE = 'C:\Users\TestUserXy'
            $script:Reports = Join-Path $TestDir ('Rep-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $Reports -Force)
            $script:ErrorFolder = Join-Path $TestDir ('Anon-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $ErrorFolder -Force)
            $State.ErrorFolderReady = $true
            Write-Warning 'Problem in C:\Users\TestUserXy\AppData on TESTPC-77 for TestUserXy'
            $null = Write-RunSummary 6>$null 3>$null
            $files = @(Get-ChildItem -LiteralPath $ErrorFolder -Filter ($ErrorReportPrefix + '*.txt') -File)
            $text = Get-Content -LiteralPath $files[0].FullName -Raw
            ($files.Count -eq 1) -and ($text -notmatch 'TestUserXy') -and ($text -notmatch 'TESTPC-77') -and ($text -match '<Benutzer>') -and ($text -match '<Computer>')
        } finally { $env:USERNAME = $saved[0]; $env:COMPUTERNAME = $saved[1]; $env:USERPROFILE = $saved[2] }
    }
    Test-Case 'Release notes become readable plain text' {
        $md = "## Changes`r`n<!-- hidden -->`r`n- **Fixed** the [export](https://example.com/x)`r`n![shot](a.png)`r`n`r`n`r`n`r`n* Faster ``start``"
        $txt = Format-ReleaseNotes $md
        ($txt -eq "Changes`r`n`r`n- Fixed the export`r`n`r`n- Faster start") -and ((Format-ReleaseNotes '') -eq '') -and ((Format-ReleaseNotes ('x' * 3000) 100).Length -eq 104)
    }
    Test-Case "GitHub's generated release notes are shortened" {
        $md = "## What's Changed`r`n* Faster export by @someone in https://github.com/storytold/designcraft/pull/2181`r`n* Fix (#2129) by @dependabot[bot] in https://github.com/storytold/designcraft/pull/2160`r`n`r`n## New Contributors`r`n* @x made their first contribution in https://github.com/storytold/designcraft/pull/1`r`n`r`n**Full Changelog**: https://github.com/storytold/designcraft/compare/v0.17.0...v0.17.1"
        $txt = Format-ReleaseNotes $md
        $long = Format-ReleaseNotes ((1..40 | ForEach-Object { "- line $_" }) -join "`n") 1500 25
        ($txt -eq "What's Changed`r`n- Faster export (#2181)`r`n- Fix (#2129) (#2160)") -and (($long -split "`r`n").Count -eq 26) -and $long.EndsWith('...') -and
        ((Format-ReleaseNotes '**Full Changelog**: https://github.com/storytold/deckcraft/compare/v0.15.0...v0.15.1') -eq '')
    }
    Test-Case 'Several updates: the notes name the other programs; quick exit after the window' {
        ($UpdaterText -match [regex]::Escape("`$others = @(foreach (`$it in `$list.Items)")) -and ($UpdaterText -match [regex]::Escape("if (-not `$ui.Finished) { `$form.Dispose() }")) -and
        ($UpdaterText -notmatch [regex]::Escape('$runspace.Dispose()'))
    }
    Test-Case 'Notes: a program without an update shows a hint, not another program' {
        $UpdaterText -match [regex]::Escape("if (-not `$sync.Notes.ContainsKey(`$picked)) {")
    }
    Test-Case 'Notes link: only Craft release pages can be opened or copied' {
        (Test-ReleaseNotesUrl 'https://github.com/storytold/designcraft/releases/tag/v0.17.1') -and
        -not (Test-ReleaseNotesUrl 'https://github.com/evil/designcraft/releases/tag/v1') -and
        -not (Test-ReleaseNotesUrl 'https://github.com.evil.com/storytold/x/releases/tag/v1') -and
        -not (Test-ReleaseNotesUrl 'http://github.com/storytold/designcraft/releases/tag/v1') -and
        -not (Test-ReleaseNotesUrl 'https://github.com/storytold/designcraft/releases/tag/v1 & calc') -and
        -not (Test-ReleaseNotesUrl '') -and -not (Open-ReleaseNotesUrl 'file:///C:/Windows/System32/calc.exe') -and
        ($UpdaterText -match [regex]::Escape("Join-Path `$env:SystemRoot 'explorer.exe') -ArgumentList `$url"))
    }
    Test-Case 'Copyright and MIT license notice are in the script' {
        ($UpdaterText -match [regex]::Escape('# Copyright (c) 2026 slothmade (slothworks) - https://github.com/slothmade/craft-updater')) -and
        ($UpdaterText -match [regex]::Escape('# The above copyright notice and this permission notice shall be included in all copies or'))
    }
    Test-Case 'Window: copyright line opens only the project page' {
        ($ProjectUrl -eq 'https://github.com/slothmade/craft-updater') -and
        ($UpdaterText -match [regex]::Escape("`$footerLink.Add_LinkClicked({ [void](Open-ProjectPage) })")) -and
        ($UpdaterText -match [regex]::Escape("Join-Path `$env:SystemRoot 'explorer.exe') -ArgumentList `$ProjectUrl"))
    }
    Test-Case 'Launcher is plain ASCII without BOM (a BOM breaks the first line of a .cmd)' {
        $launcherPath = Join-Path (Split-Path -Parent $UpdaterPath) 'Craft-Updater-STARTEN.cmd'
        $bytes = [IO.File]::ReadAllBytes($launcherPath)
        ($bytes.Length -gt 3) -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -and
        (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) -and ([Text.Encoding]::ASCII.GetString($bytes,0,9) -eq '@echo off')
    }
    Test-Case 'Window title and header show the version with v' {
        ($UpdaterText -match [regex]::Escape("`$form.Text = 'Craft Updater v' + `$UpdaterVersion")) -and ($UpdaterText -match [regex]::Escape("`$titleVersion.Text = 'v' + `$UpdaterVersion"))
    }
    Test-Case 'Release notes are kept for a program with a newer version' {
        Reset-State; $InstalledSnapshot=$WordCraftInstalled; $ProcessSnapshot=@()
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        $Fake.Release | Add-Member -NotePropertyName body -NotePropertyValue '## New'
        $Fake.Release | Add-Member -NotePropertyName html_url -NotePropertyValue 'https://github.com/storytold/wordcraft/releases/tag/v0.14.0'
        Find-ProgramUpdate $wordProgram
        $n = $State.Notes['WordCraft']
        ($null -ne $n) -and ($n.Text -eq 'New') -and ($n.Version -eq 'v0.14.0') -and ($n.Url -like '*wordcraft/releases/tag/v0.14.0')
    }
    Test-Case 'TextureCraft is in the program list (5.8.1)' {
        $tc = @($Programs | Where-Object { $_.Name -eq 'TextureCraft' })
        ($Programs.Count -eq 14) -and ($tc.Count -eq 1) -and ($tc[0].Repo -eq 'texturecraft') -and
        ('TextureCraft' -match $tc[0].Pattern) -and -not ('WordCraft' -match $tc[0].Pattern) -and
        ('texturecraft-0.3.2-windows-x64.msi' -match '(?i)(^|[._-])(x64|amd64|x86_64)([._-]|$)')
    }
    Test-Case 'Window: "What is new" button is wired up' {
        ($UpdaterText -match [regex]::Escape('$btnNotes.Add_Click({ & $showNotes })')) -and ($UpdaterText -match [regex]::Escape('$list.Add_DoubleClick({ & $showNotes })')) -and
        ($UpdaterText -match [regex]::Escape("Notes = [hashtable]::Synchronized(@{})"))
    }

} finally {
    Remove-Item -LiteralPath $TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($Failures.Count -eq 0) {
    Write-Host ('ALL TESTS PASSED / ALLE TESTS BESTANDEN: ' + $Passed) -ForegroundColor Green
    exit 0
} else {
    Write-Host ('PASSED / BESTANDEN: ' + $Passed + ' | FAILED / FEHLGESCHLAGEN: ' + $Failures.Count) -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
