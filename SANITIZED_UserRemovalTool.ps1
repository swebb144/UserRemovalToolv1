
#Hide console window
Add-Type -Name Win32ShowWindow -Namespace Win32Functions -MemberDefinition '
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(int handle, int state);
'
$consolePtr = (Get-Process -Id $PID).MainWindowHandle
[Win32Functions.Win32ShowWindow]::ShowWindow($consolePtr, 0)  # 0 = Hide


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# GUI Setup
$form = New-Object System.Windows.Forms.Form
$form.Text = "User Offboarding Tool"
$form.Size = New-Object System.Drawing.Size(600, 500)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Text = "Enter Username:"
$label.Location = New-Object System.Drawing.Point(20, 20)
$label.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Location = New-Object System.Drawing.Point(130, 20)
$textBox.Size = New-Object System.Drawing.Size(400, 20)
$form.Controls.Add($textBox)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 60)
$progressBar.Size = New-Object System.Drawing.Size(540, 20)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$form.Controls.Add($progressBar)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 100)
$logBox.Size = New-Object System.Drawing.Size(540, 300)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

$button = New-Object System.Windows.Forms.Button
$button.Text = "Start Offboarding"
$button.Location = New-Object System.Drawing.Point(230, 420)
$button.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($button)

# Logging function
$logFile = "C:\UserRemovalTool\UserOffboarding.log"
function Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logBox.AppendText("$timestamp - $message`r`n")
    $logBox.Refresh()
    Add-Content -Path $logFile -Value "$timestamp - $message"
}

# Offboarding logic
$button.Add_Click({
    $username = $textBox.Text
    $domain = "yourdomain.com"
    if (-not $username) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a username.")
        return
    }

    $progressBar.Value = 0
    Log "Starting offboarding for user: $username"

    try {
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.ReadWrite.All"
        Log "Connected to Microsoft Graph."
        $progressBar.Value = 10
    } catch {
        Log "ERROR: Failed to connect to Microsoft Graph. $_"
        return
    }

    try {
        Import-Module ActiveDirectory
        Log "Active Directory module imported."
        $progressBar.Value = 20
    } catch {
        Log "ERROR: Failed to import Active Directory module. $_"
        return
    }

    try {
        $cloudUser = Get-MgUser -UserId "$username@$domain"
        $onPremUser = Get-ADUser -Identity $username -Properties MemberOf
        Log "Retrieved user objects from Graph and on-prem AD."
        $progressBar.Value = 30
    } catch {
        Log "ERROR: Failed to retrieve user objects. $_"
        return
    }

    try {
        $groups = Get-MgUserMemberOf -UserId $cloudUser.Id
    } catch {
        Log "ERROR: Failed to retrieve Azure AD group memberships. $_"
        $groups = @()
    }

    foreach ($group in $groups) {
        if ($group.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group") {
            $groupId = $group.Id
            try {
                $licenseDetails = Get-MgGroupLicenseDetail -GroupId $groupId
                if ($licenseDetails.SkuId.Count -gt 0) {
                    $groupDetails = Get-MgGroup -GroupId $groupId
                    Log "User is in a licensing group: $($groupDetails.DisplayName)"
                    try {
                        Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $cloudUser.Id
                        Log "Removed user from licensing group: $($groupDetails.DisplayName)"
                    } catch {
                        Log "ERROR: Could not remove user from licensing group $($groupDetails.DisplayName): $($_.Exception.Message)"
                    }
                }
            } catch { continue }
        }
    }
    $progressBar.Value = 40

    try {
        $assignedLicenses = Get-MgUserLicenseDetail -UserId $cloudUser.Id
        $skuIds = $assignedLicenses.SkuId
        if ($skuIds.Count -gt 0) {
            $removeLicenses = @{ "AddLicenses" = @(); "RemoveLicenses" = $skuIds }
            Set-MgUserLicense -UserId $cloudUser.Id -BodyParameter $removeLicenses
            Log "Removed all directly assigned licenses."
        } else {
            Log "No directly assigned licenses found to remove."
        }
    } catch {
        Log "ERROR: Failed to remove directly assigned licenses. $_"
    }
    $progressBar.Value = 50

    foreach ($group in $groups) {
        if ($group.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group") {
            $groupId = $group.Id
            $groupDetails = Get-MgGroup -GroupId $groupId

            if ($groupDetails.MailEnabled -and $groupDetails.SecurityEnabled) {
                Log "Skipped mail-enabled security group: $($groupDetails.DisplayName)"
                continue
            }

            if ($groupDetails.OnPremisesSyncEnabled -eq $true) {
                Log "Skipped on-prem synced group: $($groupDetails.DisplayName)"
                continue
            }

            try {
                Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $cloudUser.Id
                Log "Removed from Azure AD group: $($groupDetails.DisplayName)"
            } catch {
                $errorMessage = $_.Exception.Message
                if ($errorMessage -like "*Insufficient privileges*" -or $errorMessage -like "*Authorization_RequestDenied*") {
                    Log "Skipped group due to insufficient privileges: $($groupDetails.DisplayName)"
                } else {
                    Log "ERROR: Failed to remove from group $($groupDetails.DisplayName): $errorMessage"
                }
            }
        }
    }
    $progressBar.Value = 60

    try {
        foreach ($groupDN in $onPremUser.MemberOf) {
            Remove-ADGroupMember -Identity $groupDN -Members $username -Confirm:$false
            Log "Removed from on-prem AD group: $groupDN"
        }
    } catch {
        Log "ERROR: Failed to remove from on-prem AD groups. $_"
    }
    $progressBar.Value = 70

    try {
        Disable-ADAccount -Identity $username
        Log "Disabled on-prem AD account."
    } catch {
        Log "ERROR: Failed to disable on-prem AD account. $_"
    }
    $progressBar.Value = 80

    try {
        Update-MgUser -UserId $cloudUser.Id -BodyParameter @{ AccountEnabled = $false }
        Log "Blocked Azure AD sign-in."
    } catch {
        Log "ERROR: Failed to block Azure AD sign-in. $_"
    }
    $progressBar.Value = 90

    try {
        $session = New-PSSession -ConfigurationName Microsoft.Exchange `
            -ConnectionUri http://yourexchangeserver/PowerShell/ `
            -Authentication Kerberos
        Import-PSSession $session -DisableNameChecking -AllowClobber
        Log "Connected to on-prem Exchange server: yourexchangeserver"
    } catch {
        Log "ERROR: Failed to connect to on-prem Exchange server. $_"
    }

    try {
        $dlMemberships = Get-DistributionGroup | Where-Object {
            (Get-DistributionGroupMember -Identity $_.Identity -ErrorAction SilentlyContinue) -match $username
        }

        foreach ($dl in $dlMemberships) {
            Remove-DistributionGroupMember -Identity $dl.Identity -Member $username -Confirm:$false
            Log "Removed from on-prem Exchange distribution list: $($dl.DisplayName)"
        }
    } catch {
        Log "ERROR: Failed to remove from on-prem Exchange distribution lists. $_"
    }

    try {
        Start-ADSyncSyncCycle -PolicyType Delta
        Log "Triggered AD sync."
    } catch {
        Log "ERROR: Failed to trigger AD sync. $_"
    }

    $progressBar.Value = 100
    Log "✅ Offboarding complete for user: $username"
})

# Show GUI
[void]$form.ShowDialog()
