# Role-Based Access Control & Privileged Access

Author: Alex Scheaffer

Access is granted to **groups**, groups are nested in a fixed pattern, and privileged access is never standing.

<!-- diagram: diagrams/rbac-model.mmd -->
```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320, "htmlLabels": true}}}%%
flowchart LR
    U["<b>User account</b><br/>priya.raman<br/>EmployeeID 100103"]

    subgraph ROLE ["Role groups · managed by automation"]
        R1["ROLE-All-Employees"]
        R2["ROLE-Finance"]
        R3["ROLE-Finance-AP"]
        R4["ROLE-Site-A"]
    end

    subgraph RES ["Resource groups · owned by IT / app owners"]
        X1["RES-FS-Finance-RW<br/>Finance file share"]
        X2["APP-ERP-AP-User<br/>ERP payables module"]
        X3["LIC-M365-E3<br/>Group-based licensing"]
        X4["GPO-Site-A-Printers<br/>GPO security filtering"]
    end

    CAP["<b>Conditional Access</b><br/>Policies assigned to role groups"]

    U --> R1 & R2 & R3 & R4
    R1 --> X3
    R2 --> X1
    R3 --> X2
    R4 --> X4
    R1 -. targeted by .-> CAP

    A["<b>Separate admin account</b><br/>adm-marcus.lee"]
    P["<b>PRIV-Tier1-Admins</b><br/>PIM eligible, time-bound<br/>MFA + justification to activate"]
    A -. PIM activation .-> P

    classDef box fill:#f6f8fa,stroke:#57606a,color:#1f2328
    classDef priv fill:#fdecea,stroke:#c0392b,stroke-width:2px,color:#1f2328
    classDef control fill:#fff4e5,stroke:#d79b00,stroke-width:2px,color:#1f2328
    class U,R1,R2,R3,R4,X1,X2,X3,X4,A box
    class P priv
    class CAP control
    style ROLE fill:none,stroke:#4a7fc1,stroke-width:2px,color:#4a7fc1
    style RES fill:none,stroke:#5a9a4a,stroke-width:2px,color:#5a9a4a
```

## Group layers

| Layer | Prefix | Members | Managed by | Grants |
|---|---|---|---|---|
| **Role** | `ROLE-` | User accounts | Lifecycle automation, from HRIS data | Nothing directly; nested into resource groups |
| **Resource** | `RES-`, `APP-` | Role groups | Resource / app owners | File share, app, database or API permissions |
| **Licensing** | `LIC-` | Role groups | IT | M365 and SaaS licenses (group-based licensing) |
| **Policy** | `GPO-` | Role groups | IT | GPO security filtering |
| **Privileged** | `PRIV-` | Admin accounts, PIM-eligible only | Identity team + PIM | Admin roles, time-bound |

This is the classic AGDLP pattern (Accounts → Global groups → Domain Local groups → Permissions), extended to licensing, Group Policy and Conditional Access.

## How roles are derived

Role groups come from four HRIS fields, defined in [`config/roles.example.json`](../config/roles.example.json):

| HRIS field | Example | Role group |
|---|---|---|
| Worker type | Employee | `ROLE-All-Employees` |
| Department | Finance | `ROLE-Finance` |
| Job code | FIN-AP | `ROLE-Finance-AP` |
| Location | SITE-A | `ROLE-Site-A` |

When HRIS changes any of these, the next sync adds the new role groups and removes the old ones. Everything nested underneath (shares, apps, licenses, GPOs, Conditional Access) follows automatically. Nobody has to remember to remove last department's access.

## Guardrails

- **Users are never placed directly in resource groups.** If a person needs something their role doesn't give, the fix is a new or adjusted role, not a one-off grant.
- **Automation touches only `ROLE-` groups.** `Test-RoleMap` refuses to run if the role map contains any other prefix, so automation cannot grant `PRIV-` access, even by mistake.
- **Other memberships are left alone by movers.** Manually managed groups (e.g. `VPN-Users`) are reported but not removed when someone changes role; leavers lose everything except their primary group.
- **Resource groups have named owners**, who review membership (which is role groups, a short list) instead of reviewing individual users.

## Privileged Identity Management

| Control | Implementation |
|---|---|
| Separate admin identities | `adm-` accounts in tiered OUs; daily-use accounts hold no admin rights |
| No standing access | Admin accounts are **eligible** for `PRIV-` groups through Entra PIM for Groups, not permanent members |
| Just-in-time activation | Time-bound (e.g. 1–8 hours), with justification and ticket reference |
| Strong authentication to activate | Conditional Access authentication context requires phishing-resistant MFA and a compliant device |
| Approval for the highest tiers | Tier 0 activation requires a second approver |
| Visibility | Every activation is logged to the SIEM and alerts on activation outside change windows |
| Periodic review | Access reviews of PIM eligibility; unused eligibility is removed |

Admin accounts carry the owner's EmployeeID, so when that person leaves the lifecycle process finds and disables the admin account too, even though it is excluded from normal role management.
