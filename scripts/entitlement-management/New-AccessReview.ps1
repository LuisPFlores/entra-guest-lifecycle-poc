<#
.SYNOPSIS
    Creates a standalone recurring Access Review for guest users.

.DESCRIPTION
    Configures a quarterly access review targeting guest users in the
    SG-Guests-Active group. Sponsors are assigned as reviewers.

    This complements the access review built into the Access Package assignment
    policy and provides an additional review for guests who may have been
    onboarded outside Entitlement Management.

.PARAMETER GroupDisplayName
    The group to review. Default: "SG-Guests-Active"

.PARAMETER ReviewDisplayName
    Display name for the access review. Default: "Quarterly Guest Access Review"

.PARAMETER RecurrenceMonths
    Review recurrence in months. Default: 3 (quarterly)

.PARAMETER DurationDays
    Days reviewers have to complete the review. Default: 14

.PARAMETER AutoApplyEnabled
    Whether denied users are automatically removed. Default: $true

.NOTES
    Required Graph API Permissions:
    - AccessReview.ReadWrite.All
    - Group.Read.All

    Required License: Entra ID Governance (P2)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$GroupDisplayName = "SG-Guests-Active",

    [Parameter()]
    [string]$ReviewDisplayName = "Quarterly Guest Access Review",

    [Parameter()]
    [int]$RecurrenceMonths = 3,

    [Parameter()]
    [int]$DurationDays = 14,

    [Parameter()]
    [bool]$AutoApplyEnabled = $true,

    [Parameter()]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

#region --- Authentication ---
try {
    Write-Output "[AUTH] Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "AccessReview.ReadWrite.All","Group.Read.All" -NoWelcome
    Write-Output "[AUTH] Connected successfully"
}
catch {
    Write-Error "[AUTH] Failed to connect: $_"
    throw
}
#endregion

#region --- Resolve Target Group ---
Write-Output "[GROUP] Resolving group '$GroupDisplayName'..."

$group = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'" | Select-Object -First 1

if (-not $group) {
    Write-Error "[GROUP] Group '$GroupDisplayName' not found. Run New-GuestAccessPackage.ps1 first."
    throw "Target group not found"
}

Write-Output "[GROUP] Found group: $($group.Id)"
#endregion

#region --- Create Access Review Definition ---
Write-Output "[REVIEW] Creating access review definition..."

$reviewBody = @{
    displayName                    = $ReviewDisplayName
    descriptionForAdmins           = "Quarterly review of guest users to ensure continued business need. Sponsors review their guests."
    descriptionForReviewers        = "Please review the guest users you sponsor. Deny access for guests who no longer have a business need."
    scope = @{
        "@odata.type"              = "#microsoft.graph.accessReviewQueryScope"
        query                      = "/groups/$($group.Id)/members/microsoft.graph.user/?`$filter=userType eq 'Guest'"
        queryType                  = "MicrosoftGraph"
        queryRoot                  = $null
    }
    reviewers = @(
        @{
            query                  = "./sponsors"
            queryType              = "MicrosoftGraph"
            queryRoot              = "decisions"
        }
    )
    fallbackReviewers = @(
        @{
            query                  = "/groups/$($group.Id)/owners"
            queryType              = "MicrosoftGraph"
            queryRoot              = $null
        }
    )
    settings = @{
        mailNotificationsEnabled   = $true
        reminderNotificationsEnabled = $true
        justificationRequiredOnApproval = $true
        defaultDecisionEnabled     = $true
        defaultDecision            = "Deny"
        instanceDurationInDays     = $DurationDays
        autoApplyDecisionsEnabled  = $AutoApplyEnabled
        recommendationsEnabled     = $true
        recommendationInsightSettings = @(
            @{
                "@odata.type"      = "#microsoft.graph.userLastSignInRecommendationInsightSetting"
                recommendationLookBackDuration = "P30D"
                signInScope        = "tenant"
            }
        )
        recurrence = @{
            pattern = @{
                type               = "absoluteMonthly"
                interval           = $RecurrenceMonths
            }
            range = @{
                type               = "noEnd"
                startDate          = (Get-Date).AddDays(7).ToString("yyyy-MM-dd")
            }
        }
        decisionHistoriesForReviewersEnabled = $true
    }
    stageSettings = @()
} | ConvertTo-Json -Depth 10

if ($WhatIf) {
    Write-Output "[WHATIF] Would create access review:"
    Write-Output "  Name       : $ReviewDisplayName"
    Write-Output "  Target     : Guests in $GroupDisplayName"
    Write-Output "  Reviewers  : User sponsors (fallback: group owners)"
    Write-Output "  Recurrence : Every $RecurrenceMonths months"
    Write-Output "  Duration   : $DurationDays days"
    Write-Output "  Auto-apply : $AutoApplyEnabled"
    Write-Output "  Default    : Deny (if no response)"
}
else {
    try {
        $review = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/accessReviews/definitions" `
            -Body $reviewBody -ContentType 'application/json'
        Write-Output "[REVIEW] Created access review: $($review.id)"
    }
    catch {
        Write-Error "[REVIEW] Failed to create access review: $_"
        throw
    }
}
#endregion

#region --- Summary ---
Write-Output ""
Write-Output "============================================================"
Write-Output "ACCESS REVIEW CONFIGURATION"
Write-Output "============================================================"
Write-Output "Review Name    : $ReviewDisplayName"
Write-Output "Target Group   : $GroupDisplayName"
Write-Output "Reviewers      : Guest sponsors (fallback: group owners)"
Write-Output "Recurrence     : Every $RecurrenceMonths months"
Write-Output "Duration       : $DurationDays days per review cycle"
Write-Output "Default Action : Deny (auto-remove if no response)"
Write-Output "Recommendations: Based on last 30-day sign-in activity"
Write-Output "============================================================"
Write-Output ""
Write-Output "Notes:"
Write-Output "  - Guests without sponsors will be reviewed by group owners"
Write-Output "  - Denied guests are auto-removed from $GroupDisplayName"
Write-Output "  - Review starts in 7 days, then repeats quarterly"
Write-Output "============================================================"

Disconnect-MgGraph
Write-Output "[DONE] Access review setup complete."
#endregion
