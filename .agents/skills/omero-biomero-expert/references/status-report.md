# Operational status reports

Read this reference for every deployment-status, smoke-audit, post-deployment, and post-integration-test report. Lead with the outcome. Use current evidence and a timestamp with timezone. Do not expose secrets or sensitive configuration.

## Classification

| Result | Meaning |
| --- | --- |
| PASS | Verified with current evidence. |
| WARN | Operational, but currently degraded or exposed to a material risk. |
| FAIL | Required functionality is unavailable. |
| NOT TESTED | An applicable check was skipped or evidence is missing. |
| N/A | The dimension does not apply to this operation. |

Keep current service state, audit findings, validation coverage, deployment result, and Git delivery independent. A running container alone does not prove application readiness. Never count an unavailable or skipped check as PASS. An unavailable check reduces validation coverage; it does not by itself prove an operational failure.

For a read-only status request, deployment result is **N/A**, with “No deployment or restart was requested.” Git delivery is **N/A**, with “No changes were delivered during this audit,” unless delivery was requested. A dirty worktree belongs in audit findings or operational notes; it is not a failed Git delivery. Never use a “deployment live” heading when no deployment occurred.

Use icons consistently: ✅ verified success; ⚠️ current warning or degraded condition; ❌ failure or unavailable required functionality; ⏭️ skipped or not tested; ℹ️ useful context without current negative impact. Do not attach warning or failure icons to N/A.

Use compact tables and short bullets. Keep evidence quantitative where possible, such as `11/11 services running`, and do not repeat the same evidence in multiple sections. Separate warnings, expected operational notes, and skipped validation. Every operator follow-up needs an action and a concrete acceptance criterion. Include only genuine remaining actions.

## Pure read-only deployment status

Use this structure for a pure read-only status audit. A smoke-audit report follows the same structure, with the audit type identifying the read-only smoke scope.

```markdown
# <✅ | ⚠️ | ❌> PROD <operational | degraded | unavailable> — <short outcome>

Generated: <timestamp and timezone>
Environment: <environment>
Audit type: Read-only deployment status

| Dimension | Result | Summary |
| --- | --- | --- |
| Current service state | | |
| Audit findings | | |
| Validation coverage | | |
| Deployment result | N/A | No deployment or restart was requested |
| Git delivery | N/A | No changes were delivered during this audit |

## Verified

| Area | Result | Evidence |
| --- | --- | --- |
| Containers | | |
| Databases | | |
| OMERO | | |
| External access | | |
| Importer | | |
| Analyzer/HPC | | |
| Tracking/Metabase | | |
| Logging | | |
| Persistent storage | | |
| Disk capacity | | |
| Boot persistence | | |
| Backup verification | | |

## Warnings

- <current degraded condition or material operational, recovery, security, or future-change risk; write `None` when there are none>

## Operational notes

- <expected or fully handled context without current negative impact; write `None` when there are none>

## Validation not run

- ⏭️ <applicable check not performed; write `None` when there are none>

## Operator follow-up

| Priority | Area | Action | Acceptance criterion |
| --- | --- | --- | --- |
| | | | |

<Write `None` instead of the table if no actions remain.>

## Changes performed

None — read-only audit.
```

Omit a Verified row only when its area is genuinely inapplicable. If an applicable check was not run, retain a **NOT TESTED** result where useful and explain the missing evidence under Validation not run. Include authenticated behavior, imports, workflows, restart or reboot recovery, build provenance, off-host backup verification, and other material checks there when not performed. Do not present skipped validation as a warning.

Choose the heading from the current operational result: ✅ operational when required services are verified ready and no current material warning remains; ⚠️ degraded when the stack is operational with a current warning or material risk; ❌ unavailable when required functionality is unavailable. State the scope and limits of the evidence. For a read-only audit, write the Changes performed line **exactly** as shown.

A healthy single-node OpenSearch cluster may legitimately be yellow because replicas cannot be assigned. If all primary shards are available and ingestion works, describe that as an operational note, not an automatic warning. If primary shards or ingestion are unavailable, classify the actual fault.

## Post-deployment report

For an actual deployment, use a distinct heading:

```markdown
# <✅ | ⚠️ | ❌> PROD deployment <live | degraded | failed> — NL-BIOMERO <version>
```

Start with Generated, Environment, release or commit, deployment window, and total elapsed time. Use the same five-dimension summary table, now reporting the **actual** deployment result and Git-delivery result. Then include these sections in order:

1. Live handoff: current user-facing and operational state.
2. Delivered changes: what was changed and which version or commit is running.
3. Verification: compact evidence table with result, probe, time, and limits.
4. Warnings: current degraded conditions and material risks, or `None`.
5. Operational notes: expected context without current negative impact, or `None`.
6. Validation not run: each item prefixed `⏭️`, or `None`.
7. Operator follow-up: priority, area, action, and acceptance criterion, or `None`.
8. Detailed deployment status audit: the applicable Verified areas from the read-only structure, assessed after deployment.

Do not claim a successful deployment merely because the command exited zero. Base the deployment result on final readiness evidence. Report incomplete checks as NOT TESTED. Distinguish the deployment result from the live service state and from Git delivery.

## Post-integration-test report

Use the five-dimension summary and the same warning, note, skipped-validation, and follow-up rules. State what test tier ran and whether a deployment also occurred; use N/A for deployment and Git delivery when neither happened. Include fixture identity, unique isolated test location, exact created paths and object/import/workflow/Slurm identifiers, state transitions, final usability evidence, cleanup results, phase durations, and total runtime. Verify final pixels or previews and metadata where applicable, not only a DONE state. Report retained failed-run evidence and any cleanup that could not be verified. Never imply a passing test covered formats, workflows, or recovery paths it did not exercise.
