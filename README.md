# Entra ID Governance — Stale Guest Lifecycle POC

## Overview

This proof-of-concept automates the lifecycle management of stale guest users (≈50,000) in Microsoft Entra ID without deleting accounts. It uses:

- **Azure Automation** (PowerShell runbooks) for scheduled automation — no Logic Apps
- **Dynamic Security Groups** for self-healing Conditional Access targeting
- **Conditional Access** to block access for disabled guests
- **Microsoft Graph API** for all identity operations

## Architecture

```mermaid
flowchart TD
    R1[Disable-StaleGuests.ps1 - Daily Schedule]
    Q[Query Guest Users via Graph API]
    DIS[Disable Account]
    DG[Dynamic Group: SG-Guests-Disabled-Stale]
    CA[CA Policy: Block Access]
    ADMIN[Admin Re-enables Guest]
    REM[Auto-removed from Dynamic Group]
    UNBLOCK[Access Restored]
    REDEP[30-day inactivity detected]

    R1 --> Q
    Q --> DIS
    DIS --> DG
    DG --> CA

    ADMIN --> REM
    REM --> UNBLOCK

    REDEP --> DIS
```

## Guest Lifecycle with Entitlement Management & Access Reviews

This POC extends beyond stale-guest disablement to implement a **full governed lifecycle** using Entra ID Governance features:

```mermaid
flowchart LR
    A[1. Invitation via<br/>Access Package] --> B[2. Active Period<br/>+ Quarterly Reviews]
    B --> C[3. 1-Year Inactivity<br/>→ Auto-Disable]
    C --> D[4. 60-Day Grace Period<br/>Sponsor Notified]
    D -->|Sponsor Reactivates| B
    D -->|No Action| E[Cleanup:<br/>Revoke & Remove]
```

### Lifecycle Requirements

| # | Requirement | How It's Implemented |
|---|---|---|
| 1 | **Initial invitation through Entitlement Management** — establishes guest access with defined scope and permissions | Access Package in "External Collaboration" catalog. Connected Organization sponsors approve requests. Guest is added to `SG-Guests-Active` group upon approval. |
| 2 | **Regular access reviews** — ensure continued business need and appropriate permissions | Quarterly Access Reviews configured on the assignment policy AND as a standalone review. Sponsors review their guests; auto-deny if no response. Sign-in activity recommendations enabled. |
| 3 | **Automated disablement after 1 year of inactivity** — reduces security risk while preserving account data | `Disable-StaleGuests.ps1` runs daily with 365-day threshold. Disables account + stamps `extensionAttribute1` with ISO 8601 date. Dynamic group + CA policy blocks access immediately. |
| 4 | **60-day grace period** — allows sponsors to reactivate accounts before permanent data cleanup | `Remove-ExpiredGuests.ps1` runs weekly. Notifies sponsors at day 45. At day 60+: revokes access packages, removes group memberships. `Invoke-GuestReactivation.ps1` enables sponsor-initiated recovery. |

### Entitlement Management Setup

The Access Package provides **governed onboarding** that replaces ad-hoc B2B invitations:

- **Catalog**: "External Collaboration" — groups all external access packages
- **Access Package**: "Guest Access - Standard" — requestable via MyAccess portal
- **Approval**: Connected Organization internal sponsors (first stage, 14-day timeout)
- **Reviews**: Quarterly, sponsors as reviewers, auto-deny on no response
- **Expiration**: None (inactivity-based disablement is the enforcement mechanism, not time-based expiration)

```powershell
# Set up Entitlement Management
.\scripts\entitlement-management\New-GuestAccessPackage.ps1 -WhatIf   # Validate
.\scripts\entitlement-management\New-GuestAccessPackage.ps1            # Execute

# Set up standalone Access Review
.\scripts\entitlement-management\New-AccessReview.ps1 -WhatIf
.\scripts\entitlement-management\New-AccessReview.ps1
```

### Grace Period & Sponsor Reactivation

After disablement, the 60-day grace period provides a safety net:

| Day | Action |
|---|---|
| 0 | Guest disabled by `Disable-StaleGuests.ps1` (1-year inactivity) |
| 0–44 | Sponsor can reactivate at any time via `Invoke-GuestReactivation.ps1` |
| 45 | Automated email notification sent to sponsor |
| 60 | `Remove-ExpiredGuests.ps1` revokes access packages + removes groups |
| 60+ | Account preserved (disabled) unless `-DeleteAccount` flag is used |

```powershell
# Grace period cleanup (weekly schedule)
.\scripts\Remove-ExpiredGuests.ps1 -SenderUserId "noreply@contoso.com" -WhatIf
.\scripts\Remove-ExpiredGuests.ps1 -SenderUserId "noreply@contoso.com"

# Sponsor reactivation (on-demand)
.\scripts\Invoke-GuestReactivation.ps1 `
    -GuestUserId "<guest-object-id>" `
    -SponsorId "<sponsor-object-id>" `
    -Justification "Active project collaboration" `
    -RestoreAccessPackage -AccessPackageId "<package-id>"
```

### Additional Prerequisites for Lifecycle Features

| Requirement | Details |
|---|---|
| **License** | Entra ID P2 / Entra ID Governance (for Entitlement Management + Access Reviews) |
| **Graph Permissions** | Add: `EntitlementManagement.ReadWrite.All`, `AccessReview.ReadWrite.All`, `Mail.Send` |
| **Connected Organizations** | Configure partner domains in Entra admin center |
| **Sponsor Assignment** | Set `sponsors` relationship on guest users |
| **Shared Mailbox** | For notification emails from cleanup runbook |

> 📖 **Full implementation details**: See [docs/entitlement-management-guide.md](docs/entitlement-management-guide.md)

## Prerequisites

| Requirement | Details |
|---|---|
| Entra ID License | P1 or P2 (required for `signInActivity`, dynamic groups, CA) |
| Azure Automation Account | With System-Assigned Managed Identity |
| Graph API Permissions | `User.ReadWrite.All`, `AuditLog.Read.All`, `Group.ReadWrite.All`, `Policy.ReadWrite.ConditionalAccess`, `Application.Read.All` |
| PowerShell Modules | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.SignIns` |

## Deployment Steps

### 1. Create Azure Automation Account

```powershell
# In Azure Portal or via Az CLI
az automation account create `
    --name "aa-entra-guest-lifecycle" `
    --resource-group "rg-entra-governance" `
    --location "eastus"
```

Enable **System-Assigned Managed Identity** on the Automation Account.

### 2. Grant Graph API Permissions to Managed Identity

Use the `scripts/Grant-AutomationPermissions.ps1` or manually assign:

- `User.ReadWrite.All`
- `AuditLog.Read.All`
- `Group.ReadWrite.All`
- `Policy.ReadWrite.ConditionalAccess`
- `Application.Read.All`

### 3. Import PowerShell Modules in Automation Account

In the Automation Account → Modules → Browse Gallery:
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Identity.SignIns`

### 4. Create Dynamic Security Group

Run `scripts/New-DynamicGroup.ps1` or manually create:

- **Name**: `SG-Guests-Disabled-Stale`
- **Type**: Security, Dynamic
- **Rule**: `(user.accountEnabled -eq false) and (user.userType -eq "Guest")`

### 5. Create Conditional Access Policy

Run `scripts/New-ConditionalAccessPolicy.ps1` — deploys in **Report-Only** mode initially.

- **Target**: Members of `SG-Guests-Disabled-Stale`
- **Resources**: All cloud apps
- **Grant**: Block access

### 6. Deploy Automation Runbook

Import `scripts/Disable-StaleGuests.ps1` as a runbook and create a daily schedule.

### 7. Initial Execution (One-Time)

For the first run targeting 365-day stale guests:

```powershell
# Run with -InactivityDays 365 for initial cleanup
.\scripts\Disable-StaleGuests.ps1 -InactivityDays 365 -WhatIf
```

After validating with `-WhatIf`, remove the flag for execution.

### 8. Ongoing Schedule

Set the daily runbook schedule with `-InactivityDays 30` for the ongoing 30-day inactivity threshold.

## Operational Workflow

| Event | Automated Action | Result |
|---|---|---|
| Guest inactive > threshold | Runbook disables account | Added to dynamic group → blocked by CA |
| Admin re-enables guest | Dynamic group auto-removes | CA no longer applies → access restored |
| Re-enabled guest inactive 30 days | Runbook disables again | Re-added to dynamic group → blocked again |

## Cost Estimate

| Component | Monthly Cost |
|---|---|
| Azure Automation (Basic) | Free tier: 500 min/month included |
| Estimated runtime (~50k users) | ~15-20 min/day = ~600 min/month ≈ $0.20 overage |
| Dynamic Group | Included in Entra P1/P2 |
| Conditional Access | Included in Entra P1/P2 |
| **Total additional cost** | **~$0–$1/month** |

## File Structure

```
Entra-GuestLifecycle-POC/
├── README.md                          # This file
├── LICENSE                            # MIT License
├── docs/
│   ├── entitlement-management-guide.md # Full lifecycle implementation guide
│   ├── step-by-step-guide.md          # Portal walkthrough (10 scenarios)
│   └── testing-checklist.md           # Validation checklist (50 tests)
└── scripts/
    ├── Disable-StaleGuests.ps1        # Main runbook (365-day inactivity + date stamp)
    ├── Remove-ExpiredGuests.ps1       # Grace period cleanup (60-day)
    ├── Invoke-GuestReactivation.ps1   # Sponsor reactivation workflow
    ├── New-DynamicGroup.ps1           # Creates dynamic security group
    ├── New-ConditionalAccessPolicy.ps1 # Creates CA block policy
    ├── Test-GuestLifecycle.ps1        # End-to-end validation script
    └── entitlement-management/
        ├── New-GuestAccessPackage.ps1 # Access Package + catalog setup
        └── New-AccessReview.ps1       # Quarterly access review setup
```

## Important Notes

- **Do NOT delete guest accounts** — disabling preserves the guest object for re-enablement
- Dynamic group membership updates may take 5–30 minutes after `accountEnabled` changes
- The runbook uses batch processing with throttle handling for 50k+ users
- Always test with `-WhatIf` before production execution
- CA policy deploys in Report-Only mode — switch to Enabled after validation

## How Azure Automation Runbooks Work

Azure Automation executes your PowerShell script (`Disable-StaleGuests.ps1`) on a schedule in Azure's serverless infrastructure — no VM, no Logic App, no local machine required.

### Execution Flow

```mermaid
sequenceDiagram
    participant Schedule as Daily Schedule
    participant AA as Azure Automation
    participant MI as Managed Identity
    participant Graph as Microsoft Graph API
    participant Entra as Entra ID

    Schedule->>AA: Triggers runbook
    AA->>MI: Authenticates (no credentials stored)
    MI->>Graph: OAuth2 token (app-only)
    AA->>Graph: GET /users (filter guests)
    Graph-->>AA: Returns guests with signInActivity
    AA->>AA: Filters inactive > threshold
    AA->>Graph: PATCH /users/{id} accountEnabled=false
    Graph->>Entra: User disabled
    Entra->>Entra: Dynamic group re-evaluates
```

1. **Schedule triggers** the runbook daily (e.g., 02:00 AM)
2. **Managed Identity authenticates** to Microsoft Graph (no stored credentials)
3. **Script queries** guest users with stale `signInActivity`
4. **Script disables** inactive accounts (`accountEnabled = false`)
5. **Dynamic group auto-updates** → CA policy blocks access

### Key Benefits Over Alternatives

| Traditional Approach | Azure Automation |
|---|---|
| Logic App ($$$ per action) | Free tier: 500 min/month included |
| Stored credentials/secrets | Managed Identity (auto-rotated, no secrets) |
| Always-on VM + Task Scheduler | Serverless — runs only when triggered |
| Manual intervention | Fully automated with audit trail |

### Authentication Difference

```powershell
# Azure Automation (Managed Identity — no credentials needed):
Connect-MgGraph -Identity -NoWelcome

# Interactive/local testing (prompts for login):
Connect-MgGraph -Scopes "User.ReadWrite.All" -NoWelcome
```

### Cost

| Component | Monthly Cost |
|---|---|
| Free tier | 500 min/month included |
| This POC (~15-20 min/day) | ~$0–$0.20 overage |
| Managed Identity | Free |
| **Total** | **~$0–$1/month** |
