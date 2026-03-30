  = New-Object System.Drawing.Point(153, 108)
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

# Logo PictureBox — decoded from embedded base64 PNG (left side of header)
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

        $actMon = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Monitor"
        $trigMonRepeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $trigMonStartup = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $TASK_MONITOR -Action $actMon `
            -Trigger @($trigMonRepeat, $trigMonStartup) `
            -RunLevel Highest -User "SYSTEM" -Force | Out-Null
        Start-ScheduledTask -TaskName $TASK_MONITOR

        $actPull = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$AGENT_PATH`" -Mode Pull"
        $trigPullRepeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $trigPullStartup = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $TASK_PULL -Action $actPull `
            -Trigger @($trigPullRepeat, $trigPullStartup) `
            -RunLevel Highest -User "SYSTEM" -Force | Out-Null
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
            "$TASK_MONITOR  — runs every 1 minute & on startup`n" +
            "$TASK_PULL  — runs every 5 minutes & on startup`n`n" +
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
