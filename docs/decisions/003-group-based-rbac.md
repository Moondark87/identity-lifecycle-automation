# ADR 003: Grant Access Through Nested Role and Resource Groups

Author: Alex Scheaffer

Status: Accepted

## Context
Access had been granted directly to individual users on shares, applications and licenses. When someone changed roles, their old access stayed. When someone left, finding everything they had was a manual search. Access reviews meant reviewing thousands of individual grants.

## Decision
- Users are members of **role groups** (`ROLE-*`) only, derived from HRIS worker type, department, job code and location.
- Role groups are nested into **resource groups** (`RES-*`, `APP-*`, `LIC-*`, `GPO-*`) owned by the resource or application owner.
- Permissions, licenses, GPO filtering and Conditional Access assignments target groups, never individual users.

## Rationale
- A role change in HRIS updates every downstream permission in one step
- Offboarding removes all access by removing group memberships
- Owners review a short list of role groups instead of individual users
- Group-based licensing ties license cost to role
- Follows the established AGDLP pattern, so AD administrators already know it

## Alternatives Considered
- **Direct user grants:** the problem being solved.
- **Department-only groups:** too coarse; job-code roles are needed for finer-grained apps.
- **Attribute-based dynamic groups only (Entra):** a good fit for cloud apps, but on-premises resources still need AD groups. Dynamic groups can be layered on later from the same HRIS attributes.

## Consequences
- One-off access requests become role design questions, which is intentional friction.
- The role map ([`config/roles.example.json`](../../config/roles.example.json)) must be maintained alongside HR job codes.
- Manually managed groups still exist for exceptions; movers don't remove them, and access reviews cover them.
