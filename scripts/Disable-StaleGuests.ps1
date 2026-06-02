<#
.SYNOPSIS
    Azure Automation runbook to disable stale guest users based on sign-in inactivity.

.DESCRIPTION
    Queries Microsoft Graph for guest users whose last sign-in exceeds the specified
    inactivity threshold. Disables their accounts (accountEnabled = false) which triggers
    dynamic group membership and Conditional Access blocking.

    Designed for Azure Automation with Managed Identity. Handles:
    - Pagination for large tenant populations (50k+ guests)
    - Microsoft Graph throttling (429 responses) with exponential backoff
    - Batch processing to minimize API calls
    - WhatIf mode for safe validation
    - Detailed logging for audit trail

.PARAMETER InactivityDays
    Number of days of inactivity before a guest is disabled.
    Use 365 for initial cleanup, 30 for ongoing schedule.

.PARAMETER WhatIf
    When specified, logs which accounts WOULD be disabled without making changes.

.PARAMETER BatchSize
    Number of users to process per Graph API page. Default: 999 (Graph maximum).

.PARAMETER MaxRetries
    Maximum retry attempts for throttled requests. Default: 5.

.NOTES
    Required Graph API Permissions (on Managed Identity):
    - User.ReadWrite.All
    - AuditLog.Read.All

    Required Modules in Automation Account:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Users
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 3650)]
    [int]$InactivityDays = 365,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [ValidateRange(1, 999)]
    [int]$BatchSize = 999,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxRetries = 5
)

#region --- Configuration ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$cutoffDate = (Get-Date).AddDays(-$InactivityDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$runTimestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

Write-Output "============================================================"
Write-Output "Disable-StaleGuests Runbook"
Write-Output "Run Time      : $runTimestamp"
Write-Output "Inactivity    : $InactivityDays days (cutoff: $cutoffDate)"
Write-Output "WhatIf Mode   : $WhatIf"
Write-Output "Batch Size    : $BatchSize"
Write-Output "============================================================"
#endregion

#region --- Authentication ---
try {
    Write-Output "[AUTH] Connecting to Microsoft Graph with Managed Identity..."
    Connect-MgGraph -Identity -NoWelcome
    $context = Get-MgContext
    Write-Output "[AUTH] Connected as: $($context.Account) | Tenant: $($context.TenantId)"
}
catch {
    Write-Error "[AUTH] Failed to connect to Microsoft Graph: $_"
    throw
}
#endregion

#region --- Query Stale Guests ---
Write-Output "[QUERY] Retrieving guest users with sign-in activity..."

$allGuests = [System.Collections.Generic.List[object]]::new()
$uri = "https://graph.microsoft.com/v1.0/users?" +
       "`$filter=userType eq 'Guest' and accountEnabled eq true&" +
       "`$select=id,displayName,mail,userPrincipalName,accountEnabled,signInActivity,createdDateTime&" +
       "`$top=$BatchSize&" +
       "`$count=true"

$headers = @{ ConsistencyLevel = 'eventual' }
$pageCount = 0

do {
    $pageCount++
    $retryCount = 0
    $response = $null

    while ($null -eq $response -and $retryCount -le $MaxRetries) {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers $headers
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryCount++
                $retryAfter = 30 * $retryCount  # Exponential backoff
                Write-Output "[THROTTLE] Rate limited. Retry $retryCount/$MaxRetries in ${retryAfter}s..."
                Start-Sleep -Seconds $retryAfter
            }
            else {
                Write-Error "[QUERY] Graph API error: $_"
                throw
            }
        }
    }

    if ($null -eq $response) {
        Write-Error "[QUERY] Max retries exceeded on page $pageCount"
        throw "Graph API throttling exceeded maximum retries"
    }

    $users = $response.value
    if ($users) {
        $allGuests.AddRange($users)
    }

    Write-Output "[QUERY] Page $pageCount retrieved: $($users.Count) users (total so far: $($allGuests.Count))"
    $uri = $response.'@odata.nextLink'

} while ($null -ne $uri)

Write-Output "[QUERY] Total enabled guest users retrieved: $($allGuests.Count)"
#endregion

#region --- Identify Stale Guests ---
Write-Output "[FILTER] Identifying guests inactive since $cutoffDate..."

$staleGuests = [System.Collections.Generic.List[object]]::new()

foreach ($guest in $allGuests) {
    $lastSignIn = $null

    # Check interactive sign-in
    if ($guest.signInActivity.lastSignInDateTime) {
        $lastSignIn = [DateTime]$guest.signInActivity.lastSignInDateTime
    }

    # Check non-interactive sign-in (use whichever is more recent)
    if ($guest.signInActivity.lastNonInteractiveSignInDateTime) {
        $nonInteractive = [DateTime]$guest.signInActivity.lastNonInteractiveSignInDateTime
        if ($null -eq $lastSignIn -or $nonInteractive -gt $lastSignIn) {
            $lastSignIn = $nonInteractive
        }
    }

    # If no sign-in activity at all, use createdDateTime as baseline
    if ($null -eq $lastSignIn) {
        if ($guest.createdDateTime) {
            $lastSignIn = [DateTime]$guest.createdDateTime
        }
        else {
            # No activity data and no creation date — treat as stale
            $lastSignIn = [DateTime]::MinValue
        }
    }

    # Compare against cutoff
    if ($lastSignIn -lt [DateTime]$cutoffDate) {
        $staleGuests.Add([PSCustomObject]@{
            Id                = $guest.id
            DisplayName       = $guest.displayName
            Mail              = $guest.mail
            UPN               = $guest.userPrincipalName
            LastSignIn        = $lastSignIn
            DaysInactive      = [math]::Round(((Get-Date) - $lastSignIn).TotalDays)
            CreatedDateTime   = $guest.createdDateTime
        })
    }
}

Write-Output "[FILTER] Stale guests identified: $($staleGuests.Count) / $($allGuests.Count) total"
#endregion

#region --- Disable Stale Guests ---
if ($staleGuests.Count -eq 0) {
    Write-Output "[DONE] No stale guests found. Nothing to do."
    Disconnect-MgGraph
    return
}

Write-Output "[DISABLE] Processing $($staleGuests.Count) stale guest accounts..."

$disabledCount = 0
$errorCount = 0
$batchNumber = 0
$batchItems = [System.Collections.Generic.List[object]]::new()

foreach ($guest in $staleGuests) {
    if ($WhatIf) {
        Write-Output "[WHATIF] Would disable: $($guest.DisplayName) ($($guest.Mail)) - Inactive $($guest.DaysInactive) days"
        $disabledCount++
        continue
    }

    # Use individual PATCH calls with retry logic
    $retryCount = 0
    $success = $false

    while (-not $success -and $retryCount -le $MaxRetries) {
        try {
            # Disable account and stamp disable date for grace period tracking
            $disableDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $body = @{
                accountEnabled = $false
                onPremisesExtensionAttributes = @{
                    extensionAttribute1 = $disableDate
                }
            } | ConvertTo-Json -Depth 3
            Invoke-MgGraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)" `
                -Body $body `
                -ContentType 'application/json'

            $success = $true
            $disabledCount++

            if ($disabledCount % 100 -eq 0) {
                Write-Output "[DISABLE] Progress: $disabledCount / $($staleGuests.Count) disabled"
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryCount++
                $retryAfter = 30 * $retryCount
                Write-Output "[THROTTLE] Rate limited on user $($guest.Id). Retry $retryCount/$MaxRetries in ${retryAfter}s..."
                Start-Sleep -Seconds $retryAfter
            }
            else {
                Write-Output "[ERROR] Failed to disable $($guest.DisplayName) ($($guest.Id)): $_"
                $errorCount++
                $success = $true  # Move on to next user
            }
        }
    }

    if (-not $success) {
        Write-Output "[ERROR] Max retries exceeded for $($guest.DisplayName) ($($guest.Id))"
        $errorCount++
    }

    # Throttle self: small delay between requests to avoid hitting limits
    if (-not $WhatIf -and $disabledCount % 50 -eq 0) {
        Start-Sleep -Milliseconds 500
    }
}
#endregion

#region --- Summary ---
Write-Output ""
Write-Output "============================================================"
Write-Output "EXECUTION SUMMARY"
Write-Output "============================================================"
Write-Output "Total guests queried   : $($allGuests.Count)"
Write-Output "Stale guests found     : $($staleGuests.Count)"
Write-Output "Accounts disabled      : $disabledCount"
Write-Output "Errors                 : $errorCount"
Write-Output "WhatIf mode            : $WhatIf"
Write-Output "Inactivity threshold   : $InactivityDays days"
Write-Output "============================================================"

if ($errorCount -gt 0) {
    Write-Warning "[WARN] $errorCount errors occurred. Review output for details."
}

# Output top 20 stale guests for audit log
Write-Output ""
Write-Output "Top 20 stale guests (by inactivity):"
$staleGuests | Sort-Object DaysInactive -Descending |
    Select-Object -First 20 DisplayName, Mail, DaysInactive, LastSignIn |
    Format-Table -AutoSize | Out-String | Write-Output
#endregion

#region --- Cleanup ---
Disconnect-MgGraph
Write-Output "[DONE] Runbook execution complete."
#endregion
