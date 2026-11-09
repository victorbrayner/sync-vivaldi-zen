#requires -Version 5.1
<#
    Installs (or removes) the Vivaldi Tabs Agent as a scheduled task that
    starts at user logon.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\install-agent.ps1
        powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Uninstall
#>

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$taskName = 'VivaldiTabsAgent'
$agentScript = Join-Path $PSScriptRoot 'agent.ps1'
$configPath = Join-Path $PSScriptRoot 'config.json'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Windows PowerShell 5.1 or newer is required.'
}

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'."
    } else {
        Write-Host "Scheduled task '$taskName' was not installed."
    }
    Write-Host 'The agent files were left untouched.'
    exit 0
}

if (-not (Test-Path -LiteralPath $agentScript)) {
    throw "agent.ps1 not found next to this script: $agentScript"
}
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "config.json not found next to this script: $configPath"
}

try {
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "config.json is not valid JSON: $_"
}

$outputDir = [Environment]::ExpandEnvironmentVariables([string]$config.outputDir)
if (-not [System.IO.Path]::IsPathRooted($outputDir)) {
    $outputDir = Join-Path $PSScriptRoot $outputDir
}
$outputDir = [System.IO.Path]::GetFullPath($outputDir)

if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Write-Host "Created output directory: $outputDir"
}

$port = 8765
if ($null -ne $config.port) { $port = [int]$config.port }
$inUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($inUse) {
    Write-Warning "Port $port is already in use. Change 'port' in config.json and in extension/background.js before starting."
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$agentScript`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$description = 'Sends Vivaldi open tabs to the Syncthing folder (Abas do Vivaldi).'

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description $description `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host ''
Write-Host "Scheduled task '$taskName' installed and started."
Write-Host "Agent folder : $PSScriptRoot"
Write-Host "Output folder: $outputDir"
Write-Host "Local port   : $port"
Write-Host ''
Write-Host 'Check agent.log in this folder for activity.'
Write-Host 'To remove it later, run this script again with -Uninstall.'
