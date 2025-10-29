#!/bin/bash
# Build and push all images for v3.0 (PostgreSQL + Iceberg)

set -e

REGISTRY="sfsenorthamerica-secfieldkeller.registry.snowflakecomputing.com"
REPO="websocket_test_db/websocket_test_schema/websocket_images"
TAG="${1:-latest}"

echo "============================================================"
echo " Building v3.0 Images (PostgreSQL + Iceberg)"
echo "============================================================"
echo "Registry: $REGISTRY"
echo "Repository: $REPO"
echo "Tag: $TAG"
echo "============================================================"
echo ""

# 1. Build tunnel-sidecar (generic - no changes)
echo "🔨 Building tunnel-sidecar..."
docker build \
  --platform linux/amd64 \
  -f Dockerfile.tunnel-sidecar.pixi \
  -t tunnel-sidecar:$TAG \
  -t $REGISTRY/$REPO/tunnel-sidecar:$TAG \
  .
echo "✅ tunnel-sidecar built"
echo ""

# 2. Build snowflake-agent (PostgreSQL)
echo "🔨 Building snowflake-agent (PostgreSQL)..."
docker build \
  --platform linux/amd64 \
  -f Dockerfile.snowflake.pixi \
  -t snowflake-agent:$TAG \
  -t $REGISTRY/$REPO/snowflake-agent:$TAG \
  .
echo "✅ snowflake-agent built"
echo ""

# 3. Build iceberg-agent (NEW!)
echo "🔨 Building iceberg-agent (Iceberg/DuckDB)..."
docker build \
  --platform linux/amd64 \
  -f Dockerfile.iceberg.pixi \
  -t iceberg-agent:$TAG \
  -t $REGISTRY/$REPO/iceberg-agent:$TAG \
  .
echo "✅ iceberg-agent built"
echo ""

echo "============================================================"
echo " Pushing Images to Snowflake Registry"
echo "============================================================"
echo ""

# Push all images
echo "📤 Pushing tunnel-sidecar..."
docker push $REGISTRY/$REPO/tunnel-sidecar:$TAG
echo "✅ tunnel-sidecar pushed"
echo ""

echo "📤 Pushing snowflake-agent..."
docker push $REGISTRY/$REPO/snowflake-agent:$TAG
echo "✅ snowflake-agent pushed"
echo ""

echo "📤 Pushing iceberg-agent..."
docker push $REGISTRY/$REPO/iceberg-agent:$TAG
echo "✅ iceberg-agent pushed"
echo ""

echo "============================================================"
echo " ✅ All images built and pushed successfully!"
echo "============================================================"
echo ""
echo "Images:"
echo "  - $REGISTRY/$REPO/tunnel-sidecar:$TAG"
echo "  - $REGISTRY/$REPO/snowflake-agent:$TAG"
echo "  - $REGISTRY/$REPO/iceberg-agent:$TAG"
echo ""
echo "Next steps:"
echo "  1. Create/update service: @CREATE-SERVICE-V3-ICEBERG.sql"
echo "  2. Start local Iceberg: pixi run start-iceberg"
echo "  3. Initialize demo data: pixi run init-iceberg-data"
echo "  4. Update on-premise config with new endpoint"
echo "  5. Start agent: pixi run start-agent"
echo "============================================================"



