# Step-by-Step Deployment Guide

Complete walkthrough for deploying the Stale Guest Lifecycle POC from the Microsoft Entra and Azure admin portals, with corresponding PowerShell scripts.

---

## Scenario 1: Set Up Azure Automation Account

### Portal Steps

1. Go to **Azure Portal** → search **Automation Accounts** → **+ Create**
2. Fill in:
   - **Subscription**: Select your subscription
   - **Resource Group**: Create or select `rg-entra-governance`
   - **Automation account name**: `aa-entra-guest-lifecycle`
   - **Region**: Select your preferred region
3. On the **Advanced** tab:
   - **System assigned**: ✓ Enabled
4. Click **Review + Create** → **Create**
5. After creation, go to the Automation Account → **Identity** (left menu)
6. Confirm **System assigned** status is **On** and copy the **Object (principal) ID**

### Import Required Modules

1. In the Automation Account → **Modules** (left menu) → **+ Add a module**
2. Select **Browse from gallery**
3. Search and import each module (select **Runtime version: 7.2**):
   - `Microsoft.Graph.Authentication`
   - `Microsoft.Graph.Users`
   - `Microsoft.Graph.Groups`
   - `Microsoft.Graph.Identity.SignIns`
4. Wait for each module status to show **Available** before importing the next

> **Note**: `Microsoft.Graph.Authentication` must be imported first as it's a dependency.

---

## Scenario 2: Grant Graph API Permissions to Managed Identity

### Portal Steps (Enterprise Applications)

1. Go to **Entra Admin Center** → **Identity** → **Applications** → **Enterprise applications**
2. Change the filter to **Managed Identities** (Application type dropdown)
3. Find and click **aa-entra-guest-lifecycle**
4. Go to **Permissions** → **Grant admin consent** is not available for Managed Identities via portal

### Script (Required — Portal Cannot Do This)

Managed Identity app role assignments must be done via PowerShell:

```powershell
# Connect with Global Admin or Privileged Role Administrator
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

# Get the Managed Identity service principal
$miObjectId = "<paste Object ID from Automation Account Identity blade>"
$miSp = Get-MgServicePrincipal -ServicePrincipalId $miObjectId

# Get the Microsoft Graph service principal
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Define required permissions
$permissions = @(
    "User.ReadWrite.All"        # Read/write user profiles (disable accounts)
    "AuditLog.Read.All"         # Read sign-in activity
    "Group.ReadWrite.All"       # Create and manage groups
    "Policy.ReadWrite.ConditionalAccess"  # Create CA policies
    "Application.Read.All"      # Read application registrations
)

# Assign each permission
foreach ($permName in $permissions) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $permName }
    
    if (-not $appRole) {
        Write-Warning "Permission not found: $permName"
        continue
    }

    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $miSp.Id `
            -PrincipalId $miSp.Id `
            -ResourceId $graphSp.Id `
            -AppRoleId $appRole.Id
        Write-Host "Assigned: $permName" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Host "Already assigned: $permName" -ForegroundColor Yellow
        } else {
            Write-Error "Failed: $permName - $_"
        }
    }
}

Disconnect-MgGraph
```

### Verify Permissions

1. Go to **Entra Admin Center** → **Identity** → **Applications** → **Enterprise applications**
2. Filter: **Managed Identities** → select **aa-entra-guest-lifecycle**
3. Go to **Permissions** → verify all 5 permissions appear under **Admin consent**

---

## Scenario 3: Create Dynamic Security Group

### Portal Steps

1. Go to **Entra Admin Center** → **Identity** → **Groups** → **All groups**
2. Click **+ New group**
3. Fill in:
   - **Group type**: Security
   - **Group name**: `SG-Guests-Disabled-Stale`
   - **Group description**: `Dynamic group containing all disabled guest users. Used by CA policy to block stale guest access.`
   - **Membership type**: **Dynamic User**
4. Click **Add dynamic query**
5. In the rule builder, switch to **Edit** (text mode) and paste:
   ```
   (user.accountEnabled -eq false) and (user.userType -eq "Guest")
   ```
6. Click **Validate Rules** tab → add a known disabled guest → verify it shows as matching
7. Click **Save** → **Create**
8. Note: Initial population takes 5–30 minutes

### Script Alternative

```powershell
.\scripts\New-DynamicGroup.ps1
```

### Verify Group Population

1. Go to **Groups** → **SG-Guests-Disabled-Stale** → **Members**
2. Wait up to 30 minutes for initial population
3. Confirm disabled guests appear as members
4. Go to **Audit logs** → filter Activity: **Add member to group** → confirm dynamic additions

---

## Scenario 4: Create Conditional Access Policy (Block Stale Guests)

### Portal Steps

1. Go to **Entra Admin Center** → **Protection** → **Conditional Access** → **Policies**
2. Click **+ New policy**
3. **Name**: `Block Stale Guest Access`
4. **Users**:
   - **Include** tab → **Select users and groups** → check **Users and groups**
   - Click **Select** → search `SG-Guests-Disabled-Stale` → check it → **Select**
   - **Exclude** tab → **Users and groups** → add your **break-glass/emergency access accounts**
5. **Target resources**:
   - **Include** tab → select **All cloud apps**
6. **Conditions**: Leave all as **Not configured**
7. **Grant**:
   - Click **0 controls selected**
   - Select **Block access** → click **Select**
8. **Session**: Leave as default
9. **Enable policy**: Select **Report-only**
10. Click **Create**

### Script Alternative

```powershell
.\scripts\New-ConditionalAccessPolicy.ps1
```

### Verify Policy (Report-Only)

1. Go to **Entra Admin Center** → **Identity** → **Monitoring** → **Sign-in logs**
2. Find a sign-in from a disabled guest (or simulate one)
3. Click the sign-in entry → **Conditional Access** tab
4. Verify **Block Stale Guest Access** shows with result: **Report-only: Not applied**

### Promote to Enabled (After Validation)

1. Go to **Protection** → **Conditional Access** → **Policies**
2. Click **Block Stale Guest Access**
3. Change **Enable policy** from **Report-only** to **On**
4. Click **Save**

> **Warning**: Only promote after confirming the dynamic group contains only the intended stale guests.

---

## Scenario 5: Initial Stale Guest Cleanup (365 Days)

### Pre-Check: Verify Sign-In Activity Data

1. Go to **Entra Admin Center** → **Identity** → **Users** → **All users**
2. Click any guest user → **Sign-in logs**
3. Confirm sign-in data is available (requires P1/P2 license)

Or via Graph Explorer:
```
GET https://graph.microsoft.com/v1.0/users?$filter=userType eq 'Guest'&$select=displayName,signInActivity&$top=5&$count=true
Header: ConsistencyLevel: eventual
```

### Run WhatIf (Dry Run)

1. Go to **Azure Portal** → **Automation Accounts** → **aa-entra-guest-lifecycle**
2. Go to **Runbooks** → **+ Create a runbook**
   - **Name**: `Disable-StaleGuests`
   - **Runbook type**: PowerShell
   - **Runtime version**: 7.2
3. Paste contents of `scripts/Disable-StaleGuests.ps1` → **Save** → **Publish**
4. Click **Start** → set parameters:
   - **InactivityDays**: `365`
   - **WhatIf**: `True`
5. Review output → confirm the correct guests would be disabled

### Execute Initial Cleanup

1. Go to the runbook → **Start** → set parameters:
   - **InactivityDays**: `365`
   - **WhatIf**: `False`
2. Monitor the job output for progress and errors
3. After completion, verify:
   - **Entra Admin Center** → **Users** → filter by **Account enabled: No** + **User type: Guest**
   - Count should match the runbook summary

### Script (Interactive)

```powershell
# Dry run
.\scripts\Disable-StaleGuests.ps1 -InactivityDays 365 -WhatIf

# Execute
.\scripts\Disable-StaleGuests.ps1 -InactivityDays 365
```

---

## Scenario 6: Schedule Ongoing 30-Day Automation

### Portal Steps

1. Go to **Azure Portal** → **Automation Accounts** → **aa-entra-guest-lifecycle**
2. Go to **Runbooks** → **Disable-StaleGuests** → **Schedules** → **+ Add a schedule**
3. Click **Link a schedule to your runbook** → **+ Add a schedule**
4. Fill in:
   - **Name**: `Daily-StaleGuest-Check`
   - **Starts**: Tomorrow at 02:00 AM (off-peak)
   - **Recurrence**: Recurring
   - **Recur every**: `1 Day`
   - **Set expiration**: No
5. Click **Create**
6. Configure parameters for the schedule:
   - **InactivityDays**: `30`
   - **WhatIf**: `False`
   - **BatchSize**: `999`
7. Click **OK**

### Verify Schedule

1. Go to **Automation Account** → **Schedules** → confirm `Daily-StaleGuest-Check` is **Enabled**
2. Go to **Jobs** → next day, verify the job ran successfully
3. Check **Output** tab for execution summary

---

## Scenario 7: Reprovisioning a Guest (Admin Re-enables)

### Portal Steps

1. Go to **Entra Admin Center** → **Identity** → **Users** → **All users**
2. Search for the guest user (e.g., teacher requesting access again)
3. Click the user → **Properties** → **Edit properties**
4. Find **Account enabled** → toggle to **Yes**
5. Click **Save**

### What Happens Automatically

| Time | Event |
|---|---|
| T+0 min | `accountEnabled` = true saved |
| T+5–30 min | Dynamic group re-evaluates → user removed from `SG-Guests-Disabled-Stale` |
| T+5–30 min | CA policy `Block Stale Guest Access` no longer applies to this user |
| T+30 min | User can sign in normally |

### Verify Reprovisioning

1. After 30 minutes, go to **Groups** → **SG-Guests-Disabled-Stale** → **Members**
2. Search for the re-enabled guest → should **NOT** appear
3. Ask the guest to sign in → should succeed without CA block

### Bulk Reprovisioning (PowerShell)

```powershell
# Re-enable specific guests by email
$guestsToEnable = @(
    "teacher1@external.org",
    "teacher2@external.org"
)

Connect-MgGraph -Scopes "User.ReadWrite.All"

foreach ($email in $guestsToEnable) {
    $user = Get-MgUser -Filter "mail eq '$email' and userType eq 'Guest'"
    if ($user) {
        Update-MgUser -UserId $user.Id -AccountEnabled:$true
        Write-Host "Enabled: $($user.DisplayName) ($email)"
    } else {
        Write-Warning "Not found: $email"
    }
}

Disconnect-MgGraph
```

---

## Scenario 8: Re-Deprovisioning (30-Day Inactivity After Re-enable)

### How It Works

This is fully automated — no admin action needed:

1. Guest was re-enabled (Scenario 7)
2. Guest does not sign in for 30 days
3. Next daily runbook execution detects the guest via `signInActivity`
4. Runbook sets `accountEnabled = false`
5. Dynamic group re-adds the guest → CA blocks access again

### Verify Re-Deprovisioning

1. Go to **Azure Portal** → **Automation Accounts** → **Jobs**
2. Open the latest `Disable-StaleGuests` job
3. Check **Output** → re-enabled guest should appear in the disabled list
4. Go to **Entra Admin Center** → **Users** → verify guest is disabled again
5. Go to **Groups** → **SG-Guests-Disabled-Stale** → verify guest re-appears

---

## Scenario 9: Monitoring & Troubleshooting

### Daily Monitoring

1. **Azure Portal** → **Automation Accounts** → **aa-entra-guest-lifecycle** → **Jobs**
   - Check job status: **Completed** ✓
   - If **Failed**: click job → **Errors** tab for details
2. **Entra Admin Center** → **Identity** → **Monitoring** → **Audit logs**
   - Filter: Activity = "Update user", Target = Guest users
   - Verify bulk disable operations correspond to runbook timing

### Weekly Monitoring

1. **Groups** → **SG-Guests-Disabled-Stale** → check **Members** count
   - Should grow slowly over time as guests go inactive
   - Sudden drops indicate bulk re-enablement
2. **Protection** → **Conditional Access** → **Insights and reporting**
   - Filter by policy `Block Stale Guest Access`
   - Review blocked sign-in attempts (validates CA is working)

### Troubleshooting

| Issue | Check | Fix |
|---|---|---|
| Runbook fails with auth error | Automation Account → Identity → verify MI is On | Re-enable MI and re-assign permissions |
| Runbook fails with 403 | Enterprise Apps → MI → Permissions | Re-run permission assignment script |
| Dynamic group not updating | Groups → group → Properties → Processing status | Verify rule syntax; check Entra license |
| CA not blocking | Sign-in logs → CA tab | Verify policy state is "On", not Report-only |
| Guest still blocked after re-enable | Groups → check if guest still in group | Wait 30 min; if persistent, check accountEnabled value |
| Runbook timeout (>3 hrs) | Large tenant with many guests | Reduce scope with additional filters or split into batches |

### Useful Log Queries (Entra Audit)

**Find all guests disabled by automation:**
- Activity: `Update user`
- Modified Properties: `AccountEnabled` → New Value: `false`
- Initiated by: `aa-entra-guest-lifecycle` (Managed Identity)

**Find guests re-enabled by admins:**
- Activity: `Update user`
- Modified Properties: `AccountEnabled` → New Value: `true`
- Initiated by: (Admin UPN)

---

## Scenario 10: End-to-End Validation Test

### Portal + Script Walkthrough

1. **Create test guest**:
   - Entra Admin Center → Users → + Invite external user
   - Email: use a test external email you control
   - Name: `POC-Test-Guest-Lifecycle`
   - Click **Invite**

2. **Verify guest is enabled and NOT in dynamic group**:
   - Users → POC-Test-Guest-Lifecycle → Account enabled: Yes ✓
   - Groups → SG-Guests-Disabled-Stale → Members → search: not found ✓

3. **Simulate stale by disabling**:
   - Users → POC-Test-Guest-Lifecycle → Edit properties → Account enabled: No → Save

4. **Wait 30 minutes, then verify group membership**:
   - Groups → SG-Guests-Disabled-Stale → Members → POC-Test-Guest-Lifecycle appears ✓

5. **Verify CA impact** (if policy is Enabled):
   - Attempt sign-in with the test guest → should be blocked ✓
   - Sign-in logs → CA tab → "Block Stale Guest Access: Failure" ✓

6. **Re-enable the guest**:
   - Users → POC-Test-Guest-Lifecycle → Edit properties → Account enabled: Yes → Save

7. **Wait 30 minutes, then verify removal**:
   - Groups → SG-Guests-Disabled-Stale → Members → POC-Test-Guest-Lifecycle gone ✓
   - Attempt sign-in → should succeed ✓

8. **Cleanup**:
   - Users → POC-Test-Guest-Lifecycle → Delete user (or keep for further testing)

### Automated Script

```powershell
.\scripts\Test-GuestLifecycle.ps1 -TestGuestEmail "testguest@yourdomain.com"
```

---

## Quick Reference: Admin Portal Paths

| Task | Portal Path |
|---|---|
| Manage users | Entra Admin Center → Identity → Users → All users |
| Manage groups | Entra Admin Center → Identity → Groups → All groups |
| Conditional Access | Entra Admin Center → Protection → Conditional Access → Policies |
| Sign-in logs | Entra Admin Center → Identity → Monitoring → Sign-in logs |
| Audit logs | Entra Admin Center → Identity → Monitoring → Audit logs |
| Automation Account | Azure Portal → Automation Accounts → aa-entra-guest-lifecycle |
| Automation Jobs | Azure Portal → Automation Accounts → Jobs |
| Automation Runbooks | Azure Portal → Automation Accounts → Runbooks |
| Automation Schedules | Azure Portal → Automation Accounts → Schedules |
