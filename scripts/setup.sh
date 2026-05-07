#!/usr/bin/env bash
set -euo pipefail

echo "==> Starting monitoring stack setup..."

cd "$(dirname "$0")/../docker"

echo "==> Creating required directories..."
mkdir -p ../grafana/dashboards
mkdir -p ../prometheus/alerts

echo "==> Pulling latest images..."
docker compose pull

echo "==> Starting services..."
docker compose up -d

echo "==> Waiting for services to be healthy..."
sleep 5

echo "==> Checking service status..."
docker compose ps

echo ""
echo "==> Setup complete!"
echo "    Prometheus:   http://localhost:9090"
echo "    Grafana:      http://localhost:3000 (admin/admin)"
echo "    Alertmanager: http://localhost:9093"
