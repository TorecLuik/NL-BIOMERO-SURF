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
.PHONY: help provision init-env init render-config logs-retention metabase-dashboards export-metabase-dashboards deploy doctor audit backup-verify active-work set-host adopt-volume new-key show-key logs-auth install-services backup docs-dates reference-data up down ps build rebuild restart logs check smoke gpu config spider snellius psql psql-biomero
.DEFAULT_GOAL := help

help:
	@echo "Setup"
	@echo "  make provision          prepare a fresh VM: packages, submodule, nginx"
	@echo "  make init-env           write .env, generating every secret"
	@echo "  make init               submodules, runtime config, hostname, /logs auth"
	@echo "  make deploy             set up and start the stack, then smoke test"
	@echo "  make doctor             diagnose configuration drift, changes nothing"
	@echo "  make audit              read-only production status audit"
	@echo "  make active-work        read-only imports, tasks and Spider queue"
	@echo "  make backup-verify      verify latest backup without restoring"
	@echo "  make render-config      render slurm-config.ini from the template"
	@echo "  make set-host HOST=fqdn set the per-VM public hostname"
	@echo "  make adopt-volume       record an existing volume's database credentials"
	@echo "  make new-key            generate the cluster SSH key (FORCE=1 to replace)"
	@echo "  make show-key           print the public half of the cluster key"
	@echo "  make logs-auth          create the basic-auth file nginx needs for /logs"
	@echo "  make metabase-dashboards rebuild the embedded Metabase dashboards"
	@echo "  make logs-retention     apply the OpenSearch log retention policy"
	@echo "  make docs-dates         refresh the date stamps in deployment_docs/"
	@echo "  make reference-data     re-download and verify the test datasets"
	@echo "  make install-services   start at boot, nightly backup (systemd)"
	@echo "  make backup             run the nightly backup now"
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
	@echo "  make smoke              read-only smoke checks of the running stack"
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

# .env, with every secret generated. Only the Spider account has to be supplied,
# because it is the one value that means something outside this VM. Refuses to
# overwrite an existing .env, whose database passwords may be the only record of
# what unlocks the storage volume.
init-env:
	@./scripts/init-env.sh $(if $(SPIDER_USER),--user $(SPIDER_USER),) $(if $(SPIDER_PROJECT),--project $(SPIDER_PROJECT),) $(if $(FORCE),--force,)

# Everything between filling in .env and deploying. Each step derives what it
# needs from .env or the host, so there is no decision to make between them, and
# all of them are safe to re-run.
#
# HOST overrides the public hostname, which otherwise comes from hostname -f.
init:
	git submodule update --init --recursive
	@$(MAKE) --no-print-directory render-config
	@$(MAKE) --no-print-directory set-host HOST=$(if $(HOST),$(HOST),$$(hostname -f))
	@$(MAKE) --no-print-directory logs-auth
	@$(MAKE) --no-print-directory doctor

# slurm-config.ini is rendered from the committed template and the values in
# .env, so it is reproducible per VM rather than state that travels with the
# data. make deploy renders it too; this is for setting it up before deploying.
#
# The OMERO.biomero admin UI can write this file from the omeroweb container.
# Those edits are deliberately not preserved -- the next render overwrites
# them -- so a change worth keeping belongs in web/slurm-config-template.ini.
render-config:
	@./scripts/render-slurm-config.sh

# The Metabase dashboards OMERO.web embeds. Metabase ships only its own sample
# content, so without these the ids in .env name nothing and both BIOMERO status
# pages read "Not found." make deploy runs the restore; these are for doing it
# on its own, and for re-exporting after editing a dashboard in the UI.
# OpenSearch keeps every document forever without an ISM policy. This also
# reports security audit indices; their deletion requires separate approval.
logs-retention:
	@./scripts/apply-opensearch-retention.sh

metabase-dashboards:
	@./scripts/restore-metabase-dashboards.sh $(if $(FORCE),--force,)

export-metabase-dashboards:
	@./scripts/export-metabase-dashboards.sh $(IDS)

deploy:
	@./scripts/bootstrap-prod.sh

# nginx serves /logs behind basic auth from /etc/nginx/.htpasswd, which is
# host state rather than repository content: nothing generates it, and without
# it /logs answers 401 while the rest of the site works. Credentials come from
# NGINX_LOGS_USER and NGINX_LOGS_PASSWORD in .env.
#
# htpasswd is installed here rather than by provision, because this is the only
# thing that uses it and /logs is optional.
logs-auth:
	@user=$$(grep -hE '^NGINX_LOGS_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2-); \
	pass=$$(grep -hE '^NGINX_LOGS_PASSWORD=' .env 2>/dev/null | tail -1 | cut -d= -f2-); \
	if [ -z "$$user" ] || [ -z "$$pass" ] || [ "$$pass" = "CHANGE ME" ]; then \
		echo "  [FAIL] set NGINX_LOGS_USER and NGINX_LOGS_PASSWORD in .env first"; exit 1; fi; \
	if ! command -v htpasswd >/dev/null 2>&1; then \
		echo "  installing apache2-utils for htpasswd..."; \
		sudo apt-get install -y -qq apache2-utils >/dev/null 2>&1 || { \
			echo "  [FAIL] could not install apache2-utils; install it and re-run"; exit 1; }; \
	fi; \
	sudo htpasswd -b -c /etc/nginx/.htpasswd "$$user" "$$pass" >/dev/null 2>&1; \
	sudo chmod 644 /etc/nginx/.htpasswd; \
	if sudo nginx -t >/dev/null 2>&1; then sudo systemctl reload nginx; \
		printf '  [ ok ] /logs basic auth set for %s\n' "$$user"; \
	else echo "  [warn] wrote the file but nginx -t failed; check: sudo nginx -t"; fi

# Record the database credentials of a volume that predates volume-identity.
# Verifies the password in .env against the running database before writing, so
# it cannot enshrine a wrong one. Needs the database up: make up
adopt-volume:
	@./scripts/volume-identity.sh adopt

# The cluster SSH key, deliberately separate from whatever key this VM uses for
# its git remote: it represents an authorisation granted on the cluster, so it
# outlives the VM and is revoked on purpose rather than by rebuilding a machine.
# Its name comes from SLURM_ACCESS_KEY in .env. Refuses to replace an existing
# key unless FORCE=1, because the replacement has to be registered again before
# the cluster is reachable.
# Production host units: boot-time start once the volume is mounted, and the
# nightly backup timer. See scripts/install-host-services.sh.
install-services:
	@./scripts/install-host-services.sh

backup:
	@./scripts/backup-nightly.sh

new-key:
	@./scripts/new-slurm-key.sh $(if $(FORCE),--force,)

show-key:
	@./scripts/new-slurm-key.sh --show

# Read-only. Checks the things that have actually gone wrong here: a missing or
# stale submodule, pins that disagree between files, and images that do not
# match the pins they were supposedly built from.
doctor:
	@echo "== Submodule =="
	@if [ -f biomero-importer/Dockerfile ]; then 		printf '  [ ok ] biomero-importer checked out at %s\n' "$$(git -c safe.directory=$(CURDIR)/biomero-importer -C biomero-importer describe --tags 2>/dev/null || echo unknown)"; 		pin=$$(grep -E '^BIOMERO_IMPORTER_VERSION=' .env | cut -d= -f2); 		have=$$(git -c safe.directory=$(CURDIR)/biomero-importer -C biomero-importer describe --tags 2>/dev/null | sed 's/^v//'); 		if [ "$$have" = "$$pin" ]; then printf '  [ ok ] submodule matches BIOMERO_IMPORTER_VERSION (%s)\n' "$$pin"; 		else printf '  [warn] submodule is %s but pin is %s; the importer image would build from the wrong source\n' "$$have" "$$pin"; fi; 	else 		echo "  [FAIL] biomero-importer/ is empty; run: make init"; 	fi
	@echo "== Pins =="
	@for v in BIOMERO_VERSION OMERO_BIOMERO_VERSION BIOMERO_IMPORTER_VERSION OMERO_FORMS_VERSION; do 		lo=$$(grep -E "^$$v=" .env 2>/dev/null | cut -d= -f2); 		if [ -z "$$lo" ]; then printf '  [warn] %-26s not set in .env\n' "$$v"; 		else printf '  [ ok ] %-26s %s\n' "$$v" "$$lo"; fi; 	done
	@echo "== Installed vs pins =="
	@pin=$$(grep -E '^BIOMERO_VERSION=' .env 2>/dev/null); pin=$${pin#*=}; 	got=$$($(COMPOSE) exec -T biomeroworker $(WORKER_PY) -m pip list 2>/dev/null | awk '/^biomero /{print $$2}'); 	if [ -z "$$got" ]; then echo "  [warn] worker not running; start it with: make up"; 	elif [ "$$got" = "$$pin" ]; then printf '  [ ok ] worker biomero %s matches pin\n' "$$got"; 	else printf '  [warn] worker biomero is %s but pin is %s; rebuild with: make build\n' "$$got" "$$pin"; fi
	@echo "== Required files =="
	@for f in .env web/slurm-config.ini; do 		if [ -e "$$f" ]; then printf '  [ ok ] %s\n' "$$f"; else printf '  [FAIL] %s missing\n' "$$f"; fi; 	done
# .ssh/config is written by make deploy, not by make init, so it is legitimately
# absent between the two. Reporting it as [FAIL] there sent people looking for a
# file they were never meant to create by hand.
	@if [ ! -x .ssh ]; then echo "  [warn] .ssh inaccessible to this account; not tested"; \
	elif [ -e .ssh/config ]; then printf '  [ ok ] %s\n' ".ssh/config"; 		else printf '  [warn] %s not written yet; make deploy creates it\n' ".ssh/config"; fi
	@echo "== Public hostname =="
	@host=$$(hostname -f 2>/dev/null); \
	envfile=.env; \
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
	@pin=$$(grep -E '^BIOMERO_IMPORTER_VERSION=' .env | cut -d= -f2); \
	img=$$($(COMPOSE) config --images 2>/dev/null | grep -m1 'biomero-importer'); \
	got=$$([ -n "$$img" ] && $(COMPOSE) exec -T biomero-importer /opt/conda/envs/auto-import-env/bin/pip list 2>/dev/null | awk '/^biomero-importer /{print $$2}'); \
	sub=$$(git -c safe.directory=$(CURDIR)/biomero-importer -C biomero-importer describe --tags --exact-match 2>/dev/null | sed 's/^v//'); \
	if [ -z "$$got" ]; then echo "  [warn] could not read the importer image; is it built?"; \
	elif [ "$$got" = "$$pin" ]; then printf '  [ ok ] importer image is %s\n' "$$got"; \
	elif [ "$$got" = "0.0.0" ] && [ "$$sub" = "$$pin" ]; then \
	     printf '  [warn] importer image self-reports 0.0.0; submodule is %s, image build provenance NOT TESTED\n' "$$sub"; \
	else printf '  [warn] importer image is %s but the submodule pin is %s\n' "$$got" "$$pin"; \
	     echo "         the image builds from biomero-importer/, so rebuild it: make rebuild:biomero-importer"; fi
	@echo "== Metabase app DB =="
	@if grep -q 'MB_DB_TYPE: postgres' docker-compose.yml; then \
	  printf '  [ ok ] compose points Metabase at Postgres\n'; \
	  got=$$($(COMPOSE) exec -T database-biomero psql -U $${BIOMERO_POSTGRES_USER:-biomero} -d metabase -tAc 'SELECT count(*) FROM report_dashboard' 2>/dev/null); \
	  if [ -n "$$got" ]; then printf '  [ ok ] metabase database reachable, %s dashboards\n' "$$got"; \
	  else echo "  [warn] cannot read the metabase database; is database-biomero up?"; fi; \
	  for v in METABASE_IMPORTS_DB_PAGE_DASHBOARD_ID METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID; do \
	    id=$$(grep -E "^$$v=" .env 2>/dev/null | cut -d= -f2); \
	    [ -n "$$id" ] || continue; \
	    ok=$$($(COMPOSE) exec -T database-biomero psql -U $${BIOMERO_POSTGRES_USER:-biomero} -d metabase -tAc "SELECT enable_embedding FROM report_dashboard WHERE id=$$id" 2>/dev/null); \
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
	@echo "== Host services =="
	@for u in nl-biomero.service nl-biomero-backup.timer; do \
	  if systemctl is-enabled --quiet $$u 2>/dev/null; then printf '  [ ok ] %s enabled\n' "$$u"; \
	  else printf '  [warn] %s not installed; production needs: make install-services\n' "$$u"; fi; \
	done
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
# The values are per-VM, so they are written to .env, which is gitignored and
# lives on the storage volume. .env is a symlink into config/, which is
# root-owned, so the edit is written back through the link in place: sed -i
# would either replace the link with a regular file or fail on the temporary
# file it cannot create in that directory.
set-host:
	@test -n "$(HOST)" || { echo "usage: make set-host HOST=my.vm.example.org"; exit 2; }
	@if [ ! -f .env ]; then \
		echo "  [FAIL] .env does not exist; copy .env.example to .env"; \
		exit 1; \
	fi
	@tmp=$$(mktemp); \
	sed -E -e "s|^OMERO_CSRF_TRUSTED_ORIGINS=.*|OMERO_CSRF_TRUSTED_ORIGINS=[\"https://$(HOST)\"]|" \
	       -e "s|^METABASE_SITE_URL=.*|METABASE_SITE_URL=https://$(HOST)/metabase|" \
	       -e "s|^OBSERVABILITY_ROOT_URL=.*|OBSERVABILITY_ROOT_URL=https://$(HOST)/logs/|" \
	       .env > "$$tmp" && cat "$$tmp" > .env; \
	rc=$$?; rm -f "$$tmp"; \
	if [ $$rc -ne 0 ]; then echo "  [FAIL] could not write .env"; exit 1; fi
	@printf 'updated .env\n'
	@echo "Restart to apply: make up"

# -- stack ------------------------------------------------------------------

up:
	@python3 scripts/check-storage-mount.py
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
	@python3 scripts/check-storage-mount.py
	$(COMPOSE) up -d --build

# -- inspect ----------------------------------------------------------------

logs:
	@$(COMPOSE) logs --tail=120

# -- verify -----------------------------------------------------------------

check:
	@./scripts/bootstrap-prod.sh --check-only

smoke:
	@./scripts/smoke-readonly.sh

audit:
	@./scripts/audit-readonly.sh

active-work:
	@./scripts/check-active-work.sh

backup-verify:
	@./scripts/verify-backup-readonly.sh

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
	@python3 scripts/check-storage-mount.py
	$(COMPOSE) restart $*

rebuild\:%:
	@python3 scripts/check-storage-mount.py
	$(COMPOSE) up -d --build $*

shell\:%:
	$(COMPOSE) exec $* sh -l
