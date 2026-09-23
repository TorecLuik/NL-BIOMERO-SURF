#!/bin/sh
# Wait for OpenSearch to be ready
until curl -s -o /dev/null -w "%{http_code}" http://opensearch:9200 | grep -q "200"; do
  echo "Waiting for OpenSearch..."
  sleep 5
done

echo "OpenSearch is ready. Creating index template..."

# Create index template with proper mappings
curl -X PUT "http://opensearch:9200/_index_template/biomero-logs-template" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns": ["biomero-logs-*"],
    "priority": 100,
    "template": {
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "service": { "type": "keyword" },
          "file": { "type": "keyword" },
          "level": { "type": "keyword" },
          "job": { "type": "keyword" },
          "logger": { "type": "keyword" },
          "pid": { "type": "keyword" },
          "thread": { "type": "keyword" },
          "message": { "type": "text" }
        }
      },
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "plugins.index_state_management.rollover_alias": "biomero-logs"
      }
    }
  }'

echo ""
echo "Index template created successfully."

# Rollover needs a write alias: ISM rolls an alias over to a fresh backing
# index, and cannot do anything with a plain index of a fixed name. fluent-bit
# writes to "biomero-logs", so that name has to be the alias, not the index.
#
# A name cannot be both, so an older deployment whose biomero-logs is a concrete
# index keeps it and gets no rollover -- converting it means reindexing 400MB+,
# which is not something a start-up script should do unasked. Deletion at 90
# days still applies there, so the volume cannot fill indefinitely.
if curl -s -o /dev/null -w "%{http_code}" "http://opensearch:9200/biomero-logs" | grep -q "200"; then
  if curl -s "http://opensearch:9200/_cat/aliases/biomero-logs?h=alias" | grep -q "biomero-logs"; then
    echo "Write alias biomero-logs already present."
  else
    echo "biomero-logs is a concrete index, not an alias; leaving it alone."
    echo "  Rollover stays inactive for it. Age-off at 90 days still applies."
    echo "  To enable rollover, reindex it behind the alias during a maintenance window."
  fi
else
  # Nothing there yet: create the first backing index with the alias as writer.
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "http://opensearch:9200/biomero-logs-000001" \
    -H "Content-Type: application/json" \
    -d '{"aliases":{"biomero-logs":{"is_write_index":true}}}')
  case "$code" in
    200|201) echo "Created biomero-logs-000001 with write alias biomero-logs." ;;
    *)       echo "Could not create the rollover alias (HTTP $code); logs will"
             echo "  still be written, but rollover will not fire." ;;
  esac
fi
