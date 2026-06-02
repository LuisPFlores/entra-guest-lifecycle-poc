<#
.SYNOPSIS
    Creates an Entitlement Management Access Package for governed guest onboarding.

.DESCRIPTION
    Establishes the Entitlement Management infrastructure for guest lifecycle:
    - Access Package Catalog for external collaboration
    - Access Package with resource group (SG-Guests-Active)
    - Assignment Policy with Connected Organization sponsor approval
    - Annual renewal requirement (not inactivity-based — inactivity is handled by Disable-StaleGuests.ps1)

    This replaces ad-hoc B2B invitations with a governed onboarding process.

.PARAMETER CatalogDisplayName
    Display name for the access package catalog. Default: "External Collaboration"

.PARAMETER PackageDisplayName
    Display name for the access package. Default: "Guest Access - Standard"

.PARAMETER ResourceGroupName
    Name of the security group to use as the access package resource.
    Default: "SG-Guests-Active"

.PARAMETER ApprovalRequired
    Whether sponsor approval is required. Default: $true

.PARAMETER AccessReviewEnabled
    Whether to enable quarterly access reviews on the assignment policy. Default: $true

.PARAMETER WhatIf
    When specified, shows what would be created without making changes.

.NOTES
    Required Graph API Permissions:
    - EntitlementManagement.ReadWrite.All
    - Group.ReadWrite.All
    - Directory.ReadWrite.All

    Required License: Entra ID Governance (P2)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$CatalogDisplayName = "External Collaboration",

    [Parameter()]
    [string]$PackageDisplayName = "Guest Access - Standard",

    [Parameter()]
    [string]$ResourceGroupName = "SG-Guests-Active",

    [Parameter()]
    [switch]$ApprovalRequired = $true,

    [Parameter()]
    [switch]$AccessReviewEnabled = $true,

    [Parameter()]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

#region --- Authentication ---
try {
    Write-Output "[AUTH] Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All" -NoWelcome
    $context = Get-MgContext
    Write-Output "[AUTH] Connected as: $($context.Account) | Tenant: $($context.TenantId)"
}
catch {
    Write-Error "[AUTH] Failed to connect: $_"
    throw
}
#endregion

#region --- Create Resource Group ---
Write-Output "[GROUP] Checking for resource group '$ResourceGroupName'..."

$resourceGroup = Get-MgGroup -Filter "displayName eq '$ResourceGroupName'" -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $resourceGroup) {
    if ($WhatIf) {
        Write-Output "[WHATIF] Would create security group: $ResourceGroupName"
    }
    else {
        Write-Output "[GROUP] Creating security group: $ResourceGroupName"
        $resourceGroup = New-MgGroup -DisplayName $ResourceGroupName `
            -SecurityEnabled:$true `
            -MailEnabled:$false `
            -MailNickname ($ResourceGroupName -replace '[^a-zA-Z0-9]', '') `
            -Description "Active guest users managed through Entitlement Management" `
            -GroupTypes @()
        Write-Output "[GROUP] Created group: $($resourceGroup.Id)"
    }
}
else {
    Write-Output "[GROUP] Group already exists: $($resourceGroup.Id)"
}
#endregion

#region --- Create Access Package Catalog ---
Write-Output "[CATALOG] Checking for catalog '$CatalogDisplayName'..."

$catalog = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?`$filter=displayName eq '$CatalogDisplayName'" |
    Select-Object -ExpandProperty value | Select-Object -First 1

if (-not $catalog) {
    if ($WhatIf) {
        Write-Output "[WHATIF] Would create catalog: $CatalogDisplayName"
    }
    else {
        Write-Output "[CATALOG] Creating catalog: $CatalogDisplayName"
        $catalogBody = @{
            displayName  = $CatalogDisplayName
            description  = "Catalog for governed external/guest collaboration access packages"
            isExternallyVisible = $true
            state        = "published"
        } | ConvertTo-Json

        $catalog = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs" `
            -Body $catalogBody -ContentType 'application/json'
        Write-Output "[CATALOG] Created catalog: $($catalog.id)"
    }
}
else {
    Write-Output "[CATALOG] Catalog already exists: $($catalog.id)"
}
#endregion

#region --- Add Resource Group to Catalog ---
if (-not $WhatIf -and $catalog -and $resourceGroup) {
    Write-Output "[RESOURCE] Adding group to catalog as resource..."

    $resourceBody = @{
        catalogId    = $catalog.id
        requestType  = "AdminAdd"
        accessPackageResource = @{
            displayName  = $ResourceGroupName
            resourceType = "AadGroup"
            originId     = $resourceGroup.Id
            originSystem = "AadGroup"
        }
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/resourceRequests" `
            -Body $resourceBody -ContentType 'application/json' | Out-Null
        Write-Output "[RESOURCE] Group added to catalog successfully"
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            Write-Output "[RESOURCE] Group already exists in catalog"
        }
        else { throw }
    }
}
#endregion

#region --- Create Access Package ---
if (-not $WhatIf -and $catalog) {
    Write-Output "[PACKAGE] Creating access package '$PackageDisplayName'..."

    $existingPackage = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages?`$filter=displayName eq '$PackageDisplayName' and catalogId eq '$($catalog.id)'" |
        Select-Object -ExpandProperty value | Select-Object -First 1

    if ($existingPackage) {
        Write-Output "[PACKAGE] Access package already exists: $($existingPackage.id)"
        $accessPackage = $existingPackage
    }
    else {
        $packageBody = @{
            displayName = $PackageDisplayName
            description = "Standard guest access with sponsor approval and quarterly reviews. Managed lifecycle: 1-year inactivity disable, 60-day grace period."
            catalogId   = $catalog.id
            isHidden    = $false
        } | ConvertTo-Json

        $accessPackage = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages" `
            -Body $packageBody -ContentType 'application/json'
        Write-Output "[PACKAGE] Created access package: $($accessPackage.id)"
    }
}
elseif ($WhatIf) {
    Write-Output "[WHATIF] Would create access package: $PackageDisplayName"
}
#endregion

#region --- Create Assignment Policy ---
if (-not $WhatIf -and $accessPackage) {
    Write-Output "[POLICY] Creating assignment policy with sponsor approval..."

    $policyBody = @{
        displayName       = "Guest Access - Sponsor Approval Policy"
        description       = "Requires connected organization sponsor approval. Annual renewal. Quarterly access reviews."
        allowedTargetScope = "specificConnectedOrganizationUsers"
        specificAllowedTargets = @()
        expiration = @{
            type     = "noExpiration"  # Expiration handled by inactivity runbook, not time-based
        }
        requestorSettings = @{
            enableTargetsToSelfAddAccess     = $true
            enableTargetsToSelfUpdateAccess  = $true
            enableTargetsToSelfRemoveAccess  = $true
            allowCustomAssignmentSchedule    = $false
        }
        requestApprovalSettings = @{
            isApprovalRequiredForAdd     = $ApprovalRequired.IsPresent -or $ApprovalRequired
            isApprovalRequiredForUpdate  = $false
            stages = @(
                @{
                    durationBeforeAutomaticDenial   = "P14D"
                    isApproverJustificationRequired = $true
                    isEscalationEnabled             = $false
                    primaryApprovers = @(
                        @{
                            "@odata.type" = "#microsoft.graph.internalSponsors"
                        }
                    )
                }
            )
        }
        accessPackage = @{
            id = $accessPackage.id
        }
    }

    # Add access review settings if enabled
    if ($AccessReviewEnabled) {
        $policyBody["reviewSettings"] = @{
            isEnabled                       = $true
            expirationBehavior              = "keepAccess"
            isRecommendationEnabled         = $true
            isReviewerJustificationRequired = $true
            isSelfReview                    = $false
            schedule = @{
                startDateTime = (Get-Date).AddDays(90).ToString("yyyy-MM-ddT00:00:00Z")
                expiration = @{
                    type = "noExpiration"
                }
                recurrence = @{
                    pattern = @{
                        type     = "absoluteMonthly"
                        interval = 3  # Quarterly
                    }
                }
            }
            primaryReviewers = @(
                @{
                    "@odata.type" = "#microsoft.graph.internalSponsors"
                }
            )
        }
    }

    $policyJson = $policyBody | ConvertTo-Json -Depth 10

    try {
        $policy = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies" `
            -Body $policyJson -ContentType 'application/json'
        Write-Output "[POLICY] Created assignment policy: $($policy.id)"
    }
    catch {
        Write-Output "[POLICY] Error creating policy: $_"
        throw
    }
}
elseif ($WhatIf) {
    Write-Output "[WHATIF] Would create assignment policy with sponsor approval and quarterly reviews"
}
#endregion

#region --- Summary ---
Write-Output ""
Write-Output "============================================================"
Write-Output "ENTITLEMENT MANAGEMENT SETUP COMPLETE"
Write-Output "============================================================"
Write-Output "Catalog         : $CatalogDisplayName"
Write-Output "Access Package  : $PackageDisplayName"
Write-Output "Resource Group  : $ResourceGroupName"
Write-Output "Approval        : Connected Organization Internal Sponsors"
Write-Output "Access Reviews  : Quarterly (sponsors as reviewers)"
Write-Output "Expiration      : None (inactivity managed by Disable-StaleGuests.ps1)"
Write-Output "============================================================"
Write-Output ""
Write-Output "Next Steps:"
Write-Output "  1. Configure Connected Organizations in Entra ID"
Write-Output "  2. Set user-level sponsors on existing guest accounts"
Write-Output "  3. Share MyAccess portal URL with external users"
Write-Output "  4. Switch Disable-StaleGuests.ps1 to -InactivityDays 365"
Write-Output "============================================================"

Disconnect-MgGraph
Write-Output "[DONE] Setup complete."
#endregion
