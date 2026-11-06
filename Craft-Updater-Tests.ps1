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
$SkippedUpdaterPath = Join-Path $Root 'SkippedUpdaterVersion.json'
$ErrorFolder = Join-Path $TestDir 'Fehlermeldung'
$OldInstallDir = Join-Path $TestDir 'Programme\Craft Updater'
# Take the real architecture patterns from the updater.
$X64Pattern = [regex]::Match($UpdaterText,"'amd64' \{ \`$Platform='x64'; \`$ArchPattern='([^']+)'").Groups[1].Value
$X86Pattern = [regex]::Match($UpdaterText,"'x86'   \{ \`$Platform='x86'; \`$ArchPattern='([^']+)'").Groups[1].Value
if (-not $X64Pattern -or -not $X86Pattern) { throw 'Architecture patterns not found in the updater.' }
$Platform = 'x64'; $ArchPattern = $X64Pattern

# --- Replacements for functions that need the network, registry or Windows Installer ---
$Fake = @{ FreshChecked = 0; InstalledNow = @(); Repos = @(); RepoError = $false; Release = $null; CandidateError = @{}; Language = '1033'; Answer = ''; Asked = 0; ProbeLock = $false; LockSeen = $false }
function Test-IsAdmin { return $true }
# Replaces user input; counts how often it was asked.
function Read-Host([string]$Prompt) { $Fake.Asked++; return $Fake.Answer }
function Get-ReleaseCached([string]$repo) { return $Fake.Release }
# Repository list for the automatic app search (5.9); the real function is kept for its own test.
$RealCraftRepoList = ${function:Get-CraftRepoList}
function Get-CraftRepoList { if ($Fake.RepoError) { throw 'offline' }; return $Fake.Repos }
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

# New installation (5.9): same idea as above, counts how often it was called.
function Test-FreshInstallCandidate($item) {
    $Fake.FreshChecked++
    $message = $Fake.CandidateError[$item.Program.Name]
    if ($message) { throw $message }
    return [pscustomobject]@{ Item=$item; Check=[pscustomobject]@{ Signer='Learning Machines Inc' } }
}
function Find-InstalledEntries($program) { return ,@($Fake.InstalledNow | Where-Object { [string]$_.DisplayName -match $program.Pattern }) }

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
        ($Programs.Count -ge 14) -and ($tc.Count -eq 1) -and ($tc[0].Repo -eq 'texturecraft') -and
        ('TextureCraft' -match $tc[0].Pattern) -and -not ('WordCraft' -match $tc[0].Pattern) -and
        ('texturecraft-0.3.2-windows-x64.msi' -match '(?i)(^|[._-])(x64|amd64|x86_64)([._-]|$)')
    }
    Write-Host "`n[15] New in 5.8.1: notice about a newer Craft Updater"
    function Test-UpdaterNotice($release,[string]$localVersion='') {
        Reset-State; $State.UpdaterUpdate = $null; $Fake.Release = $release
        $saved = $env:CRAFT_UPDATER_TEST_LOCAL_VERSION; $env:CRAFT_UPDATER_TEST_LOCAL_VERSION = $localVersion
        try { Find-UpdaterUpdate } finally { $env:CRAFT_UPDATER_TEST_LOCAL_VERSION = $saved }
        return $State.UpdaterUpdate
    }
    Test-Case 'Updater notice: newer release on GitHub is reported with its release page' {
        $u = Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0'; draft=$false; prerelease=$false })
        ($null -ne $u) -and ($u.Version -eq 'v99.0') -and ($u.Url -eq 'https://github.com/slothmade/craft-updater/releases/tag/v99.0') -and ($State.Warnings.Count -eq 0)
    }
    Test-Case 'Updater notice: same or older version gives no notice' {
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name=('v' + $UpdaterVersion) }))) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='v5.8' })))
    }
    Test-Case 'Updater notice: test switch pretends an older version (and only takes version numbers)' {
        $u = Test-UpdaterNotice ([pscustomobject]@{ tag_name='v5.8' }) '5.7'
        ($null -ne $u) -and ($u.Version -eq 'v5.8') -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='v5.8' }) '5.7; Remove-Item x'))
    }
    Test-Case 'Updater notice: odd answers are ignored quietly (no tag, odd tag, draft, prerelease, nothing)' {
        ($null -eq (Test-UpdaterNotice $null)) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='' }))) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0/../../evil' }))) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='latest' }))) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0'; draft=$true }))) -and
        ($null -eq (Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0'; prerelease=$true }))) -and
        ($State.Warnings.Count -eq 0)
    }
    Test-Case 'Updater notice: only the release page of this project may be opened' {
        (Test-UpdaterReleaseUrl 'https://github.com/slothmade/craft-updater/releases/tag/v5.9') -and
        (Test-UpdaterReleaseUrl 'https://github.com/slothmade/craft-updater/releases/tag/v5.8.2') -and
        -not (Test-UpdaterReleaseUrl 'https://github.com/someone/craft-updater/releases/tag/v5.9') -and
        -not (Test-UpdaterReleaseUrl 'https://github.com/slothmade/craft-updater/releases/download/v5.9/x.zip') -and
        -not (Test-UpdaterReleaseUrl 'https://evil.example/slothmade/craft-updater/releases/tag/v5.9') -and
        -not (Open-UpdaterReleasePage 'https://evil.example/')
    }
    Test-Case 'Updater notice: own releases use a separate cache file and are checked first' {
        ($UpdaterText -match [regex]::Escape("`$cacheName = `$(if (`$owner -eq `$Owner) { `$repo } else { `$owner + '--' + `$repo })")) -and
        ($UpdaterText -match 'function Invoke-UpdateRun \{\s+try \{\s+Find-UpdaterUpdate\s+Find-NewCraftApps\s+\$searchIndex = 0')
    }
    Test-Case 'Window: updater notice link is wired up and opens only the checked page' {
        ($UpdaterText -match [regex]::Escape('$choice = Show-UpdaterNoticeDialog $form ([string]$notice.Version)')) -and
        ($UpdaterText -match [regex]::Escape("if (`$choice -eq 'open') { [void](Open-UpdaterReleasePage ([string]`$notice.Url)) }")) -and
        ($UpdaterText -match [regex]::Escape('$footerLink,$updateLink,$header')) -and ($UpdaterText -match [regex]::Escape('UpdaterUpdate = $null'))
    }
    Test-Case 'Window: "What is new" button is wired up' {
        ($UpdaterText -match [regex]::Escape('$btnNotes.Add_Click({ & $showNotes })')) -and ($UpdaterText -match [regex]::Escape('$list.Add_DoubleClick({ & $showNotes })')) -and
        ($UpdaterText -match [regex]::Escape("Notes = [hashtable]::Synchronized(@{})"))
    }

    Write-Host "`n[16] New in 5.9: MaterialCraft, updated version in the window, tidy comments"
    Test-Case 'MaterialCraft is in the program list (5.9)' {
        $mc = @($Programs | Where-Object { $_.Name -eq 'MaterialCraft' })
        ($Programs.Count -eq 15) -and ($mc.Count -eq 1) -and ($mc[0].Repo -eq 'materialcraft') -and
        ('MaterialCraft' -match $mc[0].Pattern) -and ('MaterialCraft 0.1.1' -match $mc[0].Pattern) -and
        -not ('MaterialCraftX' -match $mc[0].Pattern) -and -not ('TextureCraft' -match $mc[0].Pattern) -and
        ('materialcraft-0.1.1-windows-x64.msi' -match $X64Pattern)
    }
    Test-Case 'Program names, repositories and patterns are unique' {
        $names = @($Programs | ForEach-Object { $_.Name }); $repos = @($Programs | ForEach-Object { $_.Repo })
        $clash = @(foreach ($p in $Programs) { foreach ($q in $Programs) { if ($p.Name -ne $q.Name -and $q.Name -match $p.Pattern) { $p.Name + '~' + $q.Name } } })
        (@($names | Sort-Object -Unique).Count -eq $names.Count) -and (@($repos | Sort-Object -Unique).Count -eq $repos.Count) -and ($clash.Count -eq 0)
    }
    Test-Case 'Window: after an update the new version is shown as installed' {
        $done = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.2.0'; Latest='v0.3.2'; Status='Installiert - nachgeprueft' })
        $reboot = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.2.0'; Latest='0.3.2'; Status='Installiert - Neustart erforderlich' })
        ($done[0] -eq 'v0.3.2') -and ($done[1] -eq '') -and ($reboot[0] -eq 'v0.3.2') -and ($reboot[1] -eq '')
    }
    Test-Case 'Window: before or without an update the columns stay as they were' {
        $ready = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.2.0'; Latest='0.3.2'; Status='Installationsbereit' })
        $skip = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.2.0'; Latest='0.3.2'; Status='Nur Download' })
        $fail = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.2.0'; Latest='0.3.2'; Status='Installationsfehler' })
        $same = Get-RowVersionTexts ([pscustomobject]@{ Installed='0.3.2'; Latest='0.3.2'; Status='Aktuell' })
        $none = Get-RowVersionTexts ([pscustomobject]@{ Installed=''; Latest='0.3.2'; Status='Nicht installiert' })
        ($ready[0] -eq 'v0.2.0') -and ($ready[1] -eq 'v0.3.2') -and ($skip[1] -eq 'v0.3.2') -and ($fail[0] -eq 'v0.2.0') -and ($fail[1] -eq 'v0.3.2') -and
        ($same[0] -eq 'v0.3.2') -and ($same[1] -eq '') -and ($none[0] -eq '') -and ($none[1] -eq '')
    }
    Test-Case 'Window: uses the column helper and grows for more than 14 programs' {
        ($UpdaterText -match [regex]::Escape('$texts = Get-RowVersionTexts $row')) -and
        ($UpdaterText -match [regex]::Escape('$wantedHeight = Get-CraftWindowHeight $Programs.Count')) -and
        ((Get-CraftWindowHeight 14) -eq 548) -and ((Get-CraftWindowHeight 15) -eq 568) -and ((Get-CraftWindowHeight 40) -eq 748) -and ((Get-CraftWindowHeight 3) -eq 548)
    }
    Test-Case 'No leftover plans for a signed .exe in the script comments' {
        -not ($UpdaterText -match 'until there is a signed \.exe') -and -not ($UpdaterText -match 'replaced later by a signed \.exe')
    }

    Write-Host "`n[17] New in 5.9: skip this Craft Updater version"
    function Clear-Skipped { Remove-Item -LiteralPath $SkippedUpdaterPath -Force -ErrorAction SilentlyContinue }
    Test-Case 'Skip: nothing skipped without a file' { Clear-Skipped; $null -eq (Read-SkippedUpdaterVersion) }
    Test-Case 'Skip: a skipped version is remembered' {
        Clear-Skipped
        (Save-SkippedUpdaterVersion 'v99.0') -and ((Read-SkippedUpdaterVersion) -eq (Parse-Version '99.0'))
    }
    Test-Case 'Skip: the skipped version gives no notice, an even newer one does' {
        Clear-Skipped; [void](Save-SkippedUpdaterVersion 'v99.0')
        $same = Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0' })
        $newer = Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0.1' })
        $result = ($null -eq $same) -and ($null -ne $newer) -and ($newer.Version -eq 'v99.0.1')
        Clear-Skipped; $result
    }
    Test-Case 'Skip: only plain version numbers are stored' {
        Clear-Skipped
        -not (Save-SkippedUpdaterVersion '99.0') -and -not (Save-SkippedUpdaterVersion 'v99.0; Remove-Item x') -and
        -not (Save-SkippedUpdaterVersion '') -and -not (Test-Path -LiteralPath $SkippedUpdaterPath)
    }
    Test-Case 'Skip: a broken or odd file is ignored and the notice shows' {
        [void](New-Item -ItemType Directory -Path $Root -Force)
        [IO.File]::WriteAllText($SkippedUpdaterPath,'not json')
        $broken = Read-SkippedUpdaterVersion
        [IO.File]::WriteAllText($SkippedUpdaterPath,'{"Version":"latest"}')
        $odd = Read-SkippedUpdaterVersion
        $u = Test-UpdaterNotice ([pscustomobject]@{ tag_name='v99.0' })
        Clear-Skipped
        ($null -eq $broken) -and ($null -eq $odd) -and ($null -ne $u)
    }
    Write-Host "`n[18] New in 5.9: new Craft apps are found automatically"
    $ProgramsBackup = $Programs
    function New-DiscoveryRelease([string]$repo,[string]$title='',[string]$file='') {
        if (-not $file) { $file = $repo + '-1.0.0-windows-x64.msi' }
        $r = New-FakeRelease 'v1.0.0' @(New-FakeAsset $file ('https://github.com/storytold/' + $repo + '/releases/download/v1.0.0/' + $file))
        $r | Add-Member -NotePropertyName name -NotePropertyValue $title
        return $r
    }
    Test-Case 'Discovery: a Craft app with a Windows installer becomes a program' {
        $p = ConvertTo-DiscoveredProgram 'newtoolcraft' (New-DiscoveryRelease 'newtoolcraft')
        ($null -ne $p) -and $p.Discovered -and ($p.Name -eq 'NewtoolCraft') -and ($p.Repo -eq 'newtoolcraft') -and
        ('NewtoolCraft' -match $p.Pattern) -and ('Newtool Craft 1.0' -match $p.Pattern) -and ('newtoolcraft' -match $p.Pattern) -and
        -not ('NewtoolCraftX' -match $p.Pattern) -and -not ('My NewtoolCraft' -match $p.Pattern)
    }
    Test-Case 'Discovery: the name is taken from the release title when it fits' {
        $a = ConvertTo-DiscoveredProgram 'xyzcraft' (New-DiscoveryRelease 'xyzcraft' 'XYZCraft v1.0.0')
        $b = ConvertTo-DiscoveredProgram 'xyzcraft' (New-DiscoveryRelease 'xyzcraft' 'Release v1.0.0')
        $c = ConvertTo-DiscoveredProgram 'big-tool-craft' (New-DiscoveryRelease 'big-tool-craft' 'Big Tool Craft 1.0')
        ($a.Name -eq 'XYZCraft') -and ($b.Name -eq 'XyzCraft') -and ($c.Name -eq 'Big Tool Craft') -and
        ('Big Tool Craft' -match $c.Pattern) -and ('BigToolCraft' -match $c.Pattern)
    }
    Test-Case 'Discovery: excluded, known and non-Craft repositories are ignored' {
        ($null -eq (ConvertTo-DiscoveredProgram 'artcraft' (New-DiscoveryRelease 'artcraft'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'craft-anything' (New-DiscoveryRelease 'craft-anything'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'wordcraft' (New-DiscoveryRelease 'wordcraft'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'word-craft' (New-DiscoveryRelease 'word-craft'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'craft' (New-DiscoveryRelease 'craft'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'craftnotes' (New-DiscoveryRelease 'craftnotes')))
    }
    Test-Case 'Discovery: no Windows installer for this PC, or no stable release = not an app' {
        $draft = New-DiscoveryRelease 'newtoolcraft'; $draft.draft = $true
        $pre = New-DiscoveryRelease 'newtoolcraft'; $pre.prerelease = $true
        $badTag = New-DiscoveryRelease 'newtoolcraft'; $badTag.tag_name = 'latest'
        ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' (New-DiscoveryRelease 'newtoolcraft' '' 'newtoolcraft-1.0.0-windows-arm64.msi'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' (New-DiscoveryRelease 'newtoolcraft' '' 'newtoolcraft-1.0.0-macos.dmg'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' (New-DiscoveryRelease 'newtoolcraft' '' 'other-1.0.0-windows-x64.msi'))) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' $draft)) -and ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' $pre)) -and
        ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' $badTag)) -and ($null -eq (ConvertTo-DiscoveredProgram 'newtoolcraft' $null))
    }
    Test-Case 'Discovery: found apps are added to the list, everything else stays' {
        Reset-State; $Fake.RepoError = $false
        $Fake.Repos = @('notes','newtoolcraft','wordcraft','craft-launcher','artcraft')
        $Fake.Release = New-DiscoveryRelease 'newtoolcraft' 'NewToolCraft v1.0.0'
        Find-NewCraftApps
        $added = @($Programs | Where-Object { $_.Discovered })
        $result = ($Programs.Count -eq ($ProgramsBackup.Count + 1)) -and ($added.Count -eq 1) -and ($added[0].Name -eq 'NewToolCraft') -and ($State.Warnings.Count -eq 0)
        $script:Programs = $ProgramsBackup
        $result
    }
    Test-Case 'Discovery: at most 5 unknown repositories are looked at per run' {
        Reset-State; $Fake.RepoError = $false
        $Fake.Repos = @('acraft','bcraft','ccraft','dcraft','ecraft','fcraft','gcraft')
        $Fake.Release = New-FakeRelease 'v1.0.0' @()
        $script:CountedReleases = 0
        function Get-ReleaseCached([string]$repo) { $script:CountedReleases++; return $Fake.Release }
        Find-NewCraftApps
        $result = ($script:CountedReleases -eq 5) -and ($Programs.Count -eq $ProgramsBackup.Count)
        $script:Programs = $ProgramsBackup
        $result
    }
    Test-Case 'Discovery: offline or rate limit = fixed list only, no warning' {
        Reset-State; $Fake.RepoError = $true
        Find-NewCraftApps
        $Fake.RepoError = $false
        ($Programs.Count -eq $ProgramsBackup.Count) -and ($State.Warnings.Count -eq 0)
    }
    Test-Case 'Discovery: repository list skips forks, archived and odd names' {
        $CacheRoot = Join-Path $TestDir 'RepoListCache'; [void](New-Item -ItemType Directory -Path $CacheRoot -Force)
        Reset-State
        function Invoke-Retry([string]$uri,[string]$outFile='') {
            return @([pscustomobject]@{ name='NewToolCraft' }, [pscustomobject]@{ name='forkcraft'; fork=$true },
                     [pscustomobject]@{ name='oldcraft'; archived=$true }, [pscustomobject]@{ name='bad name craft' })
        }
        $first = @(& $RealCraftRepoList)
        function Invoke-Retry([string]$uri,[string]$outFile='') { throw 'must come from the cache' }
        $second = @(& $RealCraftRepoList)
        ($first.Count -eq 1) -and ($first[0] -eq 'newtoolcraft') -and ($second.Count -eq 1) -and ($second[0] -eq 'newtoolcraft')
    }
    Test-Case 'Discovery: a similar program from another publisher is not mistaken for the app' {
        Reset-State; $ProcessSnapshot=@()
        $p = ConvertTo-DiscoveredProgram 'minecraft' (New-DiscoveryRelease 'minecraft')
        $InstalledSnapshot = @([pscustomobject]@{ DisplayName='Minecraft Launcher'; DisplayVersion='2.1.0'; Publisher='Mojang'; PSChildName='Minecraft'; WindowsInstaller=0; PSPath='HKLM' })
        Find-ProgramUpdate $p
        ($null -ne $p) -and ((Get-LastResult).Status -eq 'Nicht installiert') -and -not $State.SecurityBlocked
    }
    Test-Case 'Window: found apps get their own row marked "newly found"' {
        ($UpdaterText -match [regex]::Escape('$item = & $addRow ([string]$key)')) -and
        ($UpdaterText -match [regex]::Escape("if (`$sync.Discovered.ContainsKey([string]`$key)) { `$stText += (L ' (neu entdeckt)' ' (newly found)') }")) -and
        ($UpdaterText -match [regex]::Escape('$order = @(@($ui.Index.Keys)')) -and
        ($UpdaterText -match 'function Invoke-UpdateRun \{\s+try \{\s+Find-UpdaterUpdate\s+Find-NewCraftApps')
    }
    $Programs = $ProgramsBackup

    Write-Host "`n[19] New in 5.9: new installation of Craft programs (checks and flow)"
    function Set-FreshRun {
        Reset-State; $Fake.FreshChecked = 0; $Fake.InstalledNow = @()
        Add-Result 'WordCraft' '0.12.0' 'v0.12.0' 'Aktuell' 'x'
        Add-Result 'FigCraft' '' '' 'Nicht installiert' 'x'
    }
    $RealVerifiedInstaller = ${function:Get-VerifiedInstaller}
    function Get-VerifiedInstaller($program,$release,$app,[string]$localText,[string]$remoteText,[version]$remote,[switch]$FreshInstall) {
        $script:VerifiedCalls++
        $item = New-FakeInstaller (New-FakeItem $program.Name)
        return (New-PendingItem $program $null '' 'v0.14.0' ([version]'0.14.0.0') $item.File ('A'*64) $null ([bool]$FreshInstall))
    }
    Test-Case 'Fresh: only programs that are not installed are offered' {
        Set-FreshRun
        $c = @(Get-FreshInstallChoices)
        ($c.Count -eq 1) -and ($c[0] -eq 'FigCraft')
    }
    Test-Case 'Fresh: nothing is offered after a security error' {
        Set-FreshRun; Add-Result 'GridCraft' '0.1' 'v0.2' 'Sicherheitsfehler' 'x'
        @(Get-FreshInstallChoices).Count -eq 0
    }
    Test-Case 'Fresh: nothing happens without approval or in check-only mode' {
        Set-FreshRun; $script:VerifiedCalls = 0; $count = $State.Results.Count
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        Invoke-FreshInstall @('FigCraft')
        $NurPruefen = $true
        Invoke-FreshInstall @('FigCraft') -Approved
        ($State.Results.Count -eq $count) -and ($script:VerifiedCalls -eq 0)
    }
    Test-Case 'Fresh: programs that were not offered are ignored' {
        Set-FreshRun; $script:VerifiedCalls = 0; $count = $State.Results.Count
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        Invoke-FreshInstall @('WordCraft','EvilCraft') -Approved
        ($State.Results.Count -eq $count) -and ($script:VerifiedCalls -eq 0)
    }
    Test-Case 'Fresh: installed in the meantime = skipped, nothing downloaded' {
        Set-FreshRun; $script:VerifiedCalls = 0
        $Fake.InstalledNow = @([pscustomobject]@{ DisplayName='FigCraft'; Publisher='Learning Machines Inc' })
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        Invoke-FreshInstall @('FigCraft') -Approved
        ((Get-LastResult).Status -eq 'Uebersprungen') -and ($script:VerifiedCalls -eq 0)
    }
    Test-Case 'Fresh: the downloaded installer goes through the pre-install check' {
        Set-FreshRun; $script:VerifiedCalls = 0
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        $Fake.CandidateError['FigCraft'] = 'Programm laeuft'
        Invoke-FreshInstall @('FigCraft') -Approved
        ($script:VerifiedCalls -eq 1) -and ($Fake.FreshChecked -ge 1) -and ((Get-LastResult).Status -eq 'Nur Download') -and -not $State.SecurityBlocked
    }
    Test-Case 'Fresh: a security error blocks the new installation' {
        Set-FreshRun
        $Fake.Release = New-FakeRelease 'v0.14.0' @()
        $Fake.CandidateError['FigCraft'] = ($SecurityPrefix + 'X')
        Invoke-FreshInstall @('FigCraft') -Approved
        $State.SecurityBlocked -and (@($State.Results | Where-Object { $_.Program -eq 'FigCraft' -and $_.Status -eq 'Sicherheitsfehler' }).Count -eq 1) -and
        (@($State.Results | Where-Object { $_.Status -match '^Installiert' }).Count -eq 0)
    }
    Test-Case 'Fresh: install step and preflight use the new-installation check' {
        ([regex]::Matches($UpdaterText,[regex]::Escape('if ($item.Fresh) { Test-FreshInstallCandidate $item } else { Test-InstallationCandidate $item }'))).Count -eq 2
    }
    Test-Case 'Fresh: only per-machine installers are accepted' {
        ((Get-MsiScopeArguments @{ ALLUSERS='1'; MSIINSTALLPERUSER='' }) -eq '') -and
        ((Get-MsiScopeArguments @{ ALLUSERS='2'; MSIINSTALLPERUSER='1' }) -like '*ALLUSERS=2*') -and
        ((Get-ThrowMessage { Get-MsiScopeArguments @{ ALLUSERS=''; MSIINSTALLPERUSER='' } }) -like '*Installationskontext*')
    }
    Test-Case 'Fresh: texts say "newly installed" and are counted on their own' {
        $row = Get-RowVersionTexts ([pscustomobject]@{ Installed=''; Latest='0.3.2'; Status='Installiert (neu) - nachgeprueft' })
        $sum = Get-SummaryText ([pscustomobject]@{ Updated=0; Fresh=1; Current=3; Missing=0; Rejected=0; Problems=0; Skipped=0; Reboot=$false; SecurityBlocked=$false }) ''
        ((Get-FriendlyStatus 'Installiert (neu) - nachgeprueft') -eq 'Neu installiert') -and
        ((Get-FriendlyStatus 'Installiert (neu) - Neustart erforderlich') -eq 'Neu installiert - Neustart nötig') -and
        ($row[0] -eq 'v0.3.2') -and ($sum[0] -like 'Fertig!*neu installiert*') -and ($sum[2] -ne '')
    }
    Set-Item -Path Function:\Get-VerifiedInstaller -Value $RealVerifiedInstaller

    Test-Case 'Window: skipping hides the notice for this window too' {
        ($UpdaterText -match [regex]::Escape('if (Save-SkippedUpdaterVersion ([string]$notice.Version)) { $sync.UpdaterUpdate = $null; $updateLink.Visible = $false }')) -and
        ($UpdaterText -match [regex]::Escape("'skip'"))
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
