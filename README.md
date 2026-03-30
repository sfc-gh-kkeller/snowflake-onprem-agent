# Snowflake On-Premise Agent

> Secure encrypted tunnel connecting Snowflake to on-premise systems, cross-cloud resources, and data lakes — **No Private Link Required**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

Snowflake On-Premise Agent creates a secure, encrypted tunnel between Snowflake Container Services (SPCS) and any on-premise or cross-cloud system. Unlike traditional Private Link solutions that require complex infrastructure (reverse proxies, DMZ, VPN gateways), this solution uses **outbound-only connections** that work through firewalls and are easy to deploy.

### What Can You Connect?

| Use Case | Description |
|----------|-------------|
| **Databases** | PostgreSQL, MySQL, SQL Server, Oracle — query on-prem databases from Snowflake |
| **Cortex Agents** | Let AI agents call UDFs that access on-premise data sources |
| **Iceberg Catalogs** | Connect to on-premise Apache Iceberg catalogs and data lakes |
| **Data Pipelines** | Build ingestion pipelines from on-premise systems (NiFi, custom ETL) |
| **Cross-Cloud** | Connect Snowflake accounts across AWS, Azure, and GCP |
| **APIs & Services** | Access internal REST APIs, microservices, or legacy systems |

### Who Is This For?

- **All Snowflake customers** — No Business Critical edition or Private Link required
- **Enterprises with strict security policies** — Outbound-only traffic, no inbound firewall rules needed
- **Hybrid cloud architectures** — Keep sensitive data on-premise while leveraging Snowflake AI/ML

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Snowflake Container Services (SPCS)                                         │
│                                                                             │
│  ┌──────────────────┐    ┌──────────────────┐    ┌─────────────────────┐   │
│  │ Your App         │    │ Cortex Agents    │    │ Notebooks           │   │
│  │ (Streamlit, UDF) │    │ (AI + Tools)     │    │ (Python, SQL)       │   │
│  └────────┬─────────┘    └────────┬─────────┘    └──────────┬──────────┘   │
│           │                       │                         │               │
│           └───────────────────────┼─────────────────────────┘               │
│                                   ▼                                         │
│                    ┌──────────────────────────┐                             │
│                    │ SPCS Tunnel Sidecar      │                             │
│                    │ (WebSocket Server)       │                             │
│                    └────────────┬─────────────┘                             │
└─────────────────────────────────┼───────────────────────────────────────────┘
                                  │ WSS (TLS + AES-256 encrypted)
                                  │
┌─────────────────────────────────┼───────────────────────────────────────────┐
│ Customer Network (On-Premise / Cross-Cloud)                                 │
│                                 │                                           │
│     ┌───────────────────────────▼──────────────────────────────┐           │
│     │ On-Premise Agent                                          │           │
│     │ • Initiates OUTBOUND WebSocket connection (firewall-safe) │           │
│     │ • RSA-2048 key exchange + AES-256 tunnel encryption       │           │
│     │ • Forwards TCP traffic to local services                  │           │
│     └─────┬─────────────┬──────────────┬───────────────┬───────┘           │
│           │             │              │               │                    │
│           ▼             ▼              ▼               ▼                    │
│     ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌─────────────┐             │
│     │PostgreSQL│  │ MySQL    │  │ Iceberg   │  │ REST APIs   │             │
│     │ :5432    │  │ :3306    │  │ Catalog   │  │ & Services  │             │
│     └──────────┘  └──────────┘  └───────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Features

- **No Private Link Required** — Works for all Snowflake customers, any edition
- **Firewall-Friendly** — Agent initiates outbound connections only (no inbound ports)
- **End-to-End Encrypted** — RSA-2048 key exchange + AES-256 tunnel encryption
- **Proven Model** — Same pattern as PowerBI Gateway, Azure Integration Runtime, Fivetran Agent
- **Multi-Service** — Connect multiple on-premise services through one tunnel
- **Cross-Cloud** — Connect Snowflake accounts across different cloud providers

### Why Not Private Link?

| Challenge | Private Link | This Solution |
|-----------|-------------|---------------|
| Inbound traffic to customer network | Required | **Not required** |
| Reverse proxy farm | Must deploy & maintain | **Not needed** |
| DMZ configuration | Often required | **Not needed** |
| Cost at scale | Expensive | **Minimal** |
| Cross-cloud support | No | **Yes** |
| Works for all customers | BC edition only | **All editions** |

## Quick Start (PostgreSQL Demo)

> **Note:** PostgreSQL is used as a demonstration. The tunnel works with any TCP-based service.

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

## Use Cases in Detail

### Cortex Agents with On-Premise Data

Let Snowflake Cortex AI agents query on-premise databases through custom tools:

```sql
-- Create a Cortex Agent that can query on-premise PostgreSQL
CREATE CORTEX AGENT my_agent
  TOOLS = (query_onpremise_tool)
  ...;

-- Agent can now answer: "Show me underpaid employees"
-- by querying on-prem PostgreSQL (names, emails) + Snowflake (salaries)
```

### On-Premise Iceberg Catalog

Connect to Apache Iceberg catalogs hosted on-premise or in other clouds:

```python
# In a Snowflake Notebook, query on-premise Iceberg via the tunnel
from pyiceberg.catalog import load_catalog

catalog = load_catalog("onprem", uri="http://localhost:8181")  # tunneled
table = catalog.load_table("db.sales")
df = table.scan().to_pandas()
```

### Data Ingestion Pipelines

Use Apache NiFi or custom ETL running in SPCS to pull data from on-premise:

```
NiFi (in SPCS) → Tunnel → On-Prem Database → Snowflake Tables
```

### Cross-Cloud Connectivity

Connect Snowflake accounts across AWS, Azure, and GCP:

```
Snowflake (AWS us-west-2) ←→ Tunnel ←→ Snowflake (Azure westeurope)
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
- **No Public Exposure** — On-premise services never exposed to internet
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
    {"local_port": 8181, "remote_host": "localhost", "remote_port": 8181, "description": "Iceberg REST Catalog"},
    {"local_port": 6379, "remote_host": "localhost", "remote_port": 6379, "description": "Redis"}
  ]
}
```

## Documentation

- [Snowflake Container Services](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)
- [Personal Access Tokens](https://docs.snowflake.com/en/user-guide/admin-user-management#personal-access-tokens)

## License

MIT License — see [LICENSE](LICENSE) for details.
