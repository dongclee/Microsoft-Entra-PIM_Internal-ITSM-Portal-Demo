# Microsoft Entra PIM + Internal ITSM Portal Demo

**[한국어](README.md) | [English](README_EN.md)**

> **In one sentence:** A sample project showing how employees can **request, approve, provision time-limited eligibility, and track Microsoft Entra administrator roles** through an internal ITSM-style portal.

**Version:** 2.0.5.1  
**Purpose:** Learning and customer demonstrations, not a production ITSM product.

## Why this project?

Organizations often want to manage access requests in their own service portal instead of moving back and forth between an ITSM system and an identity administration portal. This demo connects the **request, approval, eligible-role assignment, revocation, and evidence** experience in one sample interface.

**Important boundary:** This version does **not replace Microsoft Entra PIM end to end**. The internal portal creates **Eligible** assignments, meaning a user is allowed to activate a role. The user still goes to **Microsoft Entra PIM > My roles** to **activate** that role. Entra PIM policies enforce requirements such as MFA, activation approval, and maximum activation duration.

<img width="1536" height="1024" alt="EntraID_PIM_ITSM_Portal" src="https://github.com/user-attachments/assets/1b0ffa17-c293-4a1e-b2c2-bb59115260a6" />

## How it works in 30 seconds

1. An employee requests an administrator role in the internal portal.
2. Three approval gates are completed: System Owner, Security, and Segregation of Duties (SoD).
3. The portal creates a time-limited **Eligible** assignment.
4. The employee activates the role in Microsoft Entra PIM when needed.
5. Eligibility expires at the end of its period, or a portal-created assignment can be revoked earlier.
6. Request and approval records can be downloaded as evidence.

**Example:** Grant eligibility for the **User Administrator** role for **30 days**. Actual active administrator access is a separate, policy-controlled step. The portal's **4-hour activation value is request context**, not an enforced limit.

## Features

| Feature | What it does |
|---|---|
| Dashboard | Shows request counts and statuses |
| PIM Request | Captures user, role, business reason, and duration |
| Approvals | Tracks System Owner, Security, and SoD decisions |
| Role Assignment | Creates simulated or real time-bound eligibility after approval |
| Activation | Links to Microsoft Entra PIM My roles |
| Expiry / Revoke | Displays expiry and submits scoped revocation for portal-owned eligibility |
| Audit / Evidence | Exports requests, approvals, events, and SHA-256 manifest in a ZIP |
| Settings / Health | Displays mode, role allowlist, and application status |

### Simulation vs. Live

- **Simulation (default):** Walk through the workflow without writing PIM changes to Microsoft Graph.
- **Live (optional):** After a separate privileged permission grant, submit **real Entra directory-role eligibility** creation/removal requests through Microsoft Graph. Use **only in an approved test tenant**.

## Simple architecture

```text
Employee / Approver
        |
        v
Internal ITSM-style Portal (Flask)
        |  Request -> Three approvals -> Execute -> Audit
        v
Azure App Service + Microsoft Entra sign-in (Easy Auth)
        |
        | Live mode: Managed Identity
        v
Microsoft Graph -> Entra directory-role eligibility create/remove
        |
        v
User activates the role in Entra PIM My roles
```

- **PowerShell Launcher:** Generates portal code, deploys Azure resources, configures sign-in, validates, and cleans up.
- **Python Flask + SQLite:** Provides the web UI, tickets, approvals, and event records.
- **App Service Easy Auth:** Handles organization sign-in.
- **Managed Identity + Microsoft Graph:** Performs Live eligibility operations.

> **Scope:** This demo covers **Microsoft Entra directory roles**. **Azure RBAC PIM** for subscriptions/resource groups is out of scope. Integration with a real customer ITSM system is also out of scope.

## Quick start

### Requirements

- Windows PowerShell 5.1 or PowerShell 7.x
- An Azure subscription and a test Microsoft Entra tenant
- Appropriate privileges to create Azure resources and Entra applications
- PowerShell modules: `Az.Accounts` (3.0.0+), `Az.Resources` (7.0.0+), `Az.Websites` (3.0.0+), `Microsoft.Graph.Authentication` (2.0.0+)
- Budget for Azure App Service. Confirm PIM licensing and Live availability for your environment.

### 1. Prepare the launcher

Include this source file in your repository:

`Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1`

Copy or rename it with a **`.ps1` extension**. For Windows PowerShell 5.1, save it as **UTF-8 with BOM**.

### 2. Run it

```powershell
.\Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1 -PortalMode Simulation
```

Start in **Simulation** mode. Enter your tenant ID, subscription ID, and resource names when prompted.

### 3. First-time deployment menu sequence

| Menu | Action |
|---|---|
| `P` | Check/install PowerShell modules |
| `1` | Read the operating model and scope |
| `2` | Sign in to Azure and Microsoft Graph |
| `3` | Configure demo values |
| `4` | Generate Flask source and deployment ZIP |
| `5` | Preview the deployment plan (WhatIf) |
| `6` | Create Azure App Service resources |
| `7` | Configure Microsoft Entra sign-in (Easy Auth) |
| `9` | Deploy the portal package |
| `10` | Check authentication, version, routes, and health |
| `11` | Display portal links and demo steps |

**Menu 8 is not needed for the default Simulation demo.** It is a separate privileged Live-mode action.

### 4. Try the portal

1. On the Dashboard, click **Sample request**.
2. Open the ticket and approve all three gates: **SystemOwner / Security / SoD**.
3. Click **Execute Eligible**.
4. In Simulation mode, confirm the `SimulatedEligible` status.
5. Download the Evidence ZIP from **Audit / Evidence**.

### 5. Switch to Live (optional)

If the **same version of the portal is already deployed and healthy**, use:

`2 -> 5 -> 8 -> 10 -> Live action in the portal`

- Menu `8` grants Microsoft Graph **application permissions** to the App Service managed identity and switches the portal to Live.
- This enables real changes, so administrative approval and a test tenant are required.
- Run menu `10` and then test an actual eligible-role request in the portal. **A PASS in menu 10 does not, by itself, prove that a Graph write succeeded.**
- Regenerate/redeploy with menus `4`/`9` only if code changes or the version/route/deployment checks require it.

## Cleanup

1. If you used Live, revoke relevant **portal-owned** eligibility from the portal's **Expiry / Revoke** page first.
2. Use launcher menu `12` to export evidence.
3. Use menu `90` to preview cleanup.
4. Use menu `99` to remove **launcher-tracked deployment objects**.

**Warning:** Menu `99` does not bulk-revoke portal PIM eligibility. It may delete an **entire dedicated resource group created by the launcher**, so do not place unrelated resources in that group. Preserve the state file and review the cleanup preview.

## Safety and production limitations

- **Do not deploy this sample unchanged to production.** It uses single-instance SQLite for demonstration.
- Three approval gates **do not guarantee three distinct human approvers**. If the approver allowlist is empty, any authenticated demo user can approve. Production requires role-specific authorization and prevention of self-approval.
- Live Microsoft Graph application permissions are powerful. Apply least privilege, change approval, logging, and periodic review.
- Production use requires stronger authorization, secret management, centralized logging, protected networking, durable data storage, and proper workflow integration.
- The launcher uses `Publish-AzWebApp` for demo deployment. Review your organization's deployment-security requirements.
- **Never commit** generated `*-State.json` files, output folders, evidence ZIPs, logs, tenant identifiers, user information, or secrets to a public repository.
- The authentication app secret has a default **7-day lifetime** and may require renewal.
- SHA-256 manifests help check file integrity but **do not create immutable evidence storage**.

## FAQ

**Q: Can this completely replace the Entra admin center for PIM?**  
A: **No.** It handles requests, approvals, and eligible-role provisioning/revocation. **Actual role activation still happens in Entra PIM.**

**Q: Does Simulation grant real privileges?**  
A: **No.** It only demonstrates the workflow and records.

**Q: Can it delete pre-existing eligible assignments?**  
A: The portal's revoke flow is designed to target only eligibility created and tracked by this portal. Still verify targets and current state before Live cleanup.

**Q: Does it integrate with ServiceNow or another existing ITSM system?**  
A: **Not out of the box.** This is a standalone **ITSM-style sample portal**. Real ITSM integration requires additional work.

## Suggested repository layout

```text
README.md                 # Korean guide
README_EN.md              # This English guide
Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1
.gitignore
LICENSE                   # If the publisher chooses a license
```

**Before publishing:** Remove real customer names, email addresses, tenant/subscription IDs, authentication secrets, portal URLs, and customer-only screenshots. Review slides and file metadata separately if publishing the customer briefing deck.

---

**Basis:** The supplied Launcher v2.0.5.1 and customer demo/code guide v2.0.5.1. This README describes the source's intended behavior and is not a guarantee of a separately tested deployment.
