<#
.SYNOPSIS
    Creates a Conditional Access policy to block access for disabled stale guest users.

.DESCRIPTION
    Creates a CA policy in Report-Only mode that blocks access for all members of the
    "SG-Guests-Disabled-Stale" dynamic security group.

    The policy targets all cloud applications. When a guest's accountEnabled is set to
    false, they are automatically added to the dynamic group and blocked by this policy.

    Deploys in REPORT-ONLY mode for safe validation. Switch to Enabled after testing.

.PARAMETER GroupId
    Object ID of the SG-Guests-Disabled-Stale dynamic group.
    If not provided, the script will look up the group by name.

.PARAMETER PolicyName
    Display name for the CA policy. Default: "Block Stale Guest Access"

.PARAMETER State
    Initial policy state. Default: "enabledForReportingButNotEnforced" (Report-Only).
    Options: enabled, disabled, enabledForReportingButNotEnforced

.NOTES
    Required Graph API Permissions:
    - Policy.ReadWrite.ConditionalAccess
    - Group.Read.All

    Required Modules:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Identity.SignIns
    - Microsoft.Graph.Groups
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$GroupId,

    [Parameter()]
    [string]$PolicyName = "Block Stale Guest Access",

    [Parameter()]
    [ValidateSet("enabled", "disabled", "enabledForReportingButNotEnforced")]
    [string]$State = "enabledForReportingButNotEnforced",

    [Parameter()]
    [string]$GroupName = "SG-Guests-Disabled-Stale"
)

$ErrorActionPreference = 'Stop'

#region --- Authentication ---
Write-Host "[AUTH] Connecting to Microsoft Graph..." -ForegroundColor Cyan

$automationConnection = $null
try {
    $automationConnection = Get-AutomationVariable -Name 'RunningInAutomation' -ErrorAction SilentlyContinue
}
catch { }

if ($automationConnection) {
    Connect-MgGraph -Identity -NoWelcome
}
else {
    Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess", "Group.Read.All" -NoWelcome
}

$context = Get-MgContext
Write-Host "[AUTH] Connected | Tenant: $($context.TenantId)" -ForegroundColor Green
#endregion

#region --- Resolve Group ID ---
if (-not $GroupId) {
    Write-Host "[LOOKUP] Resolving group '$GroupName'..." -ForegroundColor Cyan
    $group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

    if (-not $group) {
        Write-Error "[ERROR] Group '$GroupName' not found. Run New-DynamicGroup.ps1 first."
        Disconnect-MgGraph
        throw "Dynamic group not found"
    }

    $GroupId = $group.Id
    Write-Host "[LOOKUP] Found group: $GroupId" -ForegroundColor Green
}
#endregion

#region --- Check Existing Policy ---
Write-Host "[CHECK] Verifying CA policy does not already exist..." -ForegroundColor Cyan

$existingPolicies = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"

$existingPolicy = $existingPolicies.value | Where-Object { $_.displayName -eq $PolicyName }

if ($existingPolicy) {
    Write-Host "[EXISTS] CA policy '$PolicyName' already exists." -ForegroundColor Yellow
    Write-Host "         Policy ID : $($existingPolicy.id)"
    Write-Host "         State     : $($existingPolicy.state)"
    Write-Host ""
    Write-Host "No changes made. Delete the existing policy to recreate." -ForegroundColor Yellow
    Disconnect-MgGraph
    return
}
#endregion

#region --- Create Conditional Access Policy ---
Write-Host "[CREATE] Creating CA policy '$PolicyName' in $State mode..." -ForegroundColor Cyan

$policyBody = @{
    displayName = $PolicyName
    state       = $State
    conditions  = @{
        users = @{
            includeGroups = @($GroupId)
        }
        applications = @{
            includeApplications = @("All")
        }
        clientAppTypes = @("all")
    }
    grantControls = @{
        operator        = "OR"
        builtInControls = @("block")
    }
} | ConvertTo-Json -Depth 10

$newPolicy = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" `
    -Body $policyBody `
    -ContentType 'application/json'

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Conditional Access Policy Created Successfully" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Display Name  : $($newPolicy.displayName)"
Write-Host "Policy ID     : $($newPolicy.id)"
Write-Host "State         : $($newPolicy.state)"
Write-Host "Target Group  : $GroupId ($GroupName)"
Write-Host "Applications  : All cloud apps"
Write-Host "Grant Control : Block"
Write-Host "============================================================" -ForegroundColor Green
#endregion

#region --- Next Steps ---
Write-Host ""
Write-Host "[NEXT STEPS]" -ForegroundColor Cyan
Write-Host ""

if ($State -eq "enabledForReportingButNotEnforced") {
    Write-Host "  1. The policy is in REPORT-ONLY mode." -ForegroundColor Yellow
    Write-Host "  2. Monitor the CA Insights workbook for 1-2 weeks."
    Write-Host "  3. Verify only disabled guests are affected."
    Write-Host "  4. Switch to ENABLED mode when ready:"
    Write-Host ""
    Write-Host "     # Enable the policy" -ForegroundColor Gray
    Write-Host "     `$body = @{ state = 'enabled' } | ConvertTo-Json" -ForegroundColor Gray
    Write-Host "     Invoke-MgGraphRequest -Method PATCH ``" -ForegroundColor Gray
    Write-Host "         -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($newPolicy.id)' ``" -ForegroundColor Gray
    Write-Host "         -Body `$body -ContentType 'application/json'" -ForegroundColor Gray
}
else {
    Write-Host "  Policy is ACTIVE. Disabled guests in the dynamic group are now blocked." -ForegroundColor Green
}

Write-Host ""
Write-Host "[IMPORTANT] Exclude break-glass/emergency accounts from this policy!" -ForegroundColor Red
Write-Host "            Add exclusion via Entra Portal > CA > $PolicyName > Users > Exclude" -ForegroundColor Red
#endregion

#region --- Cleanup ---
Disconnect-MgGraph
Write-Host ""
Write-Host "[DONE] Script complete." -ForegroundColor Green
#endregion
