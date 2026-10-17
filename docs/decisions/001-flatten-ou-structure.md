# ADR 001: Flatten the OU Structure

Author: Alex Scheaffer

Status: Accepted

## Context
The directory's OUs mirrored the org chart (location → department → team), with GPOs linked at many levels and inheritance blocked in places. A transfer meant moving the account, which silently changed the policy applied to it. Effective policy was hard to predict, and every reorganization meant restructuring the directory.

## Decision
Organize OUs by **object type, administrative tier and delegation boundary** only. Store department, location and title as attributes sourced from HRIS. Target user GPOs with security filtering on `GPO-*` groups instead of OU placement.

## Rationale
- A transfer becomes an attribute change, not an object move
- Effective policy is determined by group membership, which is visible and auditable
- Reorganizations change data, not directory structure
- Delegation is set in a few well-known places
- Lifecycle automation becomes practical: it never needs to know the org chart's OU layout

## Alternatives Considered
- **Keep the existing tree and clean it up:** fixes today's drift but keeps the coupling between org chart and policy.
- **Fully flat (everything in one OU):** loses tiered delegation and separate GPO scope for admins, servers and kiosks.

## Consequences
- Every GPO needs an explicit target group; the migration includes mapping each GPO's intended audience.
- Attribute quality matters, which makes HRIS-fed attributes ([ADR 002](002-employeeid-as-identity-anchor.md)) a prerequisite.
- Objects move in waves, with before/after RSoP comparison.
