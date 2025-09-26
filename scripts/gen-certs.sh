#!/bin/sh
set -euo pipefail

ESCTL=/usr/share/elasticsearch/bin/elasticsearch-certutil
JAR=/usr/share/elasticsearch/jdk/bin/jar

echo "==> Generating CA..."
$ESCTL ca --silent --pem --out /certs/ca.zip

echo "==> Extracting CA..."
cd /certs
$JAR xf ca.zip && rm -f ca.zip

echo "==> Writing instances.yml..."
cat >/tmp/instances.yml <<'YAML'
instances:
  - name: elasticsearch
    dns: [ "elasticsearch" ]
  - name: kibana
    dns: [ "kibana" ]
  - name: logstash
    dns: [ "logstash" ]
YAML

echo "==> Generating node certificates signed by our CA..."
$ESCTL cert --silent --pem \
  --in /tmp/instances.yml \
  --out /certs/certs.zip \
  --ca-cert /certs/ca/ca.crt \
  --ca-key  /certs/ca/ca.key

echo "==> Extracting service certificates..."
cd /certs
$JAR xf certs.zip && rm -f certs.zip

echo "==> Adjusting permissions..."
chmod -R a+rX /certs

echo "==> Done."
