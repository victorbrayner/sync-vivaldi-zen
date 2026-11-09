#requires -Version 5.1
<#
    Vivaldi Tabs Agent
    ------------------
    Receives tab snapshots from the Vivaldi extension over HTTP on loopback,
    writes tabs.json / tabs-data.js and a periodic heartbeat into the folder
    shared by Syncthing.

    No administrator rights are required: the agent uses a TcpListener bound
    to 127.0.0.1 instead of HttpListener (which would need a URL ACL).
#>

$ErrorActionPreference = 'Stop'

$script:AgentVersion = '1.0.0'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LogPath = Join-Path $PSScriptRoot 'agent.log'
$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:TemplatePath = Join-Path $PSScriptRoot 'index.template.html'

function Write-Log {
    param([string]$Message)
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    try {
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8NoBom)
    } catch {
        # Logging must never take the agent down.
    }
    Write-Host $line
}

function Get-IsoNow {
    return (Get-Date).ToUniversalTime().ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-SnapshotHash {
    param([string]$Body)
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $Body,
        '"generatedAt"\s*:\s*"[^"]*"',
        '"generatedAt":""'
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Write-FileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.tmp-' + [Guid]::NewGuid().ToString('N') + '.part')
    [System.IO.File]::WriteAllText($temporary, $Content, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-AgentConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Missing config file: $script:ConfigPath"
    }

    $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $port = 8765
    if ($null -ne $config.port) { $port = [int]$config.port }
    if ($port -lt 1 -or $port -gt 65535) { throw "Invalid port in config.json: $port" }

    $outputDir = [string]$config.outputDir
    if ([string]::IsNullOrWhiteSpace($outputDir)) { throw 'outputDir is required in config.json' }
    $outputDir = [Environment]::ExpandEnvironmentVariables($outputDir)
    if (-not [System.IO.Path]::IsPathRooted($outputDir)) {
        $outputDir = Join-Path $PSScriptRoot $outputDir
    }
    $outputDir = [System.IO.Path]::GetFullPath($outputDir)

    $heartbeatSeconds = 60
    if ($null -ne $config.heartbeatSeconds) { $heartbeatSeconds = [int]$config.heartbeatSeconds }
    if ($heartbeatSeconds -lt 10) { $heartbeatSeconds = 10 }

    $device = [string]$config.deviceName
    if ([string]::IsNullOrWhiteSpace($device)) { $device = $env:COMPUTERNAME }

    return [pscustomobject]@{
        Port             = $port
        OutputDir        = $outputDir
        Device           = $device
        HeartbeatSeconds = $heartbeatSeconds
    }
}

function Write-Heartbeat {
    $heartbeat = [ordered]@{
        device       = $script:Device
        agentVersion = $script:AgentVersion
        agentAt      = Get-IsoNow
        extensionAt  = $script:ExtensionAt
        snapshotAt   = $script:SnapshotAt
    }
    $json = $heartbeat | ConvertTo-Json -Compress -Depth 5
    Write-FileAtomic (Join-Path $script:OutputDir 'heartbeat.json') $json
    Write-FileAtomic (Join-Path $script:OutputDir 'heartbeat.js') ('window.__VIVALDI_HEARTBEAT__ = ' + $json + ';' + "`n")
}

function Publish-Viewer {
    if (-not (Test-Path -LiteralPath $script:TemplatePath)) {
        Write-Log "WARNING viewer template not found: $script:TemplatePath"
        return
    }
    $html = [System.IO.File]::ReadAllText($script:TemplatePath)
    Write-FileAtomic (Join-Path $script:OutputDir 'index.html') $html
    Write-Log 'viewer published as index.html'
}

function Save-Snapshot {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { throw 'empty snapshot body' }
    $Body = $Body.TrimStart([char]0xFEFF).Trim()
    if ($Body.Length -gt 5MB) { throw 'snapshot body too large' }

    # Validate before writing anything.
    $snapshot = $Body | ConvertFrom-Json
    if ($null -eq $snapshot.windows) { throw 'snapshot has no windows property' }

    $hash = Get-SnapshotHash $Body
    $changed = ($hash -ne $script:LastSnapshotHash)

    if ($changed) {
        Write-FileAtomic (Join-Path $script:OutputDir 'tabs.json') $Body
        Write-FileAtomic (Join-Path $script:OutputDir 'tabs-data.js') ('window.__VIVALDI_TABS__ = ' + $Body + ';' + "`n")
        $script:LastSnapshotHash = $hash
    }

    $script:ExtensionAt = Get-IsoNow
    # Read generatedAt from the raw body: ConvertFrom-Json may turn ISO strings
    # into DateTime objects and then re-format them with locale conventions.
    if ($Body -match '"generatedAt"\s*:\s*"([^"]+)"') {
        $script:SnapshotAt = $Matches[1]
    } else {
        $script:SnapshotAt = $script:ExtensionAt
    }

    # Always refresh the heartbeat so the viewer sees the extension is still
    # alive, even when the snapshot data itself has not changed.
    Write-Heartbeat

    if (-not $changed) {
        # Data is identical; keep the files untouched to avoid needless
        # Syncthing traffic. The heartbeat above already updated liveness.
        return
    }

    $tabCount = 0
    $windowCount = 0
    if ($null -ne $snapshot.tabCount) { $tabCount = [int]$snapshot.tabCount }
    if ($null -ne $snapshot.windowCount) { $windowCount = [int]$snapshot.windowCount }
    Write-Log "snapshot saved: $tabCount tab(s) in $windowCount window(s)"
}

function Read-HttpRequest {
    param([System.IO.Stream]$Stream)

    $buffer = New-Object byte[] 8192
    $memory = New-Object System.IO.MemoryStream
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        $memory.Write($buffer, 0, $read)
        $data = $memory.ToArray()

        for ($i = 3; $i -lt $data.Length; $i++) {
            if ($data[$i - 3] -eq 13 -and $data[$i - 2] -eq 10 -and
                $data[$i - 1] -eq 13 -and $data[$i] -eq 10) {
                $headerEnd = $i - 3
                break
            }
        }

        if ($memory.Length -gt 65536) { throw 'request headers too large' }
    }

    $all = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $bodyStart = $headerEnd + 4
    $lines = $headerText -split "`r`n"
    $requestLine = @($lines[0] -split ' ' | Where-Object { $_ -ne '' })
    if ($requestLine.Count -lt 2) { return $null }

    $contentLength = 0
    foreach ($line in $lines) {
        if ($line -match '^(?i)Content-Length:\s*(\d+)\s*$') {
            $contentLength = [int]$Matches[1]
        }
    }
    if ($contentLength -gt 5MB) { throw 'request body too large' }

    $bodyBytes = New-Object byte[] $contentLength
    $already = [Math]::Max(0, $all.Length - $bodyStart)
    if ($already -gt 0) {
        $copy = [Math]::Min($already, $contentLength)
        [Array]::Copy($all, $bodyStart, $bodyBytes, 0, $copy)
    }
    $total = [Math]::Min($already, $contentLength)
    while ($total -lt $contentLength) {
        $read = $Stream.Read($bodyBytes, $total, $contentLength - $total)
        if ($read -le 0) { break }
        $total += $read
    }

    $path = $requestLine[1]
    if ($path) {
        $queryIndex = $path.IndexOf('?')
        if ($queryIndex -ge 0) { $path = $path.Substring(0, $queryIndex) }
    }

    return [pscustomobject]@{
        Method = $requestLine[0].ToUpperInvariant()
        Path   = $path
        Body   = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $total)
    }
}

function Send-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$Reason,
        [string]$Body = '',
        [string]$ContentType = 'text/plain; charset=utf-8'
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $Status $Reason`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Content-Length: $($bodyBytes.Length)`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
            "Access-Control-Allow-Headers: Content-Type`r`n" +
            "Access-Control-Allow-Private-Network: true`r`n" +
            "Connection: close`r`n`r`n"

    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Handle-Client {
    param([System.Net.Sockets.TcpClient]$Client)

    $Client.ReceiveTimeout = 5000
    $stream = $Client.GetStream()
    $request = Read-HttpRequest -Stream $stream
    if ($null -eq $request) { return }

    if ($request.Method -eq 'OPTIONS') {
        Send-HttpResponse -Stream $stream -Status 204 -Reason 'No Content'
        return
    }

    try {
        if ($request.Method -eq 'POST' -and $request.Path -eq '/snapshot') {
            Save-Snapshot -Body $request.Body
            Send-HttpResponse -Stream $stream -Status 204 -Reason 'No Content'
            return
        }

        if ($request.Method -eq 'POST' -and $request.Path -eq '/ping') {
            $script:ExtensionAt = Get-IsoNow
            Send-HttpResponse -Stream $stream -Status 204 -Reason 'No Content'
            return
        }

        if ($request.Method -eq 'GET' -and $request.Path -eq '/') {
            Send-HttpResponse -Stream $stream -Status 200 -Reason 'OK' -Body 'Vivaldi Tabs Agent is running.'
            return
        }

        if ($request.Method -eq 'GET' -and $request.Path -eq '/health') {
            $health = [ordered]@{
                status      = 'ok'
                device      = $script:Device
                agentAt     = Get-IsoNow
                extensionAt = $script:ExtensionAt
                snapshotAt  = $script:SnapshotAt
            } | ConvertTo-Json -Compress -Depth 5
            Send-HttpResponse -Stream $stream -Status 200 -Reason 'OK' -Body $health -ContentType 'application/json; charset=utf-8'
            return
        }

        Send-HttpResponse -Stream $stream -Status 404 -Reason 'Not Found'
    } catch {
        Write-Log "ERROR processing $($request.Method) $($request.Path): $_"
        try {
            Send-HttpResponse -Stream $stream -Status 400 -Reason 'Bad Request' -Body 'Invalid request.'
        } catch {
            # The client may already have disconnected.
        }
    }
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

try {
    if (Test-Path -LiteralPath $script:LogPath) {
        $size = (Get-Item -LiteralPath $script:LogPath).Length
        if ($size -gt 5MB) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
    }
} catch {
    # Ignore log rotation problems.
}

try {
    $config = Get-AgentConfig
} catch {
    Write-Log "ERROR reading config.json: $_"
    exit 1
}

$script:Device = $config.Device
$script:OutputDir = $config.OutputDir
$script:ExtensionAt = $null
$script:SnapshotAt = $null

try {
    if (-not (Test-Path -LiteralPath $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
        Write-Log "created output directory: $script:OutputDir"
    }
} catch {
    Write-Log "ERROR creating output directory $($script:OutputDir): $_"
    exit 1
}

# Seed the heartbeat from the previous run so the viewer does not briefly
# claim the extension was never seen.
$heartbeatPath = Join-Path $script:OutputDir 'heartbeat.json'
if (Test-Path -LiteralPath $heartbeatPath) {
    try {
        $previousText = Get-Content -LiteralPath $heartbeatPath -Raw -Encoding UTF8
        if ($previousText -match '"extensionAt"\s*:\s*"([^"]+)"') {
            $script:ExtensionAt = $Matches[1]
        }
        if ($previousText -match '"snapshotAt"\s*:\s*"([^"]+)"') {
            $script:SnapshotAt = $Matches[1]
        }
    } catch {
        Write-Log 'WARNING could not read previous heartbeat'
    }
}

$script:LastSnapshotHash = $null
$previousTabsPath = Join-Path $script:OutputDir 'tabs.json'
if (Test-Path -LiteralPath $previousTabsPath) {
    try {
        $script:LastSnapshotHash = Get-SnapshotHash ([System.IO.File]::ReadAllText($previousTabsPath))
    } catch {
        Write-Log 'WARNING could not read previous snapshot'
    }
}

try {
    Publish-Viewer
    Write-Heartbeat
} catch {
    Write-Log "ERROR publishing viewer files: $_"
    exit 1
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $config.Port)
try {
    $listener.Start()
} catch {
    Write-Log "ERROR could not listen on 127.0.0.1:$($config.Port): $_"
    exit 1
}

Write-Log "agent $script:AgentVersion listening on http://127.0.0.1:$($config.Port)"
Write-Log "writing to $script:OutputDir"

$nextHeartbeat = (Get-Date).AddSeconds($config.HeartbeatSeconds)

try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try {
                Handle-Client -Client $client
            } catch {
                Write-Log "ERROR handling request: $_"
            } finally {
                $client.Close()
            }
        }

        if ((Get-Date) -ge $nextHeartbeat) {
            try {
                Write-Heartbeat
            } catch {
                Write-Log "ERROR writing heartbeat: $_"
            }
            $nextHeartbeat = (Get-Date).AddSeconds($config.HeartbeatSeconds)
        }

        Start-Sleep -Milliseconds 100
    }
} finally {
    $listener.Stop()
    Write-Log 'agent stopped'
}
