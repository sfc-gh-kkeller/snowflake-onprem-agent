#!/bin/bash
# ============================================================================
# SnowAgent Demo Startup Script
# ============================================================================
# This script starts all components needed for local testing:
# - Docker Iceberg stack (Lakekeeper, MinIO, PostgreSQL container)
# - Pixi PostgreSQL (for tunnel demo)
# - On-premise tunnel agent
#
# Usage: ./start-demo.sh
# ============================================================================

set -e  # Exit on error

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  SnowAgent Demo Startup"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

# ============================================================================
# Step 1: Check Prerequisites
# ============================================================================
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker not found. Please install Docker first.${NC}"
    exit 1
fi

if ! command -v pixi &> /dev/null; then
    echo -e "${RED}✗ Pixi not found. Please install Pixi first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"

# ============================================================================
# Step 2: Start Docker Iceberg Stack
# ============================================================================
echo -e "\n${YELLOW}[2/6] Starting Docker Iceberg stack (Lakekeeper, MinIO)...${NC}"

# Check if already running
if docker ps | grep -q "iceberg-lakekeeper"; then
    echo -e "${GREEN}✓ Iceberg stack already running${NC}"
else
    echo "Starting docker-compose..."
    docker compose -f docker-compose.iceberg.yml up -d
    
    # Wait for services to be healthy
    echo "Waiting for services to be healthy (max 60s)..."
    for i in {1..60}; do
        if docker ps | grep -q "iceberg-lakekeeper.*healthy" && \
           docker ps | grep -q "iceberg-minio.*healthy"; then
            echo -e "${GREEN}✓ Iceberg stack is healthy${NC}"
            break
        fi
        if [ $i -eq 60 ]; then
            echo -e "${RED}✗ Timeout waiting for services to be healthy${NC}"
            echo "Check logs with: docker compose -f docker-compose.iceberg.yml logs"
            exit 1
        fi
        sleep 1
    done
fi

# ============================================================================
# Step 3: Check Pixi PostgreSQL
# ============================================================================
echo -e "\n${YELLOW}[3/6] Checking Pixi PostgreSQL...${NC}"

# Check if PostgreSQL is running
if pgrep -f "postgres -D" > /dev/null; then
    echo -e "${GREEN}✓ Pixi PostgreSQL is running (port 5432)${NC}"
else
    echo -e "${YELLOW}⚠ Pixi PostgreSQL not running${NC}"
    echo "Starting pixi PostgreSQL..."
    pixi run start-postgres &
    sleep 3
    
    if pgrep -f "postgres -D" > /dev/null; then
        echo -e "${GREEN}✓ Pixi PostgreSQL started${NC}"
    else
        echo -e "${RED}✗ Failed to start pixi PostgreSQL${NC}"
        echo "Try manually: pixi run start-postgres"
        exit 1
    fi
fi

# ============================================================================
# Step 4: Verify Iceberg Data
# ============================================================================
echo -e "\n${YELLOW}[4/6] Checking Iceberg demo data...${NC}"

# Check if demo.sales table exists
ICEBERG_CHECK=$(curl -s http://localhost:8181/catalog/v1/config?warehouse=demo 2>/dev/null || echo "")

if [ -z "$ICEBERG_CHECK" ]; then
    echo -e "${YELLOW}⚠ Lakekeeper not responding yet, waiting...${NC}"
    sleep 5
fi

# Try to list tables
TABLE_CHECK=$(curl -s http://localhost:8181/catalog/v1/9675dbc6-af14-11f0-8f08-87262cab6d95/namespaces/demo/tables 2>/dev/null || echo "")

if echo "$TABLE_CHECK" | grep -q "sales"; then
    echo -e "${GREEN}✓ Iceberg demo.sales table exists${NC}"
else
    echo -e "${YELLOW}⚠ Iceberg demo data not found. Seeding...${NC}"
    pixi run duckdb < demo-data/lakekeeper_seed.sql
    echo -e "${GREEN}✓ Iceberg data seeded${NC}"
fi

# ============================================================================
# Step 5: Verify PostgreSQL Demo Data
# ============================================================================
echo -e "\n${YELLOW}[5/6] Checking PostgreSQL demo data...${NC}"

# Check if test_user and test_db exist
USER_EXISTS=$(pixi run psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='test_user'" 2>/dev/null || echo "")

if [ "$USER_EXISTS" = "1" ]; then
    echo -e "${GREEN}✓ PostgreSQL test_user exists${NC}"
else
    echo -e "${YELLOW}⚠ PostgreSQL test_user not found. Creating...${NC}"
    pixi run psql -d postgres -c "CREATE USER test_user WITH PASSWORD 'test_pass' LOGIN;"
fi

DB_EXISTS=$(pixi run psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='test_db'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
    echo -e "${GREEN}✓ PostgreSQL test_db exists${NC}"
else
    echo -e "${YELLOW}⚠ PostgreSQL test_db not found. Creating...${NC}"
    pixi run psql -d postgres -c "CREATE DATABASE test_db OWNER test_user;"
fi

# Check if users table exists
TABLE_EXISTS=$(pixi run psql -d test_db -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='users'" 2>/dev/null || echo "")

if [ "$TABLE_EXISTS" = "1" ]; then
    echo -e "${GREEN}✓ PostgreSQL demo data exists${NC}"
else
    echo -e "${YELLOW}⚠ PostgreSQL demo data not found. Seeding...${NC}"
    pixi run psql -d test_db < demo-data/init_postgres.sql
    pixi run psql -d test_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO test_user;"
    pixi run psql -d test_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO test_user;"
    echo -e "${GREEN}✓ PostgreSQL data seeded${NC}"
fi

# ============================================================================
# Step 6: Start On-Premise Agent
# ============================================================================
echo -e "\n${YELLOW}[6/6] Starting on-premise tunnel agent...${NC}"

# Check if agent is already running
if pgrep -f "onpremise_agent.py" > /dev/null; then
    echo -e "${YELLOW}⚠ Agent already running. Restarting...${NC}"
    pkill -f "onpremise_agent.py"
    sleep 2
fi

# Check if config exists
if [ ! -f "onpremise-deployment/.env" ]; then
    if [ -f "onpremise-deployment/config.kevin.env" ]; then
        echo "Copying config.kevin.env to .env..."
        cp onpremise-deployment/config.kevin.env onpremise-deployment/.env
    else
        echo -e "${RED}✗ No config file found!${NC}"
        echo "Please create onpremise-deployment/.env with your Snowflake credentials"
        exit 1
    fi
fi

# Start agent in background
echo "Starting agent (logging to /tmp/onpremise-agent.log)..."
pixi run python onpremise-deployment/onpremise_agent.py > /tmp/onpremise-agent.log 2>&1 &
AGENT_PID=$!

# Wait for agent to start
sleep 3

if ps -p $AGENT_PID > /dev/null; then
    echo -e "${GREEN}✓ Agent started (PID: $AGENT_PID)${NC}"
    
    # Check if connected
    sleep 2
    if grep -q "authenticated and ready" /tmp/onpremise-agent.log 2>/dev/null; then
        echo -e "${GREEN}✓ Agent connected to Snowflake!${NC}"
    else
        echo -e "${YELLOW}⚠ Agent started but not yet connected. Check logs:${NC}"
        echo "  tail -f /tmp/onpremise-agent.log"
    fi
else
    echo -e "${RED}✗ Agent failed to start. Check logs:${NC}"
    echo "  cat /tmp/onpremise-agent.log"
    exit 1
fi

# ============================================================================
# Summary
# ============================================================================
echo -e "\n${BLUE}"
echo "═══════════════════════════════════════════════════════════"
echo "  Demo Environment Ready!"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

echo -e "${GREEN}Running Services:${NC}"
echo "  • Docker Iceberg Stack:"
echo "    - Lakekeeper (Iceberg REST): http://localhost:8181"
echo "    - MinIO (S3): http://localhost:9000"
echo "    - PostgreSQL (metadata): internal"
echo ""
echo "  • Pixi PostgreSQL:"
echo "    - Port: 5432"
echo "    - Database: test_db"
echo "    - User: test_user / test_pass"
echo ""
echo "  • On-Premise Tunnel Agent:"
echo "    - Status: Running (PID: $AGENT_PID)"
echo "    - Logs: /tmp/onpremise-agent.log"
echo "    - Port Mappings: 5432, 8181, 9000"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "  1. Check agent logs:"
echo "     tail -f /tmp/onpremise-agent.log"
echo ""
echo "  2. Test PostgreSQL query in Snowflake:"
echo "     SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5');"
echo ""
echo "  3. Test Iceberg query in Snowflake:"
echo "     SELECT query_iceberg('SELECT * FROM demo.demo.sales LIMIT 3');"
echo ""
echo "  4. View service status:"
echo "     docker compose -f docker-compose.iceberg.yml ps"
echo "     ps aux | grep -E 'postgres|onpremise_agent'"

echo -e "\n${YELLOW}Useful Commands:${NC}"
echo "  • View agent logs: tail -f /tmp/onpremise-agent.log"
echo "  • View docker logs: docker compose -f docker-compose.iceberg.yml logs -f"
echo "  • Stop all: ./stop-demo.sh (or pkill -f onpremise_agent.py && docker compose -f docker-compose.iceberg.yml down)"
echo "  • Restart agent: pkill -f onpremise_agent.py && ./start-demo.sh"

echo -e "\n${GREEN}✓ All systems ready for testing!${NC}"




