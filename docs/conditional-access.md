# Conditional Access

Author: Alex Scheaffer

Conditional Access is where identity data turns into an access decision. Because policies are assigned to **role groups** fed by HRIS, a person's policy changes as soon as their HR record does. Nobody has to edit a policy when someone joins, moves or leaves.

## Policy set

| ID | Policy | Assigned to | Control |
|---|---|---|---|
| CA01 | Require MFA | All users | MFA on every sign-in |
| CA02 | Block legacy authentication | All users | Block protocols that can't do MFA |
| CA03 | Require a compliant or hybrid-joined device | `ROLE-All-Employees` | M365 and internal apps only from managed devices |
| CA04 | Contractor access | `ROLE-All-Contractors` | MFA, approved apps only, shorter sign-in frequency |
| CA05 | Risk-based sign-in | All users | Medium risk: MFA. High risk: block |
| CA06 | Privileged activation | PIM authentication context | Phishing-resistant MFA plus a compliant device to activate `PRIV-` groups |
| CA07 | Admin portals | Admin accounts | Phishing-resistant MFA, compliant device, no persistent browser session |

**Break-glass accounts** (`bg-*`) are excluded from every policy. They have long random passwords stored offline, and any sign-in raises an alert. They are also excluded from lifecycle automation.

## How lifecycle and Conditional Access work together

| Lifecycle event | Effect on access |
|---|---|
| Joiner | Role groups are assigned before day one, so device and MFA policies apply from the first sign-in |
| Mover | Role groups change, so contractor-to-employee (or the reverse) picks up the right policy on the next token refresh |
| Leaver | Account disabled and sessions revoked. Entra blocks token refresh, and Continuous Access Evaluation ends sessions in supported apps almost immediately |
| Privilege activation | Activating `PRIV-` membership triggers CA06 through the authentication context |

## Rollout

1. Create every policy in **report-only** mode.
2. Review sign-in logs for the impact on each policy for at least one business cycle.
3. Fix the gaps: unmanaged devices, legacy clients, service accounts that need named-location exceptions.
4. Enforce one policy at a time, starting with a pilot group.
5. Monitor Conditional Access failures in the SIEM, and review exclusions quarterly.
