#!/bin/bash
# ============================================================================
# SnowAgent - Build and Push Docker Images
# ============================================================================
# Builds and pushes all required containers to Snowflake registry
#
# Usage: ./build-and-push.sh <SNOWFLAKE_REGISTRY_URL>
#
# Example:
#   ./build-and-push.sh sfsenorthamerica-secfieldkeller.registry.snowflakecomputing.com/websocket_test_db/websocket_test_schema/websocket_images
#
# Prerequisites:
#   - Docker installed and running
#   - Logged into Snowflake registry: docker login <registry_url>
# ============================================================================

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Validate Arguments
# ============================================================================

if [ -z "$1" ]; then
    echo -e "${RED}Error: Snowflake registry URL required${NC}"
    echo ""
    echo "Usage: $0 <SNOWFLAKE_REGISTRY_URL>"
    echo ""
    echo "Example:"
    echo "  $0 sfsenorthamerica-secfieldkeller.registry.snowflakecomputing.com/websocket_test_db/websocket_test_schema/websocket_images"
    echo ""
    echo "Your registry URL format:"
    echo "  <org>-<account>.registry.snowflakecomputing.com/<database>/<schema>/<repository>"
    echo ""
    exit 1
fi

REGISTRY_URL="$1"
TAG="${2:-latest}"  # Optional tag, defaults to 'latest'

# Extract registry host for docker login check
REGISTRY_HOST=$(echo "$REGISTRY_URL" | cut -d'/' -f1)

echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  SnowAgent - Build and Push Docker Images"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo -e "${CYAN}Registry:${NC} $REGISTRY_URL"
echo -e "${CYAN}Tag:${NC} $TAG"
echo -e "${CYAN}Architecture:${NC} linux/amd64 (Intel)"
echo ""

# ============================================================================
# Image Definitions
# ============================================================================

# Image name and Dockerfile pairs (compatible with bash 3.2+)
IMAGES=(
    "postgresql-query:Dockerfile.postgresql_service.pixi"
    "tunnel-sidecar:Dockerfile.tunnel-sidecar.pixi"
    "pgadmin-test:Dockerfile.pgadmin"
)

# ============================================================================
# Build and Push Images
# ============================================================================

TOTAL=${#IMAGES[@]}
CURRENT=0
FAILED=()

for IMAGE_PAIR in "${IMAGES[@]}"; do
    CURRENT=$((CURRENT + 1))
    IMAGE_NAME="${IMAGE_PAIR%%:*}"
    DOCKERFILE="${IMAGE_PAIR##*:}"
    
    echo -e "${BLUE}"
    echo "═══════════════════════════════════════════════════════════"
    echo "  [$CURRENT/$TOTAL] Building: $IMAGE_NAME"
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${NC}"
    
    # Check if Dockerfile exists
    if [ ! -f "$DOCKERFILE" ]; then
        echo -e "${RED}✗ Dockerfile not found: $DOCKERFILE${NC}"
        FAILED+=("$IMAGE_NAME")
        echo ""
        continue
    fi
    
    # Full image name with registry
    FULL_IMAGE_NAME="$REGISTRY_URL/$IMAGE_NAME:$TAG"
    
    echo -e "${YELLOW}Building image...${NC}"
    echo "  Dockerfile: $DOCKERFILE"
    echo "  Image: $FULL_IMAGE_NAME"
    echo "  Platform: linux/amd64"
    echo ""
    
    # Build image
    if docker build \
        --platform linux/amd64 \
        -f "$DOCKERFILE" \
        -t "$IMAGE_NAME:$TAG" \
        -t "$FULL_IMAGE_NAME" \
        . ; then
        echo -e "${GREEN}✓ Build successful${NC}"
    else
        echo -e "${RED}✗ Build failed${NC}"
        FAILED+=("$IMAGE_NAME")
        echo ""
        continue
    fi
    
    echo ""
    echo -e "${YELLOW}Pushing image to registry...${NC}"
    
    # Push image
    if docker push "$FULL_IMAGE_NAME"; then
        echo -e "${GREEN}✓ Push successful${NC}"
    else
        echo -e "${RED}✗ Push failed${NC}"
        echo ""
        echo -e "${YELLOW}Authentication issue?${NC} Try logging in:"
        echo -e "${CYAN}  docker login $REGISTRY_HOST -u <username>${NC}"
        echo ""
        echo "Use your Snowflake username and Personal Access Token (PAT) as password"
        FAILED+=("$IMAGE_NAME")
    fi
    
    echo ""
done

# ============================================================================
# Summary
# ============================================================================

echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  Build Summary"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""

if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All images built and pushed successfully!${NC}"
    echo ""
    echo "Images available:"
    for IMAGE_PAIR in "${IMAGES[@]}"; do
        IMAGE_NAME="${IMAGE_PAIR%%:*}"
        echo -e "  ${GREEN}✓${NC} $REGISTRY_URL/$IMAGE_NAME:$TAG"
    done
else
    echo -e "${RED}✗ Some images failed:${NC}"
    for IMAGE_NAME in "${FAILED[@]}"; do
        echo -e "  ${RED}✗${NC} $IMAGE_NAME"
    done
    echo ""
    echo -e "${YELLOW}Review errors above and retry${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  Next Steps"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"
echo ""
echo "1. Update CREATE-SERVICE.sql with your registry URL:"
echo ""
echo "   spec:"
echo "     containers:"
echo "     - name: postgresql-query"
echo "       image: $REGISTRY_URL/postgresql-query:$TAG"
echo "     - name: tunnel-sidecar"
echo "       image: $REGISTRY_URL/tunnel-sidecar:$TAG"
echo ""
echo "2. Deploy service in Snowflake:"
echo "   snowsql -f SETUP-SNOWFLAKE-SERVICE.sql"
echo "   (or execute step-by-step in Snowflake UI)"
echo ""
echo "3. Get WebSocket endpoint:"
echo "   snowsql -q \"SHOW ENDPOINTS IN SERVICE websocket_multi_db_service\""
echo ""
echo "4. Configure on-premise agent:"
echo "   cp onpremise-deployment/config.template.env onpremise-deployment/.env"
echo "   vim onpremise-deployment/.env  # Add SNOWFLAKE_URL, SNOWFLAKE_ACCOUNT, SNOWFLAKE_PAT"
echo ""
echo -e "${GREEN}Build complete!${NC}"
echo ""

