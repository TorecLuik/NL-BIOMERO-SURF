# SURF preparation for 1.8

*Created 2026-11-23 · last updated 2026-11-23*

Coordination: [NL-BIOMERO#131](https://github.com/NL-BioImaging/NL-BIOMERO/issues/131).
Branch `surf/prep-1.8` starts at production baseline
`447f898bdacf1f39e0ed032ad53f08896b179714`. This is preparation of the existing
2.8.2 deployment; beta.16 arrives through the separate integration branch.
No container restart or runtime configuration render is part of this work.

## Preserve administrator Slurm settings

The template now captures the live configuration, including cisegmentation
v0.6.4, cideconvolve v3.3.0, cidenoise v0.1.0, their resource requests, and the
plate/Zarr/dual-mode UI lists. Existing versions and resource requests remain
unchanged. Project paths retain `${SPIDER_PROJECT}` parameterization.

Validation renders with envsubst in memory using only SPIDER_USER and
SPIDER_PROJECT from .env, then compares parsed INI sections and all keys/values
against the runtime file: **7 sections, 110 settings match**. The live file
remains unchanged, SHA256
`f292c9eef1c0194135162d6e669ad961818154734163ac250acff287c717e6e7`.
Comments/formatting are deliberately not compared. `make config` and `make gpu`
provide the effective running-client baseline without submission.

Preserved assignments requiring separate execution review:

- StarDist and StarDist5D now inherit MIG GPU requests from the live settings.
  Historical tests documented missing CUDA 10/cuDNN 7 dependencies in these
  containers. Do not infer GPU usability from allocation alone.
- Cellpose and deconvolve_plate retain explicit full-A100 partition/GRES, but
  the administrator removed their explicit use_gpu entries. Preserve that
  distinction: resource allocation alone does not prove --nv injection.
- cisegmentation, cideconvolve and cidenoise inherit the live MIG default.
  GPU compatibility and complete effective CPU/memory requests need selected
  integration tests; this preparation does not submit jobs.

## Backup repair

The 2026-11-23 service journal identifies the actual failure:
`tar: omero/Files/Dir-005: file changed as we read it`. Tar exited 1 while
archiving the live repository; set -e stopped the script before secrets,
checksums and COMPLETE. Preserve that incomplete set as evidence.

The existing backup script now retries the OMERO archive up to three times
only for tar exit 1. Success requires a subsequent exit 0. Fatal errors stop
immediately, and repeated changes leave an incomplete set without COMPLETE.
Shell syntax and simulated success, retry-success, retry-exhaustion and fatal
error cases are checked before live validation through make backup and
make backup-verify.

Nightly captures still consist of independent database dumps, OMERO repository
and configuration archives. They are not an atomic recovery point or a tested
restore. L-Drive (including linked source/result pixels) is persistent production
storage and remains excluded. Same-volume backups do not protect against loss
of the attached volume; a migration needs a separately planned consistent
recovery point covering L-Drive and off-volume protection.

## October tracking investigation

Task `65b93787-896b-4048-9f44-05115fb3b650` is an unfinished
SLURM_Import_Results.py task created on 2026-10-14 at 09:45:19 UTC. Its event
stream contains TaskCreated and TaskStarted, with no terminal task event.
Its parent workflow `579506e7-ac77-4a3c-a3e9-d8b8f9e3ef67` (stardist5d)
recorded WorkflowFailed at 09:45:23 UTC that day and remains FAILED at 50%.
The preceding compute task completed. Current checks show zero open imports
and zero jobs in the Spider queue.

Disposition: stale child-task tracking under a terminal failed parent, not
current compute work. No tracking or event records were changed. The existing
active-work gate correctly continues to flag the missing terminal task event.
If a correction is approved, reconcile the OMERO import failure evidence and
append a truthful terminal failure via WorkflowTracker.fail_task; preserve
history and do not directly edit the projection or fabricate successful output.
The integration must address terminal child-task recording on parent failure.
