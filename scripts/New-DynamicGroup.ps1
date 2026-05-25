<#
.SYNOPSIS
    Creates a dynamic security group for disabled guest users.

.DESCRIPTION
    Creates the dynamic security group "SG-Guests-Disabled-Stale" with a membership rule
    that automatically includes all guest users where accountEnabled = false.

    This group is used as the target for the Conditional Access block policy.
    When a guest is re-enabled, they are automatically removed from this group
    (within 5-30 minutes of the attribute change).

.PARAMETER GroupName
    Display name for the dynamic group. Default: "SG-Guests-Disabled-Stale"

.PARAMETER Description
    Description for the group. Default describes the POC purpose.

.NOTES
    Required Graph API Permissions:
    - Group.ReadWrite.All

    Required Modules:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Groups
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$GroupName = "SG-Guests-Disabled-Stale",

    [Parameter()]
    [string]$Description = "Dynamic group containing all disabled guest users. Used by CA policy to block stale guest access. Members are auto-managed based on accountEnabled status."
)

$ErrorActionPreference = 'Stop'

#region --- Authentication ---
Write-Host "[AUTH] Connecting to Microsoft Graph..." -ForegroundColor Cyan

# Detect if running in Azure Automation (Managed Identity) or interactive
$automationConnection = $null
try {
    $automationConnection = Get-AutomationVariable -Name 'RunningInAutomation' -ErrorAction SilentlyContinue
}
catch { }

if ($automationConnection) {
    Connect-MgGraph -Identity -NoWelcome
}
else {
    Connect-MgGraph -Scopes "Group.ReadWrite.All" -NoWelcome
}

$context = Get-MgContext
Write-Host "[AUTH] Connected | Tenant: $($context.TenantId)" -ForegroundColor Green
#endregion

#region --- Check Existing Group ---
Write-Host "[CHECK] Verifying group does not already exist..." -ForegroundColor Cyan

$existingGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

if ($existingGroup) {
    Write-Host "[EXISTS] Group '$GroupName' already exists." -ForegroundColor Yellow
    Write-Host "         Group ID   : $($existingGroup.Id)"
    Write-Host "         Rule       : $($existingGroup.MembershipRule)"
    Write-Host ""
    Write-Host "No changes made. Delete the existing group first if you need to recreate it." -ForegroundColor Yellow
    Disconnect-MgGraph
    return $existingGroup
}
#endregion

#region --- Create Dynamic Group ---
Write-Host "[CREATE] Creating dynamic security group '$GroupName'..." -ForegroundColor Cyan

$membershipRule = '(user.accountEnabled -eq false) and (user.userType -eq "Guest")'

$groupParams = @{
    DisplayName                = $GroupName
    Description                = $Description
    SecurityEnabled            = $true
    MailEnabled                = $false
    MailNickname               = ($GroupName -replace '[^a-zA-Z0-9]', '').ToLower()
    GroupTypes                 = @("DynamicMembership")
    MembershipRule             = $membershipRule
    MembershipRuleProcessingState = "On"
}

$newGroup = New-MgGroup -BodyParameter $groupParams

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Dynamic Security Group Created Successfully" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Display Name    : $($newGroup.DisplayName)"
Write-Host "Object ID       : $($newGroup.Id)"
Write-Host "Membership Rule : $membershipRule"
Write-Host "Processing State: On"
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Dynamic group membership will begin populating within 5-30 minutes." -ForegroundColor Cyan
Write-Host "[INFO] Use this Group ID for the Conditional Access policy:" -ForegroundColor Cyan
Write-Host "       $($newGroup.Id)" -ForegroundColor White
#endregion

#region --- Verify Rule Processing ---
Write-Host ""
Write-Host "[VERIFY] Checking membership rule processing status..." -ForegroundColor Cyan

Start-Sleep -Seconds 5
$verifyGroup = Get-MgGroup -GroupId $newGroup.Id -Property "membershipRule,membershipRuleProcessingState"

if ($verifyGroup.MembershipRuleProcessingState -eq "On") {
    Write-Host "[VERIFY] Rule processing is ACTIVE. Group will auto-populate." -ForegroundColor Green
}
else {
    Write-Warning "[VERIFY] Rule processing state is '$($verifyGroup.MembershipRuleProcessingState)'. Check group configuration."
}
#endregion

#region --- Cleanup ---
Disconnect-MgGraph
Write-Host "[DONE] Script complete." -ForegroundColor Green

return $newGroup
#endregion
