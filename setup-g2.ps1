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
    $LOG_FILE = "$INSTALL_DIR\pull.log"
    function Write-PullLog($msg) {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
        Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    }

    if (!(Test-Path $CONFIG_FILE)) { Write-PullLog "ERROR config missing: $CONFIG_FILE"; exit 1 }
    $Config = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json

    try {
        $uri  = "$GEN2_BASE_URL/api/groundprobe/jobs?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
        $resp = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorAction Stop
        $jobs = $resp.Content | ConvertFrom-Json
    } catch {
        Write-PullLog "ERROR fetching jobs — $($_.Exception.Message)"
        exit 1
    }

    if ($null -eq $jobs -or $jobs.Count -eq 0) { exit 0 }
    Write-PullLog "INFO  fetched $($jobs.Count) job(s)"

    # Safely read TARGETS — PS 5.1 ConvertFrom-Json can return {} for an empty []
    $Current = [System.Collections.Generic.List[string]]::new()
    $rawTargets = $Config.TARGETS
    if ($rawTargets -is [System.Object[]]) {
        foreach ($t in $rawTargets) { if ($t -is [string] -and $t.Trim()) { $Current.Add($t) } }
    } elseif ($rawTargets -is [string] -and $rawTargets.Trim()) {
        $Current.Add($rawTargets)
    }

    foreach ($job in $jobs) {
        Write-PullLog "INFO  job $($job.id) action=$($job.action) monitor=$($job.monitor_name) target=$($job.target)"

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

        # Rebuild config — write without BOM so values stay clean on re-read
        $json = @{
            ORG_ID      = $Config.ORG_ID
            LICENSE_KEY = $Config.LICENSE_KEY
            SERVER_ID   = $Config.SERVER_ID
            TARGETS     = @($Current.ToArray())
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($CONFIG_FILE, $json, [System.Text.UTF8Encoding]::new($false))

        try {
            $ackUri = "$GEN2_BASE_URL/api/groundprobe/jobs/$($job.id)/ack?license_key=$($Config.LICENSE_KEY)&org_id=$($Config.ORG_ID)"
            Invoke-WebRequest -Uri $ackUri -Method Post -UseBasicParsing | Out-Null
            Write-PullLog "INFO  ack sent for job $($job.id)"
        } catch {
            Write-PullLog "WARN  ack failed for job $($job.id) — $($_.Exception.Message)"
        }
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
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

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
$clrAccent = [System.Drawing.Color]::FromArgb(74, 144, 226)
$clrText   = [System.Drawing.Color]::White
$clrMuted  = [System.Drawing.Color]::FromArgb(160, 160, 190)
$clrErr    = [System.Drawing.Color]::FromArgb(220,  80,  80)
$clrInput  = [System.Drawing.Color]::FromArgb(45,  45,  68)
$fntH1     = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$fntLabel  = New-Object System.Drawing.Font("Segoe UI",  9)
$fntInput  = New-Object System.Drawing.Font("Consolas", 10)
$fntBtn    = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

# ---- Embedded logo (base64-encoded PNG) ----
$LOGO_B64 = "iVBORw0KGgoAAAANSUhEUgAAAyEAAABbCAIAAADr3R2eAAAQAElEQVR4AeydCZwVxbn2mX3ODMuwCMgizowGXIIIaASiUQxeZgzXGIUvGle83rjE++kN8WrUawwauQajv0uM5vqJCwYNkhiDzhCJoCJLABURFZUZQBZnkG2AOX1m//6kTd/2nD7dVXX6dJ+B8lc21VVvvfXWUz1dz3nf7urs4048IzPTCd+88hs/Xv/N6dEQ02k//MvXTjlXGZ9MGALojbrmpeNOPlN5FLqhRkAjoBHQCGgENAIKCGR3ydT/isor80rKQrSuLbbHqKlub2lUtiH0IWB528HPGUWX9hbyOmkENAIagU6CgDZTI3A4IJChHCtSOiFSVhEuwFCT2I6VyjZkwhAw3qitbt65loxOGgGNgEZAI6AR0AgEiUAmcqyc4gGHCFZ2bpBAxPXVXP+eUVsVVyh+mtM1/CFgbdOOVdHaajI6HUEI6KFqBDQCGgGNQGYgkIkcK1Jekd93RJj4dLQam6qJsinbAEcMeQhdunS0NBq11e3GbuVR6IYaAY2ARkAjoBHQCCgjkHEcq2DANyJlE5XHk0pDqy1RQmPTq9apbKZgwBnQRNlWvsvjwYptfcN3tVqhRqATIXB+xbc//WCFbHph7uOdaIyZYOq6t5fIgrzgxTmels+ccbesWuSZdE/NWkAjEAwCmcWxsvO7RsoqciK9gxm8Yy+t+zZFa9Tja9l5xUXlE3MKezkqD6ywZfcGI4VYZ2B26o40AmlFYMrFFyjoX7ZilUKrI7bJzTddGykslB3+6jXez4l+4/SRsmr37Wt4pfqvsq0yXF6b13kRyCyOFSmdWDj4rHDRjG6qatmzQdmGSHllwaCQh4Dx0dqq1n2byeikETiSEThx2PGywzdisYdnaT+WBGzjxpwuIf0P0See/N0/ss7/jh41on+/vs51yUs/3PBp8kpdoxEIGoEM4lh5vU8IPcRGcI1AofIk5PU5ET+ccnO/GhqbFqUyCr/M0Ho0AuEicMVlU0pKesja8PHHG2WbHMnyAwf0Hzr0OFkENnyycfuOOvdW/3L1pe4CjrXz5r/kWK4LNQKhIJBBHAuCldujNBQUzE7bjd1Qk46WqHmqcIRg5fY4VqGhj03aDu44FCXsaPNRp1alEeiMCEyqnKBgtg4USoF2zdU/SFOgcNSpw6UsQVgHCgFBp4xCIFM4VqT0vEhpZbjQGDVVTZ+rP4cRKf0nOFa4Q6B3RtG88z0yKSXdWCPQ+RFQ8K/oQKHstJ82WuUdcM9A4fkV31bwQepAoez0afl0I5ARHCun28BIWWVWdpjGNNe/G92k/qh7brdBReUVWVlhDoFrpWnHymjtQjI6aQSOcATUHsTWgUKpy4ZA4bCvSQcK17633jNQqPaywqzfPCFlvxbufAh0NotD5gQmXEVllfl9pd3CZltfjh1tLdHa6raDHs8HuPRFoDPvqDCHgG3tLY3Rmur22B7yvqRI6XndRt7QY+ydfSpnk/pNqep/yeK4RDmp5/iZiBUNu6ig/2hfutZKUkeAuej69SuZFyaIFDdxfS98kcKeZ93HFCOZeneZpkHtQexl+o1CmYkkUCgj/qWsCMgKLyvU1e9c87b3u4pfGqH/0QgEgkD4HOvvu0mFvSFWbXVss/rrvgUDxkRKQ/7yD1cLUcKmbUvJpJJyuw9h0YUzwah6nHFb8dCLI0PG5/Y4lpSV4/B6NuWkgn4jEet+6o09z3mAxZvmKEGVgiW0YuGn9zhO4NcptMPTKshl7/N+49LjUf/8HGOEU3qqcheA3KAHbXF9wX7gRu5tk9ViPAAemoVzHuh68pWRf0xfnHx2YY9DEzdwDFPMrGFD99OnAX6cWOc91YHCuLlLx6lCoFAkGqsWKPzbqnfSMUatUyOQCgIhc6zs/G5ECbMLeqYyhhTbtu6rMVL44ExWfvdIeWV2YUmKZqTYvGXXh6mMgt7N9b73xEdZdOFMjowKMc/E4k1zlPQ5/0kIhCwR6Tb6poKBY5R79zSv4OhvuMvAUbqfdnNe72EuYjnF/RjjIU551n0uYp5VXYdPRQ/a4iRhP3AjSE9cucsp9AhaBrWCGQMgs+AinFiFDUXllcw+ShJrO12JWqDw3bXrO91IQzRYLVAoEo1VCxQ+/4J+ozDEy0F37YxAyBwrUlZROPibzqYFVUqUsGXPx8q9ESUsHDROublfDSFYrQ2KG2KZ7ApnBuu9v+QGhRARfEJ0IThSmghKqonllni8+FlYet5XQXDrBzaTCinJyi100e5eazU02RX0CFomS60sJWaGgaMEn5b4fJkNM+2oFijUr/1LzaMOFErBpYWPTATC5FiHdpMqDznEFvvsdUJsynOf3+ek4vKQX4fEeGPTX+BYZGSTuTyb7Eq2rbg8PqGSs36Of8izSQBLOzTC3YwcyT36ISUiQ3PvVLmWrnuePQMbPMcl3gU+LcH5EtcZsKRCoFC/9i87RzpQKIuYlj8CEUgnx/KCs6iskjXeSyqN9W3GF0ZNdUdrTLkPAp053QYrN/elYeuB7bjiOjraZbVZy7NsQwV5GEDXr1/t2TCnZIinTLoFiNPJdiEyNFmdgvJ0DSUSFBYXY74ImAZAecVNEpdUCxTq1/7FEUZSBwoBQSeNgCcCoXGsSNnESFnITiwIVlPdak+MkglgP4HCZLWBlePBatm5Tra7biNvYBFNx/KczJIg+0pmQ5rKGRp4pkm5i1pYMl27CKRSBc1KfVDZ+V1zigfklZTldB+cEzkqFXvE2+pAoThWypKdO1CoPGzdUCMgiUA4HCu3+2AISpesLElr/RRvqnsHdqKsMafb4EgGRAmbdqwwaqpkR8HaWTz0YhZR2YYpyss+/55id47NO9rU3ZaOCs3CyBCVLcXNtsrHrIJuym1FGuLS41IRkYyTgVoVn3RZ74r/1/eiPx/1z8+SOer8p4/67u/7fu+PJWPvyu8/Mk7e31MdKPQXT0dtOlDoCIsu1AjEIRAOx4Jg5R/19ThTgjztaG0yaqvaGuuVOy0qr8zvc5Jyc18adjQfMGqq25v2SWlj1YRgSTU5nITT9Kns7MIeUq8BdhZI47ijiNkws14TZnUbPhX3VZx8dkFJ4ZBzep0zs+tJP4ir8utUBwr9QtJFjw4UuoCjqzQCdgRC4FgFA8dGysLeEGtTdWzLYjsQUvnCQd8sCjvQicHRmqrYtrfIiKeuX79SlmDh+GnZvYG+9r/7yN4lt9Y9N95Ku165msKD6582tixOhbCK25+iJGMxPnstRSXJmkeOHR/u84XJDEulHO5IRFJKQ7eR13vi0HX4NYWDz5JSKyh87ngVtfqNQkF4TbFb/u2HZkbqKLL16KkjTpbSibDeehQQdMpYBILmWNkFPSJlFfycDRGR1r0bcf8oG3Bo1SmryCroLqPBf1mFDbEK+o8uPuH/iJvSHmto/Hj+7oXX7371hv2rZkY3/KGpbo29eev+LRQefP/phuX3fvHnS6BcyEPI7DK+52F1FsmTzdTPq8Rg300yFRJ7LT75cjMf7hEqySwwF3asmB1Om+ql92ksHPwt8eHk9jyuoP9pIvKy1E1Ep5p/JdkbhVdcNuWxXz+w4MU5i6rmffrBCiute3sJJS/Mffw/7/gxPYoYdpjJfON06WivyNajaj5IX7YePb/i2/TOdDOtTC6JWbZmPC5DLYkLA3mugdGjVL7YmMolwVVnXpyWtXEWmqcYSUIGOxld8HamMsaA24LnzBl3P/3ELBAjOc7+0sUvUWXNO9eMiJFBc6xI2cTQd5OK1la17P1UBB1HmUhpZcHAMY5VQRYyitb9n0n1SJQQHiDShEWaFXrnixceeOc3ECmRJsggiTyEjOUczxZKKLSnjqYD9tPDL184aKynCyeto7bTYubCTiiZHU73Lp7WsHKGlNMxp+vR4jbnC39RKr/fqeJqBSXVHsSOe6OQVZPbKKvUXbffcu45Zw772nHHDvnKu8ORwkJKRpxy8uWXXly94DnWMNY8QQvjxOiLjmQTreL0OJ6yBshqRp6VxlGbVchS3b9fX+tUMCOy9ei4MacLarOLKW89ykAYLHPNgvrwzOk3XjeV6WZamVwSs2zvxZ6nlsSFgTzXwHPPPLp62UJ4jPJlYFfukocnQQJY6V9f9KJ5cVrWOrbCSBIy2MnoTDvRwIVhkxfNcp1zeSgk0Q5sciAJpLJ9MQU2Hd5ZcKAJtImOwPOCSRPHnjEaxEiOs89lT5U171wzXDnAwry4dBYox8rvc3JRWci7SbH2p+LEyjtqeIa8S2hI7k3f/fRpuT08tt80L5TWhs34rlihzVOFI8s5ni2UEGG0My1j06sK2jKqCeC42AOF7Tb6JhcBf6uad/yvW9FkVyK0mFnYv+pB+7y4W5XTtb+7gL02t/sg+6lLPis3klMkvVS7KKRK4UFsWpmBQm7r3HC5s7NqchulXCRxL2YNg2kJ8p44nWoGP/Hk7+L0OJ5OufgCx3L3Qk/K8v3JKmoXVC1y75dahZcVNm/Zukb+G4VM1qKqeXAOllXmmkmk91RSSUkPeAyXAaQtFT2ObeGCECOWc3gSJICV3lFMpBA70QA5YPh4bkSaWDK79+y18unO/GL6HZgq1QtXwnU/ulWkCX/pTBN/6eDArEGbRFo5ynDl8OfPvKCNi8pRJlCOFSmvzOn+lV+Ejjalr7AtuhNq0tHWpNZFVlZ2UXlFbjfRVUStF89Wrfu3GrULu3R0eEpaAjhXIseOt05dMsSSdlVNhSS5yAhWoWT/qpkwrabtKzraYhwFG2ayWMu+WnfzCvqNLAjqw9ggTEwQbPnlYLIrd9usWmK+0Y0vW6fuGYiju4C9VuoxAMLu9rYp5rl1sl7KKjEDhdwfWSC54Urc2W09cauFmaHEVuadVTN47Xvrt++o89bepcuJw44XEbPLiDzbpBAoBORnnp1n7ygxjzMAGBPL3UuWLvubu0BcLXPEcshkpbKyxum0TrEf0oZjwypJMQMNggzBBSFGKE9Rm705w8dzg6lchPbyTMjjXmK8UpYQib79rl94Nhk9agRDxgvINKn9pSfrAm1cVLgY6SJOJjiOhfuHQGFc9wGfGjVVzXVvK3caKauIlP6TcnO/Ghqbqpu/eF9KW/HJl4uslBAsYklSmj2F4QF737yjfl4lR0/hzBdo2fORZ6Ct6/CpgQ2EyCzY4jWU7RE/JeRMtpWnfJbr14Him+e4fUooXtjrXC1QyM9fljHuj6mvYShhCfcy83/r1QwWeXKcPliouO+TkUqezzaxhCj4UeKisY4mqQUKBV169Agg5kQrwEJz8YRjg4VcXN5REpyxFhoEGXIU8KUQU59/9reCNOvgwUZfOvVUcttPpEMBs5+a6+7OZIxPPzELtsqQPQ1QFuBPY/b/PMSVZtcQEMfK6X5MpCzkKGFz3ZpD7h/76GXyBNrgWDIt0iLbtH25UVMtpRonVuGgsZ5NoA4H1szyFEtdoLNriG1b6j6EvN7DMmEnMHcjqW07KOQOQTJN1OaFOgAAEABJREFUyd/98dTibtxzfVzGLv7ed1gdBeFSMJjf6w/PelxEf0YFCs1orLvZCoHCDZ9sFHTpwX3vv/cOHyfafSxcVLig3GVcaolZwwaCsRZaIEiz1q3/yMVmv6qI4mGSlDY8u+5/FLhIqxc8J+sbk7LBEuanGleanWYFxLGKy0LeTaqj1SBKSKzQwkI2A8HK63OibCt/5dubGiBYHKXUFg2bLOLEOvj+k/icpDQfmcLGxlc8PUBFZednPjhtBz/33ciOFkNcZ3urhLC7Wn6nKgQK3XUq1HKH/Y8f3yjSUM1gkSfHzd7TtAmCWqDwleq/mlYlO7IKAl2y2mTlq9esTVZlL8erhItRQb9diWyeHmWbIM/aTLyJmDX5wBKc5uGZ0wPrzqUjfp+cN+FsF4HEKsLQN0+7K7HcLOGvbMGLc268bqrg7JutUjzSF644ujb1BMGxCgeNi5SHvCFWtHahsWWJOWaFY8GgMyMZsKs7NDG2fZms/QX9R3k2MbYsNjr/A+mew/RFACYa27bcXRVez6JhF7nLhF7rI8WxxtIW223lPTMdxh5PGUEBtbiboHIpMXwYo0d5v8yvZrBgoFCNshyWgUIIFjMiNYO+COOFgjBJqTKdbTAeqVa+CAORp+Nt926Vv9a6+p3iFt59548hKOLySP7s3pnJfJng/6cXngrlpxeTeNdP/x3zSGnnWNmFPSLllVn5Ye4m1bLnE9w/jFYt5RT2ipRXZOcVqzX3q1XzrvVRyXcJ6TpSep7nJ+3wyjSun4OwToIIiMDV9YTLBLWFJZZdWCLStfurlHEa2hpE9xPpaD7QFlO5a8f1aJ4qxN3Mhuk4irx5p2CwEYu5x0Sssag925TCG4VWzw6ZEAOFYREsE4VJ559nZkSOmIrrS5ZhiGgWlKF3d0lPZ6Rj81hM9A0zfhjI8qHXlixNZhWEFedcup+9cxyyWTh2zGmmKyvtHOvQblIDQt5NCvdP676N5sgVjhCswgFnKDT0t4lRU9W2f6uszjyB/Yqad33Yun+LrOYjUz63eykDB64mr808+XXRbeQNCGdsyinsJWKbFBNqqlstohOZxg3zOfqSuJfJ3p196TeZklOGn5SsyixXM1g8UKjwbNNmgU0QOlegcOaMu3HPmICHciwvE9orB9sgWOGaig043kYL+F+RTEfiL2LqVZdKaeaKTbZZAwTLkzJK9aUgDF02fdXp5Vgs8BAUBft8bBLb8ppRK/3VZMuA/L6nhP60PsYYNdVqD+zn9/F+hiymo4RALJas9+aiHz7v2SIyZEJu9yFuYqHWCW58JfVofFtjfbTmFc9htTc1NG7wBtBTjylg3svMfCYcS3p4uO3VDE5roNBzEwQWYCIgsvCG9UYh1io82bN85Zrp9z90/EljzHT2hAs5pRAPouzAkfe8DJAhZQLBwgySp/9VDQc0e6ZfTL8DUuIpZglgSbLNGjKBYJl2mr7qNHKsTNhNqr2xzqip7mhrMccsfczOjZRV5Mjscy3dhUCDtv2fKdPEXK99R9tjDfpJLIFJiBdpqlsj4soqPjkjvq4Tb32XLgSRRd6EoGHLF+s4iqcD7/y6aeubLvIdrUbDql+p/1UmqD5z3DcSysIs8IxQmDdfKRNZVNIaKPTcBOFfrpZzM5ij8wwU4sBQ8Lpt8Hqj8P7pP5Vas9e+t/67k6+68pqb7Pt4bd9RxymFU//1ln37GswRiR89LwNUZQ7BwhjPiaiv/wIx39MVl00Ze8ZoKbXJNmvIHILFcIYcc2grzTRyLNhJJG27STEAkdRYU+25ELro+fsQJGLqLqpSqWqsrW7e9YGChkipt/EtDTUKmnUTEBBxZRWG/XUd7HRMgl8hVKDgHa1Ne9/62d43fmpsfLl55/utDZtxbrUe2Nayd2PsszcOrH18558vadrmsf+Fo82OhXgsCHM4VokXsmbPmTv/kiuuNx0YN0+7i0iEeHMpSQxWiGymNVDI8OET7qMYdepwd4HEWnhJssdlLGFcelJkyGzo/kYha7bUJcHwJ196rQsCa95eu6DKe5960zbxYyoEC5tfWrAQN5t5xXJM0euG2YKONyT9TddO/YGUQgix4++NVAhWXf3O15YsBU9gBEwzcQrIXMZS5lnCXNj8hEgXx8J9AkGxOgsl0/T5amOT3FZSdjvzSkoj5SHv6YU9sW3LcMWRUUi5PY/zbNXqtXG5p4aABbqfemP/SxZLpX5TqkTopuxARFxZ+Ioy05WV31/oc4Ex+fdYTRibdqxsWP2rPa/9311VUw99L/zlK3Yv/Nd9y+5p/Oi5jqb9powvR88Ah3sv3FthVJMuvPzn9z3IUmoKwwwmVE5hGTNP/T2qGZzWQKE7ZWH451d8W8Qrg6Q9iQQKFVx6dOHudZtUOQEZ8XTPvQ96ClctfM2UgXxbiTAiC7OZWIxZkqff/5B5NBdps4njEUKg9gwWlyU/Brhip912D242SzkckVPT68ZVbZWLZzxjwbEm0QfYxTt97NcPePZr1wbj4Q/WXmLmuUQv/t53zLzUEayYsjPHX3Ddj24FQGC0mnMKyDg4YXVWoVTm3PFnpYtjRcomhrubVEdLlPhae3SXFCJ24UhZZX6vofaS4POHvAi1VR3NimtStsBDzW3R+uDHFXCPEJ2i47+bjk5FXFmRIeMD+7qO4Bi7jbwBTDyFO9pi0Q0veIqFK6DwILZlMLdO7q0wKqvEnrnuxp8QobOX+JJXMBgzHH+4J9ozbszpiYWeJe6UheZqO5qKBAoVXHqQDPtCiHn2hOdAlrtY3NquJy6PjEmbIN9WgtCwMJuJxZgl2UpxzeNOIQQKD2VzGTzy2GzYFcbEKbSfUnvLT+62l/iV377d5x31Ro8aMXbMaVLmOW7WwKT/7M5p+I2kVCEMP+YOwKyRT5a42HBzwu2SCbiXp4VjZcJuUkZtNYEJ98G71BYe861IWYWLQDBVxqaqpu0rlPvKFng53/5dYZeOjvrn56RcR3HCPcfPDPfp7+zCni6jU64ScWWhvOjE73PMkMREFB0n9IMvtm15a3AvnKrAwz1a6kewvQ8IFrdOe0lcnnvrls+2xRWKnBqxWDIxNYNDDxSqffowGXm1wCFQaOXFM68tdnvab/JFk8RVmZK4UsxMYMfb5D8Xw0V1+533CVJtaBbOtsCG49LRjs/dfsPLPjYHJXK8qH4x/Q4FP+ucufPhxy7G26veflfusVSrrf8ci8WsqLwiO6+r1UfwmZY9H8OxlPvNLuqNEysrr0hZgy8NW75YpxwlNA3IEfBjiSyiRcMu8txky+wx2bGg38huo6W/QpVMm0J5iva79CjiymL46QhWuljlUkXsUtCJJbINmEtHAVSpxd0wzJNgIUNS++Hu8miwmsFPzfk9xnimm2+6VuGnfJoChZ47mjIchUAhVMOdZwwbejyapdK555y5etlCmNYVl03BIyLVVkGYjhR+GECwHOlFMgPSEddL1pdLuWEk/ZYDl6vUY3OwRkdKxKyNlXxkHoOJ7f78Pu8YMZJmOqj6uUb/OVZRWUVB2LtJRWuqWlJ4zOjQnl5HyzkwzWnw89jRHq1Z2HpA4Ge0n70668rrdYJzhUwpPENGvNPIHnJlCfgai0/ICFcWVI/YpQi4jR/9XoR/i6hKn4xC3A1j6up3unuwkEkluYQVFAxGm+DiOi6TAoWeO5rCZhQChZ4uvYEDj1aYO7wgMK27br/l9UUvrnt7yaKqeS/MfRwy9J93/JglHO+jgk7HJqiiI8cql8Jk/huXJoUFBS61jlWQGMdyq3D5yjVWPsUMsy+1IRbcOtlmDTddP1XWGEZKbFeqVdeuKpuQE4X0mWMd2k0q7OfEjc2LUnFiQQWKy8OPEkZrqo1NC6UugswXJkqV+UYqWHhg7f90tCUND5kKc3scizvQzId1BP+uX79apPeW3RsOvv+0iGSIMixXCv4ADH589u84pi8lizCqGSzy5DhjYdHyfPcesbjk/myTKawWKCRcZTZPdlQLFHo++6/ALeIsxBeIf2XEKSdDhi6/9GKI13PPPPrpBysgXk8/MQvWxTzGNRE/FfycpV0h9GL6L35lL0lT3n/XV3JDH545HZyT18fXuGzWAD+Ol/Y6J0roJeJDPROHFl85VlYOIbacrgPQG1Zqa9xxKL7W3qpmQFZOXoRAZ3F/teZ+tcJ/YKTwRqRfZviuJ3+A3CYoPhrQ1uj2WECKHTFfMa8vGNJFUdn5HENMhGtFYqbwxYaV/xWinYJdq8XdiBLy41KwC/Gtuu0Kl7zh/FFRNYM9nxw3u4aySC1aZqvDLFDIoHD7cUxHgngRk4J1QbmILcK3zq/4tlRHkDOom1QThJlWvGuQPKmEtbSVSmqRcakuTGFcg1I48EsgWYBY9h1S0wB4sxSYCEO4zbbiR/OZAT85FuwkUir30qy4uYKSEKzmnWsFhRPFIuWVhUPOTSwPuIRRtOz6MOBOD+/u2mN70zrAxvVzoCbuXYTryuo28gZ8tO4WmrWdIkqIqQpxN1r914OPcBRM/fodJShpifHjNVloT9xgSxuMIZk2S8bMKDzbRMM0vVEYVqCQESVzIlLlY8J3At/CGYNzC8YgqFnBiSWo2RexDR9/6q5H/MeJux6p6B5/Atfd+BNHhfgUmQjHqkwoNJ/3941j5ZaUFpWFvJtU046/qX1wxpyP3JLySGn4UcLY1reMFD7+Y45FH+0IwH6Mz77c3sZe7mM+w11ZkdLziodeLDLepu0rMj9KyEBGjxqhECjkB7FnDAvlZqILXAhmXvyY7IEhtCkYLB4oVHi2CTS276hzH1rnChQyFk96h4yPCXcRTpHHfv2Ap04uACnnjadC3wVe+MMC33UmKgQrKWI069HZya5SNSdWoklpKnl37aFXEX3jWEVlFXm9h6XJVhG17c2NRm11m7FbRNhRJlJemdfra45VgRXibiFK2N58MLAeRR4SatnzUWD2eHa0/91H6p4bnyQ5l9fPq4xu+IOn5hQFMtaVBcHqftrNIqNrbdi89807RCRDl1GLu7m/9h83KLUulq1YFafHPFXTJh4oNHuROnqiQSxMajk0ew/rjUKzdzg04WAzH9iRQNILcx93707tY0TuOn2sravfmYzK+NjL6FEjwEpc4WtLliZznuE+VLg4xbtOXdLkrP5wrMLB4e8mBTWJuX4lzR2yyJBzMuFRd2gijgR3U8Vr22J7PIWzBXbZgKCk9XkmTyM7hUBmurJMgpWVU+iJIVO87617PMUyREAh7kYUL9lTHY6D8rcLBW1ESdIXKBRBQ23rUU9P0sAB/RW8bskchIlzRziY0SWWp7UEH9XNN13r0oXCx4hctPleVbvpMxGdm7dsFRGzZMx4mXV6//SfWnnPDLTPcbMGs2GGO7Ew3uSs/+BYptVKx+xI70h5RVaeypuNSh06NGrZ/ZFRo/7ZnJyivod2HBVYhxz69q+oeee6aE2Vf/q6tMf2eWrL6TbYUyIDEl8AABAASURBVAaBL/58ibvrCPcSYkd4yjRXlvkioQjBIpx68P0noYmdYgb5NawQdxNfpAHB3y5wCCkYLBgoxNQ0UZZOFyhk4ki4smY/NTd4muWyGQEXQIY7XfAYAZ3vyc7JZs64m9CqYBdM3y2uu9UrvEUr2LUvYh98+LGpxweOBcEqOFrlAw6mBb4cIVitDZuUVUGw8vuH9srbl2Z3tBm1VW0Hd3x56sc/7QJ+rPw+J/nRldZxCAE4irF58aGc6/9FgbxgCMHqefYMwRcJ969+2Nj0qqvVGVR50w3XKFiTLIrnqEotsrOgyvnLwWoOIcFAoZqpnmjglVGgBSKBwgnnnuWIuXPh30tZcaV8kAjffud9OAL/3jqgQ6SwENAcO1O7ABxVpaMQeJOF5PzqDufleRPOFtc2/48vw5WTyYMzaCerzYTyBa98eTtNlWPl9z21KOznxI3aV6MpPCSe338UNDH0WYnWVvu+yIl8i5A1mMU49OEfNgbsXzWzPdbgPpwAXjBkTgUJFqYeWPeE79ceatOXFPwrGMO6y1EwKUR2WNGTLVQKBqNNMFCoYCprqica45R2NPUMFOJ1U3DpSfkgzSkGvdPGTZwzdz5RG7MkgOOpI4Y79lJWeoxjeYYUisNbU7tZzebHHvmlOCva8MlG903Yk+GsZpvvrex/vClxrKzsQ7tJ5XRV2VfXr1G1HdxubKrq0tGuppAwCk4sYoVqzf1qhRMOV5xf2iw9UbEHvYuGTbaa6EzqCBhbnJ0Zds3pdmV1G30T7NneY7J848fzBa+TZBoCLlcLu9hjFp4Gq70TnsyJpWawYKBQzVSRNVUhFgPILr4HE3a1Z/+TYWvqdDmyVJ85/oJLrrgesrX2vfUsfi7CqVcNOLpfohJcOAq0MlFP+kqU4RU06YrLpoiHs5mjZJs1WN1lOGe1f9wwJY6F+ydyrNwmbBZGfmWiNdXNOw+9IammsKi8QvDTImr6BVtBsFp2p+XdvTaBvTcLB44TtFOLiSBw4J3fhOvK6jl+puhWWB/Px1qRQWWOjFrYhRu3+BAUHqfFM5Rsryk1g80Xv91tZvG++HvfcZdxrF2W5OVHS1gtFrN02d8sDckyas/+J3MQJuslrhzmB9mafOm1eLbgW488Nvu1JUthhMxanGQ6Ts8df5aCWiw8/qQxwaQU4XUfHVep1IZYLps1WB0pcFamOxgw6cX+qL46x8orKccDZI05lEzTjpVGrfqj7nm9vhZx2NMr6KHEtr6Zvs/mtO6r9RxPdmGPbiNv8BTTAuIICLqyRF78FO/UlDy8CRZjVIi70Wr3HtFNaNU8Q8tXrDZfI6KvuKRm8J69HhFnepGKvyBvJohFmgKFyVim2S9HtUChoEsP/SIJvsXwWQUnVE4ZPuocKNf0+x+C0BCfkiLiIn2ZMmPPUHnY13NHUFN5wEcFq+766b+XlPQQtJOJ8CR8eMUEtdnFdnyexk992DuKy6tzrEjZxLxeQ+PUBXna3nzQqK1qT2H/7kjpxNye5UHanNhXm7HHqK1mLIlVvpTEtr4hoicyZIKImJYRRADnkIgrS1CbuBhc+TD2YIGDWtyNhoKJ39wXy3uGYC3JviinbLDn5lVwQfH4i334aQoUwlGSsUyrd7VAoeCz/1YvUhkoF4s6lGvShZebXi4zqiilxBJWflzJ0mBlnEi2VRlaRtaq4SefIL4hVl39TiYiTWMzDCNNmt3VKnKswmPOjpSHvKu7UVsV2/qW+/BcaguHnBv6EDDPqK1u2uHtYEdSLRmbXvVc7NGMK6vnWfeR0ckvBERcWYJ8SNAkCJbgZu6NgYQIs3Ij+f1HEovnDy1Sel7h4DNzuw0UHEsyMbW4WzJtieVqnqFXF72ejF4oG+weYIJgXX6p0Mb9iWNMU6DQ89OHWKIWKHyl+q+0DSZBucyo4s3T7oI6y3bq6OYZOFDlkeVePUV9P7JGBikv/i4haLtv1mCZDW+z8uKZSCQiLuyjpArHyi7qw02TG6iPdsiqatn1oZHChljZxf0j5RVZOfmy/for37xzLRzLX52J2prq304sTCwpGDiGRTqxXJeoIYArS+RhODXlia2Yu8whWHl9Tux55j39Jr/S65yZPcbe2eP0aT3OuK3km/f0+c6cPt95pviE/5Nov2CJWtytS5cuIuvcC3MfV/AM8eN72m1J924tU32hLBmFwtO24MU5yWo9YWQlI1LmLjZO6Y3CjAoUghIRJdJjv36ABGKLquatXraQo/vYrVqI3btr11unIplk2BYWFIg0j5ORmgU497q3lyxd/BID5DJmyJQw/NGjRsSpTfHU070ap1/8XUL3zRrsart2VdmMU+rWgfuZq4UEnlw84Dlzxt3gSbndEpG8CscqKqsoCHs3KaO2qnX/FpEROsoUl1f460Jw7MWjsL3VqK32d0Msxx5FNsY0G7JIs1SbeX1MHYHGT+anrkREA16iouOEnn2O1lRB/kR0KssUHH167wm/Lhh0pqOG3G6Duo34YclYlS/2cIMTf7AjrnfIk/t6w8o04pST41qJnD4++3fJxFjpFR7ONbUdO2Qw9/ebbVuHc4t/+olZ1QueYyymjMLxcAoUMqFgAkQsgSTgIrEufvrBitcXvXjX7beQCFSRQAw8ZS+eooj31xHsUyCCrV3ePT906HEM0F2GWq4xrgo4N2yGi41hchkzZEoY/nPPPAoa0C+QMbkCQAEaibYKKZm/VkGVvQmBZtyH9hLf88w+l4qIWujU/ffegTwJPLl4wPOCSRPB8+GZ08GTBJ4kwCShFjyZCEfl0hwLahL6c+JG7cJo7ULH8YgUFhx9WqQ0/G8/Q7CMTd4v+YuMyF0GMtpc9667jFULzep++jTrVGdSQSC64Q+tDYrbyYj3C8HqftrNWQJfKWiqf2f/qpnimtUkRWg6kXquNFn9ynE3s6P7p//U8T7ISsbtkpXJFJM6Ll+55pln5yVrMvmiScmqRMq5v9943VRu6GbiFj/2jNEspSJtk8ksqPK457BgKHQRfKAQTgyBABMgYgkkAReJdTHZ2Cnv1+8ojiKJSwWWIyJpyfzXg49YeXtG7WlrZuGhX97D7wq7qrg8zqo/vfAUV0VcedwpqkDG5AoABWgkAIwTC+t0374Gz80a7LY5BmTtAsnyU6+6lMs7WS3lUKVFVfOgUyDGqUsCTxJgkrgCwfP5Z3/LNZPYRI5jEVyLlFfmFPdLVBRYSeuBrbAT9Q2x8orgiIQ7AzPYsaOWfZvwKDhWpaPwwNr/6WiLCWouKq/sfd5vQndVClqb4WLR2lfSaiHTJE6w9i5OO3vO73dqbneh7RYLB39TFhkpb3+icu6J3Ae5yZq3Qo7kWWlYqqlKlPcsIUp45TU3uYgNG3q8S23wVSxmLozQtGdcJwkUlgi/qmaOyzyydsJLzLzLkWuDSwVhF5m4qteWLF3z9tq4QvPUUH3aGr8UDhUuUdZ+TDK1jR41gusW3xUeO5xVajisfW/95Evdvq5o9uV45LJ3LFcuFNmswa7cfO7eXiKYZ0LhQ/jzABAYzVYAC7y4o4i0QpWUbwXfv+yHjk4+OY4FOykcMt60LKyjUbOw+Yv3lXs/NIRjvqXc3K+GRm1Vy54vv2fkl04XPbiyRL7xYmnI6z2s5zkP9Bw/Ex+JVeiSYaUv6DvSReCIrYqm05WV231I99N/LOjBCoBgMct5vYZxFEm5fQjMZYlImjL8oFdbTszm5pFFi5ssgSQ8QxzJq7mv0GbEYjN+OYuMS+rdq6dLbfBVIpsgyDpvGAWBHsfVhSorZc4bhRd/7ztcS5ZhiRlWXAgWl0piVbISyGuyF0tpsnzlGo5qCVrAJcraz+XKRUviJwHXLb4r5T+HVAgWo4jFmjj6leCmnrw/ri9Z+bjm+PMAEBgBkwSwwIs7SmrG7TohnckIFmISHCu353GRspBDbE3blxspbYg1NFI2kWGHm2Jb30hlFGrGEySSjVsV9BvZ44zb+l74Ys+z7iMAVDTsInvX8CpKeoy9s0/lbAhZwcAx9lqdtxCIps2VVXzy5SJOZUKEwRAshpzbQ+gT40hmZWXndhcVRv6qy9WflKe572n2U3Nf8XrfTXkV9N1aU+HfN0Ews85HfDws6s51yUtFAoXfOlP6/gBxcUGY2uQWudUwQJxD+IHgUpac6cyYOeNu05khu9z+7N6ZLixT9jlxy6p0ZFIkWP6aBDtR26yBhv5aoqwNS1wIFmolOFakrCKvV5iu746m/UZtdXvTPuxWS0TB8krK1Nr61ard2G3UVHe0RP1SKK5n31v3iEcMLbXZhT3gT8VDL+5+6o39L1lsJXgVJZEh43N7HGsJB5ChU8sGhQxkMQAj7V1E0+bKKhw01t5RsjxcWQGouCaCuGXnFSczI7E8K1fibWoF/0pij36VzJk73/PtPL/68ksPpMSFspi9nDZa5TU0zzcK8Rsp0E13r5v4prLm0OxHaBZ+ILwXuDHMZDozLpg0UZZdoZaLwR1Y6BeuPiRDT74QLC4kXwaCJ1hws4bE7v626p3EwuBLPAkWJolyLJbSovKQnVjR2urYtmUYrZYIe0ET1dr62MqoqWr6fJWPCsVVETHcv/phBZol3kXmSwq+f+cwkBSKomlwZeFEFIkSpmD1V5qK4ibw6L2lV5xj3XzTtayLVsNwM8tXrkn3O1CeA+Tm7ikTJ+BOWRDGl0MYhYxUgj3AIdybqL2s4O51YxbcOw2mFoIlcjFkgisLxJSfwbKDmQq7tesR36zB3srMP/TfvzUzIR43b9nq7sEybRPiWDlFfWEnQd7QTePsx+Zd66O1VfYSqXxO1wEMoUt2rlQr34Wb69+NblL/+E/q9hibXj3CaRaXcW73IakjKaUhmgZXVk5RPykbUhQGN1idt5L2Zm+Zf0h0CAuPk3wQm5/I/+jE53+Xr1zj/py7vT+/fvHbdZLn5r7otTfJSCV3yoKqa67+AUfZJBIoVHhZAejcnUPPPDsvfbMsCIIgwUIbXk9GRCashKni120ARkLNRbhpMkug9fjkktUGUE7vEyqnYIZnX0IcK1Jekd9/lKeuZAK+lOP+adu/VVkVBCu/7ynKzX1p2NHWEj20IVadL9qUlYRIs6Ib/qBsto8N8weM9lGboCrfXVnZhb0Euw5SrKO1SaK7VtF3XWUDhR9/vJGbuIQlYqKyC9WWz7aJKZaQWr5yDTf3r58k+m6BqZoF3p2yIKYQKITleK6UaoHCN5auwCT3tHzFaneB9NUy8Ecem+05drsBsx6dbT8NLM/U3zztLilT3W1T24rCrhP0pDZrsLe18gwKPdZpYBk65T4g7hH05lj5R4+GoAQ2AMeOjJpqI5UNsQacAU101BxkoVFbFdsc3EchXIYGzdq98HrZR+BdFIpUHeExyuiGPzTVZ8QzBCKTpSzT2ijxE6ItulOkI4VA4bIVq+6590HuhiL6RWRQJbumovb5F17i6FcybTC9EbKkM03ralqPAAALIElEQVSBQris5+jUAoUi0F33o1vr6oUuoWRGqpXT6dR/vQXXlFRzHG/LU3jBUKovS5gevzv5Kk96bcmLZHCjioi5yMx86FERD5CLBqrQMPupuWSCTIydqZcirF4cK6cwUlqRU9Q3yGHE9dW2/zPYSVyh+Gl2XnFReUVO2D/6W/fVpEITxccrKNm6f8uuqqnGlsWBUR+RfVDb9qnv3S848BDFoh8+7yPaHcJOoCCH3Cb89YW2xvr25oMito2TDxSy/q15e+38P74sot9TxryxotNTMk4AG4gpxBWqndptUCCdaQoUwmU9h6MQKITEAJ2nZgRm/HIW1JNMMIm+Xlqw8MzxFwiaF2cV/Niv6yFOc+IpGE6//yF6hIsk1oZYAu2DbvpiAH+SuJR8UeWphKmnL1zIslPvwbGKyysiQ87x7D6tAo211c27PlDuIlJemeyzHso6FRoSJWwJcEMsQQsblt+7783/DMC/0rR9xd43vT+f0lSnvpGM4JARa94RRC90FJcYXXSjxKrf7PpuROv+TXH6AzxN2lVs2/KkdV+taNr21lcLkp7J+mws5wo/N1Nc0pRvrNZgiGiw2lmnChlswIVmv7nLkk6iRZ6eDLVAIYuc+4jUAoXib40xrtvvvI8BupuRei2z8NqSpRWTLnH5NqVIL8SY0CMiqSwDGrABiKBfVCbOkg8/+iSuRPyUvwVon7i8pyR/4/x1MDueksoCKGfKmHr6UlDixrHyen0tUlapoNTHJrFtywgUKivM63Ni6IFOjI999rpRo/7APhrSl1j49y6etnfJrdAgH70spsEtuzc0fjx/1ytXixAss0m6CR9jxIdn9uV4xL/iWG4Wtsf2mBm144F3fgMgIm3BgZCuiyRMkbG4CPheFRV4nK6jpfHAuqc8u247WHdg/TOeYggo+GzszhXlJS3FGyuWmwkvwvcv+yFLi3kqdbRssFOZgQP6j5D8ruJhGSi0kIRmEQ5jFQQuq9DHDHMHZWGJJTTJbKauGT14mHBMpq4qTsOGTzZCOE4bN1GNDcRpS3Yq68ix9DBB+B2tU78y/HUQv0vx15SjMb5MvRvHipROzO1Z7th3MIXtsQaihB3N+5W7g2AFvHtToqltxhdGTfWXkZ3E6swoOcS03ryjfl7lwfVPs7qDvLJdcBToGnqgVrtfvQFW4c5p4jo6sGYWzdPHHjw9SQfffxIEGIXdMOxpbdgMPWI49nKFPBoaVs6gi2QgU25sWQzxdVcOqo0f/T7OTvcmqdRikmDzxg+eafxgjoswDt09r/9HR/MBFxmrStZnw32ce67VnIy5pLH8kBdJSLKmDh91Dg19WVNRAs2SIgEuNii8/Xe4Bgqt2QRhJgsaxMQBnVWunOEqQg9hwUuuuB6HEJSFLpS1JTbEw4RjEqYFM6CvRAHxErxWKGHgZ0+4cNKFl8dd/OJ6ApB8ddHrEOJ0dATt49cUk7V85RoASaULpsPfqU/KsQqHnEuULRVbU29rbKpiuVXWU1j6T6H74TDeqFnYVBfa+y8YIJUOvv80q/vOFy/EswVPYmXFFwW9YOFP1MMCTxUCiME/9r/7SN1z47/48yV737wDPZCAxCaeJbSiOWwPVelIUBx3G/AegQCjsPeOPbuqpnq2ddds1ZpdALK9CytPOTFcS9glA8hxdlpKfM8ImmRae2Ddkzv/NLlh1S8bN8wzNi2MffaGsfmvxsaX96/97Z4lt+7+y/VtB0TfEebWefxJY8QT3Mi0wX5kSWP54RbMqsmCFOdC4KZMyfKVa/ABmAsVa6q9eep5VmiLBCQagH5+MWMDPMzTBmwTR8OU9FzYFHSiWWQ5x6eCpFSC0wCIQgJkBsJE0x0hWmgHeLJeAiyJtdNRJ+XUkpgX5MGftlxF6CEsyOLt2MqXQi5LLm/6okfTWswgcUE66qecWhLXKqZC0bhcQRglDJzhO7YSLRSWs++PL9yoCxMBnuLyCpJMFoFIAOEvnXkEIjoFLv64HLUlTj0NmQ5/p96ZY+UU94NgZeXkO1oWTGHLF+tw/yj3ldttUHF5RVaWxAfRlPtyadhU9w6uOBeBjK3Cs8USzsqKLwp6wcKfuGyzwFOFAGLwj6hALCljx6sN8xeB9r9/z+DAu481rHxg37J7Glb8omH1r6If/b45kEfuHMfCLZi7PAsSLgSWYStxU6aEuzOkIa0LFcpZCxMNwBKIBTbAw9JtgyMyh18htBKowZP1EmBJrJ3gnJgop5bEvCAP/rQNGBB6NK3FDBIXZKKdlFBOLYlrFVOhaFxRAZtKqHraLdfLdgqbSX2zBvFO+UtnHoHInH3+uEAvMSVOPQ3FexGUdOZYReUVBf1OFVSRDrGOjvZoTXXrAfXdZSLlFXlHDU+HbeI6O9qaIVg4e8SbaEmNgEagcyGgrdUIHDkIPP/sbxW+uODLZg2dFGQHjlVw9GmR0pAfdTdqq41Nf1HGtGDgmNCHgPFGbVVsy2IyOmkENAIaAY2ARqBTI/DC3McVvue4fOUaXG6deuCpGB/PsbJyI5GyyuyiPqkoTbFta8Nmo1b9gzNZ+d0PDaGwR4pmpNi8de/GVEaRYu+dobm2USOgEdAIaAQ6AQKECBe8OEf2hVYGVle/k8gmmSM2xXOsSHll4THfChcOo3Zhy64PlW0gSlg4aJxyc78aQrBa9nzqlzatRyOgEdAIaAQ0Aj4iMHrUCBFtV1w25U8vPKXwvXAjFkvHZg0iNqcm42frr3CsvF5DI2UVfqqX19W0balRo76VVH6fk4rLQw50Mmhjy+JojborDg06aQQ0AhoBjYBGIH0IPPrfM1YvW0gEcOaMuyFScZSLEsqXLn7prttvKSlRiQvN/+PLr1RnxOfj0oehp+avcCwIVl5JmWeb9Am0x/ZCTdpbhL6w4WhGpLwyp9tgx6rACtuiO3FidbSJfu82MMN0RxoBjYBGII0IaNWdBwHCfzAnEhHACyZNhEg998yjn36wwkqUUK7wAJaJwfKVa35+34Nm/kg+foVj7V/zcOL7+UGW7HzxoqYdK1OZj4a//TJIgx37+uKl7zfXvZ3KKHRbjYBGQCOgEdAIpA+ByRdNSp/yzVu2HuGPYVnYfoVjWaU6oxHQCASJgO5LI6AR0AgEicCpI9K1t1Fd/c6r/uXfghxLJvelOVYmz462TSOgEdAIaAQ0Av4jMODofv4r7dLFfM49+M1R0zEWX3R2do7lCwhaiUZAI6AR0AhoBI4gBI4d4v+DyxCs2++8Tz/nbr+MNMeyo6HzGgGNgEZAI6ARSB2BjNZwxWVTfLdPEyxHSDXHcoRFF2oENAIaAY2ARuDwRGD4ySf4O7B9+xq0B8sRUs2xHGHRhRoBjUBICOhuNQIagTQjMHTocT72sHnL1u9OvkqHCB0h1RzLERZdqBHQCGgENAIagcMTgSHHDPJlYMQH58ydP6Fyin7IPRmemmMlQ6bzlWuLNQIaAY2ARkAj4I7A6FEjIoWF7jKetbCr15YsrZh0id5o1B0rzbHc8dG1GgGNgEZAI6AROHwQqJx4rvJgoFYbPtn4yGOzh48657of3SrovlLu7jBoqDnWYTCJeggaAY2ARkAjoBEQQgDP09kTLpx+/0NQJXxRpM1btpopsX1d/U6qlq9c89KChTdPuwtqNenCyx+e9XiipC5xREBzLEdYdKFGQCOgEQgdAW2ARiAtCOB/eubZeVAlfFGkCZVTzHT8SWPi0pnjL6DqymtumnbbPfqpdoXJ0BxLATTdRCOgEdAIaAQ0AhoBjYAHAppjeQCkqzslAtpojYBGQCOgEdAIhI3A/wcAAP//+nTXOwAAAAZJREFUAwCfDZ2/xKhThQAAAABJRU5ErkJggg=="

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
$header.Size      = New-Object System.Drawing.Size(480, 88)
$header.Location  = New-Object System.Drawing.Point(0, 0)
$header.BackColor = $clrPanel
$form.Controls.Add($header)

# Logo PictureBox — decoded from embedded base64 PNG
$logoBytes  = [System.Convert]::FromBase64String($LOGO_B64)
$logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
$logoBitmap = [System.Drawing.Image]::FromStream($logoStream)

$picLogo           = New-Object System.Windows.Forms.PictureBox
$picLogo.Image     = $logoBitmap
$picLogo.SizeMode  = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$picLogo.Location  = New-Object System.Drawing.Point(14, 12)
$picLogo.Size      = New-Object System.Drawing.Size(148, 48)
$picLogo.BackColor = $clrPanel
$header.Controls.Add($picLogo)

# Subtitle sits directly below the logo, left-aligned with it
$lblSub           = New-Object System.Windows.Forms.Label
$lblSub.Text      = "Windows Agent Installer"
$lblSub.ForeColor = $clrMuted
$lblSub.Location  = New-Object System.Drawing.Point(16, 64)
$lblSub.Size      = New-Object System.Drawing.Size(300, 18)
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

$txtOrg     = Add-Field "Organization ID"              ""                 108
$txtLicense = Add-Field "License Key"                  ""                 164
$txtServer  = Add-Field "Server ID (friendly name)"    $env:COMPUTERNAME  220

# Status label
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = ""
$lblStatus.Location  = New-Object System.Drawing.Point(30, 290)
$lblStatus.Size      = New-Object System.Drawing.Size(410, 20)
$lblStatus.ForeColor = $clrMuted
$form.Controls.Add($lblStatus)

# Install button
$btnInstall           = New-Object System.Windows.Forms.Button
$btnInstall.Text      = "Install"
$btnInstall.Location  = New-Object System.Drawing.Point(30, 318)
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

        # Use schtasks.exe directly — avoids PowerShell's XML Duration limit.
        # /sc MINUTE /mo N creates an indefinitely repeating task with no expiry.
        $monTr  = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File '$AGENT_PATH' -Mode Monitor"
        $pullTr = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File '$AGENT_PATH' -Mode Pull"

        $r = & schtasks.exe /create /tn $TASK_MONITOR /tr $monTr /sc MINUTE /mo 1 /ru SYSTEM /rl HIGHEST /f 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Monitor task registration failed: $r" }
        Start-ScheduledTask -TaskName $TASK_MONITOR

        $r = & schtasks.exe /create /tn $TASK_PULL /tr $pullTr /sc MINUTE /mo 5 /ru SYSTEM /rl HIGHEST /f 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Pull task registration failed: $r" }
        Start-ScheduledTask -TaskName $TASK_PULL

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
