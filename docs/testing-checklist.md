# Testing Checklist — Stale Guest Lifecycle POC

## Pre-Deployment Validation

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 1 | Entra P1/P2 license active | Entra Portal > Licenses | signInActivity and dynamic groups available | ☐ |
| 2 | Azure Automation Account exists | Azure Portal > Automation Accounts | Account with Managed Identity enabled | ☐ |
| 3 | Graph modules imported | Automation > Modules | Microsoft.Graph.* modules present | ☐ |
| 4 | Managed Identity permissions | Enterprise Apps > MI > Permissions | User.ReadWrite.All, AuditLog.Read.All, Group.ReadWrite.All, Policy.ReadWrite.ConditionalAccess | ☐ |
| 5 | signInActivity data available | Graph Explorer: `GET /users?$select=signInActivity&$top=5` | lastSignInDateTime populated for active users | ☐ |

## Dynamic Group Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 6 | Group creation | Run `New-DynamicGroup.ps1` | SG-Guests-Disabled-Stale created with correct rule | ☐ |
| 7 | Membership rule syntax | Entra > Groups > SG-Guests-Disabled-Stale > Dynamic membership rules | Rule: `(user.accountEnabled -eq false) and (user.userType -eq "Guest")` | ☐ |
| 8 | Processing state active | Group properties | MembershipRuleProcessingState = "On" | ☐ |
| 9 | Existing disabled guests populate | Wait 30 min, check members | Pre-existing disabled guests appear in group | ☐ |
| 10 | Member auto-added on disable | Disable a test guest, wait 30 min | Guest appears in group members | ☐ |
| 11 | Member auto-removed on enable | Re-enable guest, wait 30 min | Guest removed from group members | ☐ |

## Conditional Access Policy Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 12 | Policy creation | Run `New-ConditionalAccessPolicy.ps1` | Policy created in Report-Only mode | ☐ |
| 13 | Policy targets correct group | CA > Policies > Block Stale Guest Access > Users | SG-Guests-Disabled-Stale included | ☐ |
| 14 | All cloud apps targeted | CA > Policy > Target resources | "All cloud apps" selected | ☐ |
| 15 | Block control configured | CA > Policy > Grant | "Block access" selected | ☐ |
| 16 | Report-only logging | Sign-in logs > CA tab | Policy shows "Report-only: Not applied" or "Would block" | ☐ |
| 17 | Break-glass excluded | CA > Policy > Users > Exclude | Emergency access accounts excluded | ☐ |
| 18 | Policy enforcement (after promotion) | Switch to Enabled, test blocked guest sign-in | Sign-in blocked with CA error | ☐ |

## Automation Runbook Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 19 | WhatIf mode (365-day threshold) | Run `Disable-StaleGuests.ps1 -InactivityDays 365 -WhatIf` | Lists stale guests without disabling | ☐ |
| 20 | WhatIf mode (30-day threshold) | Run `Disable-StaleGuests.ps1 -InactivityDays 30 -WhatIf` | Lists stale guests without disabling | ☐ |
| 21 | Correct stale identification | Review WhatIf output | Only guests inactive > threshold listed | ☐ |
| 22 | Active guests not affected | Verify active guests excluded | Guests with recent sign-ins not listed | ☐ |
| 23 | Guests with no sign-in data | Check guests created > threshold ago with no signInActivity | Correctly identified using createdDateTime fallback | ☐ |
| 24 | Pagination works (large tenant) | Run against tenant with > 999 guests | All pages retrieved, total count correct | ☐ |
| 25 | Throttling handled | Monitor runbook output | 429 responses retried with backoff | ☐ |
| 26 | Accounts actually disabled | Run without -WhatIf on test subset | accountEnabled = false on target guests | ☐ |
| 27 | Already disabled guests skipped | Run again after disabling | Filter `accountEnabled eq true` excludes already-disabled | ☐ |
| 28 | Scheduled execution | Create daily schedule in Automation | Runbook triggers automatically at scheduled time | ☐ |

## Reprovisioning Flow Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 29 | Admin re-enables guest | Set accountEnabled = true via Portal/Graph | Account enabled immediately | ☐ |
| 30 | Dynamic group removal | Wait up to 30 min after re-enable | Guest removed from SG-Guests-Disabled-Stale | ☐ |
| 31 | CA block lifted | Attempt sign-in after group removal | Access no longer blocked (CA doesn't apply) | ☐ |
| 32 | No manual group management needed | Verify no scripts/workflows trigger | Entirely handled by dynamic membership rule | ☐ |

## Re-Deprovisioning Flow Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 33 | Re-enabled guest goes inactive | Wait or simulate 30+ days inactivity | signInActivity stale | ☐ |
| 34 | Runbook re-disables guest | Next scheduled run picks up inactive guest | accountEnabled set to false again | ☐ |
| 35 | Dynamic group re-adds guest | Wait for group processing | Guest re-appears in dynamic group | ☐ |
| 36 | CA re-blocks access | Verify sign-in blocked again | Full cycle completes automatically | ☐ |

## Scale & Performance Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 37 | 50k guest query performance | Run against production tenant | Completes within 20 minutes | ☐ |
| 38 | Batch disable performance | Disable 1000+ guests in single run | Completes with < 1% error rate | ☐ |
| 39 | Dynamic group at scale | 50k members in dynamic group | Group evaluates within 24 hours | ☐ |
| 40 | Automation job doesn't timeout | Monitor job execution | Completes within Azure Automation limits (3 hrs) | ☐ |

## Security & Compliance Tests

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 41 | Audit log entries | Entra > Audit logs | "Update user" entries for each disabled guest | ☐ |
| 42 | Managed Identity least privilege | Review MI permissions | Only required Graph permissions assigned | ☐ |
| 43 | No member users affected | Verify filter includes `userType eq 'Guest'` | Internal members never disabled by runbook | ☐ |
| 44 | Admin accounts excluded | Verify admin guests with recent activity | Active admin guests not affected | ☐ |

## End-to-End Validation

| # | Test | Steps | Expected Result | Status |
|---|------|-------|-----------------|--------|
| 45 | Full automated test | Run `Test-GuestLifecycle.ps1 -TestGuestEmail <email>` | All 7 lifecycle tests pass | ☐ |
| 46 | Rollback capability | Re-enable disabled guests in bulk | `Get-MgGroupMember` + `Update-MgUser -AccountEnabled:$true` works | ☐ |

## Post-Deployment Monitoring

| # | Check | Frequency | Tool |
|---|-------|-----------|------|
| 47 | Runbook execution success | Daily | Azure Automation > Jobs | ☐ |
| 48 | Dynamic group membership count | Weekly | Entra > Groups > Members count | ☐ |
| 49 | CA policy sign-in impact | Weekly | CA Insights workbook | ☐ |
| 50 | False positive reports | Ongoing | Service desk tickets from teachers | ☐ |

---

## Rollback Procedure

If issues are detected:

1. **Immediate**: Set CA policy to Report-Only or Disabled
2. **Bulk re-enable**: 
   ```powershell
   $groupId = (Get-MgGroup -Filter "displayName eq 'SG-Guests-Disabled-Stale'").Id
   $members = Get-MgGroupMember -GroupId $groupId -All
   $members | ForEach-Object { Update-MgUser -UserId $_.Id -AccountEnabled:$true }
   ```
3. **Disable runbook schedule** in Azure Automation
4. **Investigate** before re-enabling automation
