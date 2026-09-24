#!/usr/bin/env bash
# Apply the log retention policy; report existing security audit indices.
#
# OpenSearch keeps every document forever unless an ISM policy says otherwise.
# Without this, biomero-logs grows for the life of the deployment and the only
# signal is the volume filling up.
#
# Existing security-auditlog indices are reported but not deleted.
set -euo pipefail

PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT_DIR}"

OS_URL="${OS_URL:-http://localhost:9200}"
POLICY_FILE="opensearch/retention-policy.json"
POLICY_ID="biomero-logs-retention"

[[ -f "${POLICY_FILE}" ]] || { echo "Missing ${POLICY_FILE}" >&2; exit 1; }

if ! curl -fsS --max-time 20 "${OS_URL}/_cluster/health" >/dev/null 2>&1; then
  echo "  [warn] OpenSearch is not answering at ${OS_URL}; skipping retention"
  exit 0
fi

# Existing audit indices are production logs. Report their presence; deletion
# requires a separate explicit operator authorization.
audit="$(curl -fsS --max-time 20 "${OS_URL}/_cat/indices/security-auditlog-*?h=index" 2>/dev/null || true)"
if [[ -n "${audit}" ]]; then
  printf '  [warn] %d security audit index(es) remain; cleanup requires approval\n' "$(wc -l <<<"${audit}")"
fi

code="$(curl -s -o /tmp/ism-out -w '%{http_code}' --max-time 30 \
  -X PUT "${OS_URL}/_plugins/_ism/policies/${POLICY_ID}" \
  -H 'Content-Type: application/json' \
  --data-binary "@${POLICY_FILE}" 2>/dev/null || true)"

case "${code}" in
  200|201)
    echo "  [ ok ] retention policy ${POLICY_ID} applied" ;;
  409)
    # Already there. An update needs the policy's current version, which comes
    # from reading it back -- the 409 body is an error, not the policy.
    cur="$(curl -fsS --max-time 20 "${OS_URL}/_plugins/_ism/policies/${POLICY_ID}" 2>/dev/null || true)"
    read -r sn pt <<<"$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("_seq_no", ""), d.get("_primary_term", ""))
except Exception:
    print("", "")' "${cur}" 2>/dev/null)"
    if [[ -n "${sn}" && -n "${pt}" ]]; then
      curl -fsS -X PUT --max-time 30 \
        "${OS_URL}/_plugins/_ism/policies/${POLICY_ID}?if_seq_no=${sn}&if_primary_term=${pt}" \
        -H 'Content-Type: application/json' --data-binary "@${POLICY_FILE}" >/dev/null 2>&1 \
        && echo "  [ ok ] retention policy ${POLICY_ID} updated" \
        || echo "  [ ok ] retention policy ${POLICY_ID} already present"
    else
      echo "  [ ok ] retention policy ${POLICY_ID} already present"
    fi ;;
  *)
    echo "  [warn] could not apply the retention policy (HTTP ${code:-none})"
    head -c 300 /tmp/ism-out 2>/dev/null || true
    echo ;;
esac

# An ism_template only adopts indices created *after* the policy exists, and
# fluent-bit creates biomero-logs on its first flush -- which on a fresh deploy
# usually beats this script, since both are started by the same compose up. So
# the template alone leaves the index unmanaged, with nothing ageing off and a
# full volume as the first symptom. Attach the policy to anything already there.
managed=0
unmanaged=""
for idx in $(curl -fsS --max-time 20 "${OS_URL}/_cat/indices/biomero-logs*?h=index" 2>/dev/null); do
  explain="$(curl -fsS --max-time 20 "${OS_URL}/_plugins/_ism/explain/${idx}" 2>/dev/null || true)"
  case "${explain}" in
    *"\"${POLICY_ID}\""*) managed=$((managed + 1)) ;;
    *) unmanaged="${unmanaged} ${idx}" ;;
  esac
done

if [[ -n "${unmanaged// /}" ]]; then
  # ISM add takes a comma-separated list and is a no-op on already-managed ones.
  add_list="$(echo ${unmanaged} | tr ' ' ',')"
  if curl -fsS -X POST --max-time 30 "${OS_URL}/_plugins/_ism/add/${add_list}" \
       -H 'Content-Type: application/json' \
       -d "{\"policy_id\":\"${POLICY_ID}\"}" >/dev/null 2>&1; then
    printf '  [ ok ] attached %s to:%s\n' "${POLICY_ID}" "${unmanaged}"
  else
    printf '  [warn] could not attach %s to:%s\n' "${POLICY_ID}" "${unmanaged}"
  fi
elif (( managed > 0 )); then
  printf '  [ ok ] %d index(es) already managed by %s\n' "${managed}" "${POLICY_ID}"
fi

# Rollover rolls an alias onto a fresh backing index. A deployment predating the
# alias has biomero-logs as a concrete index, so the hot state's rollover action
# has nothing to act on and only the 90-day delete applies. Say so rather than
# reporting a policy that is only half in effect.
if curl -fsS --max-time 20 "${OS_URL}/biomero-logs" >/dev/null 2>&1 \
   && ! curl -fsS --max-time 20 "${OS_URL}/_cat/aliases/biomero-logs?h=alias" 2>/dev/null \
        | grep -q biomero-logs; then
  echo "  [warn] biomero-logs is a concrete index, not a write alias:"
  echo "  [warn]   age-off at 90 days applies, rollover does not fire."
  echo "  [warn]   reindex behind the alias to enable it."
fi

rm -f /tmp/ism-out
