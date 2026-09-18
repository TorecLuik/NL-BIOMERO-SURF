#!/usr/bin/env bash
# Export the BIOMERO Metabase dashboards to version-controlled JSON.
#
# The authoring half of a pair: run this on a host whose Metabase has the
# dashboards as you want them, commit the result, and every later deployment
# rebuilds them with scripts/restore-metabase-dashboards.sh.
#
# Metabase's own serialization (`java -jar metabase.jar export`) would be the
# obvious tool, but it is Enterprise-only -- this build answers "The 'v2-dump!'
# command is only available in Metabase Enterprise Edition" -- so the content is
# read out of its application database instead.
#
# Everything per-install is translated to something stable on the way out:
#
#   database id -> database name     numeric ids differ per install
#   table id    -> schema.table      likewise; re-resolved against the target's
#   field id    -> table.column      own scan on restore
#   credentials -> dropped entirely  restore builds them from the target's .env,
#                                    so an export never carries a password
#
# Usage:
#   scripts/export-metabase-dashboards.sh              dashboards 2 and 6
#   scripts/export-metabase-dashboards.sh 2 6 9        an explicit set
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

OUT_FILE="metabase/dashboards.json"
COMPOSE=(sudo docker compose)
DASHBOARD_IDS=("$@")
if [[ "${#DASHBOARD_IDS[@]}" -eq 0 ]]; then
  DASHBOARD_IDS=(2 6)
fi

BIOMERO_USER="$(grep -hE '^BIOMERO_POSTGRES_USER=' .env 2>/dev/null | tail -1 | cut -d= -f2-)"
: "${BIOMERO_USER:=biomero}"

if ! "${COMPOSE[@]}" ps --status running --format '{{.Service}}' 2>/dev/null \
     | grep -qx database-biomero; then
  echo "database-biomero is not running; start it first: make up" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT_FILE}")"
ids_csv="$(IFS=,; echo "${DASHBOARD_IDS[*]}")"

# One document holding the dashboards, their tiles, and the question behind each
# tile. Tiles without a question (text and heading cards) are kept too: they
# carry the layout.
"${COMPOSE[@]}" exec -T database-biomero psql -U "${BIOMERO_USER}" -d metabase -tA <<SQL > "${OUT_FILE}.raw"
SELECT jsonb_pretty(jsonb_agg(to_jsonb(d) ORDER BY d.name))
FROM (
  SELECT
    d.name,
    d.description,
    d.parameters,
    d.enable_embedding,
    d.embedding_params,
    (
      SELECT jsonb_agg(jsonb_build_object(
               'row', dc.row, 'col', dc.col,
               'size_x', dc.size_x, 'size_y', dc.size_y,
               'parameter_mappings', dc.parameter_mappings,
               'visualization_settings', dc.visualization_settings,
               'card', CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object(
                         'name', c.name,
                         'description', c.description,
                         'display', c.display,
                         'dataset_query', c.dataset_query,
                         'visualization_settings', c.visualization_settings,
                         'database_name', db.name
                       ) END
             ) ORDER BY dc.row, dc.col)
      FROM report_dashboardcard dc
      LEFT JOIN report_card c ON c.id = dc.card_id
      LEFT JOIN metabase_database db ON db.id = c.database_id
      WHERE dc.dashboard_id = d.id
    ) AS cards
  FROM report_dashboard d
  WHERE d.id IN (${ids_csv}) AND NOT d.archived
) d;
SQL

# The lookup tables a structured query's numeric ids resolve through.
"${COMPOSE[@]}" exec -T database-biomero psql -U "${BIOMERO_USER}" -d metabase -tA <<'SQL' > "${OUT_FILE}.tables"
SELECT jsonb_pretty(jsonb_object_agg(t.id::text,
         jsonb_build_object('schema', t.schema, 'table', t.name, 'database', db.name)))
FROM metabase_table t JOIN metabase_database db ON db.id = t.db_id;
SQL

"${COMPOSE[@]}" exec -T database-biomero psql -U "${BIOMERO_USER}" -d metabase -tA <<'SQL' > "${OUT_FILE}.fields"
SELECT jsonb_pretty(jsonb_object_agg(f.id::text,
         jsonb_build_object('field', f.name, 'schema', t.schema, 'table', t.name, 'database', db.name)))
FROM metabase_field f
JOIN metabase_table t ON t.id = f.table_id
JOIN metabase_database db ON db.id = t.db_id;
SQL

"${COMPOSE[@]}" exec -T database-biomero psql -U "${BIOMERO_USER}" -d metabase -tA <<'SQL' > "${OUT_FILE}.cards"
SELECT jsonb_pretty(jsonb_object_agg(id::text, name)) FROM report_card;
SQL

if [[ ! -s "${OUT_FILE}.raw" ]]; then
  echo "No dashboards exported; are ids ${ids_csv} present and unarchived?" >&2
  rm -f "${OUT_FILE}".raw "${OUT_FILE}".tables "${OUT_FILE}".fields "${OUT_FILE}".cards
  exit 1
fi

python3 - "${OUT_FILE}" <<'PY'
import json, re, sys

out = sys.argv[1]
dashboards = json.load(open(out + ".raw"))
tables = json.load(open(out + ".tables"))
fields = json.load(open(out + ".fields"))
card_names = json.load(open(out + ".cards"))


def name_table(tid):
    t = tables.get(str(tid))
    return None if t is None else {"schema": t["schema"], "table": t["table"],
                                   "database": t["database"]}


def name_field(fid):
    f = fields.get(str(fid))
    return None if f is None else {"schema": f["schema"], "table": f["table"],
                                   "field": f["field"], "database": f["database"]}


def translate(node):
    """Replace ["field", <id>, opts] and "source-table": <id> with names."""
    if isinstance(node, list):
        if (len(node) >= 2 and node[0] == "field" and isinstance(node[1], int)):
            named = name_field(node[1])
            if named:
                return ["field/name", named] + [translate(x) for x in node[2:]]
        return [translate(x) for x in node]
    if isinstance(node, dict):
        res = {}
        for k, v in node.items():
            if k == "source-table" and isinstance(v, int):
                named = name_table(v)
                res["source-table/name"] = named if named else v
            else:
                res[k] = translate(v)
        return res
    return node


def as_json(value, empty):
    """These columns are text in Postgres; store them as real JSON."""
    if isinstance(value, str):
        try:
            return json.loads(value)
        except ValueError:
            return empty
    return empty if value is None else value


def name_card(cid):
    return card_names.get(str(cid))


unresolved = []
for d in dashboards:
    d["parameters"] = as_json(d.get("parameters"), [])
    d["embedding_params"] = as_json(d.get("embedding_params"), {})
    for tile in (d.get("cards") or []):
        tile["parameter_mappings"] = as_json(tile.get("parameter_mappings"), [])
        tile["visualization_settings"] = as_json(tile.get("visualization_settings"), {})
        if tile.get("card"):
            tile["card"]["visualization_settings"] = as_json(
                tile["card"].get("visualization_settings"), {})
for d in dashboards:
    for tile in (d.get("cards") or []):
        card = tile.get("card")
        if not card:
            continue
        q = card["dataset_query"]
        if isinstance(q, str):
            q = json.loads(q)
        q.pop("database", None)          # the name on the card is what binds it
        card["dataset_query"] = translate(q)
        # Anything still numeric here would not resolve on another install.
        s = json.dumps(card["dataset_query"])
        if re.search(r'"source-table":\s*\d', s) or re.search(r'\["field",\s*\d', s):
            unresolved.append((d["name"], card["name"]))

# Dashboard filters can populate their dropdown from a question, referenced by
# card id and field id -- both per-install. Carry the card's name instead.
for d in dashboards:
    for param in (d.get("parameters") or []):
        cfg = param.get("values_source_config")
        if not isinstance(cfg, dict):
            continue
        if isinstance(cfg.get("card_id"), int):
            named = name_card(cfg.pop("card_id"))
            if named:
                cfg["card_name"] = named
            else:
                unresolved.append((d["name"], "parameter %s" % param.get("name")))
        if "value_field" in cfg:
            cfg["value_field"] = translate(cfg["value_field"])

json.dump(dashboards, open(out, "w"), indent=2, sort_keys=True)
print("dashboards: %d" % len(dashboards))
for d in dashboards:
    tiles = d.get("cards") or []
    print("  %-32s tiles=%2d questions=%2d"
          % (d["name"], len(tiles), sum(1 for t in tiles if t.get("card"))))
if unresolved:
    print("WARNING: unresolved references:", unresolved)
PY

rm -f "${OUT_FILE}".raw "${OUT_FILE}".tables "${OUT_FILE}".fields "${OUT_FILE}".cards
echo
echo "Wrote ${OUT_FILE}. Commit it; restore-metabase-dashboards.sh rebuilds"
echo "these on any deployment against that VM's own databases."
