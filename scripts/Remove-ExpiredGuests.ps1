<#
.SYNOPSIS
    Azure Automation runbook to clean up guest accounts after the 60-day grace period.

.DESCRIPTION
    Processes disabled guest accounts that have exceeded the 60-day grace period
    without sponsor reactivation. Actions:
    - Day 45: Sends notification to sponsor (warning of upcoming cleanup)
    - Day 60+: Revokes access package assignments, removes group memberships,
      and optionally deletes the guest account.

    Works in conjunction with Disable-StaleGuests.ps1 which stamps the disable
    date in extensionAttribute1 (ISO 8601 format).

    SAFETY: Only processes guests disabled by the automation (identified by the
    extensionAttribute1 stamp). Does not affect manually disabled guests.

.PARAMETER GracePeriodDays
    Days after disablement before cleanup. Default: 60

.PARAMETER NotificationDays
    Days before cleanup to notify sponsor. Default: 45

.PARAMETER DeleteAccount
    If specified, deletes the guest account after cleanup. Default: $false (preserve account)

.PARAMETER SenderUserId
    Object ID or UPN of the mailbox to send notifications from.
    Required for sponsor notifications.

.PARAMETER WhatIf
    When specified, logs what would happen without making changes.

.PARAMETER MaxRetries
    Maximum retry attempts for throttled requests. Default: 5.

.NOTES
    Required Graph API Permissions (on Managed Identity):
    - User.ReadWrite.All
    - AuditLog.Read.All
    - Mail.Send
    - EntitlementManagement.ReadWrite.All
    - GroupMember.ReadWrite.All

    Schedule: Weekly (grace period is long enough that daily is unnecessary)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateRange(30, 365)]
    [int]$GracePeriodDays = 60,

    [Parameter()]
    [ValidateRange(7, 59)]
    [int]$NotificationDays = 45,

    [Parameter()]
    [switch]$DeleteAccount,

    [Parameter()]
    [string]$SenderUserId,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxRetries = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$today = Get-Date
$graceCutoff = $today.AddDays(-$GracePeriodDays)
$notifyCutoff = $today.AddDays(-$NotificationDays)
$runTimestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

Write-Output "============================================================"
Write-Output "Remove-ExpiredGuests Runbook"
Write-Output "Run Time         : $runTimestamp"
Write-Output "Grace Period     : $GracePeriodDays days"
Write-Output "Notify at Day    : $NotificationDays"
Write-Output "Delete Accounts  : $DeleteAccount"
Write-Output "WhatIf Mode      : $WhatIf"
Write-Output "============================================================"

#region --- Authentication ---
try {
    Write-Output "[AUTH] Connecting to Microsoft Graph with Managed Identity..."
    Connect-MgGraph -Identity -NoWelcome
    $context = Get-MgContext
    Write-Output "[AUTH] Connected as: $($context.Account) | Tenant: $($context.TenantId)"
}
catch {
    Write-Error "[AUTH] Failed to connect: $_"
    throw
}
#endregion

#region --- Query Disabled Guests with Disable Date ---
Write-Output "[QUERY] Retrieving disabled guests with automation stamp..."

$allDisabledGuests = [System.Collections.Generic.List[object]]::new()
$uri = "https://graph.microsoft.com/v1.0/users?" +
       "`$filter=userType eq 'Guest' and accountEnabled eq false&" +
       "`$select=id,displayName,mail,userPrincipalName,onPremisesExtensionAttributes,sponsors&" +
       "`$top=999&" +
       "`$count=true"

$headers = @{ ConsistencyLevel = 'eventual' }

do {
    $retryCount = 0
    $response = $null

    while ($null -eq $response -and $retryCount -le $MaxRetries) {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers $headers
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryCount++
                $retryAfter = 30 * $retryCount
                Write-Output "[THROTTLE] Rate limited. Retry $retryCount/$MaxRetries in ${retryAfter}s..."
                Start-Sleep -Seconds $retryAfter
            }
            else { throw }
        }
    }

    if ($null -eq $response) { throw "Graph API throttling exceeded maximum retries" }

    foreach ($user in $response.value) {
        $disableDateStr = $user.onPremisesExtensionAttributes.extensionAttribute1
        if ($disableDateStr -and $disableDateStr -match '^\d{4}-\d{2}-\d{2}T') {
            $allDisabledGuests.Add([PSCustomObject]@{
                Id           = $user.id
                DisplayName  = $user.displayName
                Mail         = $user.mail
                UPN          = $user.userPrincipalName
                DisabledDate = [DateTime]$disableDateStr
                DaysDisabled = [math]::Round(($today - [DateTime]$disableDateStr).TotalDays)
                Sponsors     = $user.sponsors
            })
        }
    }

    $uri = $response.'@odata.nextLink'
} while ($null -ne $uri)

Write-Output "[QUERY] Found $($allDisabledGuests.Count) guests with automation disable stamp"
#endregion

#region --- Categorize: Notify vs Cleanup ---
$toNotify = $allDisabledGuests | Where-Object {
    $_.DaysDisabled -ge $NotificationDays -and $_.DaysDisabled -lt $GracePeriodDays
}
$toCleanup = $allDisabledGuests | Where-Object {
    $_.DaysDisabled -ge $GracePeriodDays
}

Write-Output "[FILTER] Guests pending notification (day $NotificationDays-$GracePeriodDays): $($toNotify.Count)"
Write-Output "[FILTER] Guests past grace period (day $GracePeriodDays+): $($toCleanup.Count)"
#endregion

#region --- Sponsor Notifications ---
if ($toNotify.Count -gt 0 -and $SenderUserId) {
    Write-Output "[NOTIFY] Sending sponsor notifications for $($toNotify.Count) guests..."

    foreach ($guest in $toNotify) {
        # Resolve sponsor
        $sponsorEmail = $null
        try {
            $sponsors = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)/sponsors" -ErrorAction SilentlyContinue
            if ($sponsors.value.Count -gt 0) {
                $sponsorId = $sponsors.value[0].id
                $sponsor = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/v1.0/users/$sponsorId`?`$select=mail,displayName"
                $sponsorEmail = $sponsor.mail
            }
        }
        catch {
            Write-Output "[NOTIFY] Could not resolve sponsor for $($guest.DisplayName): $_"
        }

        if (-not $sponsorEmail) {
            Write-Output "[NOTIFY] No sponsor found for $($guest.DisplayName) - skipping notification"
            continue
        }

        $daysRemaining = $GracePeriodDays - $guest.DaysDisabled
        $subject = "Action Required: Guest account '$($guest.DisplayName)' will be removed in $daysRemaining days"
        $body = @"
<p>Hello,</p>
<p>The guest account <strong>$($guest.DisplayName)</strong> ($($guest.Mail)) was disabled due to inactivity on $($guest.DisabledDate.ToString('yyyy-MM-dd')).</p>
<p>The account will be permanently cleaned up in <strong>$daysRemaining days</strong> unless you take action.</p>
<p><strong>To reactivate:</strong> Contact your IT administrator or use the reactivation workflow to restore this guest's access.</p>
<p>If no action is taken, the guest's group memberships and access package assignments will be removed.</p>
<p>Regards,<br/>Entra ID Governance Automation</p>
"@

        if ($WhatIf) {
            Write-Output "[WHATIF] Would notify $sponsorEmail about $($guest.DisplayName) (${daysRemaining}d remaining)"
        }
        else {
            $mailBody = @{
                message = @{
                    subject      = $subject
                    body         = @{ contentType = "HTML"; content = $body }
                    toRecipients = @(@{ emailAddress = @{ address = $sponsorEmail } })
                }
                saveToSentItems = $false
            } | ConvertTo-Json -Depth 5

            try {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/users/$SenderUserId/sendMail" `
                    -Body $mailBody -ContentType 'application/json'
                Write-Output "[NOTIFY] Notified $sponsorEmail for $($guest.DisplayName)"
            }
            catch {
                Write-Output "[NOTIFY] Failed to send mail to $sponsorEmail : $_"
            }
        }
    }
}
elseif ($toNotify.Count -gt 0 -and -not $SenderUserId) {
    Write-Output "[NOTIFY] WARNING: $($toNotify.Count) guests need notification but no SenderUserId configured"
}
#endregion

#region --- Cleanup Expired Guests ---
if ($toCleanup.Count -gt 0) {
    Write-Output "[CLEANUP] Processing $($toCleanup.Count) guests past grace period..."

    $cleanedCount = 0
    $errorCount = 0

    foreach ($guest in $toCleanup) {
        Write-Output "[CLEANUP] Processing: $($guest.DisplayName) ($($guest.Mail)) - disabled $($guest.DaysDisabled) days ago"

        if ($WhatIf) {
            Write-Output "[WHATIF] Would remove group memberships and access packages for $($guest.DisplayName)"
            if ($DeleteAccount) {
                Write-Output "[WHATIF] Would delete account: $($guest.Id)"
            }
            $cleanedCount++
            continue
        }

        try {
            # 1. Remove access package assignments
            Write-Output "[CLEANUP]   Revoking access package assignments..."
            $assignments = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=targetId eq '$($guest.Id)' and state eq 'Delivered'"

            foreach ($assignment in $assignments.value) {
                $revokeBody = @{
                    requestType = "AdminRemove"
                    accessPackageAssignment = @{ id = $assignment.id }
                } | ConvertTo-Json -Depth 5

                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentRequests" `
                    -Body $revokeBody -ContentType 'application/json' | Out-Null
                Write-Output "[CLEANUP]   Revoked assignment: $($assignment.id)"
            }

            # 2. Remove from all groups (except dynamic groups which auto-manage)
            Write-Output "[CLEANUP]   Removing group memberships..."
            $memberships = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)/memberOf?`$select=id,displayName,groupTypes"

            foreach ($group in $memberships.value) {
                # Skip dynamic groups (can't manually remove) and directory roles
                if ($group.'@odata.type' -ne '#microsoft.graph.group') { continue }
                if ($group.groupTypes -contains 'DynamicMembership') { continue }

                try {
                    Invoke-MgGraphRequest -Method DELETE `
                        -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/$($guest.Id)/`$ref"
                    Write-Output "[CLEANUP]   Removed from group: $($group.displayName)"
                }
                catch {
                    Write-Output "[CLEANUP]   Failed to remove from $($group.displayName): $_"
                }
            }

            # 3. Clear the disable date stamp
            $clearBody = @{
                onPremisesExtensionAttributes = @{
                    extensionAttribute1 = $null
                }
            } | ConvertTo-Json -Depth 3

            Invoke-MgGraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)" `
                -Body $clearBody -ContentType 'application/json' | Out-Null

            # 4. Optionally delete the account
            if ($DeleteAccount) {
                Write-Output "[CLEANUP]   Deleting guest account..."
                Invoke-MgGraphRequest -Method DELETE `
                    -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)"
                Write-Output "[CLEANUP]   Account deleted: $($guest.Id)"
            }

            $cleanedCount++
        }
        catch {
            Write-Output "[ERROR] Failed to cleanup $($guest.DisplayName): $_"
            $errorCount++
        }

        # Throttle between users
        Start-Sleep -Milliseconds 200
    }

    Write-Output "[CLEANUP] Completed: $cleanedCount cleaned, $errorCount errors"
}
#endregion

#region --- Summary ---
Write-Output ""
Write-Output "============================================================"
Write-Output "EXECUTION SUMMARY"
Write-Output "============================================================"
Write-Output "Disabled guests with stamp : $($allDisabledGuests.Count)"
Write-Output "Notified (day $NotificationDays-$GracePeriodDays)     : $($toNotify.Count)"
Write-Output "Cleaned up (day $GracePeriodDays+)     : $($toCleanup.Count)"
Write-Output "Delete mode                : $DeleteAccount"
Write-Output "WhatIf mode                : $WhatIf"
Write-Output "============================================================"

Disconnect-MgGraph
Write-Output "[DONE] Runbook execution complete."
#endregion
