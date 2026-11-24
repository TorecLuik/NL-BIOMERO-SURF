# SURF release integration and server handoff

*Created 2026-11-23 · last updated 2026-11-23*

This is the candidate upgrade from `surf/prep-1.8` to NL-BIOMERO
`v1.8.0-beta.16`. It implements the code/configuration part of
[NL-BIOMERO#131](https://github.com/NL-BioImaging/NL-BIOMERO/issues/131).
It is not evidence of a deployed or accepted upgrade. SURF preparation and
the last running baseline are recorded in [prep-1.8.md](prep-1.8.md).
The broader upstream production proposal remains #132.

## How the branch follows upstream

`docker-compose.yml` is the upstream release file. Compose automatically adds
`docker-compose.override.yml`, which retains SURF's attached-volume layout,
private configuration, Postgres Metabase, loopback web ports and logging.
The existing Make targets load both files. Do not select only the upstream
file with `-f docker-compose.yml`: that omits the SURF layer. Compose must
support `!override` (introduced in 2.24.4); check `docker compose version`.

The component set is pinned in `.env.example`: core `2.9.0b33`, scripts
`v2.9.0-beta.33`, OMERO.biomero `1.7.0b20`, importer `1.5.0-beta.15`,
viewer `0.8.2` and Zarr pixel buffer `0.7.2`. The importer gitlink selects
`0f461a7a43731545297cc1f40a6413c1e418b277`. Web and worker install the same
core/importer pins together, without the old dependency-conflict workaround.
The empty-ROI-list and generated-output site patches are removed in favor
of the release implementations; validate those behaviors in pipeline tests.

`OMERO_DATA_PATH` still means the volume root. Database files, `/OMERO` and
`/data` retain their existing host paths. The viewer adds an internal nginx
service on loopback port 4080, preserving HTTPS information from the host
proxy. Metabase remains on its existing Postgres application database.

## Configuration transition

### Nested Podman VFS on Docker

VFS is the importer's inner Podman storage driver. The outer runtime differs
from ACC's rootless Podman setup: SURF uses Docker with an enforcing
`docker-default` AppArmor profile. That profile denies mount operations,
including making `/` recursively private during image-layer extraction. SURF
reported this failure while seccomp was already unconfined; no corresponding
kernel denial was recorded, so the server still needs the controlled A/B check.

The candidate site override adds only `apparmor=unconfined` for the importer.
It keeps privileged mode off, adds no capabilities/devices and retains the
existing image, VFS storage and component pins. This is an AppArmor exception
for the nested-container service, not a restricted custom AppArmor profile.
Other services retain their existing profiles. Source of the mount restriction:
[Docker's default profile](https://github.com/moby/profiles/blob/main/apparmor/template.go).

Run the controlled check from the candidate checkout with an already-built
importer image ID (obtain that ID from the live checkout without displaying its
environment):

```sh
sudo python3 tests/test_podman_vfs.py --image <importer-image-id> --require-apparmor
```

This creates two uniquely named disposable containers with no network or host
binds and fresh anonymous stores. It checks rootless VFS, imports the same tiny
layer with the site security options, and repeats with only AppArmor changed
to `docker-default`. The candidate must unpack successfully; the default-profile
control must reproduce a remount permission denial. The script removes only
its own containers and anonymous volumes. It does not start the application,
submit imports, recreate live services or change the host's AppArmor policy.

After that check passes on SURF, validate the actual failed preprocessing case
in the existing isolated rehearsal using the candidate importer configuration.
Record the image ID, effective AppArmor profile and result before applying the
reviewed change to the live importer through the existing deployment procedure.
Layer extraction alone does not prove converter execution or end-to-end import.

### Migrating runtime settings

`make upgrade-config CHECK=1` reports proposed file paths and environment key
names, without displaying values or writing files. Exit 1 means changes are
pending, 0 means current, and 2 means a validation error.
`make upgrade-config` applies the changes without starting services:

- Update release version pins and add missing `.env.example` settings. Keep
  existing secrets, site values and explicit feature choices.
- Copy the current Slurm and BIOMERO files from `web/` into the attached
  volume's `config/` if their new targets do not already exist. Preserve
  workflows, GPU assignments and admin edits. New installs seed from examples.
- Create `config/group-mappings.json` from the existing BIOMERO file's
  `group_mappings`. The release reads this separate file; upstream demo group
  IDs must not replace SURF's mappings.
- On the first layout transition, move the former Slurm environment overrides
  into the INI with their effective precedence (including image-pull resources
  and Apptainer paths). Subsequent runs preserve UI edits. Then add missing
  Slurm controls. Advance only the three unchanged legacy
  preprocessing recipes to release defaults; leave custom converters intact.

The paths are named by `SLURM_CONFIG_HOST_PATH`, `BIOMERO_CONFIG_HOST_PATH` and
`GROUP_MAPPINGS_HOST_PATH`. Keep them under the attached volume's `config/`
so the existing backup includes them. Routine deployment no longer renders
over these files. `make render-config` is an explicit reset of the Slurm INI
from the template. `make init` seeds missing configuration and reuses existing
volume configuration on a replacement VM.

New demo defaults enable detached workflows, shallow Zarr, remote shallowing
and the viewer. An existing false flag remains false. Inspect effective flags
and any preserved custom preprocessing recipes before testing feature coverage.

## Next work for the SURF agent

First validate the published candidate without changing the running checkout:

1. Fetch `surf/upgrade-1.8` into a separate worktree and record its full SHA.
   Check Compose compatibility and run the configuration tests there:
   `python3 -m unittest discover -s tests -p test_surf_upgrade.py -v`.
2. From that worktree run
   `make upgrade-config ROOT=/opt/omero/NL-BIOMERO CHECK=1`.
   Report the planned paths/key names and whether the mounted volume and
   legacy configs are readable. Do not print values or apply the plan yet.
3. Confirm the next scheduled backup and `make backup-verify` using the
   running preparation checkout. Use the existing backup/restore procedure
   to rehearse restoration into isolated scratch databases/storage, with
   distinct ports and no live consumers or Spider submission. Include all
   three databases, configuration and link targets needed for selected images.
   Record the exact isolated paths and restore results before cleanup.
4. Report the stale October task separately from active work. The existing
   `--require-idle` gate still blocks on its unfinished task record. Do not
   delete rows or bypass the gate. A truthful terminal-task reconciliation
   through the tracking API requires a separate, explicit operator decision.

Stop there and report the candidate SHA, configuration plan, restore evidence
and remaining blockers. A passed configuration test is not permission to
restart the public service.

## Agreed maintenance window

After operator approval and resolving the active-work gate:

1. Check live imports, workflows and Spider jobs. Use `make backup` and
   `make backup-verify` for the existing recovery mechanism. Record the
   previous Git SHA and selected backup; preserve the previous private `.env`
   and runtime configuration through that backup. No Docker image export is
   needed. Verify that the selected recovery set covers the intended rollback.
2. Apply the reviewed configuration plan from the candidate worktree using
   `make upgrade-config ROOT=/opt/omero/NL-BIOMERO`. Then switch the live
   checkout to the exact reviewed candidate, preserving unrelated local edits.
   Run `git submodule update --init --recursive`, `make check`, and
   `make deploy`. Do not use reset/clean to force the checkout transition.
3. Run the release's Slurm Init for the existing Spider paths and inspect its
   completion/download results. Do not reset tracking projections or stored
   histories as a routine upgrade step. Exercise old history replay on the
   restored copy first; record any migration required by the pinned components.
4. Run `make smoke`, `make doctor`, `make config` and `make gpu`. Expect the
   additional viewer service. Check web login, authorized Zarr access, admin
   configuration persistence, dashboards and unchanged existing image pixels.
5. Select isolated fixtures from [pipeline-tests.md](pipeline-tests.md) and
   exercise import, preprocessing, CPU and selected GPU workflows, result
   import without ROI targets, empty-output failure, shallow output/viewing,
   and detached completion/recovery. Record IDs and exact results. Preserve
   old user data and failed-run evidence.

Git rollback restores code only. If new code has written events or changed
data/schema, returning to the previous SHA is not a proven data rollback.
Use the rehearsed restore with services stopped where needed. Same-volume
online backups are not atomic; L-Drive remains outside the nightly archive.
This integration adds no claim of off-volume protection.

## Following release updates

Merge the next chosen upstream tag into this branch, retaining the SURF
override. Update the release pins in `.env.example` and importer gitlink as a
coordinated set. Review new upstream mounts/environment keys against the site
override and run the configuration and processor tests. Review the output of
`make upgrade-config CHECK=1`, then use the same approved maintenance flow.
The next beta/stable transition is the practical test of repeatable updates;
#131 stays open until server acceptance and that transition are demonstrated.
