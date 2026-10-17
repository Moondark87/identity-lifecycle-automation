# ADR 004: Privileged Access Is Just-in-Time Through PIM, Never Automated

Author: Alex Scheaffer

Status: Accepted

## Context
Administrators held standing membership in powerful groups, often on the same account they used for email and browsing. A single compromised session meant immediate admin access, and nobody could say who had used admin rights, or when.

## Decision
- Admin rights live on **separate admin accounts** (`adm-*`) in tiered OUs.
- Admin accounts are **eligible** for `PRIV-*` groups through Entra PIM for Groups; activation is time-bound, needs a justification, and requires phishing-resistant MFA through a Conditional Access authentication context.
- **Lifecycle automation can never grant privileged access.** `Test-RoleMap` rejects any group without the `ROLE-` prefix.
- Admin accounts carry their owner's EmployeeID and are **offboarded automatically with their owner**.

## Rationale
- No standing privilege to steal
- Every use of admin rights is a logged, attributable event
- Keeping privilege out of automation means a bad HRIS record or role map can't create an administrator
- Tying admin accounts to an owner closes the "admin account outlives the admin" gap

## Alternatives Considered
- **Standing membership with strong MFA:** still a 24/7 target.
- **Granting privilege from job codes:** convenient, but it turns an HR data error into a security incident.

## Consequences
- Admins activate before privileged work; break-glass accounts cover PIM or Entra outages.
- Eligibility needs periodic access reviews.
- Admin accounts with no valid owner are flagged for review on every run.
