# ADR 005: Plan First, Apply Second, and Leave Ambiguous Cases to People

Author: Alex Scheaffer

Status: Accepted

## Context
Identity automation acts on real people's access. A bad export, a duplicated record or a wrong match can disable the wrong account or create duplicates, and those mistakes are visible to the whole organization within minutes.

## Decision
- Split automation into a **read-only planning step** (`New-IdentityPlan`) and a separate **apply step** (`Invoke-IdentityPlan`).
- Every apply function supports `-WhatIf`.
- Anything ambiguous becomes a **Review** item that automation never applies: missing or duplicate EmployeeIDs, possible name matches, orphaned accounts, rehires of disabled accounts, and deletion eligibility.
- Deletion is never automated.

## Rationale
- The plan can be reviewed, diffed and archived before anything changes
- Bad input shows up as an unusually large plan instead of a mass change
- People handle the cases that need judgment; automation handles the repetitive, deterministic ones
- The plan doubles as documentation of every decision

## Alternatives Considered
- **Fully automatic sync:** fastest, but a single bad export can offboard a department.
- **Fully manual tickets:** safe but slow and inconsistent; offboarding gaps are the main risk this project removes.

## Consequences
- Someone has to own the Review queue; it's part of the identity team's daily routine.
- New deployments run in plan-only mode until the Review queue is clean.
