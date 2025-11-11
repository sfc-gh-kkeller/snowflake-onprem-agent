#!/bin/bash
# ============================================================================
# SnowAgent PostgreSQL-Only Startup Script
# ============================================================================
# This script starts only the PostgreSQL components (no Iceberg):
# - Pixi PostgreSQL
# - On-premise tunnel agent (PostgreSQL only)
#
# Usage: ./start-postgres-only.sh
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
echo "  SnowAgent PostgreSQL-Only Startup"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

# ============================================================================
# Step 1: Check Prerequisites
# ============================================================================
echo -e "${YELLOW}[1/3] Checking prerequisites...${NC}"

if ! command -v pixi &> /dev/null; then
    echo -e "${RED}✗ Pixi not found. Please install Pixi first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"

# ============================================================================
# Step 2: Initialize PostgreSQL Database (if needed)
# ============================================================================
echo -e "\n${YELLOW}[2/4] Checking PostgreSQL database initialization...${NC}"

# Check if database cluster is initialized
if [ ! -d ".pixi/postgres-data" ]; then
    echo -e "${YELLOW}⚠ PostgreSQL not initialized${NC}"
    echo "Initializing PostgreSQL database cluster..."
    pixi run init-db
    
    if [ -d ".pixi/postgres-data" ]; then
        echo -e "${GREEN}✓ PostgreSQL initialized${NC}"
    else
        echo -e "${RED}✗ Failed to initialize PostgreSQL${NC}"
        echo "Try manually: pixi run init-db"
        exit 1
    fi
else
    echo -e "${GREEN}✓ PostgreSQL database cluster initialized${NC}"
fi

# ============================================================================
# Step 3: Start Pixi PostgreSQL
# ============================================================================
echo -e "\n${YELLOW}[3/4] Checking Pixi PostgreSQL...${NC}"

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
# Step 4: Verify PostgreSQL Demo Data
# ============================================================================
echo -e "\n${YELLOW}[4/5] Checking PostgreSQL demo data...${NC}"

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
# Step 5: Start On-Premise Tunnel Agent
# ============================================================================
echo -e "\n${YELLOW}[5/5] Starting on-premise tunnel agent...${NC}"

# Check if agent is already running
if pgrep -f "onpremise_agent.py" > /dev/null; then
    echo -e "${YELLOW}⚠ Agent already running. Restarting...${NC}"
    pkill -f "onpremise_agent.py"
    sleep 2
fi

# Check if config exists
if [ ! -f "onpremise-deployment/.env" ]; then
    echo -e "${RED}✗ Configuration file not found!${NC}"
    echo ""
    echo "Please create: ${YELLOW}onpremise-deployment/.env${NC}"
    echo ""
    echo "You can use the template as a starting point:"
    echo -e "  ${CYAN}cp onpremise-deployment/config.template.env onpremise-deployment/.env${NC}"
    echo ""
    echo "Then edit onpremise-deployment/.env with your Snowflake credentials:"
    echo "  - SNOWFLAKE_URL (WebSocket endpoint from service)"
    echo "  - SNOWFLAKE_ACCOUNT"
    echo "  - SNOWFLAKE_PAT (Personal Access Token)"
    echo "  - SNOWFLAKE_ROLE"
    echo ""
    echo "See config.template.env for detailed documentation"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Configuration file found: onpremise-deployment/.env${NC}"

# Start agent in background with PostgreSQL-only port mappings
echo "Starting agent with PostgreSQL-only port mappings (logging to /tmp/onpremise-agent.log)..."
PORT_MAPPINGS_FILE=port_mappings.postgres-only.json pixi run python onpremise-deployment/onpremise_agent.py > /tmp/onpremise-agent.log 2>&1 &
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
echo "  PostgreSQL Demo Environment Ready!"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

echo -e "${GREEN}Running Services:${NC}"
echo "  • Pixi PostgreSQL:"
echo "    - Port: 5432"
echo "    - Database: test_db"
echo "    - User: test_user / test_pass"
echo ""
echo "  • On-Premise Tunnel Agent:"
echo "    - Status: Running (PID: $AGENT_PID)"
echo "    - Logs: /tmp/onpremise-agent.log"
echo "    - Port Mappings: PostgreSQL (5432) only"
echo "    - Config: port_mappings.postgres-only.json"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "  1. Check agent logs:"
echo "     tail -f /tmp/onpremise-agent.log"
echo ""
echo "  2. Test PostgreSQL query in Snowflake:"
echo "     SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5');"

echo -e "\n${YELLOW}Useful Commands:${NC}"
echo "  • View agent logs: tail -f /tmp/onpremise-agent.log"
echo "  • Stop agent: pkill -f onpremise_agent.py"
echo "  • Stop PostgreSQL: pixi run stop-postgres"
echo "  • Restart agent: pkill -f onpremise_agent.py && ./start-postgres-only.sh"

echo -e "\n${GREEN}✓ PostgreSQL system ready for testing!${NC}"

