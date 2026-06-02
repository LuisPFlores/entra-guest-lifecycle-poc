<#
.SYNOPSIS
    Reactivates a disabled guest account at sponsor request.

.DESCRIPTION
    Sponsor-initiated reactivation workflow for guests within the 60-day grace period.
    - Re-enables the guest account
    - Clears the disable date stamp (extensionAttribute1)
    - Optionally restores access package assignment
    - Logs the reactivation for audit

    This script can be triggered manually by an admin or exposed through
    a Power Automate flow / Logic App for self-service sponsor reactivation.

.PARAMETER GuestUserId
    Object ID of the guest user to reactivate.

.PARAMETER SponsorId
    Object ID of the sponsor requesting reactivation (for audit).

.PARAMETER RestoreAccessPackage
    If specified, re-requests the access package assignment.

.PARAMETER AccessPackageId
    ID of the access package to restore. Required if RestoreAccessPackage is set.

.PARAMETER Justification
    Business justification for reactivation.

.NOTES
    Required Graph API Permissions:
    - User.ReadWrite.All
    - EntitlementManagement.ReadWrite.All (if restoring access package)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GuestUserId,

    [Parameter(Mandatory = $true)]
    [string]$SponsorId,

    [Parameter()]
    [switch]$RestoreAccessPackage,

    [Parameter()]
    [string]$AccessPackageId,

    [Parameter(Mandatory = $true)]
    [string]$Justification
)

$ErrorActionPreference = 'Stop'

#region --- Authentication ---
try {
    Write-Output "[AUTH] Connecting to Microsoft Graph..."
    Connect-MgGraph -Identity -NoWelcome
    Write-Output "[AUTH] Connected successfully"
}
catch {
    Write-Error "[AUTH] Failed to connect: $_"
    throw
}
#endregion

#region --- Validate Guest ---
Write-Output "[VALIDATE] Checking guest user $GuestUserId..."

$guest = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/users/$GuestUserId`?`$select=id,displayName,mail,accountEnabled,userType,onPremisesExtensionAttributes"

if ($guest.userType -ne 'Guest') {
    Write-Error "[VALIDATE] User $GuestUserId is not a guest account"
    throw "Not a guest account"
}

if ($guest.accountEnabled -eq $true) {
    Write-Output "[VALIDATE] Guest is already enabled. No action needed."
    Disconnect-MgGraph
    return
}

$disableDateStr = $guest.onPremisesExtensionAttributes.extensionAttribute1
if (-not $disableDateStr) {
    Write-Warning "[VALIDATE] No disable date stamp found. Guest may have been disabled manually."
}
else {
    $disableDate = [DateTime]$disableDateStr
    $daysDisabled = [math]::Round(((Get-Date) - $disableDate).TotalDays)
    Write-Output "[VALIDATE] Guest was disabled on $disableDateStr ($daysDisabled days ago)"

    if ($daysDisabled -gt 60) {
        Write-Warning "[VALIDATE] Guest has exceeded the 60-day grace period. Reactivation may require additional approval."
    }
}
#endregion

#region --- Reactivate Account ---
Write-Output "[REACTIVATE] Re-enabling guest account..."

$body = @{
    accountEnabled = $true
    onPremisesExtensionAttributes = @{
        extensionAttribute1 = $null  # Clear disable date stamp
    }
} | ConvertTo-Json -Depth 3

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/users/$GuestUserId" `
    -Body $body -ContentType 'application/json'

Write-Output "[REACTIVATE] Account re-enabled successfully"
#endregion

#region --- Restore Access Package (Optional) ---
if ($RestoreAccessPackage -and $AccessPackageId) {
    Write-Output "[ACCESS] Requesting access package assignment..."

    $assignmentBody = @{
        requestType = "AdminAdd"
        accessPackageAssignment = @{
            targetId = $GuestUserId
            assignmentPolicyId = $null  # Uses default policy
            accessPackageId = $AccessPackageId
        }
        justification = "Sponsor reactivation: $Justification"
    } | ConvertTo-Json -Depth 5

    try {
        $request = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentRequests" `
            -Body $assignmentBody -ContentType 'application/json'
        Write-Output "[ACCESS] Access package assignment requested: $($request.id)"
    }
    catch {
        Write-Warning "[ACCESS] Failed to restore access package: $_"
        Write-Output "[ACCESS] Guest is re-enabled but may need manual access package assignment"
    }
}
#endregion

#region --- Audit Log ---
Write-Output ""
Write-Output "============================================================"
Write-Output "REACTIVATION COMPLETE"
Write-Output "============================================================"
Write-Output "Guest          : $($guest.displayName) ($($guest.mail))"
Write-Output "Guest ID       : $GuestUserId"
Write-Output "Sponsor        : $SponsorId"
Write-Output "Justification  : $Justification"
Write-Output "Access Package : $(if ($RestoreAccessPackage) { 'Restored' } else { 'Not requested' })"
Write-Output "Timestamp      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Write-Output "============================================================"

Disconnect-MgGraph
Write-Output "[DONE] Reactivation complete."
#endregion
