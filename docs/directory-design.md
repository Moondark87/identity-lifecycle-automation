# Directory Design: Flattening the OU Structure

Author: Alex Scheaffer

## The problem with org-chart OUs

Directories that grow over many years tend to mirror the org chart: `Location > Department > Team`, several levels deep, with Group Policy linked at many of those levels and inheritance blocked in places. That causes predictable problems:

- **Moving a person changes their policy by accident.** A transfer means moving the account to another OU, which silently swaps the GPOs that apply.
- **Nobody can say what applies to whom.** Effective policy depends on the OU path, link order, enforcement and blocked inheritance.
- **Reorganizations mean directory surgery.** Every reorg needs new OUs, moved objects and relinked GPOs.
- **Delegation sprawls.** Rights get delegated at many points in the tree and drift over time.

## Target structure

OUs describe **what an object is and who administers it**, not where a person sits in the org chart. Department, location and title live in attributes, fed from HRIS.

```
corp.example.com
└── Corp
    ├── Users
    │   ├── Employees
    │   ├── Contractors
    │   └── Disabled            ← leavers wait here for the retention period
    ├── Admins
    │   ├── Tier0               ← domain / identity infrastructure
    │   ├── Tier1               ← servers and applications
    │   └── Tier2               ← workstations and service desk
    ├── ServiceAccounts
    ├── Groups
    │   ├── Roles               ← ROLE-*  (membership managed by automation)
    │   ├── Resources           ← RES-*, APP-*, LIC-*, GPO-*
    │   └── Privileged          ← PRIV-*  (PIM-managed)
    └── Computers
        ├── Workstations
        ├── Servers
        └── Kiosks
```

## Rules

| Rule | Why |
|---|---|
| OUs exist for object type, delegation boundary or GPO scope, nothing else | Keeps the tree shallow and stable through reorganizations |
| Department, location and title are attributes, not OUs | A transfer is an attribute change, not an object move |
| User-targeted GPOs use **security filtering on `GPO-*` groups** | Policy follows role membership, which follows HRIS |
| Each OU has one owning team for delegation | Delegation is visible and auditable |
| Admin accounts are separate objects in tiered OUs | Day-to-day accounts never hold admin rights |
| `Disabled` has no GPOs that grant anything, and no delegation beyond the identity team | A disabled account can't pick up access by accident |
| Nothing is ever created in the default `Users` or `Computers` containers | Redirected with `redirusr` / `redircmp` to the managed OUs |

## Migration approach

1. **Inventory.** Export every GPO, its links, enforcement and security filtering, plus every blocked-inheritance point and delegation ACL.
2. **Map intent.** For each GPO, record who it was actually meant for, then create a `GPO-*` group for that audience and nest the relevant role groups in it.
3. **Build the new tree** next to the old one and link GPOs with group filtering already in place.
4. **Move in waves** (pilot group first), comparing `gpresult` / RSoP before and after for a sample of users in each wave.
5. **Backfill attributes** (department, location, EmployeeID) from HRIS during the move. See [identity-matching.md](identity-matching.md).
6. **Retire old OUs** once empty, after confirming nothing still links to them.

The result is a directory where a reorganization changes data, not structure. That is what makes automated joiner, mover and leaver handling practical.
