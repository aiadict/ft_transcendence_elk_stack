#!/bin/sh
# scripts/kibana-setup.sh
# Idempotent setup for Kibana: Data View (index-pattern), 4 Lens visualizations, 1 Dashboard.
# Compatible with Kibana 8.x without jq. Uses Saved Objects API for maximum compatibility.

#  fail fast on any error (`-e`), usage of unset vars (`-u`), and failures in piped commands (`pipefail`). Keeps the run deterministic.
set -euo pipefail

# Core endpoints
KBN_URL="https://kibana:5601"
ES_URL="https://elasticsearch:9200"


# Helper that prints response body even on 4xx/5xx (for debugging)
# * Lightweight wrapper around `curl -X POST` that **always prints the response body** (even for 4xx/5xx).
# * Accepts path + JSON payload; adds `kbn-xsrf:true` (required by Kibana APIs) and TLS CA + basic auth.
# * Used everywhere we “save” a Kibana object so we can detect and print structured errors.

kpost() {
  # args: path json_payload
  # returns 0 always; prints response; caller can grep for errors if needed
  local path="$1"; shift
  local payload="$*"
  curl -sS --cacert "${CA_CERT}" -u "elastic:${ELASTIC_PASS}" \
       -H kbn-xsrf:true -H Content-Type:application/json \
       -X POST "${KBN_URL}${path}" -d "${payload}"
}


# Credentials & reusable curl commands
ELASTIC_PASS="${ELASTIC_PASSWORD:?missing ELASTIC_PASSWORD}"
CA_CERT="/certs/ca/ca.crt"
KCURL="curl -sS --fail --cacert ${CA_CERT} -u elastic:${ELASTIC_PASS} -H kbn-xsrf:true -H Content-Type:application/json"
ECURL="curl -sS --fail --cacert ${CA_CERT} -u elastic:${ELASTIC_PASS} -H Content-Type:application/json"

# Waiting for cluster readinges Elasticsearch and Kibana
echo ">> Waiting for Elasticsearch..."
for i in $(seq 1 120); do
  if ${ECURL} -X GET "${ES_URL}" >/dev/null 2>&1; then echo "Elasticsearch is up."; break; fi
  sleep 2
done

echo ">> Waiting for Kibana..."
for i in $(seq 1 180); do
  if ${KCURL} -X GET "${KBN_URL}/api/status" >/dev/null 2>&1; then echo "Kibana is up."; break; fi
  sleep 2
done

# Data View configurations (variables)

DATA_VIEW_ID="ftt-logs"            # Saved object id for the data view
DATA_VIEW_TITLE="ftt-logs-json*"   # Matches alias+ILM pattern
DATA_VIEW_NAME="FTT Logs"
TIME_FIELD="@timestamp"

# ---------------------------------------------------------------------------
# 1) Data View via Saved Objects API (type: index-pattern)
#    Idempotent: overwrite=true ensures we update if it exists.
# ---------------------------------------------------------------------------
echo ">> Upserting Data View '${DATA_VIEW_NAME}' (${DATA_VIEW_ID}) -> ${DATA_VIEW_TITLE}"
kpost "/api/data_views/data_view" "{
  \"data_view\": {
    \"id\": \"${DATA_VIEW_ID}\",
    \"title\": \"${DATA_VIEW_TITLE}\",
    \"timeFieldName\": \"${TIME_FIELD}\",
    \"name\": \"${DATA_VIEW_NAME}\"
  }
}" >/dev/null



echo ">> Setting default index to '${DATA_VIEW_ID}'"
${KCURL} -X POST "${KBN_URL}/api/kibana/settings" -d "{
  \"changes\": { \"defaultIndex\": \"${DATA_VIEW_ID}\" }
}" >/dev/null

# Refresh fields (best-effort; never fail the script)
${KCURL} -X POST "${KBN_URL}/api/data_views/data_view/${DATA_VIEW_ID}/refresh_fields" >/dev/null 2>&1 || true
# Some Kibana builds don’t have the legacy route; also ignore any failure
${KCURL} -X POST "${KBN_URL}/api/index_patterns/index_pattern/${DATA_VIEW_ID}/refresh_fields" >/dev/null 2>&1 || true



# Optional debug: show that the key fields exist in the data view
${KCURL} -X GET "${KBN_URL}/api/data_views/data_view/${DATA_VIEW_ID}" \
| sed 's/\\\\n/\n/g' | sed 's/\\\\\"/\"/g' | sed 's/{\"fields\"/\
{\"fields\"/g' \
| grep -E '\"name\":\"(@timestamp|res\.statusCode|req\.url|responseTime)\"' -n || true



# ---------------------------------------------------------------------------
# 2) Lens visualizations (4x) referencing the Data View id = ftt-logs
#    Using deterministic ids; re-running updates in place (overwrite=true).
#    Set default data view
# ## 11) Lens states (four visualizations) — **formBased datasource**

# Each `LENS*_STATE` is a full persisted Lens “state” object:

# * Common bits:

#   * `"adHocDataViews": {}` and empty `indexpattern/textBased` sections are normal.
#   * The real config lives in `datasourceStates.formBased.layers.<layerId>`.
#   * `columnOrder` defines the render order; each `columns.*` entry defines a field, operation, and params.
#   * Visualization config lives under `"visualization"` (type, series, legend, axes).

# ### `LENS1_STATE` — *Requests over time by status*

# * **Layer id**: `rt_layer`
# * X: `date_histogram` on `@timestamp` (auto interval; include empty rows)
# * Breakdown: `terms` on `res.statusCode` (top 5)
# * Y: `count` of records
# * Chart: line, histogram mode

# ### `LENS2_STATE` — *Top 10 URLs*

# * **Layer id**: `urls_layer`
# * X: `terms` on `req.url` (top 10, order by count desc)
# * Y: `count` of records
# * Chart: vertical bars

# ### `LENS3_STATE` — *Latency p95 over time*

# * **Layer id**: `lat_layer`
# * X: `date_histogram` on `@timestamp`
# * Y: `percentile` 95 on `responseTime`
# * Chart: area, histogram mode

# ### `LENS4_STATE` — *Status code share*

# * **Layer id**: `pie_layer`
# * Slice: `terms` on `res.statusCode` (top 5, alpha order)
# * Metric: `count` of records
# * Chart: donut with labels as percentages

# > Note: all four use `sourceField: "___records___"` for Count (this token matches your Kibana 8.8/8.9 export).
# ---------------------------------------------------------------------------
LENS1_ID="lens-requests-over-time"
LENS1_TITLE="Requests over time by status"
# 1) Requests over time by status (line)
LENS1_STATE='{
  "adHocDataViews": {},
  "visualization": {
    "legend": { "isVisible": true, "position": "right" },
    "preferredSeriesType": "line",
    "valueLabels": "hide",
    "layers": [
      {
        "layerId": "rt_layer",
        "layerType": "data",
        "xAccessor": "ts",
        "accessors": ["cnt"],
        "splitAccessor": "status",
        "seriesType": "line",
        "position": "top",
        "showGridlines": false
      }
    ]
  },
  "query": { "language": "kuery", "query": "" },
  "filters": [],
  "datasourceStates": {
    "formBased": {
      "layers": {
        "rt_layer": {
          "columnOrder": ["ts", "status", "cnt"],
          "columns": {
            "ts": {
              "label": "@timestamp",
              "dataType": "date",
              "operationType": "date_histogram",
              "sourceField": "@timestamp",
              "isBucketed": true,
              "scale": "interval",
              "params": { "interval": "auto", "includeEmptyRows": true, "dropPartials": false }
            },
            "status": {
              "label": "Top values of res.statusCode",
              "dataType": "number",
              "operationType": "terms",
              "sourceField": "res.statusCode",
              "isBucketed": true,
              "scale": "ordinal",
              "params": {
                "size": 5,
                "orderBy": { "type": "column", "columnId": "cnt" },
                "orderDirection": "desc"
              }
            },
            "cnt": {
              "label": "Count of records",
              "dataType": "number",
              "operationType": "count",
              "sourceField": "___records___",
              "isBucketed": false,
              "scale": "ratio",
              "params": { "emptyAsNull": true }
            }
          },
          "incompleteColumns": {},
          "sampling": 1
        }
      }
    },
    "indexpattern": { "layers": {} },
    "textBased": { "layers": {} }
  }
}'


LENS2_ID="lens-top-urls"
LENS2_TITLE="Top 10 URLs"
# 2) Top 10 URLs (bar)
LENS2_STATE='{
  "adHocDataViews": {},
  "visualization": {
    "legend": { "isVisible": false, "position": "right" },
    "preferredSeriesType": "bar",
    "valueLabels": "hide",
    "layers": [
      {
        "layerId": "urls_layer",
        "layerType": "data",
        "xAccessor": "url",
        "accessors": ["cnt"],
        "seriesType": "bar",
        "position": "top",
        "showGridlines": false
      }
    ]
  },
  "query": { "language": "kuery", "query": "" },
  "filters": [],
  "datasourceStates": {
    "formBased": {
      "layers": {
        "urls_layer": {
          "columnOrder": ["url", "cnt"],
          "columns": {
            "url": {
              "label": "Top values of req.url",
              "dataType": "string",
              "operationType": "terms",
              "sourceField": "req.url",
              "isBucketed": true,
              "scale": "ordinal",
              "params": {
                "size": 10,
                "orderBy": { "type": "column", "columnId": "cnt" },
                "orderDirection": "desc"
              }
            },
            "cnt": {
              "label": "Count of records",
              "dataType": "number",
              "operationType": "count",
              "sourceField": "___records___",
              "isBucketed": false,
              "scale": "ratio",
              "params": { "emptyAsNull": true }
            }
          },
          "incompleteColumns": {},
          "sampling": 1
        }
      }
    },
    "indexpattern": { "layers": {} },
    "textBased": { "layers": {} }
  }
}'







LENS3_ID="lens-latency-p95"
LENS3_TITLE="Latency p95 over time"
# 3) Latency p95 over time (area)
LENS3_STATE='{
  "adHocDataViews": {},
  "visualization": {
    "legend": { "isVisible": false },
    "preferredSeriesType": "area",
    "valueLabels": "hide",
    "layers": [
      {
        "layerId": "lat_layer",
        "layerType": "data",
        "xAccessor": "ts",
        "accessors": ["p95"],
        "seriesType": "area",
        "position": "top",
        "showGridlines": false
      }
    ]
  },
  "query": { "language": "kuery", "query": "" },
  "filters": [],
  "datasourceStates": {
    "formBased": {
      "layers": {
        "lat_layer": {
          "columnOrder": ["ts", "p95"],
          "columns": {
            "ts": {
              "label": "@timestamp",
              "dataType": "date",
              "operationType": "date_histogram",
              "sourceField": "@timestamp",
              "isBucketed": true,
              "scale": "interval",
              "params": { "interval": "auto", "includeEmptyRows": true, "dropPartials": false }
            },
            "p95": {
              "label": "p95 of responseTime",
              "dataType": "number",
              "operationType": "percentile",
              "sourceField": "responseTime",
              "isBucketed": false,
              "scale": "ratio",
              "params": { "percentile": 95, "emptyAsNull": true }
            }
          },
          "incompleteColumns": {},
          "sampling": 1
        }
      }
    },
    "indexpattern": { "layers": {} },
    "textBased": { "layers": {} }
  }
}'







LENS4_ID="lens-status-pie"
LENS4_TITLE="Status code share"
LENS4_STATE='{
  "adHocDataViews": {},
  "visualization": {
    "shape": "donut",
    "labels": { "show": true },
    "valueLabels": "hide",
    "layers": [
      {
        "layerId": "pie_layer",
        "layerType": "data",
        "primaryGroups": ["slice"],
        "metrics": ["cnt"],
        "numberDisplay": "percent"
      }
    ]
  },
  "query": { "language": "kuery", "query": "" },
  "filters": [],
  "datasourceStates": {
    "formBased": {
      "layers": {
        "pie_layer": {
          "columnOrder": ["slice", "cnt"],
          "columns": {
            "slice": {
              "label": "res.statusCode",
              "dataType": "number",
              "operationType": "terms",
              "sourceField": "res.statusCode",
              "isBucketed": true,
              "scale": "ordinal",
              "params": {
                "size": 5,
                "orderBy": { "type": "alphabetical" },
                "orderDirection": "asc"
              }
            },
            "cnt": {
              "label": "Count of records",
              "dataType": "number",
              "operationType": "count",
              "sourceField": "___records___",
              "isBucketed": false,
              "scale": "ratio",
              "params": { "emptyAsNull": true }
            }
          },
          "incompleteColumns": {},
          "sampling": 1
        }
      }
    },
    "indexpattern": { "layers": {} },
    "textBased": { "layers": {} }
  }
}'

# `so_upsert_lens()` — save a Lens object
# Args**: `id`, `title`, `visType`, `state_json`, `layer_id`.
# Builds a Saved Object body with:
# `attributes`: `title`, `visualizationType`, and the **raw** `state` object (not stringified).
# `references`: wires the Data View by name
# `indexpattern-datasource-layer-${layer_id}` → **must match the layer id** inside `formBased.layers`.
# POST `/api/saved_objects/lens/${id}?overwrite=true` via `kpost`.
# If the response contains `"statusCode"`, prints the error and **exits** (keeps runs clean).

so_upsert_lens () {
  local id="$1" title="$2" visType="$3" state_json="$4" layer_id="$5"

  local BODY_OBJECT
  BODY_OBJECT=$(cat <<JSON
{
  "attributes": {
    "title": "${title}",
    "description": "",
    "visualizationType": "${visType}",
    "state": ${state_json}
  },
  "references": [
    { "type": "index-pattern", "id": "${DATA_VIEW_ID}", "name": "indexpattern-datasource-layer-${layer_id}" }
  ]
}
JSON
)
  echo ">> Upserting Lens '${title}' (${id}) as ${visType}..."
  RESP="$(kpost "/api/saved_objects/lens/${id}?overwrite=true" "${BODY_OBJECT}")" || true
  if printf '%s' "$RESP" | grep -q '"statusCode":'; then
    echo "!! Kibana error creating lens '${id}':"
    echo "$RESP"
    exit 1
  fi
}


# Create the four Lens visualizations
# Calls `so_upsert_lens` with each Lens id/title/type/state and its matching layer id:
# `rt_layer`, `urls_layer`, `lat_layer`, `pie_layer`.
# Idempotent**: `overwrite=true` updates in place across runs.

so_upsert_lens "${LENS1_ID}" "${LENS1_TITLE}" "lnsXY"  "${LENS1_STATE}" "rt_layer"
so_upsert_lens "${LENS2_ID}" "${LENS2_TITLE}" "lnsXY"  "${LENS2_STATE}" "urls_layer"
so_upsert_lens "${LENS3_ID}" "${LENS3_TITLE}" "lnsXY"  "${LENS3_STATE}" "lat_layer"
so_upsert_lens "${LENS4_ID}" "${LENS4_TITLE}" "lnsPie" "${LENS4_STATE}" "pie_layer"



# 14) Dashboard definition
# `DASH_ID`, `DASH_TITLE`: stable id and title.
# `PANELS_JSON`: four panels with grid placement (two rows, two cols).
# Uses **`panelRefName`** so the actual Lens ids live in the top-level `references`.
# `PANELS_JSON_ESCAPED`: flattens + escapes `PANELS_JSON` for embedding into the Saved Object.
# `DASH_BODY`:
# `timeRestore: true` + `timeFrom: "now-24h"` + `refreshInterval: 60s`: the dashboard opens with a 24h range and auto-refresh.
# `kibanaSavedObjectMeta.searchSourceJSON`: blank kuery + no filters.
# `panelsJSON`: the escaped layout.
# `references`: maps `panel_1..4` → Lens ids.
# POST `/api/saved_objects/dashboard/${DASH_ID}?overwrite=true`.
# On error, prints the response and exits.

DASH_ID="dashboard-ftt-overview"
DASH_TITLE="FTT Logs Overview"

# Use panelRefName, not raw "id" (ids live in the top-level references array)
PANELS_JSON='[
  {"panelIndex":"1","type":"lens","panelRefName":"panel_1","gridData":{"x":0,"y":0,"w":24,"h":15,"i":"1"},"embeddableConfig":{}},
  {"panelIndex":"2","type":"lens","panelRefName":"panel_2","gridData":{"x":24,"y":0,"w":24,"h":15,"i":"2"},"embeddableConfig":{}},
  {"panelIndex":"3","type":"lens","panelRefName":"panel_3","gridData":{"x":0,"y":15,"w":24,"h":15,"i":"3"},"embeddableConfig":{}},
  {"panelIndex":"4","type":"lens","panelRefName":"panel_4","gridData":{"x":24,"y":15,"w":24,"h":15,"i":"4"},"embeddableConfig":{}}
]'

# Turn newlines into spaces, then escape backslashes and quotes
PANELS_JSON_ESCAPED=$(printf '%s' "$PANELS_JSON" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')


DASH_BODY='{
  "attributes": {
    "title": "FTT Logs Overview",
    "description": "Auto-created dashboard for FTT logs (alias + ILM)",
    "timeRestore": true,
    "timeFrom": "now-24h",
    "timeTo": "now",
    "refreshInterval": { "pause": false, "value": 60000 },
    "optionsJSON": "{}",
    "kibanaSavedObjectMeta": {
      "searchSourceJSON": "{\"query\":{\"language\":\"kuery\",\"query\":\"\"},\"filter\":[]}"
    },
    "panelsJSON": "'"${PANELS_JSON_ESCAPED}"'"
  },
  "references": [
    {"type":"lens","id":"'"${LENS1_ID}"'","name":"panel_1"},
    {"type":"lens","id":"'"${LENS2_ID}"'","name":"panel_2"},
    {"type":"lens","id":"'"${LENS3_ID}"'","name":"panel_3"},
    {"type":"lens","id":"'"${LENS4_ID}"'","name":"panel_4"}
  ]
}'




echo ">> Upserting Dashboard '${DASH_TITLE}' (${DASH_ID})..."
RESP="$(kpost "/api/saved_objects/dashboard/${DASH_ID}?overwrite=true" "${DASH_BODY}")" || true
if printf '%s' "$RESP" | grep -q '"statusCode":'; then
  echo "!! Kibana error creating dashboard '${DASH_ID}':"
  echo "$RESP"
  exit 1
fi

echo ">> Done. Open Kibana → Dashboard → 'FTT Logs Overview'."

