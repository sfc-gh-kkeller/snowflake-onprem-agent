#!/bin/bash
# ============================================================================
# Stop PostgreSQL Demo (Agent + PostgreSQL)
# ============================================================================
# Stops both the tunnel agent and PostgreSQL database
# Usage: ./stop-postgres-demo.sh
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
echo "  Stop PostgreSQL Demo"
echo "═══════════════════════════════════════════════════════════"
echo -e "${NC}"

# ============================================================================
# Stop On-Premise Agent
# ============================================================================
echo -e "${YELLOW}[1/2] Stopping on-premise tunnel agent...${NC}"

if pgrep -f "onpremise_agent.py" > /dev/null; then
    AGENT_PID=$(pgrep -f "onpremise_agent.py")
    echo "  Found agent running (PID: $AGENT_PID)"
    
    # Graceful shutdown
    pkill -f "onpremise_agent.py"
    sleep 2
    
    # Check if still running
    if pgrep -f "onpremise_agent.py" > /dev/null; then
        echo -e "${YELLOW}  ⚠ Agent still running, force killing...${NC}"
        pkill -9 -f "onpremise_agent.py"
        sleep 1
    fi
    
    # Verify stopped
    if pgrep -f "onpremise_agent.py" > /dev/null; then
        echo -e "${RED}  ✗ Failed to stop agent${NC}"
    else
        echo -e "${GREEN}  ✓ Agent stopped${NC}"
    fi
else
    echo -e "${GREEN}  ✓ Agent not running${NC}"
fi

# ============================================================================
# Stop Pixi PostgreSQL
# ============================================================================
echo -e "\n${YELLOW}[2/2] Stopping Pixi PostgreSQL...${NC}"

if pgrep -f "postgres -D" > /dev/null; then
    echo "  Stopping PostgreSQL via Pixi..."
    pixi run stop-postgres 2>/dev/null
    sleep 2
    
    # Check if still running
    if pgrep -f "postgres -D" > /dev/null; then
        echo -e "${YELLOW}  ⚠ PostgreSQL still running, force killing...${NC}"
        pkill -f "postgres -D"
        sleep 1
    fi
    
    # Verify stopped
    if pgrep -f "postgres -D" > /dev/null; then
        echo -e "${RED}  ✗ Failed to stop PostgreSQL${NC}"
    else
        echo -e "${GREEN}  ✓ PostgreSQL stopped${NC}"
    fi
else
    echo -e "${GREEN}  ✓ PostgreSQL not running${NC}"
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
echo "  ✓ Pixi PostgreSQL database"
echo ""
echo -e "${GREEN}To restart: ${NC}./start-postgres-demo.sh"
echo ""

