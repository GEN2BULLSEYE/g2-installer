# --- 1. Environment Setup ---
$INSTALL_DIR = "$env:ProgramData\g2serve"
$CONFIG_FILE = "$INSTALL_DIR\agent.json"
$AGENT_PATH  = "$INSTALL_DIR\g2agent.ps1"
$PULL_PATH   = "$INSTALL_DIR\pull-agent.ps1"
$GEN2_BASE_URL = "https://gen2bullseye.com"
$FIXED_WEBHOOK_URL = "https://nscl.tailc52c94.ts.net/webhook/ps2"

# --- 2. Existing Installation Detection ---
$TaskMonitor = Get-ScheduledTask -TaskName "G2_Monitor_Agent" -ErrorAction SilentlyContinue
$TaskPull = Get-ScheduledTask -TaskName "G2_Pull_Agent" -ErrorAction SilentlyContinue

if ($TaskMonitor -or $TaskPull -or (Test-Path $INSTALL_DIR)) {
    Write-Host "--- Existing GEN2 Installation Detected ---" -ForegroundColor Yellow
    $confirm = Read-Host "An existing installation was found. Would you like to UNINSTALL it first? (y/n)"
    
    if ($confirm -eq 'y') {
        Write-Host "Removing existing tasks and files..." -ForegroundColor Cyan
        Unregister-ScheduledTask -TaskName "G2_Monitor_Agent" -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "G2_Pull_Agent" -Confirm:$false -ErrorAction SilentlyContinue
        Get-Job | Stop-Job -ErrorAction SilentlyContinue
        if (Test-Path $INSTALL_DIR) { Remove-Item -Recurse -Force $INSTALL_DIR }
        Write-Host "Cleanup complete.`n" -ForegroundColor Green
    }
}

# --- 3. Fresh Installation ---
if (!(Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Path $INSTALL_DIR -Force }

Write-Host "--- GEN2 Windows Ground Probe Setup ---" -ForegroundColor Cyan
$OrgId    = Read-Host "Organization ID"
$License  = Read-Host "License Key"
$ServerId = Read-Host "Server ID (Friendly Name)"

$InitConfig = @{
    ORG_ID = $OrgId
    LICENSE_KEY = $License
    SERVER_ID = $ServerId
    TARGETS = @()
}
$InitConfig | ConvertTo-Json | Out-File $CONFIG_FILE -Encoding utf8

# --- 4. Write the Agent Script (Using Literal String) ---
$agentCode = @'
$Config = Get-Content "C:\ProgramData\g2serve\agent.json" | ConvertFrom-Json
$LocalIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike '*Loopback*' }).IPAddress[0]
$WanIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip").Trim()
$WifiSSID = (netsh wlan show interfaces | Select-String "SSID" | Select-Object -First 1).ToString().Split(":")[1].Trim()
if (!$WifiSSID) { $WifiSSID = "N/A" }

foreach ($entry in $Config.TARGETS) {
    Start-Job -ScriptBlock {
        param($entry, $Config, $LocalIP, $WanIP, $WifiSSID)
        $Webhook = "https://nscl.tailc52c94.ts.net/webhook/ps2"
        $parts = $entry -split '\|'
        $Name = $parts[0].Trim(); $Target = $parts[1].Trim()
        $ping = Test-Connection -ComputerName ($Target -replace 'https?://', '') -Count 2 -ErrorAction SilentlyContinue
        $PingLat = if ($ping) { $ping.ResponseTime.Average } else { 0 }
        $HttpStatus = "n/a"; $HttpLat = 0
        if ($Target -like "http*") {
            try {
                $s = Get-Date; $res = Invoke-WebRequest -Uri $Target -UseBasicParsing -TimeoutSec 3
                $HttpLat = ((Get-Date) - $s).TotalMilliseconds; $HttpStatus = "up"
            } catch { $HttpStatus = "down" }
        }
        $Payload = @{
            org_id = $Config.ORG_ID; license_key = $Config.LICENSE_KEY; server_id = $Config.SERVER_ID
            local_ip = $LocalIP; wan_ip = $WanIP; wifi_ssid = $WifiSSID
            monitor = $Name; target = $Target; ping_status = if($ping){"up"}else{"down"}
            ping_latency_ms = $PingLat; http_status = $HttpStatus; http_latency_ms = $HttpLat
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        Invoke-RestMethod -Uri $Webhook -Method Post -ContentType "application/json" -Body (ConvertTo-Json $Payload)
    } -ArgumentList $entry, $Config, $LocalIP, $WanIP, $WifiSSID
}
'@
$agentCode | Out-File $AGENT_PATH -Encoding utf8

# --- 5. Write the Pull Agent (Using Literal String) ---
# We hardcode the base URL here to avoid variable injection issues during setup
$pullCode = @'
$CONFIG_FILE = "C:\ProgramData\g2serve\agent.json"
$GEN2_BASE_URL = "https://gen2bullseye.com"
if (!(Test-Path $CONFIG_FILE)) { exit 1 }
$Config = Get-Content $CONFIG_FILE | ConvertFrom-Json
try {
    $uri = "$GEN2_BASE_URL/api/groundprobe/jobs?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
    $jobs = Invoke-RestMethod -Uri $uri -Method Get
} catch { exit 1 }
if ($null -eq $jobs) { exit 0 }
foreach ($job in $jobs) {
    $Current = [System.Collections.Generic.List[string]]::new($Config.TARGETS)
    if ($job.action -eq "add") {
        $entry = "$($job.monitor_name) | $($job.target)"
        if (!($Current -contains $entry)) { $Current.Add($entry) }
    } elseif ($job.action -eq "remove") {
        $Current.RemoveAll({ param($t) $t.Split('|')[0].Trim() -eq $job.monitor_name })
    }
    $Config.TARGETS = $Current.ToArray()
    $Config | ConvertTo-Json | Out-File $CONFIG_FILE -Encoding utf8
    $ackUri = "$GEN2_BASE_URL/api/groundprobe/jobs/$($job.id)/ack?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
    Invoke-WebRequest -Uri $ackUri -Method Post
}
'@
$pullCode | Out-File $PULL_PATH -Encoding utf8

# --- 6. Task Registration ---
Write-Host "Registering Scheduled Tasks..." -ForegroundColor Yellow
$ActionMonitor = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -File `"$AGENT_PATH`""
$TriggerMonitor = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "G2_Monitor_Agent" -Action $ActionMonitor -Trigger $TriggerMonitor -User "System" -Force

$ActionPull = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -File `"$PULL_PATH`""
$TriggerPull = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "G2_Pull_Agent" -Action $ActionPull -Trigger $TriggerPull -User "System" -Force

Write-Host "`nInstallation Complete!" -ForegroundColor Green
