#!/bin/sh
# scripts/es-setup.sh
# Purpose: Secure bootstrap for Elasticsearch + roles/ILM/templates used by Logstash/Kibana
# Runtime: Executed *inside* the curlimages/curl container by docker-compose `setup` service.

set -eu

ES_URL="${ES_URL:-https://elasticsearch:9200}"
CA_CERT="${CA_CERT:-/certs/ca/ca.crt}"

# --- Required env (already provided by docker-compose) ---
: "${ELASTIC_PASSWORD:?missing ELASTIC_PASSWORD}"
: "${KIBANA_SYSTEM_PASSWORD:?missing KIBANA_SYSTEM_PASSWORD}"
: "${LOGSTASH_SYSTEM_PASSWORD:?missing LOGSTASH_SYSTEM_PASSWORD}"
: "${LS_ES_USER:?missing LS_ES_USER}"
: "${LS_ES_PASS:?missing LS_ES_PASS}"

# --- Helpers ---
_curl() {
  # Always JSON; pass-through extra curl args
  curl -sS --fail \
    --cacert "$CA_CERT" \
    -u "elastic:$ELASTIC_PASSWORD" \
    -H "Content-Type: application/json" \
    "$@"
}

# POSIX-safe JSON string escaper (handles ", \, \n, \r, \t)
json_escape() {
  # Reads one argument and prints escaped result
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/\r/\\r/g' \
    -e ':a;N;$!ba;s/\n/\\n/g' \
    -e 's/	/\\t/g'
}

# --- Wait for ES ---
echo ">> Waiting for Elasticsearch over HTTPS..."
i=0
while :; do
  if _curl -X GET "$ES_URL" -o /dev/null >/dev/null 2>&1; then
    echo "Elasticsearch is up."
    break
  fi
  i=$((i+1))
  if [ "$i" -ge 120 ]; then
    echo "WARN: Elasticsearch did not respond after ~240s; continuing anyway..."
    break
  fi
  sleep 2
done

# --- 1) Built-in users: set passwords (idempotent) ---
echo ">> Setting built-in passwords (kibana_system, logstash_system)..."
_pw_kibana=$(json_escape "$KIBANA_SYSTEM_PASSWORD")
_pw_logstash=$(json_escape "$LOGSTASH_SYSTEM_PASSWORD")
_curl -X POST "$ES_URL/_security/user/kibana_system/_password"    --data-binary @- <<EOF || true
{"password":"$_pw_kibana"}
EOF
_curl -X POST "$ES_URL/_security/user/logstash_system/_password" --data-binary @- <<EOF || true
{"password":"$_pw_logstash"}
EOF

# --- 2) Role for Logstash writer ---
echo ">> Creating/updating role ft_logs_writer..."
_curl -X PUT "$ES_URL/_security/role/ft_logs_writer" --data-binary @- <<'EOF'
{
  "cluster": ["monitor","manage_ilm","manage_index_templates","manage_pipeline"],
  "indices": [
    {
      "names": ["ftt-logs-json","ftt-logs-json*","ftt-logs-plain","ftt-logs-plain*"],
      "privileges": ["create_index","create_doc","create","index","write","view_index_metadata"]
    }
  ]
}
EOF

# --- 3) Ensure LS_ES_USER exists and has role ---
echo ">> Ensuring user exists and has ft_logs_writer role..."
_pw_ls=$(json_escape "$LS_ES_PASS")
_user_payload=$(cat <<EOF
{"password":"$_pw_ls","roles":["ft_logs_writer"],"full_name":"FT Logs Writer","enabled":true}
EOF
)
# Try POST (create), then PUT (update)
printf '%s' "$_user_payload" | _curl -X POST "$ES_URL/_security/user/${LS_ES_USER}" --data-binary @- || \
printf '%s' "$_user_payload" | _curl -X PUT  "$ES_URL/_security/user/${LS_ES_USER}" --data-binary @- || true

# --- 4) ILM policy ---
echo ">> Creating ILM policy ftt-logs-7d..."
_curl -X PUT "$ES_URL/_ilm/policy/ftt-logs-7d" --data-binary @- <<'EOF'
{
  "policy": {
    "phases": {
      "hot": { "actions": { "rollover": { "max_primary_shard_size": "25gb", "max_age": "1d" } } },
      "delete": { "min_age": "7d", "actions": { "delete": {} } }
    }
  }
}
EOF

# --- 5) Index template with rollover alias ---
echo ">> Creating index template ftt-logs-json-template..."
_curl -X PUT "$ES_URL/_index_template/ftt-logs-json-template" --data-binary @- <<'EOF'
{
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
        "res": { "properties": { "statusCode": { "type": "integer" } } },
        "responseTime": { "type": "float" },
        "event": { "properties": { "original": { "type": "text" } } }
      }
    },
    "aliases": { "ftt-logs-json": {} }
  },
  "priority": 500
}
EOF

# --- 6) Ensure alias has a write index on clean cluster ---
echo ">> Ensuring alias ftt-logs-json has a write index..."
if ! _curl -X GET "$ES_URL/_alias/ftt-logs-json" -o /dev/null >/dev/null 2>&1; then
  _curl -X PUT "$ES_URL/ftt-logs-json-000001" --data-binary @- <<'EOF' || true
{
  "aliases": { "ftt-logs-json": { "is_write_index": true } }
}
EOF
fi

# --- 7) Snapshot repo + SLM ---
echo ">> Ensuring snapshot repo ftt-fs-repo..."
_curl -X PUT "$ES_URL/_snapshot/ftt-fs-repo" --data-binary @- <<'EOF' || true
{ "type": "fs", "settings": { "location": "/snapshots", "compress": true } }
EOF

echo ">> Ensuring SLM policy ftt-daily-snapshots..."
_curl -X PUT "$ES_URL/_slm/policy/ftt-daily-snapshots" --data-binary @- <<'EOF'
{
  "name": "<ftt-snap-{now/d}>",
  "schedule": "0 30 1 * * ?",
  "repository": "ftt-fs-repo",
  "config": {
    "indices": ["ftt-logs-json*"],
    "ignore_unavailable": true,
    "include_global_state": false
  },
  "retention": { "expire_after": "90d", "min_count": 10, "max_count": 100 }
}
EOF

# --- 8) Single-node convenience (replicas=0) ---
if [ "${SINGLE_NODE:-true}" = "true" ]; then
  echo ">> Setting replicas=0 on common system indices (single-node mode)..."
  for idx in ".kibana" ".kibana_*" ".security" ".internal.alerts-*" ".fleet*" ".monitoring-*" ".reporting-*"; do
    _curl -X PUT "$ES_URL/${idx}/_settings" --data-binary @- <<'EOF' || true
{"index":{"number_of_replicas":"0"}}
EOF
  done
fi

echo ">> ES setup complete."
