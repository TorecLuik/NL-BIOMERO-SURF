# Metabase Dashboards

BIOMERO Import and Analyze status pages embed Metabase dashboards. Most blank, spinner, or iframe failures are Metabase configuration or datasource problems, not OMERO.web React problems.

## They Are Built From the Repository

`metabase/dashboards.json` holds both dashboards and their questions;
`make deploy` restores them, and `make metabase-dashboards` does it on its own.
**Do not fix a missing dashboard by copying Metabase state from another host.**

Everything per-install travels by name, because ids are exactly what makes a
copied Metabase useless elsewhere:

```text
database id            -> database name ("BIOMERO", "OMERO")
table / field id       -> schema.table.column
filter source card id  -> the card's name
credentials            -> rebuilt from the target's .env, never exported
```

The restore connects both databases with this VM's own credentials, scans them,
recreates the dashboards, enables embedding, and writes the ids it used back
into `.env`. So the ids are *outputs*, not constants -- on a rebuilt VM they
will not be 2 and 6.

Re-running is safe on a volume that already holds data: a dashboard is left
alone when it is complete, meaning its tiles are present **and** embedding is
on. `--force` replaces by name.

Filters wired to query-builder cards target a field id too. Both scripts
translate those mapping targets by name like the queries; a definitions file
with a numeric `["field", <id>]` anywhere in it will break on any other install
("Failed to fetch :metadata/column <id>").

To change a dashboard, edit it in the UI and re-export:

```bash
make export-metabase-dashboards          # the two ids .env embeds, by default
make export-metabase-dashboards IDS=5    # or an explicit set
```

Then commit `metabase/dashboards.json`.

Metabase's own serialization (`java -jar metabase.jar export`) would be the
obvious tool and is **Enterprise-only**; this build answers `The 'v2-dump!'
command is only available in Metabase Enterprise Edition`. That is why the
content is read from its application database instead.

## Where Metabase Keeps Its Data

The application database is **Postgres, on `database-biomero`, database
`metabase`** -- not the H2 file older notes describe. Inspect it directly:

```bash
sudo docker compose exec -T database-biomero psql -U biomero -d metabase \
  -c "SELECT d.id, d.name, d.enable_embedding, count(dc.id) AS tiles
      FROM report_dashboard d
      LEFT JOIN report_dashboardcard dc ON dc.dashboard_id = d.id
      WHERE NOT d.archived GROUP BY 1,2,3 ORDER BY 1;"
```

Good state is both BIOMERO dashboards unarchived, embedding true, tiles > 0, and
`.env` naming those ids. A fresh Metabase instead shows one dashboard
("E-commerce insights"), ~26 sample cards and an H2 "Sample Database" -- that is
the untouched install, and it is what makes both status pages read "Not found."

## Environment Alignment

Verify the public Metabase URL and embedding settings through the read-only
API or `make audit`. If a secret mismatch is suspected, compare only the
necessary keys in memory and report equality, never the values. Do not dump
container environments or `.env` into logs.

Metabase env should include:

```text
MB_ENABLE_EMBEDDING=true
MB_ENABLE_EMBEDDING_STATIC=true
MB_EMBEDDING_SECRET_KEY=<same value as METABASE_SECRET_KEY>
MB_SITE_URL=https://<host>/metabase
```

If an iframe says `Message seems corrupt or manipulated`, the Metabase embedding key and `METABASE_SECRET_KEY` do not match. Update `.env`, then restart `omeroweb`.

## Error: Embedding Is Not Enabled

The iframe reaches Metabase, but the resource is not embeddable or the id in
`.env` points at the wrong object. Rebuild rather than patch:

```bash
make metabase-dashboards           # creates what is missing, leaves the rest
make metabase-dashboards FORCE=1   # replace by name
sudo docker compose up -d omeroweb # pick up any ids that changed
```

The restore sets embedding, so a dashboard that is present but unembeddable is
almost always one whose creation was interrupted -- embedding is set last.

## Dashboard Spinner / Query Failure

A card that spins forever usually means its query failed. Check the logs:

```bash
sudo docker compose logs --since=15m metabase \
  | grep -Ei 'error|exception|failed|timeout|permission|query|card|dashboard|FATAL' | tail -50
```

Observed:

```text
Error processing query: FATAL: password authentication failed for user "biomero"
:context :embedded-dashboard
:card-name "Biomero Workflow Progress"
```

That is a datasource whose credentials came from another environment -- the
signature of Metabase state copied between hosts. `make metabase-dashboards`
rewrites both datasources from this VM's `.env`, which is the fix; there is no
need to edit the application database by hand.

A card that renders but is empty is different: the schema scan has not seen the
table yet. The restore requests one and waits, but a table created later (a new
BIOMERO view, say) needs another:

```bash
# id from: SELECT id,name FROM metabase_database;
curl -s -X POST -H "X-Metabase-Session: $TOKEN" \
  http://localhost:3000/api/database/<id>/sync_schema
```

## Signed Embed Smoke Test

Query an embedded card without a browser. Take the ids from `.env` and the
database rather than hardcoding them -- they differ per install:

```bash
set -a; . ./.env; set +a
DASH=$METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID
read -r DASHCARD CARD < <(sudo docker compose exec -T database-biomero \
  psql -U "$BIOMERO_POSTGRES_USER" -d metabase -tA -F' ' \
  -c "SELECT dc.id, dc.card_id FROM report_dashboardcard dc
      WHERE dc.dashboard_id=$DASH AND dc.card_id IS NOT NULL
      ORDER BY dc.id LIMIT 1;")

TOKEN=$(SECRET="$METABASE_SECRET_KEY" DASH="$DASH" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
secret = os.environ["SECRET"].encode()
b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
hdr = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
pay = b64(json.dumps({"resource": {"dashboard": int(os.environ["DASH"])},
                      "params": {}, "exp": int(time.time()) + 600},
                     separators=(",", ":")).encode())
msg = hdr + "." + pay
print(msg + "." + b64(hmac.new(secret, msg.encode(), hashlib.sha256).digest()))
PY
)

curl -sS -o /tmp/card.out -w '%{http_code} %{size_download}\n' \
  "http://localhost:3000/api/embed/dashboard/$TOKEN/dashcard/$DASHCARD/card/$CARD"
head -c 300 /tmp/card.out
```

A good result is HTTP `202` with JSON data rows. `401` means
`METABASE_SECRET_KEY` in `.env` and Metabase's embedding key disagree; restart
`metabase` and `omeroweb` after correcting it.

## Proxied Dashboard Links

OMERO.biomero rewrites Metabase links rendered as `localhost` or `127.0.0.1` so
they stay under the public OMERO origin when embedded behind a reverse proxy.
This is upstream behavior; no patch is applied.

If proxied dashboard links break, confirm the shipped bundle still carries the
rewrite before considering any patch:

```bash
docker compose exec -T omeroweb sh -c \
  'grep -l "127.0.0.1" /opt/omero/web/venv3/lib/python3.12/site-packages/omero_biomero/static/omero_biomero/assets/main.*.js'
```
