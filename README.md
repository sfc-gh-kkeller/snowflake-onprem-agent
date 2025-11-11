# SnowAgent - PostgreSQL Tunnel Demo

Secure WebSocket tunnel for accessing on-premise PostgreSQL from Snowflake Container Services.

## Overview

SnowAgent creates a secure, encrypted tunnel between Snowflake Container Services and your on-premise PostgreSQL database. This allows Snowflake UDFs and services to query your local database without exposing it to the internet.

### Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│ Snowflake Container Services                                        │
│                                                                      │
│ ┌─────────────────┐      ┌─────────────────────────┐               │
│ │ PostgreSQL      │      │ Tunnel Sidecar          │               │
│ │ Query Service   │─────►│ - WebSocket: 8081       │               │
│ │ Port: 8080      │      │   (PUBLIC - agent connects here)        │
│ │ (internal)      │      │ - Tunnel ports: 5432... │               │
│ └─────────────────┘      │   (INTERNAL - services use these)       │
│                          └──────────┬──────────────┘               │
│                                     │                               │
│ ┌─────────────────┐                 │                               │
│ │ pgAdmin         │                 │                               │
│ │ (Optional Test) │────────────────►│                               │
│ │ Port: 80        │  Connects to tunnel port 5432                  │
│ └─────────────────┘  (internal: websocket-multi-db-service...5432) │
│                                     │                               │
└─────────────────────────────────────┼───────────────────────────────┘
                                      │ WSS (encrypted)
                            ┌─────────▼──────────┐
                            │ Firewall-Friendly  │
                            │ Outbound Connection│
                            └─────────┬──────────┘
                                      │
┌─────────────────────────────────────┼───────────────────────────────┐
│ On-Premise                          │                               │
│                                     │                               │
│ ┌───────────────────────────────────▼────────────┐                 │
│ │ On-Premise Agent                               │                 │
│ │ - Initiates outbound WebSocket                 │                 │
│ │ - AES-256 + RSA-2048 encryption                │                 │
│ │ - Forwards to localhost:5432                   │                 │
│ └───────────────────┬────────────────────────────┘                 │
│                     │                                               │
│ ┌───────────────────▼────────────────────────────┐                 │
│ │ PostgreSQL Database                            │                 │
│ │ localhost:5432                                 │                 │
│ │ - Demo database: test_db                       │                 │
│ │ - Demo data: users table                       │                 │
│ └────────────────────────────────────────────────┘                 │
└────────────────────────────────────────────────────────────────────┘
```

**Demo Components:**
- **PostgreSQL Query Service** - UDF handler for programmatic queries
- **Tunnel Sidecar** - WebSocket tunnel server with encrypted connection
- **pgAdmin (Optional)** - Visual database browser to test the tunnel
- **On-Premise Agent** - Tunnel client running locally
- **PostgreSQL Database** - Local database with demo data

### Key Features

- ✅ **Firewall-friendly** - Outbound WebSocket connection only
- ✅ **Encrypted** - RSA-2048 key exchange + AES-256 tunnel encryption
- ✅ **Session-based** - Persistent TCP connections through WebSocket
- ✅ **Authenticated** - Snowflake PAT token authentication
- ✅ **Resilient** - Auto-reconnect with session recovery
- ✅ **Zero public exposure** - No inbound ports required

---

## Quick Start

### Setup Flow

```
1. Build Docker Images → 2. Deploy in Snowflake → 3. Configure On-Premise → 4. Start Agent → 5. Test
   (push to registry)       (get WebSocket URL)       (edit .env file)        (connect!)       (query!)
```

**Important:** You must build and deploy the Snowflake service BEFORE starting the on-premise agent!

### Prerequisites

- **On-Premise:**
  - [Pixi](https://pixi.sh) package manager
  - Python 3.11+
  - PostgreSQL (managed by Pixi)
  - Docker (for building images)

- **Snowflake:**
  - Snowflake account with Container Services enabled
  - Compute pool created
  - Image repository configured
  - Personal Access Token (PAT)

### 1. Build and Push Docker Images

**⚠️ Do this FIRST before starting anything on-premise!**

```bash
# Build and push all containers
./build-and-push.sh <YOUR_REGISTRY_URL>

# Example:
./build-and-push.sh sfsenorthamerica-secfieldkeller.registry.snowflakecomputing.com/websocket_test_db/websocket_test_schema/websocket_images
```

This builds and pushes:
- `postgresql-query` - PostgreSQL query service (UDF handler)
- `tunnel-sidecar` - WebSocket tunnel server
- `pgadmin-test` - pgAdmin for testing (optional)

**Note:** If push fails, login first:
```bash
docker login <registry-host> -u <username>
# Password: Use your Snowflake Personal Access Token (PAT)
```

### 2. Deploy Service in Snowflake

**Use the step-by-step deployment guide:**

Open `SETUP-SNOWFLAKE-SERVICE.sql` in Snowflake and execute each section:
- **Step 1:** Create database, schema, role, and compute pool
- **Step 2:** Create image repository and get registry URL
- **Step 3:** Create the WebSocket tunnel service
- **Step 4:** Get the WebSocket endpoint (save this for your `.env` file!)

```sql
-- Open in Snowflake UI
SETUP-SNOWFLAKE-SERVICE.sql
```

**Key steps:**
```sql
-- 1. Get WebSocket endpoint (you'll need this for .env)
SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;
-- Change https:// to wss:// in your .env file!

-- 2. Check service status (wait until READY)
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');

-- 3. View logs if needed
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'tunnel-sidecar', 100);
```

### 3. Configure On-Premise

```bash
# Clone repository (if not already done)
cd /path/to/SnowAgent

# Copy template and edit with your credentials
cp onpremise-deployment/config.template.env onpremise-deployment/.env

# Edit .env with your Snowflake credentials
vim onpremise-deployment/.env
```

**Required configuration (only 3 fields!):**
```bash
# WebSocket endpoint from step 2 (change https:// to wss://)
SNOWFLAKE_URL=wss://xyz-abc123.snowflakecomputing.app

# Your Snowflake account name
SNOWFLAKE_ACCOUNT=YOUR-ACCOUNT-NAME

# Personal Access Token (PAT)
SNOWFLAKE_PAT=your-personal-access-token
```

All PostgreSQL settings use smart defaults - no database credentials needed!

### 4. Start On-Premise Demo

```bash
# Start PostgreSQL + Agent (auto-initializes database if needed)
./start-postgres-demo.sh
```

This will:
- ✅ Initialize PostgreSQL database (if first run)
- ✅ Start PostgreSQL on port 5432
- ✅ Create test database and demo data
- ✅ Start tunnel agent (connects to Snowflake service)

**The agent will connect to the Snowflake service you deployed in step 2.**

### 5. Test the Tunnel


-- Query your on-premise database from Snowflake!
```sql
SELECT query_onpremise('SELECT * FROM users');
```

---

## File Structure

```
SnowAgent/
├── onpremise-deployment/          # On-premise agent
│   ├── onpremise_agent.py         # Tunnel agent (runs locally)
│   ├── .env                       # Your configuration (create this!)
│   ├── config.template.env        # Configuration template
│   └── port_mappings.postgres-only.json  # Port forwarding config
│
├── Dockerfile.postgresql_service.pixi  # PostgreSQL query service
├── Dockerfile.tunnel-sidecar.pixi      # Tunnel sidecar
├── Dockerfile.pgadmin                  # pgAdmin (optional testing)
│
├── snowflake_agent.py             # Query service (runs in Snowflake)
├── tunnel_sidecar.py              # Tunnel sidecar (runs in Snowflake)
│
├── build-and-push.sh              # Build & push all containers
├── SETUP-SNOWFLAKE-SERVICE.sql    # Complete Snowflake deployment guide
├── start-postgres-demo.sh         # Start PostgreSQL + agent
├── stop-agent.sh                  # Stop agent only
├── stop-postgres-demo.sh          # Stop agent + PostgreSQL
│
├── demo-data/
│   └── init_postgres.sql          # Demo database schema
│
├── pixi.toml                      # Pixi dependencies
└── README.md                      # This file
```

---

## Commands

### Start/Stop Services

```bash
# Start PostgreSQL + Agent
./start-postgres-demo.sh

# Stop agent only (PostgreSQL keeps running)
./stop-agent.sh

# Stop everything (agent + PostgreSQL)
./stop-postgres-demo.sh
```

### Manual Controls

```bash
# PostgreSQL management (via Pixi)
pixi run start-postgres     # Start PostgreSQL
pixi run stop-postgres      # Stop PostgreSQL
pixi run psql -d test_db    # Connect to database

# Check processes
ps aux | grep postgres      # PostgreSQL process
ps aux | grep onpremise     # Agent process
tail -f /tmp/onpremise-agent.log  # View agent logs
```

### Docker Build

```bash
# Build and push all containers
./build-and-push.sh <REGISTRY_URL>

# Build specific container
docker build --platform linux/amd64 \
  -f Dockerfile.postgresql_service.pixi \
  -t my-image:latest .
```

---

## Configuration

### On-Premise Agent Config

File: `onpremise-deployment/.env`

**Important:** You must create this file before starting the demo!

```bash
# Copy template and edit with your credentials
cp onpremise-deployment/config.template.env onpremise-deployment/.env
```

**Edit `.env` with only 3 required fields:**
```bash
# WebSocket endpoint from: SHOW ENDPOINTS IN SERVICE websocket_multi_db_service
# Change https:// to wss://
SNOWFLAKE_URL=wss://xyz.snowflakecomputing.app

# Your Snowflake account (format: ORGNAME-ACCOUNTNAME)
SNOWFLAKE_ACCOUNT=YOUR-ACCOUNT-NAME

# Personal Access Token - Generate in Snowflake UI
SNOWFLAKE_PAT=your-pat-token-here
```

**That's it!** All PostgreSQL settings use smart defaults (test_db, kevin, peer auth).

### Port Mappings

File: `onpremise-deployment/port_mappings.postgres-only.json`

```json
{
  "mappings": [
    {
      "local_port": 5432,
      "remote_host": "localhost",
      "remote_port": 5432,
      "description": "PostgreSQL"
    }
  ]
}
```

---

## Troubleshooting

### Agent Won't Connect

**Check logs:**
```bash
tail -f /tmp/onpremise-agent.log
```

**Common issues:**
- Invalid PAT token → Generate new PAT in Snowflake
- Wrong WebSocket URL → Check `SNOWFLAKE_URL` in config
- Firewall blocking → Ensure outbound WSS (443) allowed

### PostgreSQL Connection Failed

**Check PostgreSQL:**
```bash
# Is it running?
ps aux | grep postgres

# Can you connect locally?
pixi run psql -d test_db -c "SELECT version()"

# Check port
netstat -an | grep 5432
```

### Docker Push Failed

**Login to registry:**
```bash
docker login <registry-host> -u <username>
# Password: Your Snowflake PAT
```

**Check credentials:**
```bash
# View Snowflake registry
SHOW IMAGE REPOSITORIES;

# Check permissions
SHOW GRANTS ON IMAGE REPOSITORY <repo_name>;
```

### Service Not Starting in Snowflake

**Check service status:**
```sql
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');
```

**View logs:**
```sql
-- Tunnel sidecar logs
SELECT * FROM TABLE(SYSTEM$GET_SERVICE_LOGS(
  'websocket_multi_db_service', 0, 'tunnel-sidecar'
)) ORDER BY TIMESTAMP DESC LIMIT 50;

-- PostgreSQL service logs  
SELECT * FROM TABLE(SYSTEM$GET_SERVICE_LOGS(
  'websocket_multi_db_service', 0, 'snowflake-agent'
)) ORDER BY TIMESTAMP DESC LIMIT 50;
```

---

## Security

### Authentication

- **PAT Token:** Snowflake Personal Access Token for authentication
- **RSA-2048:** Secure key exchange between agent and sidecar
- **AES-256:** All tunnel traffic encrypted

### Network Security

- **Outbound only:** Agent initiates connection (firewall-friendly)
- **No public ports:** PostgreSQL never exposed to internet
- **WebSocket over TLS:** Encrypted transport (WSS)

### Best Practices

1. **Rotate PAT tokens** regularly
2. **Use restrictive roles** for service account
3. **Monitor logs** for suspicious activity
4. **Limit port mappings** to only required services
5. **Keep software updated** (Pixi, Python, PostgreSQL)

---

## Architecture Details

### Session Management

The tunnel uses session-based connections:

1. **Container** opens connection to `tunnel-sidecar:5432`
2. **Tunnel-sidecar** creates session, sends `session_create` to agent
3. **Agent** connects to `localhost:5432`, session established
4. **Bidirectional data flow** through WebSocket
5. **Session cleanup** on disconnect or timeout

### Message Types

- `handshake` - Initial authentication and key exchange
- `port_mapping` - Configuration push from agent to sidecar
- `session_create` - New TCP connection request
- `session_data` - Data forwarding
- `session_close` - Connection termination
- `session_reset` - Recovery after reconnect

### Encryption Flow

1. **Agent** generates RSA-2048 keypair, sends public key
2. **Sidecar** generates AES-256 key, wraps with agent's public key
3. **Agent** unwraps AES key with private key
4. **All messages** encrypted with shared AES-256 key

---

## Advanced Topics

### Archived Features

The `archive_new/` directory contains additional components:

- **Iceberg support** - Apache Iceberg REST catalog integration
- **Discovery API** - Dynamic port mapping discovery
- **pgAdmin testing** - Web-based PostgreSQL admin
- **Reverse tunneling** - Browser → Container access (planned)
- **OAuth integration** - Local portal with Snowflake OAuth (planned)

See archived documentation for details.

### Custom Port Mappings

To add more services, update `port_mappings.postgres-only.json`:

```json
{
  "mappings": [
    {"local_port": 5432, "remote_host": "localhost", "remote_port": 5432, "description": "PostgreSQL"},
    {"local_port": 3306, "remote_host": "localhost", "remote_port": 3306, "description": "MySQL"},
    {"local_port": 6379, "remote_host": "localhost", "remote_port": 6379, "description": "Redis"}
  ]
}
```

---

## Support

### Documentation

- See `archive_new/` for advanced guides
- Check Snowflake docs: [Container Services](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)

### Logs

- **Agent:** `/tmp/onpremise-agent.log`
- **PostgreSQL:** `.pixi/postgres.log`
- **Snowflake Service:** `SYSTEM$GET_SERVICE_LOGS()`

---

## License

[Your License Here]

## Contributing

[Contributing Guidelines]

---

## Quick Reference

### Essential Commands

```bash
# 1. Build and push containers (do this FIRST!)
./build-and-push.sh <registry-url>

# 2. Deploy in Snowflake (follow step-by-step guide)
snowsql -f SETUP-SNOWFLAKE-SERVICE.sql
# Or open SETUP-SNOWFLAKE-SERVICE.sql in Snowflake UI and execute each step

# 3. Get WebSocket endpoint (save for .env)
snowsql -q "SHOW ENDPOINTS IN SERVICE websocket_multi_db_service"

# 4. Configure on-premise (only 3 fields!)
cp onpremise-deployment/config.template.env onpremise-deployment/.env
vim onpremise-deployment/.env  # Add: SNOWFLAKE_URL, SNOWFLAKE_ACCOUNT, SNOWFLAKE_PAT

# 5. Start demo
./start-postgres-demo.sh

# Stop everything
./stop-postgres-demo.sh

# View agent logs
tail -f /tmp/onpremise-agent.log

# Test PostgreSQL locally
pixi run psql -d test_db -c "SELECT * FROM users"
```

### Essential SQL

```sql
-- Check service
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');

-- View logs
SELECT * FROM TABLE(SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', 0, 'tunnel-sidecar'))
ORDER BY TIMESTAMP DESC LIMIT 20;

-- Test query
SELECT query_onpremise_postgres('SELECT version()');
```

---

**Ready to connect your on-premise PostgreSQL to Snowflake!** 🚀
