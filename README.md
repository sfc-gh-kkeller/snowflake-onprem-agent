# SnowAgent - Secure TCP Tunnel for Snowflake Container Services

A secure WebSocket-based TCP tunnel solution that enables Snowflake Container Services to access on-premise databases (PostgreSQL, Iceberg/DuckDB) through RSA-2048 + AES-256 encryption.

## 🎯 Key Features

### Database Access
- **Dual Database Support**: Query both PostgreSQL and Apache Iceberg tables from Snowflake
- **DuckDB Integration**: Embedded DuckDB queries Lakekeeper-managed Iceberg tables
- **Snowflake UDFs**: Create SQL functions that query on-premise data
- **External Client Support**: Python/CLI DuckDB clients can query through Iceberg proxy

### Security & Networking
- **Outbound-Only Connection**: On-premise agent initiates connection (firewall-friendly)
- **RSA-2048 Key Exchange**: Secure key establishment with asymmetric cryptography
- **AES-256-GCM Encryption**: All tunnel traffic is encrypted end-to-end
- **Token Authentication**: Snowflake Personal Access Token (PAT) support
- **Dynamic Port Forwarding**: Configure multiple service ports through single tunnel

### Operational
- **Auto-Reconnect**: Handles Snowflake's 30-day container restarts automatically
- **Connection Pooling**: Efficient connection reuse for better performance
- **Compression**: WebSocket compression reduces bandwidth usage
- **Monitoring**: Health check endpoints and detailed logging

## 📋 Prerequisites

### Local Development
- **Docker & Docker Compose** - For running Iceberg stack (Lakekeeper, MinIO, PostgreSQL)
- **Pixi** - Package manager for Python dependencies and PostgreSQL
- **Python 3.10+** - Required for all agents

### Snowflake Requirements
- **Snowflake Account** with Container Services enabled
- **Compute Pool** configured for running services
- **Image Repository** for storing Docker images
- **Personal Access Token (PAT)** for secure authentication (recommended)

### Network Configuration
- On-premise agent needs **outbound HTTPS/WSS** access to Snowflake endpoints
- No inbound firewall rules required (agent initiates connection)

## 📁 Project Structure

```
├── iceberg_agent.py              # Iceberg + DuckDB query agent
├── snowflake_agent.py            # PostgreSQL query agent
├── tunnel_sidecar.py             # WebSocket tunnel sidecar
├── onpremise-deployment/
│   ├── onpremise_agent.py        # On-premise tunnel agent
│   ├── config.kevin.env          # Configuration template
│   └── port_mappings.json        # Port forwarding config
├── Dockerfile.*.pixi             # Docker images for SPCS
├── build-and-push-v3.sh          # Build & push images to Snowflake
├── start-demo.sh                 # Start all demo components
├── stop-demo.sh                  # Stop all demo components
├── stop-agent.sh                 # Stop only the tunnel agent
├── docker-compose.iceberg.yml    # Local Iceberg stack (MinIO, Lakekeeper, PostgreSQL)
├── demo-data/
│   ├── lakekeeper_seed.sql       # Seed Iceberg demo data
│   └── init_postgres.sql         # Seed PostgreSQL tables
├── CREATE-SERVICE-V3-ICEBERG.sql # Snowflake service & UDF definitions
├── pixi.toml                     # Pixi package manager config
├── ICEBERG-ARCHITECTURE.md       # Detailed architecture documentation
└── ICEBERG-QUICKSTART.md         # Quick start guide
```

## 🚀 Quick Start

### Option A: Automated Setup (Recommended)

```bash
# Start everything (Iceberg, PostgreSQL, Tunnel Agent)
./start-demo.sh

# Stop everything
./stop-demo.sh

# Stop only the tunnel agent (leave databases running)
./stop-agent.sh
```

### Option B: Manual Setup

#### 1. Start Iceberg Stack
```bash
# Start Iceberg stack (MinIO, Lakekeeper, PostgreSQL)
docker compose -f docker-compose.iceberg.yml up -d

# Wait for services to be healthy (check with docker ps)
# Seed demo data
pixi run duckdb < demo-data/lakekeeper_seed.sql
```

#### 2. Setup PostgreSQL Demo Database
```bash
# Create test_user and test_db for the Snowflake tunnel demo
pixi run psql -d postgres -c "CREATE USER test_user WITH PASSWORD 'test_pass' LOGIN;"
pixi run psql -d postgres -c "CREATE DATABASE test_db OWNER test_user;"

# Seed demo data (adjust -U flag to your local PostgreSQL user)
pixi run psql -d test_db -U $USER < demo-data/init_postgres.sql

# Grant permissions to test_user
pixi run psql -d test_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO test_user;"
pixi run psql -d test_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO test_user;"
```

#### 3. Build & Push Docker Images
```bash
# Update config with your Snowflake credentials
vim onpremise-deployment/config.kevin.env

# Build and push images
./build-and-push-v3.sh
```

#### 4. Create Snowflake Service
```sql
-- Run in Snowflake
USE ROLE dockertest;
USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;
USE WAREHOUSE S2;

-- Execute CREATE-SERVICE-V3-ICEBERG.sql
-- Wait ~2 minutes for service to start
SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;
```

#### 5. Start On-Premise Agent
```bash
# Update config.kevin.env with new WebSocket endpoint from SHOW ENDPOINTS
# Copy to .env
cp onpremise-deployment/config.kevin.env onpremise-deployment/.env

# Start agent
pixi run python onpremise-deployment/onpremise_agent.py
```

#### 6. Test Queries

**PostgreSQL:**
```sql
-- Query PostgreSQL through tunnel
SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5') AS result;

-- Parse JSON result
SELECT 
  value:id::INT AS user_id,
  value:name::STRING AS name,
  value:email::STRING AS email
FROM TABLE(FLATTEN(input => query_onpremise_v2('SELECT * FROM users LIMIT 5')));
```

**Iceberg:**
```sql
-- Query Iceberg table via embedded DuckDB
SELECT query_iceberg('SELECT * FROM demo.demo.sales LIMIT 3') AS result;

-- Parse and aggregate
SELECT 
  value[4]::STRING AS region,
  SUM(value[2]::INT) AS total_amount
FROM TABLE(FLATTEN(input => query_iceberg('SELECT * FROM demo.demo.sales')))
GROUP BY region;
```

## 🔧 Architecture

### Components

**Snowflake Container Services (SPCS):**
- **snowflake_agent.py** - REST API for PostgreSQL queries via asyncpg driver
- **iceberg_agent.py** - REST API with embedded DuckDB for Iceberg queries + Catalog/S3 proxy for external clients
- **tunnel_sidecar.py** - Dynamic port forwarding service (exposes local ports that forward through WebSocket)

**On-Premise:**
- **onpremise_agent.py** - Tunnel client that initiates outbound WebSocket connection and forwards traffic to local services

**Configuration:**
- **port_mappings.json** - Defines which ports to forward (PostgreSQL:5432, Lakekeeper:8181, MinIO:9000)

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Snowflake Container Services                                 │
│                                                               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │ snowflake-agent │  │ iceberg-agent   │  │tunnel-sidecar│ │
│  │ (PostgreSQL)    │  │ (DuckDB/Iceberg)│  │ (WebSocket)  │ │
│  └────────┬────────┘  └────────┬────────┘  └──────┬───────┘ │
│           │                    │                    │         │
│           └────────────────────┴────────────────────┘         │
│                                │                              │
└────────────────────────────────┼──────────────────────────────┘
                                 │ WSS (RSA-2048 + AES-256)
                                 ▼
                     ┌───────────────────────┐
                     │ On-Premise Agent      │
                     │ (TCP Proxy)           │
                     └───────────┬───────────┘
                                 │ Port Mappings:
                ┌────────────────┼────────────────┐
                ▼                ▼                ▼
         ┌──────────┐    ┌──────────┐    ┌──────────┐
         │PostgreSQL│    │Lakekeeper│    │  MinIO   │
         │  :5432   │    │  :8181   │    │  :9000   │
         └──────────┘    └──────────┘    └──────────┘
```

## 🔒 Security Details

### Encryption

**Key Exchange (RSA-2048):**
1. On-premise agent generates RSA-2048 key pair on startup
2. Public key is sent to tunnel sidecar during handshake
3. Tunnel sidecar generates AES-256 key for session encryption
4. AES key is encrypted (wrapped) with agent's RSA public key
5. Agent decrypts AES key using its RSA private key

**Data Encryption (AES-256-GCM):**
- All messages through tunnel are encrypted with AES-256 in CFB mode
- Each message has unique initialization vector (IV)
- Forward secrecy: New RSA key pair generated on each connection

### Authentication

**Production (Recommended):**
- Snowflake Personal Access Token (PAT) is exchanged for session token
- Token is sent in WebSocket headers and validated by tunnel sidecar
- Supports Snowflake's role-based access control

**Development/Testing:**
- Shared secret (`HANDSHAKE_SECRET`) for local testing
- Should not be used in production environments

### Network Security

- **Outbound-Only**: Agent initiates WebSocket connection (firewall-friendly)
- **TLS/WSS**: WebSocket Secure (WSS) for transport layer encryption
- **Double Encryption**: TLS transport + AES application-layer encryption
- **No Exposed Ports**: No need to open inbound firewall rules on-premise

## 📝 Configuration

### Port Mappings (`onpremise-deployment/port_mappings.json`)

Configure which on-premise services to forward through the tunnel:

```json
{
  "mappings": [
    {
      "local_port": 5432,
      "remote_host": "localhost",
      "remote_port": 5432,
      "description": "PostgreSQL"
    },
    {
      "local_port": 8181,
      "remote_host": "localhost",
      "remote_port": 8181,
      "description": "Iceberg REST Catalog"
    },
    {
      "local_port": 9000,
      "remote_host": "localhost",
      "remote_port": 9000,
      "description": "MinIO S3 Storage"
    }
  ]
}
```

The on-premise agent reads this file and pushes the configuration to the tunnel sidecar, which then exposes these ports for the Snowflake agents to connect to.

### Environment Variables (`onpremise-deployment/.env`)

Key configuration for the on-premise agent:

- `SNOWFLAKE_URL` - WebSocket endpoint URL from Snowflake (get via `SHOW ENDPOINTS`)
- `SNOWFLAKE_ACCOUNT` - Your Snowflake account identifier
- `SNOWFLAKE_PAT` - Personal Access Token for authentication (recommended)
- `HANDSHAKE_SECRET` - Shared secret for local testing (if not using PAT)

## 🔍 Operational Modes

### Sidecar Mode (v2.0 - Recommended)

The tunnel sidecar exposes local TCP ports that applications connect to directly:
- `snowflake_agent.py` connects to `localhost:5432` (PostgreSQL)
- `iceberg_agent.py` connects to `localhost:8181` (Lakekeeper) and `localhost:9000` (MinIO)
- Traffic is transparently forwarded through the WebSocket tunnel

**Advantages:**
- Native database drivers (asyncpg)
- Connection pooling support
- Better performance (persistent TCP connections)
- Supports all PostgreSQL features

### Query Forwarding Mode (v1.0 - Legacy)

The Snowflake agent forwards SQL queries through the tunnel as JSON messages:
- Agent receives query via REST API
- Query is serialized and sent through WebSocket
- On-premise agent executes query and returns results

**Note:** This mode is maintained for backward compatibility but sidecar mode is recommended for new deployments.

## 🐛 Troubleshooting

### Agent Connection Issues

**Symptom:** Agent fails to connect to Snowflake endpoint
```
❌ Connection failed: [SSL: CERTIFICATE_VERIFY_FAILED]
```

**Solution:** 
- Verify the WebSocket endpoint URL is correct (`SHOW ENDPOINTS IN SERVICE`)
- Ensure endpoint starts with `wss://` (not `ws://`)
- Check that Personal Access Token (PAT) is valid

### Port Mapping Not Working

**Symptom:** Connection refused when querying database
```
Connection refused to localhost:5432
```

**Solution:**
- Check that on-premise agent successfully connected (`grep "authenticated and ready" /tmp/onpremise-agent.log`)
- Verify `port_mappings.json` exists and is valid JSON
- Confirm the local services are running (PostgreSQL, Lakekeeper, MinIO)

### Snowflake Service Restarts

**Info:** Snowflake Container Services restart approximately every 30 days

**Resilience:**
- On-premise agent automatically reconnects with infinite retry
- Port mappings are re-pushed after reconnection
- Active queries may fail but subsequent queries will work

### View Agent Logs

```bash
# On-premise agent logs
tail -f /tmp/onpremise-agent.log

# Docker Iceberg stack logs
docker compose -f docker-compose.iceberg.yml logs -f

# PostgreSQL logs (if using pixi)
tail -f .pixi/postgres.log
```

## 📚 Documentation

**Architecture & Setup:**
- **[ICEBERG-ARCHITECTURE.md](ICEBERG-ARCHITECTURE.md)** - Detailed architecture and design decisions
- **[ICEBERG-QUICKSTART.md](ICEBERG-QUICKSTART.md)** - Step-by-step setup guide with examples
- **[CREATE-SERVICE-V3-ICEBERG.sql](CREATE-SERVICE-V3-ICEBERG.sql)** - Snowflake service definitions and UDF examples

**Testing & Demo:**
- **[DEMO-CHECKLIST.md](DEMO-CHECKLIST.md)** - Pre-demo checklist to verify everything is ready
- **[test_demo.sql](test_demo.sql)** - SQL test script for PostgreSQL and Iceberg queries
- **[SNOWFLAKE-INTELLIGENCE-SETUP.md](SNOWFLAKE-INTELLIGENCE-SETUP.md)** - Integration with Snowflake Cortex AI

## 📖 Quick Reference

### Common Commands

```bash
# Start everything
./start-demo.sh

# Stop everything
./stop-demo.sh

# View agent logs
tail -f /tmp/onpremise-agent.log

# Check Docker containers
docker ps | grep iceberg

# Restart agent only
pkill -f onpremise_agent.py && pixi run python onpremise-deployment/onpremise_agent.py &

# Test PostgreSQL locally
pixi run psql -d test_db -c "SELECT * FROM users LIMIT 5;"

# Test DuckDB/Iceberg locally
pixi run duckdb -c "ATTACH 'demo' AS demo (TYPE iceberg, ENDPOINT 'http://localhost:8181/catalog/'); SELECT * FROM demo.demo.sales LIMIT 3;"
```

### Key Dependencies

**Python Packages:**
- `websockets` - WebSocket client/server
- `cryptography` - RSA-2048 + AES-256 encryption
- `asyncpg` - PostgreSQL async driver
- `aiohttp` - HTTP server framework
- `duckdb` - DuckDB with Iceberg extension
- `python-dotenv` - Environment variable management

**System Requirements:**
- Docker & Docker Compose
- Pixi package manager
- Python 3.10+
- PostgreSQL 16+ (via Pixi)

### Project Links

- **GitHub**: Internal Snowflake SecLab repository
- **Snowflake Account**: Required for Container Services
- **Lakekeeper**: [https://lakekeeper.io/](https://lakekeeper.io/)
- **DuckDB Iceberg**: [https://duckdb.org/docs/extensions/iceberg.html](https://duckdb.org/docs/extensions/iceberg.html)

## 🗄️ Archive

Older iterations, experimental scripts, and alternative implementations are in the `archive/` folder.

## 📝 License

Internal demo project for Snowflake SecLab.
