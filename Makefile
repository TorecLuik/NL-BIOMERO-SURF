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
.PHONY: help provision init link-config deploy doctor set-host docs-dates reference-data up down ps build rebuild restart logs check smoke gpu config spider snellius psql psql-biomero
.DEFAULT_GOAL := help

help:
	@echo "Setup"
	@echo "  make provision          prepare a fresh VM: packages, submodule, nginx"
	@echo "  make init               fetch submodules and run preflight"
	@echo "  make deploy             set up and start the stack, then smoke test"
	@echo "  make doctor             diagnose configuration drift, changes nothing"
	@echo "  make link-config        link .env/.ssh/slurm-config to the storage volume"
	@echo "  make set-host HOST=fqdn set the per-VM public hostname"
	@echo "  make docs-dates         refresh the date stamps in deployment_docs/"
	@echo "  make reference-data     re-download and verify the test datasets"
	@echo ""
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

# -- setup ------------------------------------------------------------------

# Host preparation for a fresh VM. Stops before deploying, because the secrets
# and the SURF Research Cloud port rules cannot be set from inside the VM.
provision:
	@./scripts/provision-vm.sh

# A fresh clone has an empty biomero-importer/, and the importer image builds
# from that directory, so this has to run before the first build.
init:
	git submodule update --init --recursive
	@$(MAKE) --no-print-directory link-config
	@$(MAKE) --no-print-directory doctor

# The stack's state -- both databases, the OMERO repository, L-Drive and the
# secrets -- lives on an attached storage volume at $$OMERO_DATA_PATH, so that
# it survives the VM. A fresh clone has no secrets: they arrive with the volume,
# and this points the repo at them. Idempotent, and safe to re-run.
#
# Existing real files are left alone rather than replaced, so running this on a
# machine that predates the volume layout reports them instead of destroying
# them.
link-config:
	@path=$$(grep -hE '^OMERO_DATA_PATH=' .env 2>/dev/null | tail -1 | cut -d= -f2-); \
	[ -n "$$path" ] || path=$$(grep -hE '^OMERO_DATA_PATH=' .env.shared 2>/dev/null | tail -1 | cut -d= -f2-); \
	if [ -z "$$path" ]; then echo "  [FAIL] OMERO_DATA_PATH is not set in .env or .env.shared"; exit 1; fi; \
	if [ ! -d "$$path/config" ]; then \
		echo "  [FAIL] $$path/config does not exist."; \
		echo "         Is the storage volume attached? See deployment_docs/storage-architecture.md"; \
		exit 1; \
	fi; \
	rc=0; \
	for pair in ".env:.env" ".ssh:.ssh" "slurm-config.ini:web/slurm-config.ini"; do \
		src="$$path/config/$${pair%%:*}"; dst="$${pair##*:}"; \
		if [ -L "$$dst" ]; then \
			if [ "$$(readlink "$$dst")" = "$$src" ]; then printf '  [ ok ] %s\n' "$$dst"; \
			else ln -sfn "$$src" "$$dst"; printf '  [ ok ] %s (repointed)\n' "$$dst"; fi; \
		elif [ -e "$$dst" ]; then \
			printf '  [warn] %s is a real file, not a link; move it to %s and re-run\n' "$$dst" "$$src"; rc=1; \
		elif [ ! -e "$$src" ]; then \
			printf '  [warn] %s missing on the volume; nothing to link\n' "$$src"; rc=1; \
		else \
			ln -sfn "$$src" "$$dst"; printf '  [ ok ] %s (linked)\n' "$$dst"; \
		fi; \
	done; \
	exit $$rc

deploy:
	@./scripts/bootstrap-prod.sh

# Read-only. Checks the things that have actually gone wrong here: a missing or
# stale submodule, pins that disagree between files, and images that do not
# match the pins they were supposedly built from.
doctor:
	@echo "== Submodule =="
	@if [ -f biomero-importer/Dockerfile ]; then 		printf '  [ ok ] biomero-importer checked out at %s\n' "$$(cd biomero-importer && git describe --tags 2>/dev/null || echo unknown)"; 		pin=$$(grep -E '^BIOMERO_IMPORTER_VERSION=' .env.shared | cut -d= -f2); 		have=$$(cd biomero-importer && git describe --tags 2>/dev/null | sed 's/^v//'); 		if [ "$$have" = "$$pin" ]; then printf '  [ ok ] submodule matches BIOMERO_IMPORTER_VERSION (%s)\n' "$$pin"; 		else printf '  [warn] submodule is %s but pin is %s; the importer image would build from the wrong source\n' "$$have" "$$pin"; fi; 	else 		echo "  [FAIL] biomero-importer/ is empty; run: make init"; 	fi
	@echo "== Pins =="
	@for v in BIOMERO_VERSION OMERO_BIOMERO_VERSION BIOMERO_IMPORTER_VERSION OMERO_FORMS_VERSION; do 		sh=$$(grep -E "^$$v=" .env.shared 2>/dev/null | cut -d= -f2); 		lo=$$(grep -E "^$$v=" .env 2>/dev/null | cut -d= -f2); 		if [ -z "$$lo" ]; then printf '  [ ok ] %-26s %s (.env.shared only)\n' "$$v" "$$sh"; 		elif [ "$$sh" = "$$lo" ]; then printf '  [ ok ] %-26s %s\n' "$$v" "$$sh"; 		else printf '  [warn] %-26s .env.shared=%s but .env=%s; .env wins at build time\n' "$$v" "$$sh" "$$lo"; fi; 	done
	@echo "== Installed vs pins =="
	@pin=$$(grep -E '^BIOMERO_VERSION=' .env 2>/dev/null || grep -E '^BIOMERO_VERSION=' .env.shared); pin=$${pin#*=}; 	got=$$($(COMPOSE) exec -T biomeroworker $(WORKER_PY) -m pip list 2>/dev/null | awk '/^biomero /{print $$2}'); 	if [ -z "$$got" ]; then echo "  [warn] worker not running; start it with: make up"; 	elif [ "$$got" = "$$pin" ]; then printf '  [ ok ] worker biomero %s matches pin\n' "$$got"; 	else printf '  [warn] worker biomero is %s but pin is %s; rebuild with: make build\n' "$$got" "$$pin"; fi
	@echo "== Required files =="
	@for f in .env .ssh/id_rsa .ssh/config web/slurm-config.ini; do 		if [ -e "$$f" ]; then printf '  [ ok ] %s\n' "$$f"; else printf '  [FAIL] %s missing\n' "$$f"; fi; 	done
	@echo "== Public hostname =="
	@host=$$(hostname -f 2>/dev/null); \
	envfile=.env; [ -f "$$envfile" ] || envfile=.env.shared; \
	bad=0; \
	for k in OMERO_CSRF_TRUSTED_ORIGINS METABASE_SITE_URL OBSERVABILITY_ROOT_URL; do \
		val=$$(grep -E "^$$k=" "$$envfile" 2>/dev/null | cut -d= -f2-); \
		if [ -z "$$val" ]; then printf '  [warn] %s is not set in %s\n' "$$k" "$$envfile"; bad=1; \
		elif printf '%s' "$$val" | grep -qF "$$host"; then printf '  [ ok ] %-28s matches %s\n' "$$k" "$$host"; \
		else printf '  [warn] %-28s does not contain %s\n' "$$k" "$$host"; bad=1; fi; \
	done; \
	if [ "$$bad" = "1" ]; then echo "         these are per-VM values; fix them with: make set-host HOST=$$host"; fi
	@echo "== Public URL =="
	@host=$$(hostname -f 2>/dev/null); \
	code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -k "https://$$host/webclient/login/" 2>/dev/null); \
	case "$$code" in \
		200|302) printf '  [ ok ] https://%s/webclient/login/ answers %s\n' "$$host" "$$code" ;; \
		000|"")  printf '  [warn] https://%s did not answer; is the nginx location block installed?\n' "$$host"; \
		         echo "         sudo cp nginx/omero-web.conf /etc/nginx/app-location-conf.d/ && sudo nginx -t && sudo systemctl reload nginx" ;; \
		*)       printf '  [warn] https://%s/webclient/login/ returned %s\n' "$$host" "$$code" ;; \
	esac
	@echo "== Importer image =="
	@pin=$$(grep -E '^BIOMERO_IMPORTER_VERSION=' .env.shared | cut -d= -f2); \
	got=$$(sudo docker run --rm --entrypoint sh nl-biomero-biomero-importer:latest -c '/opt/conda/envs/auto-import-env/bin/pip list 2>/dev/null' 2>/dev/null | awk '/^biomero-importer /{print $$2}'); \
	if [ -z "$$got" ]; then echo "  [warn] importer image not built yet"; \
	elif [ "$$got" = "$$pin" ]; then printf '  [ ok ] importer image is %s\n' "$$got"; \
	else printf '  [warn] importer image is %s but the submodule pin is %s\n' "$$got" "$$pin"; \
	     echo "         the image builds from biomero-importer/, so rebuild it: make rebuild:biomero-importer"; fi
	@echo "== Metabase app DB =="
	@if grep -q 'MB_DB_TYPE: postgres' docker-compose.yml; then \
	  printf '  [ ok ] compose points Metabase at Postgres\n'; \
	  got=$$(sudo docker exec nl-biomero-database-biomero-1 psql -U $${BIOMERO_POSTGRES_USER:-biomero} -d metabase -tAc 'SELECT count(*) FROM report_dashboard' 2>/dev/null); \
	  if [ -n "$$got" ]; then printf '  [ ok ] metabase database reachable, %s dashboards\n' "$$got"; \
	  else echo "  [warn] cannot read the metabase database; is database-biomero up?"; fi; \
	  for v in METABASE_IMPORTS_DB_PAGE_DASHBOARD_ID METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID; do \
	    id=$$(grep -E "^$$v=" .env 2>/dev/null | cut -d= -f2); \
	    [ -n "$$id" ] || continue; \
	    ok=$$(sudo docker exec nl-biomero-database-biomero-1 psql -U $${BIOMERO_POSTGRES_USER:-biomero} -d metabase -tAc "SELECT enable_embedding FROM report_dashboard WHERE id=$$id" 2>/dev/null); \
	    case "$$ok" in t) printf '  [ ok ] %-40s id %s embeddable\n' "$$v" "$$id" ;; \
	      f) printf '  [warn] %s id %s exists but embedding is off\n' "$$v" "$$id" ;; \
	      *) printf '  [warn] %s id %s not found in Metabase\n' "$$v" "$$id" ;; esac; \
	  done; \
	  if [ -d metabase/metabase.db ]; then \
	    echo "  [warn] metabase/metabase.db/ is leftover H2 data; Metabase no longer reads it"; \
	    echo "         remove it once you are satisfied the migration held"; fi; \
	else \
	  echo "  [warn] Metabase is still on H2; migrate to Postgres, see the expert skill"; \
	fi
	@echo "== Container log caps =="
	@uncapped=$$(sudo docker ps --format '{{.Names}}' 2>/dev/null | while read n; do \
	    o=$$(sudo docker inspect -f '{{.HostConfig.LogConfig.Config}}' "$$n" 2>/dev/null); \
	    case "$$o" in *max-size*) ;; *) echo "$$n";; esac; done); \
	if [ -z "$$uncapped" ]; then echo "  [ ok ] every running container has a log size cap"; \
	else printf '  [warn] uncapped container logs: %s\n' "$$(echo $$uncapped | tr '\n' ' ')"; \
	     echo "         these grow without bound; re-create them: make up"; fi

# Refresh the Created/last updated stamps in deployment_docs/ from git history.
# The stamp goes stale as soon as a doc is edited, so run this before committing
# documentation changes.
#
# --follow is needed so a directory rename does not reset every Created date.
# Note the "last updated" stamp keys off the working tree being dirty, so a
# bulk change that touches every file -- a rename, a sed across the directory --
# will stamp all of them. Check `git diff` before committing the result.
docs-dates:
	@for f in deployment_docs/*.md; do \
		c=$$(git log --follow --diff-filter=A --format=%ad --date=short -- "$$f" | tail -1); \
		m=$$(git log -1 --format=%ad --date=short -- "$$f"); \
		[ -n "$$c" ] || continue; \
		if git diff --quiet -- "$$f" && git diff --cached --quiet -- "$$f"; then :; else m=$$(date +%F); fi; \
		if head -4 "$$f" | grep -q '^\*Created '; then \
			sed -i -E "s|^\*Created .*|*Created $$c · last updated $$m*|" "$$f"; \
		else \
			sed -i "1a\\\n*Created $$c · last updated $$m*" "$$f"; \
		fi; \
		printf '  %-38s %s -> %s\n' "$$(basename $$f)" "$$c" "$$m"; \
	done

# Re-download the public reference datasets used by the pipeline tests, and
# verify them. Safe to re-run; see deployment_docs/reference-data.md.
reference-data:
	@./scripts/fetch-reference-data.sh

# Rewrite the three per-VM hostname values. Run after cloning onto a new host:
# a wrong CSRF origin lets the stack start but blocks OMERO.web login.
#
# Only .env is touched. It is per-VM, gitignored, and lives on the storage
# volume, and it overrides .env.shared for all three values -- so writing them
# into the tracked .env.shared as well only dirtied the working tree with one
# machine's hostname.
set-host:
	@test -n "$(HOST)" || { echo "usage: make set-host HOST=my.vm.example.org"; exit 2; }
	@if [ ! -f .env ]; then \
		echo "  [FAIL] .env does not exist; run make link-config first"; \
		exit 1; \
	fi
	@sed -i -E "s|^OMERO_CSRF_TRUSTED_ORIGINS=.*|OMERO_CSRF_TRUSTED_ORIGINS=[\"https://$(HOST)\"]|" .env
	@sed -i -E "s|^METABASE_SITE_URL=.*|METABASE_SITE_URL=https://$(HOST)/metabase|" .env
	@sed -i -E "s|^OBSERVABILITY_ROOT_URL=.*|OBSERVABILITY_ROOT_URL=https://$(HOST)/logs/|" .env
	@printf 'updated .env\n'
	@echo "Restart to apply: make up"

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
