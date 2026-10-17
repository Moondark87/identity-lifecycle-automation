# Examples

All people, IDs and accounts here are fictional. The files are designed to exercise every plan outcome.

| File | What it is |
|---|---|
| [hris-export.sample.csv](hris-export.sample.csv) | HRIS worker export: the input from HR |
| [directory-snapshot.sample.json](directory-snapshot.sample.json) | AD users in the shape `Get-DirectorySnapshot` returns |
| [identity-plan.sample.json](identity-plan.sample.json) | Plan generated from the two files above with `-AsOf 2026-10-16` |
| [hris-email-feed.sample.csv](hris-email-feed.sample.csv) | EmployeeID → email feed that HRIS imports |

## Scenarios covered

| Person / account | Situation | Outcome |
|---|---|---|
| Tom Herrera (100104) | Starts in 3 days; preferred name "Tom" | Joiner, created **disabled** as `tom.herrera` |
| Aisha Bello (100105) | Started this week, no account yet | Joiner, enabled |
| Marcus Lee (100114) | Second Marcus Lee | Joiner as `marcus.lee2` |
| Nina Patel (100115) | Pre-hire account, starts today | Activate |
| Priya Raman (100103) | Transferred Sales → Finance | Mover: +Finance, +Finance-AP, −Sales |
| Robert Chen (100110) | New title | Update |
| Kevin O'Connor (100106) | Terminated yesterday | Leaver |
| Sofia Marino (100107) | Contractor, ends later this month | NoChange (scheduled) |
| Liam Walsh (100113) | Starts in six weeks | NoChange (future hire) |
| Owen Grant (100090) | Disabled more than 30 days ago | Review: eligible for deletion |
| James Park (100108) | Active in HRIS, disabled in AD | Review: rehire? |
| Elena Novak (100109) | Account exists but has no EmployeeID | Review: possible match |
| Chris Dale | HRIS record missing EmployeeID | Review |
| jordan.miles (100099) | EmployeeID not in HRIS | Review: orphaned account |
| kiosk.lobby | Enabled, no EmployeeID | Review |
| adm-marcus.lee, svc-backup | Admin and service accounts | Ignored by role management; left out of the email feed |
| dana.whitfield, marcus.lee | Have a manually managed `VPN-Users` group | Kept; only `ROLE-` groups are managed |

## Regenerate

```powershell
.\scripts\Invoke-IdentitySync.ps1 -HrisCsvPath .\examples\hris-export.sample.csv `
    -DirectorySnapshotPath .\examples\directory-snapshot.sample.json -AsOf 2026-10-16 `
    -PlanPath .\examples\identity-plan.sample.json -EmailFeedPath .\examples\hris-email-feed.sample.csv
```
