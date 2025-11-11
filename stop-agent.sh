#!/bin/bash
# ============================================================================
# Stop On-Premise Tunnel Agent
# ============================================================================
# Stops only the tunnel agent, leaves other services running
# Usage: ./stop-agent.sh
# ============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Stopping on-premise tunnel agent...${NC}"

# Check if agent is running
if pgrep -f "onpremise_agent.py" > /dev/null; then
    AGENT_PID=$(pgrep -f "onpremise_agent.py")
    echo -e "${YELLOW}Found agent running (PID: $AGENT_PID)${NC}"
    
    # Graceful shutdown
    pkill -f "onpremise_agent.py"
    sleep 2
    
    # Check if still running
    if pgrep -f "onpremise_agent.py" > /dev/null; then
        echo -e "${YELLOW}⚠ Agent still running, force killing...${NC}"
        pkill -9 -f "onpremise_agent.py"
        sleep 1
    fi
    
    # Verify stopped
    if pgrep -f "onpremise_agent.py" > /dev/null; then
        echo -e "${RED}✗ Failed to stop agent${NC}"
        exit 1
    else
        echo -e "${GREEN}✓ Agent stopped successfully${NC}"
    fi
else
    echo -e "${GREEN}✓ Agent not running${NC}"
fi

echo ""
echo -e "${BLUE}Status:${NC}"
echo "  • Tunnel Agent: ✓ Stopped"
echo "  • Pixi PostgreSQL: Still running (use 'pixi run stop-postgres' if needed)"
echo ""
echo -e "${YELLOW}To restart agent:${NC} ./start-postgres-demo.sh"




