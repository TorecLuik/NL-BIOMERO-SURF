#!/usr/bin/env bash
# Rebuild the BIOMERO Metabase dashboards from metabase/dashboards.json.
#
# Metabase comes up with its own sample content and nothing else, so without
# this the ids in .env name dashboards that do not exist and both BIOMERO status
# pages read "Not found." This connects the two databases, scans them, recreates
# the dashboards and their questions, enables embedding, and writes the ids it
# used back into .env.
#
# Everything here is by name, never by id: ids are per-install, which is exactly
# why copying another host's Metabase does not work. Connection details are
# built from this VM's .env, so no password ever travels in the export.
#
# Safe on a volume that already holds data: a dashboard whose name is already
# present is left alone unless --force is given, so re-running after a redeploy
# changes nothing.
#
# Usage:
#   scripts/restore-metabase-dashboards.sh           create what is missing
#   scripts/restore-metabase-dashboards.sh --force   replace dashboards by name
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

DEFINITIONS="metabase/dashboards.json"
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

[[ -f "${DEFINITIONS}" ]] || { echo "Missing ${DEFINITIONS}" >&2; exit 1; }
[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source .env
set +a

MB_URL="http://localhost:3000"
MB_USER="${METABASE_USER:?METABASE_USER must be set in .env}"
MB_PASS="${METABASE_PASSWORD:?METABASE_PASSWORD must be set in .env}"

# Metabase needs a first admin before anything can be created. On an empty
# instance that is the setup token; afterwards it is an ordinary login.
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${MB_URL}/api/health" 2>/dev/null || true)"
  [[ "${code}" == "200" ]] && break
  sleep 5
done
if [[ "${code:-}" != "200" ]]; then
  echo "Metabase did not become healthy at ${MB_URL}; is it running?" >&2
  exit 1
fi

export MB_URL MB_USER MB_PASS FORCE DEFINITIONS
export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
export BIOMERO_POSTGRES_USER BIOMERO_POSTGRES_PASSWORD BIOMERO_POSTGRES_DB

python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

URL = os.environ["MB_URL"]
FORCE = os.environ["FORCE"] == "1"


def call(method, path, body=None, token=None, raw=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-Metabase-Session", token)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            text = r.read().decode()
            return text if raw else (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400]
        raise SystemExit("%s %s -> %s %s" % (method, path, e.code, detail))


def login():
    return call("POST", "/api/session",
                {"username": os.environ["MB_USER"],
                 "password": os.environ["MB_PASS"]})["id"]


def session():
    """Log in, doing first-time setup when the instance is still empty.

    A setup-token can still be advertised after the first user exists, so a
    refused setup falls back to an ordinary login rather than failing.
    """
    token = call("GET", "/api/session/properties").get("setup-token")
    if token:
        try:
            sid = call("POST", "/api/setup", {
                "token": token,
                "user": {"email": os.environ["MB_USER"],
                         "password": os.environ["MB_PASS"],
                         "first_name": "BIOMERO", "last_name": "Admin",
                         "site_name": "BIOMERO"},
                "prefs": {"site_name": "BIOMERO", "allow_tracking": False},
            })
            print("  created the first admin account")
            return sid["id"] if isinstance(sid, dict) else sid
        except SystemExit as e:
            if "only be used to create the first user" not in str(e):
                raise
    return login()


tok = session()

# Embedding has to be on for OMERO.web's iframes to resolve at all.
call("PUT", "/api/setting/enable-embedding", {"value": True}, tok)
print("  embedding enabled")

# The two databases, by name, with this VM's own credentials.
WANT_DBS = {
    "BIOMERO": {"host": "database-biomero", "port": 5432,
                "dbname": os.environ.get("BIOMERO_POSTGRES_DB", "biomero"),
                "user": os.environ.get("BIOMERO_POSTGRES_USER", "biomero"),
                "password": os.environ.get("BIOMERO_POSTGRES_PASSWORD", "")},
    "OMERO": {"host": "database", "port": 5432,
              "dbname": os.environ.get("POSTGRES_DB", "omero"),
              "user": os.environ.get("POSTGRES_USER", "omero"),
              "password": os.environ.get("POSTGRES_PASSWORD", "")},
}

existing = {d["name"]: d for d in call("GET", "/api/database", token=tok)["data"]}
db_ids = {}
for name, details in WANT_DBS.items():
    if name in existing:
        db_ids[name] = existing[name]["id"]
        # Credentials may be this VM's or another's; make them this VM's.
        call("PUT", "/api/database/%d" % db_ids[name],
             {"name": name, "engine": "postgres", "details": details}, tok)
        print("  datasource %-8s updated (id %d)" % (name, db_ids[name]))
    else:
        created = call("POST", "/api/database",
                       {"name": name, "engine": "postgres", "details": details}, tok)
        db_ids[name] = created["id"]
        print("  datasource %-8s created (id %d)" % (name, db_ids[name]))

# The scan is what makes tables and fields addressable; queries resolve through
# it, so the dashboards stay empty until it has run at least once.
for name, dbid in db_ids.items():
    call("POST", "/api/database/%d/sync_schema" % dbid, {}, tok)
print("  schema scan requested; waiting for tables to appear")

def tables_for(dbid):
    meta = call("GET", "/api/database/%d/metadata" % dbid, token=tok)
    return {(t["schema"], t["name"]): t for t in meta.get("tables", [])}


# Wait for the tables the dashboards actually read, not just any table: on a
# fresh volume BIOMERO creates its tracking tables when the worker first
# starts, and a card resolved before they exist is saved pointing at nothing.
def referenced_tables(node, out):
    if isinstance(node, dict):
        if {"database", "schema", "table"} <= set(node):
            out.add((node["database"], node["schema"], node["table"]))
        for v in node.values():
            referenced_tables(v, out)
    elif isinstance(node, list):
        for v in node:
            referenced_tables(v, out)
    return out


needed = referenced_tables(json.load(open(os.environ["DEFINITIONS"])), set())

deadline = time.time() + 300
tables = {}
absent = needed
while time.time() < deadline:
    tables = {n: tables_for(i) for n, i in db_ids.items()}
    absent = {t for t in needed if (t[1], t[2]) not in tables.get(t[0], {})}
    if all(v for v in tables.values()) and not absent:
        break
    time.sleep(10)
for n, v in tables.items():
    print("  %-8s %d tables visible" % (n, len(v)))
if absent:
    print("  [warn] still missing after 5 minutes: "
          + ", ".join("%s.%s.%s" % t for t in sorted(absent)))


def resolve_table(ref):
    t = tables.get(ref["database"], {}).get((ref["schema"], ref["table"]))
    return None if t is None else t["id"]


def resolve_field(ref):
    t = tables.get(ref["database"], {}).get((ref["schema"], ref["table"]))
    if not t:
        return None
    for f in t.get("fields", []):
        if f["name"] == ref["field"]:
            return f["id"]
    return None


missing = []


def untranslate(node):
    """Turn the exported name references back into this install's ids."""
    if isinstance(node, list):
        if len(node) >= 2 and node[0] == "field/name" and isinstance(node[1], dict):
            fid = resolve_field(node[1])
            if fid is None:
                missing.append("field %(database)s.%(table)s.%(field)s" % node[1])
                return ["field", 0] + [untranslate(x) for x in node[2:]]
            return ["field", fid] + [untranslate(x) for x in node[2:]]
        return [untranslate(x) for x in node]
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "source-table/name" and isinstance(v, dict):
                tid = resolve_table(v)
                if tid is None:
                    missing.append("table %(database)s.%(schema)s.%(table)s" % v)
                out["source-table"] = tid if tid is not None else 0
            else:
                out[k] = untranslate(v)
        return out
    return node


definitions = json.load(open(os.environ["DEFINITIONS"]))
have = {d["name"]: d for d in call("GET", "/api/dashboard", token=tok)}
created_ids = {}

def is_complete(did, wanted_tiles):
    """Complete means usable: the tiles are there AND embedding is on.

    Embedding is what makes the OMERO.web iframe resolve, and it is set last,
    so a dashboard interrupted part-way has its tiles but stays unembeddable.
    Counting tiles alone would call that done and leave both status pages
    broken.
    """
    d = call("GET", "/api/dashboard/%d" % did, token=tok)
    return (len(d.get("dashcards") or []) >= wanted_tiles
            and bool(d.get("enable_embedding")))


for spec in definitions:
    name = spec["name"]
    wanted_tiles = len(spec.get("cards") or [])
    # "Already there" has to mean complete, not merely named: an interrupted
    # run leaves a dashboard with no tiles and embedding off, and skipping that
    # would preserve the wreckage forever.
    if name in have and not FORCE:
        did = have[name]["id"]
        if is_complete(did, wanted_tiles):
            created_ids[name] = did
            print("  dashboard %-32s exists (id %d), left alone" % (name, did))
            continue
        print("  dashboard %-32s is incomplete; rebuilding" % name)
        call("PUT", "/api/dashboard/%d" % did, {"archived": True}, tok)
    elif name in have and FORCE:
        call("PUT", "/api/dashboard/%d" % have[name]["id"],
             {"archived": True}, tok)
        print("  dashboard %-32s archived for replacement" % name)

    dash = call("POST", "/api/dashboard",
                {"name": name, "description": spec.get("description")}, tok)
    did = dash["id"]
    created_ids[name] = did

    dashcards = []
    name_to_new_card = {}
    for i, tile in enumerate(spec.get("cards") or []):
        card = tile.get("card")
        card_id = None
        if card:
            q = untranslate(card["dataset_query"])
            q["database"] = db_ids.get(card["database_name"])
            made = call("POST", "/api/card", {
                "name": card["name"],
                "description": card.get("description"),
                "display": card["display"],
                "dataset_query": q,
                "visualization_settings": card.get("visualization_settings") or {},
            }, tok)
            card_id = made["id"]
            name_to_new_card[card["name"]] = card_id
        # A mapping's card_id names the tile's own card, so it is whatever we
        # just created rather than the id the source install happened to use.
        # Its target names a field on query-builder cards, exported by name for
        # the same reason the query is.
        mappings = []
        for m in (tile.get("parameter_mappings") or []):
            m = dict(m)
            if "card_id" in m:
                m["card_id"] = card_id
            if "target" in m:
                m["target"] = untranslate(m["target"])
            mappings.append(m)
        dashcards.append({
            "id": -(i + 1),
            "card_id": card_id,
            "row": tile["row"], "col": tile["col"],
            "size_x": tile["size_x"], "size_y": tile["size_y"],
            "parameter_mappings": mappings,
            "visualization_settings": tile.get("visualization_settings") or {},
        })

    call("PUT", "/api/dashboard/%d" % did, {"dashcards": dashcards}, tok)

    # Filters that populate from a question point at it by name in the export.
    params = []
    for param in (spec.get("parameters") or []):
        param = json.loads(json.dumps(param))
        cfg = param.get("values_source_config")
        if isinstance(cfg, dict):
            cname = cfg.pop("card_name", None)
            if cname:
                if cname in name_to_new_card:
                    cfg["card_id"] = name_to_new_card[cname]
                else:
                    missing.append("filter source card %r" % cname)
                    param.pop("values_source_config", None)
                    param.pop("values_source_type", None)
            if "value_field" in cfg:
                cfg["value_field"] = untranslate(cfg["value_field"])
        params.append(param)

    call("PUT", "/api/dashboard/%d" % did, {
        "enable_embedding": True,
        "embedding_params": spec.get("embedding_params") or {},
        "parameters": params,
    }, tok)
    print("  dashboard %-32s created (id %d, %d tiles)"
          % (name, did, len(dashcards)))

if missing:
    print("  [warn] unresolved references, cards may be blank:")
    for m in sorted(set(missing)):
        print("           " + m)

json.dump(created_ids, open("/tmp/mb-dashboard-ids.json", "w"))
PY

# Point .env at whatever ids this instance ended up with.
python3 - <<'PY'
import json, re

ids = json.load(open("/tmp/mb-dashboard-ids.json"))
wanted = {
    "METABASE_WORKFLOWS_DB_PAGE_DASHBOARD_ID": "BIOMERO Analytics",
    "METABASE_IMPORTS_DB_PAGE_DASHBOARD_ID": "OMERO Automated Data Importer",
}
lines = open(".env").read().split("\n")
changed = []
for key, dash in wanted.items():
    if dash not in ids:
        continue
    for i, line in enumerate(lines):
        if re.match("^%s=" % key, line):
            new = "%s=%s" % (key, ids[dash])
            if line != new:
                lines[i] = new
                changed.append(new)
open(".env", "w").write("\n".join(lines))
for c in changed:
    print("  .env updated: " + c)
PY

rm -f /tmp/mb-dashboard-ids.json
echo
echo "Restart omeroweb to pick up the ids: make up"
