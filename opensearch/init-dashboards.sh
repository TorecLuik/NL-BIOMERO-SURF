#!/bin/sh
# Create the Dashboards index pattern for biomero-logs.
#
# Separate from init-opensearch.sh on purpose: fluent-bit waits for that one to
# finish before it starts shipping, and this waits on Dashboards, which takes
# appreciably longer to come up. Blocking log ingestion on a UI convenience is
# the wrong trade, so this runs alongside instead.
#
# The index template gives the data its field types; this is the saved object
# that lets anyone browse it. Without it /logs opens on a "create an index
# pattern" setup screen with every log already indexed and nothing shown.
set -u

DASH="http://opensearch-dashboards:5601/logs"

echo "Waiting for OpenSearch Dashboards..."
i=0
while [ "$i" -lt 60 ]; do
  if curl -s -o /dev/null -w "%{http_code}" "$DASH/api/status" | grep -q "200"; then
    break
  fi
  i=$((i + 1))
  sleep 5
done

code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$DASH/api/saved_objects/index-pattern/biomero-logs" \
  -H 'Content-Type: application/json' -H 'osd-xsrf: true' \
  -d '{"attributes":{"title":"biomero-logs*","timeFieldName":"@timestamp"}}')

case "$code" in
  200|201) echo "Index pattern created." ;;
  409)     echo "Index pattern already present." ;;
  *)       echo "Could not create the index pattern (HTTP $code); /logs will"
           echo "open on its setup screen until one exists."
           exit 0 ;;
esac

# Open /logs straight into the logs rather than the home page.
curl -s -o /dev/null -X POST "$DASH/api/opensearch-dashboards/settings" \
  -H 'Content-Type: application/json' -H 'osd-xsrf: true' \
  -d '{"changes":{"defaultIndex":"biomero-logs"}}' || true
echo "Default index set."
