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
        $TargetHost = $Target -replace 'https?://', '' -replace '/.*', ''

        # Ping check — use .NET Ping directly (more reliable than Test-Connection under SYSTEM)
        $PingSt  = "down"
        $PingLat = 0
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $total  = 0
        $count  = 0
        foreach ($i in 1..2) {
            try {
                $reply = $pinger.Send($TargetHost, 2000)
                if ($reply.Status -eq "Success") {
                    $total += $reply.RoundtripTime
                    $count++
                }
            } catch { <# ignore individual ping failure #> }
        }
        if ($count -gt 0) {
            $PingSt  = "up"
            $PingLat = [Math]::Round($total / $count, 1)
        }

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
# MODE: SETUP — WinForms GUI installer (default)
# ============================================================

# Load WinForms and Drawing assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Request DPI awareness so the form renders crisply on HiDPI screens
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class G2DpiHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
    [G2DpiHelper]::SetProcessDPIAware() | Out-Null
} catch {}

# ---- Admin check (dialog instead of console message) ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [System.Windows.Forms.MessageBox]::Show(
        "This installer must be run as Administrator.`n`nRight-click PowerShell and choose 'Run as Administrator', then run the command again.",
        "Administrator Required",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

# Capture script path now, in outer scope — $MyInvocation is unreliable inside event-handler scriptblocks
$ScriptSourcePath = $MyInvocation.MyCommand.Path

# ---- Shared theme ----
$clrBg     = [System.Drawing.Color]::FromArgb(30,  30,  46)
$clrPanel  = [System.Drawing.Color]::FromArgb(45,  45,  68)
$clrAccent = [System.Drawing.Color]::FromArgb(0,  212, 170)
$clrText   = [System.Drawing.Color]::White
$clrMuted  = [System.Drawing.Color]::FromArgb(160, 160, 190)
$clrErr    = [System.Drawing.Color]::FromArgb(220,  80,  80)
$clrInput  = [System.Drawing.Color]::FromArgb(45,  45,  68)
$fntH1     = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$fntLabel  = New-Object System.Drawing.Font("Segoe UI",  9)
$fntInput  = New-Object System.Drawing.Font("Consolas", 10)
$fntBtn    = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

# ---- Existing install dialog ----
$TaskMonitor = Get-ScheduledTask -TaskName $TASK_MONITOR -ErrorAction SilentlyContinue
$TaskPull    = Get-ScheduledTask -TaskName $TASK_PULL    -ErrorAction SilentlyContinue

if ($TaskMonitor -or $TaskPull -or (Test-Path $INSTALL_DIR)) {

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "GEN2 Ground Probe"
    $dlg.Size            = New-Object System.Drawing.Size(440, 210)
    $dlg.StartPosition   = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $clrBg
    $dlg.ForeColor       = $clrText
    $dlg.Font            = $fntLabel

    $dlgLbl = New-Object System.Windows.Forms.Label
    $dlgLbl.Text     = "An existing GEN2 Ground Probe installation was detected.`n`nWhat would you like to do?"
    $dlgLbl.Location = New-Object System.Drawing.Point(20, 20)
    $dlgLbl.Size     = New-Object System.Drawing.Size(390, 55)
    $dlgLbl.ForeColor = $clrText
    $dlg.Controls.Add($dlgLbl)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text         = "Uninstall"
    $btnUninstall.Location     = New-Object System.Drawing.Point(20, 108)
    $btnUninstall.Size         = New-Object System.Drawing.Size(118, 36)
    $btnUninstall.BackColor    = $clrErr
    $btnUninstall.ForeColor    = $clrText
    $btnUninstall.FlatStyle    = "Flat"
    $btnUninstall.DialogResult = [System.Windows.Forms.DialogResult]::No
    $dlg.Controls.Add($btnUninstall)

    $btnReconfig = New-Object System.Windows.Forms.Button
    $btnReconfig.Text         = "Reconfigure"
    $btnReconfig.Location     = New-Object System.Drawing.Point(153, 108)
    $btnReconfig.Size         = New-Object System.Drawing.Size(118, 36)
    $btnReconfig.BackColor    = $clrAccent
    $btnReconfig.ForeColor    = $clrBg
    $btnReconfig.FlatStyle    = "Flat"
    $btnReconfig.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $dlg.Controls.Add($btnReconfig)

    $btnDlgCancel = New-Object System.Windows.Forms.Button
    $btnDlgCancel.Text         = "Cancel"
    $btnDlgCancel.Location     = New-Object System.Drawing.Point(286, 108)
    $btnDlgCancel.Size         = New-Object System.Drawing.Size(118, 36)
    $btnDlgCancel.BackColor    = $clrPanel
    $btnDlgCancel.ForeColor    = $clrText
    $btnDlgCancel.FlatStyle    = "Flat"
    $btnDlgCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnDlgCancel)

    $dlg.AcceptButton = $btnReconfig
    $dlg.CancelButton = $btnDlgCancel
    # Closing via X is treated as Cancel (same as pressing the Cancel button)
    $dlg.Add_FormClosing({
        if ($dlg.DialogResult -eq [System.Windows.Forms.DialogResult]::None) {
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        }
    })

    $dlgResult = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($dlgResult -eq [System.Windows.Forms.DialogResult]::No) {
        Unregister-ScheduledTask -TaskName $TASK_MONITOR -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_PULL    -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $INSTALL_DIR) { Remove-Item -Recurse -Force $INSTALL_DIR }
        [System.Windows.Forms.MessageBox]::Show(
            "GEN2 Ground Probe has been uninstalled.`n`nRun the installer again to reinstall.",
            "Uninstalled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        exit 0
    } elseif ($dlgResult -eq [System.Windows.Forms.DialogResult]::Cancel) {
        exit 0
    }
    # Yes = Reconfigure — fall through to main form
}

# ---- Main installer form ----
$form = New-Object System.Windows.Forms.Form
$form.Text            = "GEN2 Ground Probe Installer"
$form.Size            = New-Object System.Drawing.Size(480, 420)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.BackColor       = $clrBg
$form.ForeColor       = $clrText
$form.Font            = $fntLabel

# Header bar
$header           = New-Object System.Windows.Forms.Panel
$header.Size      = New-Object System.Drawing.Size(480, 72)
$header.Location  = New-Object System.Drawing.Point(0, 0)
$header.BackColor = $clrPanel
$form.Controls.Add($header)

$lblTitle          = New-Object System.Windows.Forms.Label
$lblTitle.Text     = "GEN2 Ground Probe"
$lblTitle.Font     = $fntH1
$lblTitle.ForeColor = $clrAccent
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$lblTitle.Size     = New-Object System.Drawing.Size(380, 32)
$header.Controls.Add($lblTitle)

$lblSub           = New-Object System.Windows.Forms.Label
$lblSub.Text      = "Windows Agent Installer"
$lblSub.ForeColor = $clrMuted
$lblSub.Location  = New-Object System.Drawing.Point(22, 46)
$lblSub.Size      = New-Object System.Drawing.Size(220, 18)
$header.Controls.Add($lblSub)

# Helper — adds a muted label + styled TextBox, returns the TextBox
function Add-Field {
    param($labelText, $defaultValue, $yPos)
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $labelText
    $lbl.Location  = New-Object System.Drawing.Point(30, $yPos)
    $lbl.Size      = New-Object System.Drawing.Size(410, 18)
    $lbl.ForeColor = $clrMuted
    $form.Controls.Add($lbl)

    $txt              = New-Object System.Windows.Forms.TextBox
    $txt.Text         = $defaultValue
    $txt.Location     = New-Object System.Drawing.Point(30, ($yPos + 20))
    $txt.Size         = New-Object System.Drawing.Size(410, 28)
    $txt.BackColor    = $clrInput
    $txt.ForeColor    = $clrText
    $txt.BorderStyle  = "FixedSingle"
    $txt.Font         = $fntInput
    $form.Controls.Add($txt)
    return $txt
}

$txtOrg     = Add-Field "Organization ID"              ""                 92
$txtLicense = Add-Field "License Key"                  ""                 148
$txtServer  = Add-Field "Server ID (friendly name)"    $env:COMPUTERNAME  204

# Status label
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = ""
$lblStatus.Location  = New-Object System.Drawing.Point(30, 274)
$lblStatus.Size      = New-Object System.Drawing.Size(410, 20)
$lblStatus.ForeColor = $clrMuted
$form.Controls.Add($lblStatus)

# Install button
$btnInstall           = New-Object System.Windows.Forms.Button
$btnInstall.Text      = "Install"
$btnInstall.Location  = New-Object System.Drawing.Point(30, 302)
$btnInstall.Size      = New-Object System.Drawing.Size(410, 46)
$btnInstall.BackColor = $clrAccent
$btnInstall.ForeColor = $clrBg
$btnInstall.FlatStyle = "Flat"
$btnInstall.Font      = $fntBtn
$form.Controls.Add($btnInstall)

# ---- Install logic ----
$btnInstall.Add_Click({
    $OrgId    = $txtOrg.Text.Trim()
    $License  = $txtLicense.Text.Trim()
    $ServerId = $txtServer.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($OrgId) -or
        [string]::IsNullOrWhiteSpace($License) -or
        [string]::IsNullOrWhiteSpace($ServerId)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please fill in all three fields before installing.",
            "Required Fields",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    # Lock UI during install
    $txtOrg.Enabled     = $false
    $txtLicense.Enabled = $false
    $txtServer.Enabled  = $false
    $btnInstall.Enabled = $false
    $btnInstall.Text    = "Installing..."
    $lblStatus.ForeColor = $clrMuted

    $installOk = $true
    $installErr = ""

    try {
        $lblStatus.Text = "Creating install directory..."; $form.Refresh()
        if (!(Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null }

        $lblStatus.Text = "Writing configuration..."; $form.Refresh()
        @{
            ORG_ID      = $OrgId
            LICENSE_KEY = $License
            SERVER_ID   = $ServerId
            TARGETS     = @()
        } | ConvertTo-Json | Out-File $CONFIG_FILE -Encoding utf8

        if (-not [string]::IsNullOrEmpty($ScriptSourcePath)) {
            $lblStatus.Text = "Copying agent script..."; $form.Refresh()
            Copy-Item -Path $ScriptSourcePath -Destination $AGENT_PATH -Force
        } elseif (-not [string]::IsNullOrEmpty($ScriptUrl)) {
            $lblStatus.Text = "Downloading agent script from GitHub..."; $form.Refresh()
            Invoke-WebRequest -Uri $ScriptUrl -OutFile $AGENT_PATH -UseBasicParsing -ErrorAction Stop
        } else {
            throw "Cannot place agent script on disk. Run with -ScriptUrl pointing to the raw GitHub URL."
        }

        $lblStatus.Text = "Registering Scheduled Tasks..."; $form.Refresh()

        $actMon = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Monitor"
        $trigMon = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TASK_MONITOR -Action $actMon -Trigger $trigMon `
            -RunLevel Highest -User "SYSTEM" -Force | Out-Null

        $actPull = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Pull"
        $trigPull = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $TASK_PULL -Action $actPull -Trigger $trigPull `
            -RunLevel Highest -User "SYSTEM" -Force | Out-Null

        $lblStatus.ForeColor = $clrAccent
        $lblStatus.Text      = "Installation complete!"
        $form.Refresh()

    } catch {
        $installOk  = $false
        $installErr = $_.Exception.Message
        $lblStatus.ForeColor = $clrErr
        $lblStatus.Text      = "Error — see dialog for details"
        $form.Refresh()
    }

    if ($installOk) {
        [System.Windows.Forms.MessageBox]::Show(
            "GEN2 Ground Probe installed successfully!`n`n" +
            "Agent script : $AGENT_PATH`n" +
            "Config file  : $CONFIG_FILE`n`n" +
            "$TASK_MONITOR  — runs every 1 minute`n" +
            "$TASK_PULL  — runs every 5 minutes`n`n" +
            "Run this installer again at any time to uninstall or reconfigure.",
            "Installation Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        $form.Close()
    } else {
        # Unlock UI so user can correct inputs and retry
        $txtOrg.Enabled     = $true
        $txtLicense.Enabled = $true
        $txtServer.Enabled  = $true
        $btnInstall.Enabled = $true
        $btnInstall.Text    = "Install"
        [System.Windows.Forms.MessageBox]::Show(
            "Installation failed:`n`n$installErr",
            "Installation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[void]$form.ShowDialog()
$form.Dispose()
