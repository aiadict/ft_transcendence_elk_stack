#!/bin/sh
# scripts/es-setup.sh
# Purpose: Secure bootstrap for Elasticsearch + roles/ILM/templates used by Logstash/Kibana
# Notes:
# - Keeps your existing users (kibana_system, logstash_system, LS_ES_USER)
# - Fixes Logstash 403 on alias by granting privileges on the alias and its indices
# - Adds single-node convenience to avoid YELLOW (optional via SINGLE_NODE=true)

set -euo pipefail

ES_URL="https://elasticsearch:9200"

ELASTIC_PASS="${ELASTIC_PASSWORD:?missing ELASTIC_PASSWORD}"
KIBANA_SYSTEM_PASS="${KIBANA_SYSTEM_PASSWORD:?missing KIBANA_SYSTEM_PASSWORD}"
LOGSTASH_SYSTEM_PASS="${LOGSTASH_SYSTEM_PASSWORD:?missing LOGSTASH_SYSTEM_PASSWORD}"

# Your existing Logstash writer user (do NOT rename)
LS_USER="${LS_ES_USER:?missing LS_ES_USER}"
LS_PASS="${LS_ES_PASS:?missing LS_ES_PASS}"

CA_CERT="/certs/ca/ca.crt"
CURL="curl -sS --fail --cacert ${CA_CERT} -u elastic:${ELASTIC_PASS} -H "Content-Type:application/json"

echo ">> Waiting for Elasticsearch over HTTPS..."
for i in $(seq 1 120); do
  if ${CURL} -X GET "${ES_URL}" >/dev/null 2>&1; then
    echo "Elasticsearch is up."
    break
  fi
  sleep 2
done

# ------------------------------------------------------------------------------
# 1) Built-in users: set passwords (idempotent)
# ------------------------------------------------------------------------------
echo ">> Setting built-in passwords (kibana_system, logstash_system)..."
${CURL} -X POST "${ES_URL}/_security/user/kibana_system/_password" -d "{\"password\":\"${KIBANA_SYSTEM_PASS}\"}" || true
${CURL} -X POST "${ES_URL}/_security/user/logstash_system/_password" -d "{\"password\":\"${LOGSTASH_SYSTEM_PASS}\"}" || true

# ------------------------------------------------------------------------------
# 2) Role for Logstash writer: include alias + index patterns with required privs
#    CHANGE: Add 'ftt-logs-json' alias and ensure 'create_doc'/'index' are present
#    WHY: Fixes 403 when Logstash writes to alias ftt-logs-json
# ------------------------------------------------------------------------------
echo ">> Creating/updating role ft_logs_writer (alias + indices + required privs)..."
${CURL} -X PUT "${ES_URL}/_security/role/ft_logs_writer" -d '{
  "cluster": ["monitor","manage_ilm","manage_index_templates","manage_pipeline"],
  "indices": [
    {
      "names": ["ftt-logs-json","ftt-logs-json*","ftt-logs-plain","ftt-logs-plain*"],
      "privileges": ["create_index","create_doc","create","index","write","view_index_metadata"]
    }
  ]
}'

# ------------------------------------------------------------------------------
# 3) Ensure LS_ES_USER exists and has the role (idempotent)
#    CHANGE: Do not rename users; just make sure the role is attached
#    WHY: Guarantees indexing to the alias works with existing credentials
# ------------------------------------------------------------------------------
echo ">> Ensuring ${LS_USER} exists and has ft_logs_writer role..."
USER_PAYLOAD=$(cat <<JSON
{
  "password": "${LS_PASS}",
  "roles": ["ft_logs_writer"],
  "full_name": "FT Logs Writer",
  "enabled": true
}
JSON
)
${CURL} -X POST "${ES_URL}/_security/user/${LS_USER}" -d "${USER_PAYLOAD}" || \
${CURL} -X PUT  "${ES_URL}/_security/user/${LS_USER}" -d "${USER_PAYLOAD}" || true

# ------------------------------------------------------------------------------
# 4) ILM policy for logs (roll daily, delete after 7 days)
#    CHANGE: Keep simple and efficient defaults; adjust days if needed
# ------------------------------------------------------------------------------
echo ">> Creating ILM policy ftt-logs-7d (hot rollover daily, delete after 7d)..."
${CURL} -X PUT "${ES_URL}/_ilm/policy/ftt-logs-7d" -d '{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_primary_shard_size": "25gb", "max_age": "1d" }
        }
      },
      "delete": {
        "min_age": "7d",
        "actions": { "delete": {} }
      }
    }
  }
}'

# ------------------------------------------------------------------------------
# 5) Index template for JSON logs with rollover alias
#    CHANGE: Alias is 'ftt-logs-json' so Logstash can point to the alias safely
# ------------------------------------------------------------------------------
echo ">> Creating index template ftt-logs-json-template (alias + ILM + mappings, NO data_stream)..."
${CURL} -X PUT "${ES_URL}/_index_template/ftt-logs-json-template" -d '{
  "index_patterns": ["ftt-logs-json*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "ftt-logs-7d",
      "index.lifecycle.rollover_alias": "ftt-logs-json",
      "index.number_of_shards": 1,
      "index.number_of_replicas": 0
    },
    "mappings": {
      "dynamic": true,
      "properties": {
        "level": { "type": "integer" },
        "pid":   { "type": "integer" },
        "hostname": { "type": "keyword" },
        "msg":  { "type": "text" },
        "reqId": { "type": "keyword" },
        "req": {
          "properties": {
            "method": { "type": "keyword" },
            "url":    { "type": "keyword" },
            "host":   { "type": "keyword" },
            "remoteAddress": { "type": "keyword" },
            "remotePort":    { "type": "integer" }
          }
        },
        "res": {
          "properties": {
            "statusCode": { "type": "integer" }
          }
        },
        "responseTime": { "type": "float" },
        "event": {
          "properties": {
            "original": { "type": "text" }
          }
        }
      }
    },
    "aliases": {
      "ftt-logs-json": {}
    }
  },
  "priority": 500
}'


# ------------------------------------------------------------------------------
# 6) Bootstrap write index for alias if missing
#    CHANGE: Create ftt-logs-json-000001 with write flag
#    WHY: Prevents "no write index for alias" errors on a clean cluster
# ------------------------------------------------------------------------------
echo ">> Ensuring alias ftt-logs-json has a write index..."
if ! ${CURL} -X GET "${ES_URL}/_alias/ftt-logs-json" >/dev/null 2>&1; then
  ${CURL} -X PUT "${ES_URL}/ftt-logs-json-000001" -d '{
    "aliases": { "ftt-logs-json": { "is_write_index": true } }
  }' || true
fi


# 7) Snapshot repo + SLM policy (JSON-only)
echo ">> Ensuring snapshot repo ftt-fs-repo exists..."
${CURL} -X PUT "${ES_URL}/_snapshot/ftt-fs-repo" -d '{
  "type": "fs",
  "settings": { "location": "/snapshots", "compress": true }
}' || true

echo ">> Ensuring SLM policy ftt-daily-snapshots targets JSON logs only..."
${CURL} -X PUT "${ES_URL}/_slm/policy/ftt-daily-snapshots" -d '{
  "name": "<ftt-snap-{now/d}>",
  "schedule": "0 30 1 * * ?",
  "repository": "ftt-fs-repo",
  "config": {
    "indices": ["ftt-logs-json*"],
    "ignore_unavailable": true,
    "include_global_state": false
  },
  "retention": { "expire_after": "90d", "min_count": 10, "max_count": 100 }
}'


# ------------------------------------------------------------------------------
# 8) (Optional) single-node: set replicas=0 on common system indices
#    CHANGE: Guarded by SINGLE_NODE (defaults to true for local dev)
#    WHY: Avoids YELLOW health by removing replicas in 1-node setups
# ------------------------------------------------------------------------------
if [ "${SINGLE_NODE:-true}" = "true" ]; then
  echo ">> Setting replicas=0 on common system indices (single-node mode)..."
  for idx in ".kibana" ".kibana_*" ".security" ".internal.alerts-*" ".fleet*" ".monitoring-*" ".reporting-*"; do
    ${CURL} -X PUT "${ES_URL}/${idx}/_settings" -d '{"index":{"number_of_replicas":"0"}}' || true
  done
fi

echo ">> ES setup complete."
