<#
.SYNOPSIS
    End-to-end validation script for the Guest Lifecycle POC.

.DESCRIPTION
    Tests the full lifecycle flow:
    1. Creates a test guest user
    2. Verifies initial state (enabled, not in dynamic group)
    3. Disables the guest (simulating runbook action)
    4. Verifies dynamic group membership (with polling)
    5. Verifies CA policy applies (report-only check)
    6. Re-enables the guest (simulating admin reprovisioning)
    7. Verifies removal from dynamic group
    8. Optionally cleans up the test guest

.PARAMETER TestGuestEmail
    Email address for the test guest invitation. Must be a valid external email.

.PARAMETER TestGuestDisplayName
    Display name for the test guest. Default: "POC-Test-Guest-Lifecycle"

.PARAMETER GroupName
    Name of the dynamic group to validate. Default: "SG-Guests-Disabled-Stale"

.PARAMETER SkipCleanup
    When specified, leaves the test guest in the tenant for manual inspection.

.PARAMETER DynamicGroupWaitMinutes
    Maximum minutes to wait for dynamic group membership to update. Default: 35.

.NOTES
    Required Graph API Permissions:
    - User.ReadWrite.All
    - Group.Read.All
    - Policy.Read.All

    Run interactively (not in Automation) for real-time validation output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@]+@[^@]+\.[^@]+$')]
    [string]$TestGuestEmail,

    [Parameter()]
    [string]$TestGuestDisplayName = "POC-Test-Guest-Lifecycle",

    [Parameter()]
    [string]$GroupName = "SG-Guests-Disabled-Stale",

    [Parameter()]
    [switch]$SkipCleanup,

    [Parameter()]
    [int]$DynamicGroupWaitMinutes = 35
)

$ErrorActionPreference = 'Stop'

#region --- Helper Functions ---
function Write-TestResult {
    param([string]$TestName, [bool]$Passed, [string]$Detail = "")
    $icon = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host "$icon $TestName" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

function Wait-ForGroupMembership {
    param(
        [string]$GroupId,
        [string]$UserId,
        [bool]$ExpectMember,
        [int]$MaxWaitMinutes
    )

    $expectation = if ($ExpectMember) { "member" } else { "not a member" }
    Write-Host "[WAIT] Polling dynamic group membership (expecting: $expectation)..." -ForegroundColor Cyan
    Write-Host "       This may take up to $MaxWaitMinutes minutes for dynamic group processing." -ForegroundColor Gray

    $endTime = (Get-Date).AddMinutes($MaxWaitMinutes)
    $pollInterval = 30  # seconds

    while ((Get-Date) -lt $endTime) {
        $members = Get-MgGroupMember -GroupId $GroupId -All
        $isMember = $members.Id -contains $UserId

        if ($isMember -eq $ExpectMember) {
            Write-Host "[WAIT] Condition met after $([math]::Round(($MaxWaitMinutes * 60 - ($endTime - (Get-Date)).TotalSeconds) / 60, 1)) minutes." -ForegroundColor Green
            return $true
        }

        $remaining = [math]::Round(($endTime - (Get-Date)).TotalMinutes, 1)
        Write-Host "       Still waiting... ($remaining min remaining)" -ForegroundColor Gray
        Start-Sleep -Seconds $pollInterval
    }

    Write-Host "[WAIT] Timeout reached. Condition not met." -ForegroundColor Yellow
    return $false
}
#endregion

#region --- Setup ---
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Guest Lifecycle POC — End-to-End Validation" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Test Guest    : $TestGuestEmail"
Write-Host "Dynamic Group : $GroupName"
Write-Host "Cleanup       : $(if ($SkipCleanup) {'Skipped'} else {'Will remove test guest'})"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Connect
Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.Read.All", "Policy.Read.All" -NoWelcome
$context = Get-MgContext
Write-Host "[AUTH] Connected | Tenant: $($context.TenantId)" -ForegroundColor Green
Write-Host ""

# Resolve group
$group = Get-MgGroup -Filter "displayName eq '$GroupName'"
if (-not $group) {
    Write-Error "Dynamic group '$GroupName' not found. Run New-DynamicGroup.ps1 first."
    throw
}
$groupId = $group.Id
Write-Host "[SETUP] Dynamic group resolved: $groupId" -ForegroundColor Green

$testResults = @()
#endregion

#region --- Test 1: Create Test Guest ---
Write-Host ""
Write-Host "--- Test 1: Create Test Guest User ---" -ForegroundColor Yellow

try {
    # Check if test guest already exists
    $existing = Get-MgUser -Filter "mail eq '$TestGuestEmail' and userType eq 'Guest'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[INFO] Test guest already exists. Removing and recreating..." -ForegroundColor Yellow
        Remove-MgUser -UserId $existing.Id
        Start-Sleep -Seconds 5
    }

    # Invite guest
    $invitation = New-MgInvitation -InvitedUserEmailAddress $TestGuestEmail `
        -InvitedUserDisplayName $TestGuestDisplayName `
        -InviteRedirectUrl "https://myapps.microsoft.com" `
        -SendInvitationMessage:$false

    $testUserId = $invitation.InvitedUser.Id
    Write-TestResult "Guest created" $true "ID: $testUserId"
    $testResults += @{ Test = "Create Guest"; Passed = $true }
}
catch {
    Write-TestResult "Guest created" $false "$_"
    $testResults += @{ Test = "Create Guest"; Passed = $false }
    throw "Cannot continue without test guest"
}
#endregion

#region --- Test 2: Verify Initial State ---
Write-Host ""
Write-Host "--- Test 2: Verify Initial State (Enabled, Not in Group) ---" -ForegroundColor Yellow

Start-Sleep -Seconds 3
$user = Get-MgUser -UserId $testUserId -Property "accountEnabled,userType,displayName"

$enabledCheck = $user.AccountEnabled -eq $true
Write-TestResult "Account is enabled" $enabledCheck "accountEnabled = $($user.AccountEnabled)"
$testResults += @{ Test = "Initial State - Enabled"; Passed = $enabledCheck }

# Check not in group (may take time, just check once)
$members = Get-MgGroupMember -GroupId $groupId -All
$notInGroup = $members.Id -notcontains $testUserId
Write-TestResult "Not in dynamic group (initial)" $notInGroup
$testResults += @{ Test = "Initial State - Not in Group"; Passed = $notInGroup }
#endregion

#region --- Test 3: Disable Guest ---
Write-Host ""
Write-Host "--- Test 3: Disable Guest Account ---" -ForegroundColor Yellow

try {
    Update-MgUser -UserId $testUserId -AccountEnabled:$false
    Start-Sleep -Seconds 3
    $user = Get-MgUser -UserId $testUserId -Property "accountEnabled"
    $disabledCheck = $user.AccountEnabled -eq $false
    Write-TestResult "Account disabled successfully" $disabledCheck "accountEnabled = $($user.AccountEnabled)"
    $testResults += @{ Test = "Disable Account"; Passed = $disabledCheck }
}
catch {
    Write-TestResult "Account disabled" $false "$_"
    $testResults += @{ Test = "Disable Account"; Passed = $false }
}
#endregion

#region --- Test 4: Verify Dynamic Group Addition ---
Write-Host ""
Write-Host "--- Test 4: Verify Added to Dynamic Group ---" -ForegroundColor Yellow

$addedToGroup = Wait-ForGroupMembership -GroupId $groupId -UserId $testUserId `
    -ExpectMember $true -MaxWaitMinutes $DynamicGroupWaitMinutes

Write-TestResult "Added to dynamic group after disable" $addedToGroup
$testResults += @{ Test = "Dynamic Group Addition"; Passed = $addedToGroup }
#endregion

#region --- Test 5: Verify CA Policy Scope ---
Write-Host ""
Write-Host "--- Test 5: Verify CA Policy Targets Group ---" -ForegroundColor Yellow

try {
    $policies = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"

    $blockPolicy = $policies.value | Where-Object {
        $_.conditions.users.includeGroups -contains $groupId -and
        $_.grantControls.builtInControls -contains "block"
    }

    $caPolicyExists = $null -ne $blockPolicy
    $caState = if ($blockPolicy) { $blockPolicy.state } else { "NOT FOUND" }
    Write-TestResult "CA block policy targets dynamic group" $caPolicyExists "State: $caState"
    $testResults += @{ Test = "CA Policy Configured"; Passed = $caPolicyExists }
}
catch {
    Write-TestResult "CA policy check" $false "$_"
    $testResults += @{ Test = "CA Policy Configured"; Passed = $false }
}
#endregion

#region --- Test 6: Re-enable Guest (Reprovisioning) ---
Write-Host ""
Write-Host "--- Test 6: Re-enable Guest (Simulate Reprovisioning) ---" -ForegroundColor Yellow

try {
    Update-MgUser -UserId $testUserId -AccountEnabled:$true
    Start-Sleep -Seconds 3
    $user = Get-MgUser -UserId $testUserId -Property "accountEnabled"
    $reenabledCheck = $user.AccountEnabled -eq $true
    Write-TestResult "Account re-enabled" $reenabledCheck "accountEnabled = $($user.AccountEnabled)"
    $testResults += @{ Test = "Re-enable Account"; Passed = $reenabledCheck }
}
catch {
    Write-TestResult "Account re-enabled" $false "$_"
    $testResults += @{ Test = "Re-enable Account"; Passed = $false }
}
#endregion

#region --- Test 7: Verify Dynamic Group Removal ---
Write-Host ""
Write-Host "--- Test 7: Verify Removed from Dynamic Group ---" -ForegroundColor Yellow

$removedFromGroup = Wait-ForGroupMembership -GroupId $groupId -UserId $testUserId `
    -ExpectMember $false -MaxWaitMinutes $DynamicGroupWaitMinutes

Write-TestResult "Removed from dynamic group after re-enable" $removedFromGroup
$testResults += @{ Test = "Dynamic Group Removal"; Passed = $removedFromGroup }
#endregion

#region --- Cleanup ---
if (-not $SkipCleanup) {
    Write-Host ""
    Write-Host "--- Cleanup: Removing Test Guest ---" -ForegroundColor Yellow
    try {
        Remove-MgUser -UserId $testUserId
        Write-TestResult "Test guest removed" $true
    }
    catch {
        Write-TestResult "Test guest removal" $false "$_"
    }
}
else {
    Write-Host ""
    Write-Host "[SKIP] Cleanup skipped. Test guest remains: $testUserId" -ForegroundColor Yellow
}
#endregion

#region --- Summary ---
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$passed = ($testResults | Where-Object { $_.Passed }).Count
$failed = ($testResults | Where-Object { -not $_.Passed }).Count
$total = $testResults.Count

foreach ($result in $testResults) {
    $icon = if ($result.Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($result.Passed) { "Green" } else { "Red" }
    Write-Host "  $icon $($result.Test)" -ForegroundColor $color
}

Write-Host ""
Write-Host "Results: $passed passed, $failed failed, $total total" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor Cyan
#endregion

Disconnect-MgGraph
Write-Host "[DONE] Validation complete." -ForegroundColor Green
