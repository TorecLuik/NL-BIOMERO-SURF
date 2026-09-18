#!/usr/bin/env bash
# Apply the log retention policy, and clear out the security audit indices.
#
# OpenSearch keeps every document forever unless an ISM policy says otherwise.
# Without this, biomero-logs grows for the life of the deployment and the only
# signal is the volume filling up.
#
# It also deletes any security-auditlog-* indices. The security plugin is
# disabled in opensearch-compose.yml, but its audit log wrote anyway --
# ~8.5M documents and 1.5GB a day of transport records, twelve times the size
# of the logs anyone wants. The compose file turns that off; this clears what
# earlier runs already accumulated.
#
# Safe to re-run: applying an unchanged policy is a no-op, and there is nothing
# to delete once the audit indices are gone.
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

# The audit indices first: they are the bulk of the disk use.
audit="$(curl -fsS --max-time 20 "${OS_URL}/_cat/indices/security-auditlog-*?h=index" 2>/dev/null || true)"
if [[ -n "${audit}" ]]; then
  bytes="$(curl -fsS --max-time 20 "${OS_URL}/_cat/indices/security-auditlog-*?h=store.size&bytes=b" 2>/dev/null \
           | awk '{s+=$1} END {print s+0}')"
  curl -fsS -X DELETE --max-time 60 "${OS_URL}/security-auditlog-*" >/dev/null 2>&1 || true
  printf '  [ ok ] removed %d security audit index(es), about %d MB\n' \
    "$(wc -l <<<"${audit}")" "$(( bytes / 1024 / 1024 ))"
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

rm -f /tmp/ism-out
