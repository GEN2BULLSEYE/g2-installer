<#
.SYNOPSIS
    GEN2 Windows Ground Probe — unified installer and agent script.

.DESCRIPTION
    Run without arguments to install (Setup mode).
    Scheduled Tasks invoke this same script with -Mode Monitor or -Mode Pull.

    To run directly from GitHub (recommended):
        $u = "https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/refs/heads/main/setup-g2.ps1"
        & ([scriptblock]::Create((irm $u))) -ScriptUrl $u

.PARAMETER Mode
    Setup   — (default) Installs, uninstalls, or reconfigures the agent.
    Monitor — Runs one monitoring pass (called every minute by Scheduled Task).
    Pull    — Runs one job-pull pass (called every 5 minutes by Scheduled Task).

.PARAMETER ScriptUrl
    Raw GitHub URL of this script. Required when running via irm/iex (no local file).
    Not needed when running from a saved .ps1 file.

.NOTES
    Must be run as Administrator for Setup mode.
    Monitor and Pull modes run as SYSTEM via Scheduled Tasks.
#>
param(
    [ValidateSet("Setup", "Monitor", "Pull")]
    [string]$Mode = "Setup",

    [string]$ScriptUrl = ""
)

# ============================================================
# SHARED CONSTANTS
# ============================================================
$INSTALL_DIR   = "$env:ProgramData\g2serve"
$CONFIG_FILE   = "$INSTALL_DIR\agent.json"
$AGENT_PATH    = "$INSTALL_DIR\g2agent.ps1"
$GEN2_BASE_URL = "https://gen2bullseye.com"
$WEBHOOK_URL   = "https://nscl.tailc52c94.ts.net/webhook/ps2"
$TASK_MONITOR  = "G2_Monitor_Agent"
$TASK_PULL     = "G2_Pull_Agent"

# ============================================================
# MODE: MONITOR — runs every 1 minute via Scheduled Task
# ============================================================
if ($Mode -eq "Monitor") {
    if (!(Test-Path $CONFIG_FILE)) { exit 1 }
    $Config = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json

    # Collect network info once per run
    try {
        $LocalIP = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.InterfaceAlias -notlike '*Loopback*' } |
            Select-Object -First 1).IPAddress
    } catch { $LocalIP = "unknown" }

    try {
        $WanIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 5).Trim()
    } catch { $WanIP = "unknown" }

    try {
        $WifiSSID = (netsh wlan show interfaces |
            Select-String "^\s+SSID\s+:" |
            Select-Object -First 1).ToString().Split(":")[1].Trim()
    } catch { $WifiSSID = "N/A" }
    if ([string]::IsNullOrWhiteSpace($WifiSSID)) { $WifiSSID = "N/A" }

    foreach ($entry in $Config.TARGETS) {
        $parts = $entry -split '\|'
        if ($parts.Count -lt 2) { continue }
        $Name   = $parts[0].Trim()
        $Target = $parts[1].Trim()
        if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Target)) { continue }
        $Host   = $Target -replace 'https?://', '' -replace '/.*', ''

        # Ping check — use .NET Ping directly (more reliable than Test-Connection under SYSTEM)
        $PingSt  = "down"
        $PingLat = 0
        try {
            $pinger = New-Object System.Net.NetworkInformation.Ping
            $total  = 0
            $count  = 0
            1..2 | ForEach-Object {
                $reply = $pinger.Send($Host, 2000)
                if ($reply.Status -eq "Success") {
                    $total += $reply.RoundtripTime
                    $count++
                }
            }
            if ($count -gt 0) {
                $PingSt  = "up"
                $PingLat = [Math]::Round($total / $count, 1)
            }
        } catch { <# ICMP blocked — leave as down #> }

        # HTTP check (only for http/https targets)
        $HttpStatus = "n/a"
        $HttpLat    = 0
        if ($Target -like "http*") {
            try {
                $sw  = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Invoke-WebRequest -Uri $Target -UseBasicParsing -TimeoutSec 5
                $sw.Stop()
                $HttpLat    = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                $HttpStatus = "up"
            } catch {
                $HttpStatus = "down"
            }
        }

        $Payload = @{
            org_id          = $Config.ORG_ID
            license_key     = $Config.LICENSE_KEY
            server_id       = $Config.SERVER_ID
            local_ip        = $LocalIP
            wan_ip          = $WanIP
            wifi_ssid       = $WifiSSID
            monitor         = $Name
            target          = $Target
            ping_status     = $PingSt
            ping_latency_ms = $PingLat
            http_status     = $HttpStatus
            http_latency_ms = $HttpLat
            timestamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }

        try {
            Invoke-RestMethod -Uri $WEBHOOK_URL -Method Post `
                -ContentType "application/json" `
                -Body ($Payload | ConvertTo-Json -Compress)
        } catch { <# non-fatal: network blip #> }
    }
    exit 0
}

# ============================================================
# MODE: PULL — runs every 5 minutes via Scheduled Task
# ============================================================
if ($Mode -eq "Pull") {
    if (!(Test-Path $CONFIG_FILE)) { exit 1 }
    $Config = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json

    try {
        $uri  = "$GEN2_BASE_URL/api/groundprobe/jobs?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
        $jobs = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
    } catch { exit 1 }

    if ($null -eq $jobs -or $jobs.Count -eq 0) { exit 0 }

    # Safely read TARGETS — PS 5.1 ConvertFrom-Json can return {} for an empty []
    $Current = [System.Collections.Generic.List[string]]::new()
    $rawTargets = $Config.TARGETS
    if ($rawTargets -is [System.Object[]]) {
        foreach ($t in $rawTargets) { if ($t -is [string] -and $t.Trim()) { $Current.Add($t) } }
    } elseif ($rawTargets -is [string] -and $rawTargets.Trim()) {
        $Current.Add($rawTargets)
    }

    foreach ($job in $jobs) {
        if ($job.action -eq "add") {
            $entry = "$($job.monitor_name) | $($job.target)"
            if (-not ($Current -contains $entry)) { $Current.Add($entry) }
        } elseif ($job.action -eq "remove") {
            $exactEntry = "$($job.monitor_name) | $($job.target)"
            if ($Current -contains $exactEntry) {
                $Current.Remove($exactEntry) | Out-Null
            } else {
                $toRemove = $Current | Where-Object { $_.Split('|')[0].Trim() -eq $job.monitor_name }
                foreach ($r in @($toRemove)) { $Current.Remove($r) | Out-Null }
            }
        }

        # Rebuild config as hashtable to ensure TARGETS always serializes as a JSON array (not {} or null)
        @{
            ORG_ID      = $Config.ORG_ID
            LICENSE_KEY = $Config.LICENSE_KEY
            SERVER_ID   = $Config.SERVER_ID
            TARGETS     = @($Current.ToArray())
        } | ConvertTo-Json -Depth 5 | Out-File $CONFIG_FILE -Encoding utf8

        try {
            $ackUri = "$GEN2_BASE_URL/api/groundprobe/jobs/$($job.id)/ack?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
            Invoke-WebRequest -Uri $ackUri -Method Post -UseBasicParsing | Out-Null
        } catch { <# non-fatal #> }
    }
    exit 0
}

# ============================================================
# MODE: SETUP — interactive installer (default)
# ============================================================

# Detect existing installation
$TaskMonitor = Get-ScheduledTask -TaskName $TASK_MONITOR -ErrorAction SilentlyContinue
$TaskPull    = Get-ScheduledTask -TaskName $TASK_PULL    -ErrorAction SilentlyContinue

if ($TaskMonitor -or $TaskPull -or (Test-Path $INSTALL_DIR)) {
    Write-Host ""
    Write-Host "--- Existing GEN2 Installation Detected ---" -ForegroundColor Yellow
    Write-Host "Choose an option:"
    Write-Host "  y) Uninstall and EXIT  (run the script again to reinstall)"
    Write-Host "  n) Overwrite / reconfigure without uninstalling"
    Write-Host "  q) Quit"
    $choice = Read-Host "Selection"

    if ($choice -eq 'y') {
        Write-Host "`nUninstalling GEN2..." -ForegroundColor Cyan
        Unregister-ScheduledTask -TaskName $TASK_MONITOR -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_PULL    -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $INSTALL_DIR) { Remove-Item -Recurse -Force $INSTALL_DIR }
        Write-Host "Uninstalled successfully. Run the script again to reinstall." -ForegroundColor Green
        exit 0
    } elseif ($choice -eq 'q') {
        exit 0
    }
    Write-Host "Continuing with setup...`n" -ForegroundColor Gray
}

# Create install directory
if (!(Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}

# Collect credentials
Write-Host ""
Write-Host "--- GEN2 Windows Ground Probe Setup ---" -ForegroundColor Cyan
$OrgId    = Read-Host "Organization ID"
$License  = Read-Host "License Key"
$ServerId = Read-Host "Server ID (friendly name for this machine)"

# Write config
@{
    ORG_ID      = $OrgId
    LICENSE_KEY = $License
    SERVER_ID   = $ServerId
    TARGETS     = @()
} | ConvertTo-Json | Out-File $CONFIG_FILE -Encoding utf8

# Copy / download this script to the install directory so Scheduled Tasks can reference it
$ScriptSource = $MyInvocation.MyCommand.Path

if (-not [string]::IsNullOrEmpty($ScriptSource)) {
    # Running from a saved file — just copy it
    Copy-Item -Path $ScriptSource -Destination $AGENT_PATH -Force
} elseif (-not [string]::IsNullOrEmpty($ScriptUrl)) {
    # Running from memory (irm | iex / scriptblock) — download from GitHub
    Write-Host "Downloading agent script from GitHub..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $AGENT_PATH -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to download script from: $ScriptUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "ERROR: Cannot place the agent script on disk." -ForegroundColor Red
    Write-Host "Either save the script as a .ps1 file and run it, or supply -ScriptUrl with the raw GitHub URL." -ForegroundColor Yellow
    exit 1
}

# Register Scheduled Tasks (both point to the single copied script)
Write-Host "`nRegistering Scheduled Tasks..." -ForegroundColor Yellow

$ActionMonitor = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Monitor"

$TriggerMonitor = New-ScheduledTaskTrigger `
    -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TASK_MONITOR `
    -Action   $ActionMonitor `
    -Trigger  $TriggerMonitor `
    -RunLevel Highest `
    -User     "SYSTEM" `
    -Force | Out-Null

$ActionPull = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Pull"

$TriggerPull = New-ScheduledTaskTrigger `
    -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName $TASK_PULL `
    -Action   $ActionPull `
    -Trigger  $TriggerPull `
    -RunLevel Highest `
    -User     "SYSTEM" `
    -Force | Out-Null

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "  Agent script : $AGENT_PATH"
Write-Host "  Config file  : $CONFIG_FILE"
Write-Host "  $TASK_MONITOR  — runs every 1 minute"
Write-Host "  $TASK_PULL     — runs every 5 minutes"
Write-Host ""
Write-Host "Run this script again at any time to uninstall or reconfigure." -ForegroundColor Gray
