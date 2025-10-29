#!/bin/bash
# ============================================================================
# SnowAgent Demo Shutdown Script
# ============================================================================
# Stops all demo components gracefully
# Usage: ./stop-demo.sh
# ============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  SnowAgent Demo Shutdown"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

# ============================================================================
# Stop On-Premise Agent
# ============================================================================
echo -e "${YELLOW}[1/3] Stopping on-premise tunnel agent...${NC}"

if pgrep -f "onpremise_agent.py" > /dev/null; then
    pkill -f "onpremise_agent.py"
    sleep 2
    if pgrep -f "onpremise_agent.py" > /dev/null; then
        echo -e "${YELLOW}⚠ Agent still running, force killing...${NC}"
        pkill -9 -f "onpremise_agent.py"
    fi
    echo -e "${GREEN}✓ Agent stopped${NC}"
else
    echo -e "${GREEN}✓ Agent not running${NC}"
fi

# ============================================================================
# Stop Docker Iceberg Stack
# ============================================================================
echo -e "\n${YELLOW}[2/3] Stopping Docker Iceberg stack...${NC}"

if docker ps | grep -q "iceberg-"; then
    docker compose -f docker-compose.iceberg.yml down
    echo -e "${GREEN}✓ Iceberg stack stopped${NC}"
else
    echo -e "${GREEN}✓ Iceberg stack not running${NC}"
fi

# ============================================================================
# Note about Pixi PostgreSQL
# ============================================================================
echo -e "\n${YELLOW}[3/3] Pixi PostgreSQL...${NC}"

if pgrep -f "postgres -D" > /dev/null; then
    echo -e "${YELLOW}ℹ Pixi PostgreSQL is still running (shared resource)${NC}"
    echo "  To stop manually: pixi run postgres-stop"
    echo "  Or: pkill -f 'postgres -D'"
else
    echo -e "${GREEN}✓ Pixi PostgreSQL not running${NC}"
fi

# ============================================================================
# Summary
# ============================================================================
echo -e "\n${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  Shutdown Complete"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

echo -e "${GREEN}Stopped:${NC}"
echo "  ✓ On-premise tunnel agent"
echo "  ✓ Docker Iceberg stack (Lakekeeper, MinIO)"
echo ""
echo -e "${YELLOW}Note:${NC} Pixi PostgreSQL may still be running (shared resource)"
echo ""
echo -e "${GREEN}To restart: ./start-demo.sh${NC}"


