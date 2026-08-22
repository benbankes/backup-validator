#Requires -Version 5.1
<#
.SYNOPSIS
  Switch Codex Desktop between Windows-native mode and a specific WSL distro.

.DESCRIPTION
  Codex Desktop picks one WSL distro for the whole app: the default (*) from
  `wsl --list --verbose`. It also caches that choice in a long-lived app-server,
  so closing the window is not enough.

  Important - Set up a new project in a WSL distro or Windows ONLY after running this script.

  This script:
    1. Stops Codex Desktop (so it cannot overwrite config.toml on exit, and so new settings take effect on relaunch)
    2. Sets the WSL default distro, or leaves it alone for Windows-native mode
    3. Updates [desktop] in %USERPROFILE%\.codex\config.toml
    4. Warns if Docker Desktop WSL integration does not include the distro
    5. Relaunches Codex if it was running (or if -Restart is passed)

.EXAMPLE
  .\Switch-CodexRuntime.ps1 -List
  .\Switch-CodexRuntime.ps1 Windows
  .\Switch-CodexRuntime.ps1 Ubuntu-22.04
  .\Switch-CodexRuntime.ps1 pgz
  .\Switch-CodexRuntime.ps1 Ubuntu-26.04-Backup-Validator -Restart
#>
[CmdletBinding(DefaultParameterSetName = 'Switch')]
param(
    [Parameter(ParameterSetName = 'Switch', Position = 0)]
    [string]$Target,

    [Parameter(ParameterSetName = 'Status')]
    [Alias('Status')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Switch')]
    [switch]$Restart,

    [Parameter(ParameterSetName = 'Switch')]
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Friendly names you can pass instead of the exact WSL distro name.
# Edit this table if you add distros or want different shortcuts.
$Script:Aliases = @{
    'windows'        = 'windows'
    'win'            = 'windows'
    'native'         = 'windows'
    'pgz'            = 'Ubuntu-22.04'
    'playground'     = 'Ubuntu-22.04'
    'playgroundzend' = 'Ubuntu-22.04'
}

$Script:CodexHome = Join-Path $env:USERPROFILE '.codex'
$Script:ConfigPath = Join-Path $Script:CodexHome 'config.toml'
$Script:DockerSettingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
$Script:SkipDistroPattern = '^(docker-desktop|docker-desktop-data)$'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Get-WslListText {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = '--list --verbose'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "wsl --list --verbose failed (exit $($proc.ExitCode)): $stderr"
    }
    return $stdout
}

function Get-WslDistros {
    $text = Get-WslListText
    $distros = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($text -split "`r?`n")) {
        $trim = $line.Trim()
        if (-not $trim -or $trim -match '^NAME\b') {
            continue
        }
        $isDefault = $trim.StartsWith('*')
        $rest = $trim.TrimStart('*').Trim()
        $parts = @($rest -split '\s{2,}')
        if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            continue
        }
        $name = $parts[0]
        $state = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $version = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        $distros.Add([pscustomobject]@{
            Name      = $name
            IsDefault = $isDefault
            State     = $state
            Version   = $version
            Selectable = ($name -notmatch $Script:SkipDistroPattern)
        })
    }
    return $distros
}

function Get-DefaultWslDistro {
    param($Distros)
    $match = $Distros | Where-Object { $_.IsDefault } | Select-Object -First 1
    if ($match) { return $match.Name }
    return $null
}

function Get-TomlDesktopValue {
    param(
        [string]$Text,
        [string]$Key
    )
    $pattern = "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$"
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) {
        return $null
    }
    return $m.Groups[1].Value.Trim().Trim('"')
}

function Get-CodexDesktopSettings {
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        return [pscustomobject]@{
            WslMode = $null
            Shell   = $null
            Exists  = $false
        }
    }
    $text = [System.IO.File]::ReadAllText($Script:ConfigPath)
    return [pscustomobject]@{
        WslMode = Get-TomlDesktopValue -Text $text -Key 'runCodexInWindowsSubsystemForLinux'
        Shell   = Get-TomlDesktopValue -Text $text -Key 'integratedTerminalShell'
        Exists  = $true
    }
}

function Get-DockerIntegratedDistros {
    if (-not (Test-Path -LiteralPath $Script:DockerSettingsPath)) {
        return @()
    }
    try {
        $json = Get-Content -LiteralPath $Script:DockerSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json.IntegratedWslDistros) {
            return @()
        }
        return @($json.IntegratedWslDistros)
    } catch {
        return @()
    }
}

function Show-RuntimeStatus {
    $distros = @(Get-WslDistros)
    $defaultDistro = Get-DefaultWslDistro -Distros $distros
    $codex = Get-CodexDesktopSettings
    $docker = @(Get-DockerIntegratedDistros)
    $codexRunning = @(Get-CodexDesktopProcesses)

    Write-Host ''
    Write-Host 'Codex / WSL runtime' -ForegroundColor White
    Write-Host ('  WSL default distro : {0}' -f $(if ($defaultDistro) { $defaultDistro } else { '(none)' }))
    Write-Host ('  Codex WSL mode     : {0}' -f $(if ($null -ne $codex.WslMode) { $codex.WslMode } else { '(unset)' }))
    Write-Host ('  Codex terminal     : {0}' -f $(if ($codex.Shell) { $codex.Shell } else { '(unset)' }))
    Write-Host ('  Codex Desktop      : {0}' -f $(if ($codexRunning.Count -gt 0) { "running ($($codexRunning.Count) processes)" } else { 'not running' }))
    if ($docker.Count -gt 0) {
        Write-Host ('  Docker WSL integ.  : {0}' -f ($docker -join ', '))
    } else {
        Write-Host '  Docker WSL integ.  : (settings-store.json not found or empty)'
    }
    Write-Host ''
    Write-Host 'Distros:' -ForegroundColor White
    foreach ($d in $distros) {
        $marker = if ($d.IsDefault) { '*' } else { ' ' }
        $note = @()
        if (-not $d.Selectable) { $note += 'skipped' }
        $suffix = if ($note.Count -gt 0) { '  (' + ($note -join ', ') + ')' } else { '' }
        Write-Host ("  {0} {1,-36} {2,-12} {3}{4}" -f $marker, $d.Name, $d.State, $d.Version, $suffix)
    }
    Write-Host ''
    Write-Host 'Aliases: windows, win, native, pgz, playground  (edit $Aliases in this script to add more)' -ForegroundColor DarkGray
}

function Resolve-RuntimeTarget {
    param(
        [string]$InputName,
        $Distros
    )
    $selectable = @($Distros | Where-Object { $_.Selectable })
    $raw = $InputName.Trim()
    $key = $raw.ToLowerInvariant()

    if ($Script:Aliases.ContainsKey($key)) {
        $raw = $Script:Aliases[$key]
        $key = $raw.ToLowerInvariant()
    }

    if ($key -eq 'windows') {
        return [pscustomobject]@{ Kind = 'windows'; Distro = $null }
    }

    $exact = @($selectable | Where-Object { $_.Name -eq $raw })
    if ($exact.Count -eq 1) {
        return [pscustomobject]@{ Kind = 'wsl'; Distro = $exact[0].Name }
    }

    $ci = @($selectable | Where-Object { $_.Name.ToLowerInvariant() -eq $key })
    if ($ci.Count -eq 1) {
        return [pscustomobject]@{ Kind = 'wsl'; Distro = $ci[0].Name }
    }

    $prefix = @($selectable | Where-Object { $_.Name.ToLowerInvariant().StartsWith($key) })
    if ($prefix.Count -eq 1) {
        return [pscustomobject]@{ Kind = 'wsl'; Distro = $prefix[0].Name }
    }
    if ($prefix.Count -gt 1) {
        throw "Ambiguous distro '$InputName'. Matches: $(($prefix | ForEach-Object { $_.Name }) -join ', ')"
    }

    $available = ($selectable | ForEach-Object { $_.Name }) -join ', '
    throw "Unknown target '$InputName'. Use Windows or a distro name ($available)."
}

function Get-CodexDesktopProcesses {
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = $proc.Path } catch { $path = $null }
        if ([string]::IsNullOrEmpty($path)) {
            continue
        }
        $hit = ($path -like '*\OpenAI.Codex_*') -or
               ($path -like '*\Packages\OpenAI.Codex_*') -or
               ($path -like '*\Local\OpenAI\Codex\*')
        if ($hit) {
            $matches.Add($proc)
        }
    }
    return $matches
}

function Stop-CodexDesktop {
    $procs = @(Get-CodexDesktopProcesses)
    if ($procs.Count -eq 0) {
        Write-Ok 'Codex Desktop was not running.'
        return $false
    }
    Write-Step ("Stopping Codex Desktop ({0} processes)..." -f $procs.Count)
    foreach ($proc in $procs) {
        Write-Host ("    stopping {0} pid={1}" -f $proc.ProcessName, $proc.Id)
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 300
        $left = @(Get-CodexDesktopProcesses)
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)
    $left = @(Get-CodexDesktopProcesses)
    if ($left.Count -gt 0) {
        throw "Codex Desktop did not exit. Still running: $($left.ProcessName -join ', '). End them in Task Manager and re-run."
    }
    Write-Ok 'Codex Desktop stopped.'
    return $true
}

function Start-CodexDesktop {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) {
        throw 'OpenAI.Codex Appx package not found. Start Codex from the Start menu after this script finishes.'
    }
    $manifest = Get-AppxPackageManifest -Package $pkg
    $appId = $manifest.Package.Applications.Application.Id
    if ($appId -is [array]) {
        $appId = $appId | Select-Object -First 1
    }
    $aumid = '{0}!{1}' -f $pkg.PackageFamilyName, $appId
    Write-Step "Launching Codex Desktop ($aumid)..."
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid"
    Write-Ok 'Launch requested.'
}

function Set-TomlDesktopKey {
    param(
        [string]$Text,
        [string]$Key,
        [string]$Value
    )
    $pattern = "(?m)^(\s*)$([regex]::Escape($Key))\s*=\s*.*$"
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, "`${1}$Key = $Value", 1)
    }
    $desktopPattern = '(?m)^\[desktop\][ \t]*\r?$'
    if (-not [regex]::IsMatch($Text, $desktopPattern)) {
        throw "config.toml has no [desktop] section; expected it at $Script:ConfigPath"
    }
    $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    return [regex]::Replace($Text, $desktopPattern, "[desktop]$nl$Key = $Value", 1)
}

function Update-CodexDesktopConfig {
    param(
        [bool]$UseWsl
    )
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        throw "Codex config not found: $Script:ConfigPath"
    }
    $original = [System.IO.File]::ReadAllText($Script:ConfigPath)
    $wslValue = if ($UseWsl) { 'true' } else { 'false' }
    $shellValue = if ($UseWsl) { '"wsl"' } else { '"powershell"' }
    $updated = Set-TomlDesktopKey -Text $original -Key 'runCodexInWindowsSubsystemForLinux' -Value $wslValue
    $updated = Set-TomlDesktopKey -Text $updated -Key 'integratedTerminalShell' -Value $shellValue
    if ($updated -eq $original) {
        Write-Ok 'config.toml already had the requested [desktop] values.'
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = '{0}.{1}.bak' -f $Script:ConfigPath, $stamp
    Copy-Item -LiteralPath $Script:ConfigPath -Destination $backup -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Script:ConfigPath, $updated, $utf8NoBom)
    Write-Ok ("Updated {0} (backup {1})" -f $Script:ConfigPath, (Split-Path $backup -Leaf))
    Write-Ok ("runCodexInWindowsSubsystemForLinux = {0}" -f $wslValue)
    Write-Ok ("integratedTerminalShell = {0}" -f $shellValue)
}

function Set-DefaultWslDistro {
    param([string]$Name)
    Write-Step "Setting default WSL distro to $Name..."
    & wsl.exe --set-default $Name
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --set-default $Name failed with exit $LASTEXITCODE"
    }
    $distros = @(Get-WslDistros)
    $actual = Get-DefaultWslDistro -Distros $distros
    if ($actual -ne $Name) {
        throw "Default distro is '$actual' after set-default; expected '$Name'."
    }
    Write-Ok "Default distro is now $actual."
}

function Assert-DockerIntegration {
    param([string]$Distro)
    $integrated = @(Get-DockerIntegratedDistros)
    if ($integrated.Count -eq 0) {
        Write-Warning 'Could not read Docker Desktop IntegratedWslDistros. If you need docker from this distro, enable it in Docker Desktop > Settings > Resources > WSL integration.'
        return
    }
    if ($integrated -contains $Distro) {
        Write-Ok "Docker Desktop WSL integration already includes $Distro."
        return
    }
        Write-Warning ("Docker Desktop WSL integration does not include {0}. Enable it in Docker Desktop > Settings > Resources > WSL integration, then Apply. Currently integrated: {1}" -f $Distro, ($integrated -join ', '))
}

function Read-InteractiveTarget {
    param($Distros)
    $selectable = @($Distros | Where-Object { $_.Selectable })
    Show-RuntimeStatus
    Write-Host 'Switch to:' -ForegroundColor White
    Write-Host '  0) Windows (native agent + PowerShell terminal)'
    for ($i = 0; $i -lt $selectable.Count; $i++) {
        Write-Host ('  {0}) {1}' -f ($i + 1), $selectable[$i].Name)
    }
    Write-Host '  Q) Quit'
    $choice = Read-Host 'Choice'
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match '^[Qq]$') {
        return $null
    }
    if ($choice -eq '0') {
        return 'windows'
    }
    $asInt = 0
    if ([int]::TryParse($choice, [ref]$asInt) -and $asInt -ge 1 -and $asInt -le $selectable.Count) {
        return $selectable[$asInt - 1].Name
    }
    return $choice
}

try {
    $distros = @(Get-WslDistros)
    if ($List) {
        Show-RuntimeStatus
        exit 0
    }

    $chosen = $Target
    if ([string]::IsNullOrWhiteSpace($chosen)) {
        $chosen = Read-InteractiveTarget -Distros $distros
        if ([string]::IsNullOrWhiteSpace($chosen)) {
            Write-Host 'No change.'
            exit 0
        }
    }

    $resolved = Resolve-RuntimeTarget -InputName $chosen -Distros $distros
    $wasRunning = $false

    Write-Host ''
    if ($resolved.Kind -eq 'windows') {
        Write-Step 'Switching Codex Desktop to Windows-native mode.'
        $wasRunning = Stop-CodexDesktop
        Update-CodexDesktopConfig -UseWsl:$false
        $keep = Get-DefaultWslDistro -Distros @(Get-WslDistros)
        Write-Ok ('Left WSL default as {0} (unused while Codex is in Windows mode).' -f $keep)
    } else {
        Write-Step ("Switching Codex Desktop to WSL distro {0}." -f $resolved.Distro)
        $wasRunning = Stop-CodexDesktop
        Set-DefaultWslDistro -Name $resolved.Distro
        Update-CodexDesktopConfig -UseWsl:$true
        Assert-DockerIntegration -Distro $resolved.Distro
    }

    $shouldRestart = $false
    if ($NoRestart) {
        $shouldRestart = $false
    } elseif ($Restart) {
        $shouldRestart = $true
    } elseif ($wasRunning) {
        $shouldRestart = $true
    }

    if ($shouldRestart) {
        Start-CodexDesktop
    } else {
        Write-Ok 'Codex was left stopped. Start it from the Start menu, or re-run with -Restart.'
    }

    Write-Host ''
    Show-RuntimeStatus
} catch {
    Write-Error $_
    exit 1
}
