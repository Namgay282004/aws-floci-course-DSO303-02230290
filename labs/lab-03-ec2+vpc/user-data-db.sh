#!/bin/bash
MARKER="/var/log/usms-db-bootstrap.done"

if [ -f "$MARKER" ]; then
  echo "Bootstrap already completed at $(cat "$MARKER"). Exiting."
  exit 0
fi

sudo yum update -y
sudo yum install -y postgresql-server postgresql-contrib || sudo dnf install -y postgresql-server
sudo postgresql-setup --initdb 2>/dev/null || true
sudo systemctl enable --now postgresql 2>/dev/null || true

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "unknown-instance")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "InstanceID: ${INSTANCE_ID} | BootstrappedAt: ${TIMESTAMP}" | sudo tee "$MARKER"
