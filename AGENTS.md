# NL-BIOMERO

SURF's deployment fork of the NL-BIOMERO demonstration stack. The SURF site
layer is `docker-compose.override.yml`; `docker-compose.yml` follows upstream.
Read `deployment_docs/upgrade-1.8.md` for this integration and use the existing
Make targets for server operations. Pushing code does not deploy the server.

## Read first

1. Shared rules for all component repositories:
   [`.agents/skills/nl-biomero-engineering/SKILL.md`](.agents/skills/nl-biomero-engineering/SKILL.md)
2. Independent PR review procedure:
   [`.agents/skills/nl-biomero-review/SKILL.md`](.agents/skills/nl-biomero-review/SKILL.md)
3. Stack, deployment, documentation and release runbook:
   [`.agents/skills/omero-biomero-expert/SKILL.md`](.agents/skills/omero-biomero-expert/SKILL.md)
   and the `references/` it routes to.
4. The documentation in `docs/` for the area you change: it describes the
   design and its rationale, which the skills link to rather than repeat.

## Layout

- `docker-compose*.yml`, `deployment_scenarios/`: stack definitions.
- `.env.example`: release pins and demo defaults; `.env` is private per-VM state.
- Attached volume `config/`: persistent Slurm, BIOMERO and group-mapping settings.
- `web/`, `biomeroworker/`: image builds, `slurm-config*.ini`, processor override.
- `biomero-importer/`: git submodule (BIOMERO.importer).
- `docs/`: Sphinx documentation. `plans/`: release plans and acceptance records.
- `scripts/acceptance/`: reusable acceptance runners.

## Build and check

- Docs: `cd docs && sphinx-build -b html . _build_local` (current branch only).
- Stack: `make check`, then authorized `make deploy`; see the SURF runbook.
- Site integration tests: `python -m unittest discover -s tests -p test_surf_upgrade.py`.
- CI: `.github/workflows/` builds the docs and the Docker images.

## Related repositories

biomero (core), biomero-scripts, BIOMERO.importer, OMERO.biomero,
BIOMERO.shallower, biomero-schema, BIOMERO.ZarrViewer, all under
<https://github.com/NL-BioImaging>. Each has its own `AGENTS.md`.
