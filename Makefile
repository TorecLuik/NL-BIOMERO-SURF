# Shortcuts for working the NL-BIOMERO stack.
#
# `make` on its own lists the targets. Nothing here is required: every target is
# a thin wrapper over docker compose or a script in scripts/, so you can always
# fall back to the underlying command.
#
# Targets taking a service use a colon, e.g. `make logs:omeroweb`.

COMPOSE     := sudo docker compose
LOGS_STACK  := sudo docker compose -f opensearch-compose.yml
WORKER_PY   := /opt/omero/server/venv3/bin/python

# Services are addressed as make logs/omeroweb, so stop make from treating the
# service name as a missing file target.
.PHONY: help up down ps build rebuild restart logs check smoke gpu config spider snellius psql psql-biomero
.DEFAULT_GOAL := help

help:
	@echo "Stack"
	@echo "  make up                 start everything, including the log stack"
	@echo "  make down               stop everything"
	@echo "  make ps                 status of all containers, including the log stack"
	@echo "  make build              rebuild images and restart"
	@echo "  make rebuild:SVC        rebuild and restart one service"
	@echo "  make restart:SVC        restart one service"
	@echo ""
	@echo "Inspect"
	@echo "  make logs               last 120 lines from every service"
	@echo "  make logs:SVC           follow one service"
	@echo "  make shell:SVC          interactive shell in a container"
	@echo "  make psql               psql into the OMERO database"
	@echo "  make psql-biomero       psql into the BIOMERO database"
	@echo ""
	@echo "Verify"
	@echo "  make check              preflight only, changes nothing"
	@echo "  make smoke              full deploy-and-smoke-test"
	@echo "  make gpu                effective Slurm params per workflow"
	@echo "  make config             BIOMERO settings as the worker resolves them"
	@echo ""
	@echo "Cluster"
	@echo "  make spider             ssh to Spider from inside the worker"
	@echo "  make snellius           ssh to Snellius (needs an ssh host first)"

# -- stack ------------------------------------------------------------------

up:
	$(COMPOSE) up -d
	$(LOGS_STACK) up -d

down:
	$(COMPOSE) down
	$(LOGS_STACK) down

# Both compose files share one project, so this already lists the log stack
# alongside the core services.
ps:
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}'

build:
	$(COMPOSE) up -d --build

# -- inspect ----------------------------------------------------------------

logs:
	@$(COMPOSE) logs --tail=120

# -- verify -----------------------------------------------------------------

check:
	@./scripts/bootstrap-prod.sh --check-only

smoke:
	@./scripts/bootstrap-prod.sh

# Effective Slurm parameters per workflow. Run this after touching GPU config:
# it is what catches a --gres and --gpus conflict before Spider rejects the job.
gpu:
	@$(COMPOSE) exec -T biomeroworker $(WORKER_PY) -c "\
from biomero import SlurmClient; import re;\
c = SlurmClient.from_config();\
print('%-32s %s' % ('workflow', 'effective GPU sbatch params'));\
print('-' * 78);\
[print('%-32s %s' % (w, ' '.join(re.findall(r'--(?:partition|gres|gpus)=\\S+', c.get_workflow_command(w, 'latest', 'probe', {})[0])) or '(none: default partition)')) for w in sorted(c.slurm_model_jobs)]" \
	2>/dev/null | grep -vE 'SAWarning|record_class|^\s*$$'

config:
	@$(COMPOSE) exec -T biomeroworker $(WORKER_PY) -c "\
from biomero import SlurmClient;\
c = SlurmClient.from_config();\
[print('%-28s %s' % (k, getattr(c, k))) for k in ('inject_gpu_flag','gpu_partition','gpu_gres','gpu_gpus','env_file_submission','slurm_image_pull_via_sbatch','apptainer_tmpdir','apptainer_cachedir','slurm_conversion_partition','slurm_script_repo')];\
print('%-28s %s' % ('use_gpu', dict(c.slurm_model_use_gpu)))" \
	2>/dev/null | grep -vE 'SAWarning|record_class|^\s*$$'

# -- cluster ----------------------------------------------------------------

# From inside the worker, so this exercises the same SSH path BIOMERO uses to
# submit jobs rather than the host's own SSH setup.
spider:
	$(COMPOSE) exec biomeroworker ssh spider

# Snellius integration exists but this deployment targets Spider, so no
# `snellius` SSH host is configured. Add one to .ssh/config and mirror the
# Spider settings in slurm-config-template.ini before using this.
snellius:
	@if $(COMPOSE) exec -T biomeroworker sh -lc 'grep -qi "^Host snellius" ~/.ssh/config' 2>/dev/null; then \
		$(COMPOSE) exec biomeroworker ssh snellius; \
	else \
		echo "No 'snellius' SSH host in the worker's ~/.ssh/config."; \
		echo "This deployment targets Spider. To bring Snellius back, add a Host"; \
		echo "block to .ssh/config and point slurm-config-template.ini at it."; \
	fi

# -- databases --------------------------------------------------------------

psql:
	$(COMPOSE) exec database psql -U $${POSTGRES_USER:-omero} -d $${POSTGRES_DB:-omero}

psql-biomero:
	$(COMPOSE) exec database-biomero psql -U $${BIOMERO_POSTGRES_USER:-biomero} -d $${BIOMERO_POSTGRES_DB:-biomero}

# -- service-scoped targets -------------------------------------------------
# A colon separator, not a slash: `logs/omeroweb` collides with the real
# logs/ directory, and make would treat the target as already built.
logs\:%:
	$(COMPOSE) logs -f $*

restart\:%:
	$(COMPOSE) restart $*

rebuild\:%:
	$(COMPOSE) up -d --build $*

shell\:%:
	$(COMPOSE) exec $* sh -l
