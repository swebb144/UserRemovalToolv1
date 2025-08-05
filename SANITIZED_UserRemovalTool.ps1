# Define log file
$logFile = "<path to log>"

function Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $message"
    Write-Host $message
}

# Prompt for username
$username = Read-Host "Enter the username (UPN or sAMAccountName)"
Log "Starting offboarding for user: $username"

# Connect to Microsoft Graph
try {
    Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.ReadWrite.All"
    Log "Connected to Microsoft Graph."
} catch {
    Log "ERROR: Failed to connect to Microsoft Graph. $_"
    exit
}

# Import Active Directory module
try {
    Import-Module ActiveDirectory
    Log "Active Directory module imported."
} catch {
    Log "ERROR: Failed to import Active Directory module. $_"
    exit
}

# Get user objects
try {
    $cloudUser = Get-MgUser -UserId "$username@<yourdomain>.com"
    $onPremUser = Get-ADUser -Identity $username -Properties MemberOf
    Log "Retrieved user objects from Graph and on-prem AD."
} catch {
    Log "ERROR: Failed to retrieve user objects. $_"
    exit
}

# Remove licenses
try {
    $assignedLicenses = Get-MgUserLicenseDetail -UserId $cloudUser.Id
    $skuIds = $assignedLicenses.SkuId
    if ($skuIds.Count -gt 0) {
        $removeLicenses = @{ "AddLicenses" = @(); "RemoveLicenses" = $skuIds }
        Set-MgUserLicense -UserId $cloudUser.Id -BodyParameter $removeLicenses
        Log "Removed all assigned licenses."
    } else {
        Log "No licenses found to remove."
    }
} catch {
    Log "ERROR: Failed to remove licenses. $_"
}

# Remove from Azure AD groups (skip mail-enabled, on-prem synced, and unauthorized)
try {
    $groups = Get-MgUserMemberOf -UserId $cloudUser.Id
    foreach ($group in $groups) {
        if ($group.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group") {
            $groupId = $group.Id
            $groupDetails = Get-MgGroup -GroupId $groupId

            # Skip mail-enabled security groups
            if ($groupDetails.MailEnabled -and $groupDetails.SecurityEnabled) {
                Log "Skipped mail-enabled security group: $($groupDetails.DisplayName)"
                continue
            }

            # Skip on-prem synced groups
            if ($groupDetails.OnPremisesSyncEnabled -eq $true) {
                Log "Skipped on-prem synced group: $($groupDetails.DisplayName)"
                continue
            }

            # Attempt removal with error handling
            try {
                Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $cloudUser.Id
                Log "Removed from Azure AD group: $($groupDetails.DisplayName)"
            } catch {
                $errorMessage = $_.Exception.Message
                switch -Wildcard ($errorMessage) {
                    "*Insufficient privileges*" {
                        Log "Skipped group due to insufficient privileges: $($groupDetails.DisplayName)"
                    }
                    "*Authorization_RequestDenied*" {
                        Log "Skipped group due to authorization denial: $($groupDetails.DisplayName)"
                    }
                    default {
                        Log "ERROR: Failed to remove from group $($groupDetails.DisplayName): $errorMessage"
                    }
                }
            }
        }
    }
} catch {
    Log "ERROR: Failed to enumerate Azure AD groups. $_"
}


# Remove from on-prem AD groups
try {
    foreach ($groupDN in $onPremUser.MemberOf) {
        Remove-ADGroupMember -Identity $groupDN -Members $username -Confirm:$false
        Log "Removed from on-prem AD group: $groupDN"
    }
} catch {
    Log "ERROR: Failed to remove from on-prem AD groups. $_"
}

# Disable on-prem AD account
try {
    Disable-ADAccount -Identity $username
    Log "Disabled on-prem AD account."
} catch {
    Log "ERROR: Failed to disable on-prem AD account. $_"
}

# Block Azure AD sign-in
try {
    Update-MgUser -UserId $cloudUser.Id -BodyParameter @{ AccountEnabled = $false }
    Log "Blocked Azure AD sign-in."
} catch {
    Log "ERROR: Failed to block Azure AD sign-in. $_"
}

# Connect to on-prem Exchange server
try {
    $session = New-PSSession -ConfigurationName Microsoft.Exchange `
        -ConnectionUri http://<your_exchange_server>/PowerShell/ `
        -Authentication Kerberos

    Import-PSSession $session -DisableNameChecking -AllowClobber
    Log "Connected to on-prem Exchange server: <your_exchange_server>"
} catch {
    Log "ERROR: Failed to connect to on-prem Exchange server. $_"
}

# Remove from on-prem Exchange distribution lists
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


