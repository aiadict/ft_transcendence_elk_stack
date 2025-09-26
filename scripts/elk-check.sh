#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------
# ELK Stack validation script (HTTPS + ILM + SLM)
# - waits for ES/Kibana
# - runs end-to-end checks
# - optional --out /path/to/file.log to capture output
# ---------------------------------------------

# ---- Config you probably don't need to change ----
PROJECT_NET="elk-module_default"
CERT_VOL="elk-module_certs"
ENV_FILE=".env"
CURL_IMG="curlimages/curl:8.10.1"
ALPINE_IMG="alpine:3.20"
ES_URL="https://elasticsearch:9200"
KB_URL="https://kibana:5601"

# ---- Parse args ----
OUT_FILE=""
if [[ "${1:-}" == "--out" ]]; then
  OUT_FILE="${2:-}"
fi

# ---- Logging helpers ----
ts() { date +"%Y-%m-%d %H:%M:%S"; }
hr() { printf -- "------------------------------------------------------------\n"; }

log() {
  if [[ -n "$OUT_FILE" ]]; then
    printf "[%s] %s\n" "$(ts)" "$*" | tee -a "$OUT_FILE"
  else
    printf "[%s] %s\n" "$(ts)" "$*"
  fi
}
print() {
  if [[ -n "$OUT_FILE" ]]; then
    cat | tee -a "$OUT_FILE"
  else
    cat
  fi
}

# ---- Preconditions ----
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required"; exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose v2 is required"; exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo ".env not found in current directory"; exit 1
fi

# ---- Small wrappers around dockerized curl ----
# Usage: dcurl "<curl args...>"  (automatically mounts certs + .env and runs inside the compose network)
dcurl() {
  docker run --rm --network "$PROJECT_NET" \
    -v "${CERT_VOL}:/certs:ro" \
    -v "$PWD/${ENV_FILE}:/env:ro" \
    "$CURL_IMG" sh -lc '
      set -e
      set -a; . /env; set +a
      curl '"$*"'
    '
}
# Same as above but captures HTTP code separately.
# Usage: dcurl_status '<curl args>' -> prints body to stdout and returns 0; sets global CURL_HTTP_CODE var
# Same as dcurl but captures HTTP code on a separate line.
# Prints body to stdout and sets CURL_HTTP_CODE to 3-digit code (or 000 if missing).
CURL_HTTP_CODE=""
dcurl_status() {
  local args="$*"
  local out code body
  out="$(docker run --rm --network "$PROJECT_NET" \
           -v "${CERT_VOL}:/certs:ro" -v "$PWD/${ENV_FILE}:/env:ro" \
           "$CURL_IMG" sh -lc 'set -a; . /env; set +a; \
             curl -sS -w "\n%{http_code}" '"$args"' 2>/dev/null || true')"

  # Last line is the code; everything above is the body
  code="$(printf "%s" "$out" | tail -n1)"
  body="$(printf "%s" "$out" | sed '$d')"

  # Fallback if curl never reached the HTTP layer
  if ! printf "%s\n" "$code" | grep -Eq '^[0-9]{3}$'; then
    code="000"
  fi

  CURL_HTTP_CODE="$code"
  printf "%s" "$body"
  return 0
}

# ---- Waiters ----
# in scripts/elk-check.sh
wait_es() {
  log "Waiting for Elasticsearch (HTTPS) to be ready..."
  local i=0 code=""
  while :; do
	code="$(dcurl "-s --cacert /certs/ca/ca.crt -u elastic:\$ELASTIC_PASSWORD -o /dev/null -w '%{http_code}' \"$ES_URL/_cluster/health?wait_for_status=yellow&timeout=5s\"")"

    log "  -> ES /_cluster/health HTTP $code"
    if [[ "$code" =~ ^20[0-9]$ ]]; then
      log "Elasticsearch is up."
      return 0
    fi
    i=$((i+1))
    if (( i > 60 )); then
      log "ERROR: ES not ready after ~5min (last code=$code). Continuing checks..."
      return 1
    fi
    sleep 5
  done
}

wait_kibana() {
  log "Waiting for Kibana status=available..."
  local i=0 code=""
  while :; do
    code="$(dcurl "-s --cacert /certs/ca/ca.crt -u elastic:\$ELASTIC_PASSWORD -o /dev/null -w '%{http_code}' \"$KB_URL/api/status\"")"
    log "  -> Kibana /api/status HTTP $code"
    if [[ "$code" == "200" ]]; then
      log "Kibana is available."
      return 0
    fi
    i=$((i+1))
    if (( i > 60 )); then
      log "WARN: Kibana not available yet (last HTTP $code). Continuing checks..."
      return 1
    fi
    sleep 5
  done
}



# ---- Checks ----
check_compose_ps() {
  log "1) docker compose ps"
  docker compose ps | print
  hr | print
}
check_certs() {
  log "2) Certificates present in volume $CERT_VOL"
  docker run --rm -v "${CERT_VOL}:/certs" "$ALPINE_IMG" sh -lc 'ls -lR /certs || true' | print
  hr | print
}
check_es_root() {
  log "3) Probe ES root over HTTPS"
  dcurl "-i --cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/" | print
  hr | print
}
check_es_health() {
  log "4) Cluster health"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_cluster/health?pretty" | print
  hr | print
}
check_role_user() {
  log "5) Role: logstash_writer_ftt"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_security/role/logstash_writer_ftt" | print
  hr | print
  log "6) User: \$LS_ES_USER"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_security/user/$LS_ES_USER" | print
  hr | print
}
check_ilm_policy() {
  log "7) ILM policy ftt-logs-policy"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_ilm/policy/ftt-logs-policy" | print
  hr | print
}
check_templates() {
  log "8) Index templates"
  for t in ftt-logs-json-template ftt-logs-plain-template; do
    log "== $t =="
    dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_index_template/$t" | print
    echo | print
  done
  hr | print
}
check_indices() {
  log "9) Cat indices for streams (expect -000001 names; docs.count growing)"
  dcurl "-s --cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD \"$ES_URL/_cat/indices/ftt-logs-*-*?s=index&v\"" | print
  hr | print
}
check_search_sample() {
  log "10) Sample JSON doc from alias ftt-logs-json"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD -X GET \"$ES_URL/ftt-logs-json/_search?size=1&pretty\"" | print
  hr | print
}
check_ilm_explain() {
  log "11) ILM explain for current JSON write index"
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD \"$ES_URL/ftt-logs-json-000001/_ilm/explain?pretty\"" | print
  hr | print
}
check_snapshots_slm() {
  log "12) Snapshot repo + SLM policy"
  log "== repo =="
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_snapshot/ftt-fs-repo" | print
  echo | print
  log "== slm =="
  dcurl "--cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $ES_URL/_slm/policy/ftt-daily-snapshots" | print
  hr | print
}
check_kibana_auth() {
  log "13) kibana_system can auth to ES"
  dcurl "-i --cacert /certs/ca/ca.crt -u kibana_system:$KIBANA_SYSTEM_PASSWORD $ES_URL/_security/_authenticate" | print
  hr | print
}
check_kibana_status() {
  log "14) Kibana status"
  dcurl "-i --cacert /certs/ca/ca.crt -u elastic:$ELASTIC_PASSWORD $KB_URL/api/status" | print
  hr | print
}
tail_kibana() {
  log "15) Last 200 Kibana logs"
  docker compose logs --no-color --tail=200 kibana | print
  hr | print
}
tail_logstash() {
  log "16) Last 200 Logstash logs"
  docker compose logs --no-color --tail=200 logstash | print
  hr | print
}
check_generators() {
  log "17) Generators running?"
  docker compose ps loggen-json | print
  hr | print
}
check_plaintext_blocked() {
  log "18) (Optional) HTTP plaintext to ES should fail"
  docker run --rm --network "$PROJECT_NET" "$CURL_IMG" sh -lc 'curl -i http://elasticsearch:9200/ || true' | print
  hr | print
}

# ---- Main ----
log "ELK CHECK START"
hr | print

check_compose_ps
check_certs

# Waits
# shellcheck disable=SC1090
set +u; source "$ENV_FILE"; set -u  # so we can use $ELASTIC_PASSWORD immediately for waits
wait_es || true
wait_kibana || true

check_es_root
check_es_health
check_role_user
check_ilm_policy
check_templates
check_indices
check_search_sample
check_ilm_explain
check_snapshots_slm
check_kibana_auth
check_kibana_status
tail_kibana
tail_logstash
check_generators
check_plaintext_blocked

log "ELK CHECK DONE"
