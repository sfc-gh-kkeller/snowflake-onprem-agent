# Snowflake On-Premise Agent

> Secure WebSocket tunnel for accessing on-premise databases from Snowflake Container Services

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

Snowflake On-Premise Agent creates a secure, encrypted tunnel between Snowflake Container Services (SPCS) and your on-premise PostgreSQL database. Query your local databases directly from Snowflake UDFs without exposing them to the internet.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Snowflake Container Services                                        │
│                                                                     │
│  ┌─────────────────┐       ┌──────────────────────┐                │
│  │ PostgreSQL      │       │ Tunnel Sidecar       │                │
│  │ Query Service   │──────▶│ WebSocket: 8081      │                │
│  │ (Port 8080)     │       │ (Public Endpoint)    │                │
│  └─────────────────┘       └──────────┬───────────┘                │
│                                       │                             │
└───────────────────────────────────────┼─────────────────────────────┘
                                        │ WSS (TLS encrypted)
                                        │
┌───────────────────────────────────────┼─────────────────────────────┐
│ On-Premise Network                    │                             │
│                                       ▼                             │
│  ┌────────────────────────────────────────────┐                    │
│  │ On-Premise Agent                           │                    │
│  │ • Initiates outbound WebSocket connection  │                    │
│  │ • RSA-2048 key exchange + AES-256 tunnel   │                    │
│  │ • Forwards traffic to localhost:5432       │                    │
│  └───────────────────────┬────────────────────┘                    │
│                          │                                          │
│  ┌───────────────────────▼────────────────────┐                    │
│  │ PostgreSQL Database (localhost:5432)       │                    │
│  └────────────────────────────────────────────┘                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Features

- **Firewall-Friendly** — Outbound WebSocket connection only (no inbound ports)
- **End-to-End Encrypted** — RSA-2048 key exchange + AES-256 tunnel encryption
- **Snowflake PAT Authentication** — Uses Personal Access Tokens for secure auth
- **Session-Based** — Persistent TCP connections through WebSocket
- **Auto-Reconnect** — Resilient connection with automatic recovery
- **Zero Public Exposure** — Database never exposed to internet

## Quick Start

### Prerequisites

**On-Premise:**
- [Pixi](https://pixi.sh) package manager
- Docker (for building images)
- Python 3.11+

**Snowflake:**
- Account with Container Services enabled
- Compute pool created
- Image repository configured
- Personal Access Token (PAT)

### Setup Steps

```
1. Build Images  →  2. Deploy to Snowflake  →  3. Configure Agent  →  4. Start & Test
```

### 1. Build and Push Docker Images

```bash
# Login to Snowflake registry
docker login <YOUR_REGISTRY_HOST> -u <SNOWFLAKE_USERNAME>
# Password: Your Snowflake Personal Access Token (PAT)

# Build and push all containers
./build-and-push.sh <YOUR_REGISTRY_URL>
```

Example:
```bash
./build-and-push.sh myorg-myaccount.registry.snowflakecomputing.com/mydb/myschema/images
```

### 2. Deploy Service in Snowflake

Open `SETUP-SNOWFLAKE-SERVICE.sql` in Snowflake and execute each section:

1. Create database, schema, role, and compute pool
2. Create image repository
3. Build and push Docker images (step 1 above)
4. Create the WebSocket tunnel service
5. Get the WebSocket endpoint URL

```sql
-- Get your WebSocket endpoint (save this!)
SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;
-- Change https:// to wss:// for your .env file
```

### 3. Configure On-Premise Agent

```bash
# Copy template
cp onpremise-deployment/config.template.env onpremise-deployment/.env

# Edit with your credentials
vim onpremise-deployment/.env
```

Required configuration:
```bash
# WebSocket endpoint (change https:// to wss://)
SNOWFLAKE_URL=wss://xyz-abc123.snowflakecomputing.app

# Your Snowflake account (format: ORGNAME-ACCOUNTNAME)
SNOWFLAKE_ACCOUNT=YOUR-ACCOUNT-NAME

# Personal Access Token
SNOWFLAKE_PAT=your-pat-token-here
```

### 4. Start Demo

```bash
# Start PostgreSQL + Agent
./start-postgres-demo.sh
```

### 5. Test from Snowflake

```sql
-- Query your on-premise PostgreSQL from Snowflake!
SELECT query_onpremise('SELECT * FROM users LIMIT 5');
SELECT query_onpremise('SELECT version()');
```

## Project Structure

```
snowflake-onprem-agent/
├── onpremise-deployment/
│   ├── onpremise_agent.py          # Tunnel agent (runs on-premise)
│   ├── config.template.env         # Configuration template
│   └── port_mappings.postgres-only.json
│
├── snowflake_agent.py              # Query service (runs in Snowflake)
├── tunnel_sidecar.py               # Tunnel sidecar (runs in Snowflake)
│
├── Dockerfile.postgresql_service.pixi
├── Dockerfile.tunnel-sidecar.pixi
├── Dockerfile.pgadmin              # Optional: pgAdmin for testing
│
├── build-and-push.sh               # Build & push all containers
├── SETUP-SNOWFLAKE-SERVICE.sql     # Complete Snowflake deployment guide
├── start-postgres-demo.sh          # Start PostgreSQL + agent
├── stop-postgres-demo.sh           # Stop everything
├── stop-agent.sh                   # Stop agent only
│
├── demo-data/
│   └── init_postgres.sql           # Sample database schema
│
├── pixi.toml                       # Pixi dependencies
└── README.md
```

## Commands

```bash
# Start PostgreSQL + Agent
./start-postgres-demo.sh

# Stop agent only (PostgreSQL keeps running)
./stop-agent.sh

# Stop everything
./stop-postgres-demo.sh

# View agent logs
tail -f /tmp/onpremise-agent.log

# Connect to local PostgreSQL
pixi run psql -d test_db
```

## Troubleshooting

### Agent Won't Connect

```bash
# Check logs
tail -f /tmp/onpremise-agent.log
```

Common issues:
- **Invalid PAT** — Generate a new Personal Access Token in Snowflake
- **Wrong WebSocket URL** — Verify `SNOWFLAKE_URL` in `.env`
- **Firewall** — Ensure outbound WSS (port 443) is allowed

### Service Issues in Snowflake

```sql
-- Check service status
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');

-- View container logs
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'tunnel-sidecar', 100);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'postgresql-query', 100);

-- Restart service
ALTER SERVICE websocket_multi_db_service SUSPEND;
ALTER SERVICE websocket_multi_db_service RESUME;
```

### PostgreSQL Connection

```bash
# Check if PostgreSQL is running
ps aux | grep postgres

# Test local connection
pixi run psql -d test_db -c "SELECT version()"
```

## Security

### Authentication
- **PAT Token** — Snowflake Personal Access Token for secure authentication
- **RSA-2048** — Asymmetric key exchange for session establishment
- **AES-256** — Symmetric encryption for all tunnel traffic

### Network
- **Outbound Only** — Agent initiates connection (firewall-friendly)
- **No Public Exposure** — PostgreSQL never exposed to internet
- **TLS Transport** — WebSocket over TLS (WSS)

### Best Practices
1. Rotate PAT tokens regularly
2. Use restrictive Snowflake roles
3. Monitor agent logs for suspicious activity
4. Limit port mappings to required services only

## Custom Port Mappings

Edit `onpremise-deployment/port_mappings.postgres-only.json` to add more services:

```json
{
  "mappings": [
    {"local_port": 5432, "remote_host": "localhost", "remote_port": 5432, "description": "PostgreSQL"},
    {"local_port": 3306, "remote_host": "localhost", "remote_port": 3306, "description": "MySQL"},
    {"local_port": 6379, "remote_host": "localhost", "remote_port": 6379, "description": "Redis"}
  ]
}
```

## Documentation

- [Snowflake Container Services](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)
- [Personal Access Tokens](https://docs.snowflake.com/en/user-guide/admin-user-management#personal-access-tokens)

## License

MIT License — see [LICENSE](LICENSE) for details.
