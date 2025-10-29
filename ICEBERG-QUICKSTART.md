# Iceberg Agent - Quick Start Guide

## Overview

Query Lakekeeper-managed Iceberg tables from Snowflake through a secure tunnel to your on-premise infrastructure.

**Two query paths supported:**
1. **External DuckDB** - Python/CLI clients query through catalog and S3 proxies ✅ **TESTED**
2. **Embedded DuckDB (UDF)** - Snowflake UDFs use embedded DuckDB ✅ **READY FOR DEPLOYMENT**

## Prerequisites

### Local Infrastructure

```bash
# Start Lakekeeper + MinIO + PostgreSQL
docker-compose -f docker-compose.iceberg.yml up -d

# Seed demo data
docker run --rm --network snowagent_default \
  -v "$PWD/demo-data:/sql" \
  duckdb/duckdb:v1.4.1 \
  -c ".read /sql/lakekeeper_seed.sql"
```

### On-Premise Tunnel

```bash
# Start tunnel server on your laptop
cd onpremise-deployment
python onpremise_agent.py --config config.kevin.env
```

Ports forwarded through tunnel:
- `8181` → Lakekeeper (Iceberg REST)
- `9000` → MinIO (S3-compatible storage)

## Quick Test (Local)

### 1. Start Iceberg Agent

```bash
API_PORT=8090 ICEBERG_PORT=8181 S3_PORT=9000 \
  python iceberg_agent.py
```

### 2. Test External DuckDB Path

```bash
python demo-data/test_complete_flow.py
```

Expected output:
```
✅ External DuckDB Path: PASSED
📝 Embedded UDF Path: See documentation above
```

### 3. Query from Python

```python
import duckdb

conn = duckdb.connect()
conn.execute("INSTALL iceberg; LOAD iceberg;")
conn.execute("INSTALL httpfs; LOAD httpfs;")

# Configure S3 through proxy
conn.execute("""
CREATE SECRET iceberg_secret (
    TYPE S3,
    ENDPOINT 'http://localhost:8090/s3',
    KEY_ID 'admin',
    SECRET 'password',
    USE_SSL false,
    URL_STYLE 'path'
);
""")

# Configure Iceberg REST
conn.execute("""
CREATE SECRET iceberg_rest (
    TYPE ICEBERG,
    TOKEN 'dummy'
);
""")

# Attach catalog
conn.execute("""
ATTACH 'demo' AS demo (
    TYPE ICEBERG,
    ENDPOINT 'http://localhost:8090/catalog/',
    SECRET iceberg_rest
);
""")

# Query!
result = conn.execute("SELECT * FROM demo.demo.sales LIMIT 5").fetchall()
print(result)
```

## Deploy to Snowflake

### 1. Build and Push Docker Images

```bash
# Build iceberg-agent and tunnel-sidecar images
./build-and-push-v3.sh
```

### 2. Create Snowflake Service

```sql
-- See CREATE-SERVICE-V3-ICEBERG.sql for complete setup
CREATE SERVICE iceberg_service
IN COMPUTE POOL my_pool
FROM SPECIFICATION $$
spec:
  containers:
    - name: iceberg-agent
      image: /my_db/my_schema/my_repo/iceberg-agent:latest
      env:
        ICEBERG_PORT: "8181"
        S3_PORT: "9000"
      endpoints:
        - name: iceberg-agent
          port: 8090
    - name: tunnel-sidecar
      image: /my_db/my_schema/my_repo/tunnel-sidecar:latest
      env:
        TUNNEL_SERVER: "wss://my-laptop.example.com:8443"
        TUNNEL_TOKEN: "your-secret-token"
$$;
```

### 3. Get Public Endpoint

```sql
SHOW ENDPOINTS IN SERVICE iceberg_service;
-- Copy the ingress_url (e.g., https://abc-xyz.snowflakecomputing.app)
```

### 4. Query from External DuckDB

Replace `http://localhost:8090` with your Snowflake endpoint URL in the Python example above.

Use `USE_SSL true` for production endpoints.

### 5. Create Snowflake UDF (Optional)

```sql
-- Create UDF for embedded queries
CREATE OR REPLACE FUNCTION query_iceberg(query STRING, catalog STRING)
RETURNS VARIANT
SERVICE=iceberg_service
ENDPOINT='iceberg-agent'
AS '/query_iceberg';

-- Query from Snowflake SQL
SELECT query_iceberg(
    'SELECT COUNT(*) AS total_sales FROM demo.sales',
    'demo'
);
```

## Architecture

```
┌─────────────────────────────────────┐
│ External DuckDB Client (Python/CLI) │
└──────────────┬──────────────────────┘
               │ HTTPS
               ↓
┌─────────────────────────────────────────────────────┐
│ Snowflake Container Services                        │
│  ┌────────────────────────────────────────────────┐ │
│  │ iceberg-agent (port 8090)                      │ │
│  │  • /catalog/* → Iceberg REST proxy            │ │
│  │  • /s3/* → S3 proxy                           │ │
│  │  • /query_iceberg → Embedded DuckDB (UDF)     │ │
│  └─────────────────┬──────────────────────────────┘ │
│                    ↓ TCP via tunnel                 │
│  ┌────────────────────────────────────────────────┐ │
│  │ tunnel-sidecar                                 │ │
│  │  • WebSocket (RSA + AES-256 encryption)       │ │
│  └─────────────────┬──────────────────────────────┘ │
└────────────────────┼──────────────────────────────────┘
                     │ Secure tunnel
                     ↓
┌──────────────────────────────────────────────────────┐
│ On-Premise (Your Laptop)                             │
│  ┌─────────────────────────────────────────────────┐ │
│  │ onpremise_agent.py (Tunnel Server)              │ │
│  └──────────┬──────────────────────────────────────┘ │
│             ├─→ :8181 → Lakekeeper (Iceberg REST)    │
│             └─→ :9000 → MinIO (S3)                   │
│                                                       │
│  ┌─────────────────┐  ┌──────────────────────┐      │
│  │ Lakekeeper      │  │ MinIO                │      │
│  │ (Iceberg REST)  │  │ (S3 Storage)         │      │
│  └─────────────────┘  └──────────────────────┘      │
│  ┌──────────────────────────────────────────────┐   │
│  │ PostgreSQL (Lakekeeper Metadata)             │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

## Key Features

### URL Rewriting
The catalog proxy automatically rewrites MinIO references in Iceberg metadata:
- Internal: `http://minio:9000/warehouse/...`
- External: `https://<snowflake-endpoint>/s3/warehouse/...`

This ensures external clients can access S3 data through the proxy.

### Hostname Mapping (UDF Path)
The Dockerfile includes hostname mapping to resolve internal Docker Compose references:
```dockerfile
RUN echo "127.0.0.1 minio" >> /etc/hosts
```

This allows the embedded DuckDB to access `minio:9000` references in metadata.

### Anonymous MinIO Access
For demo purposes, MinIO is configured with public bucket access:
```bash
mc anonymous set public myminio/warehouse
```

In production, configure proper IAM credentials.

## Files

- `iceberg_agent.py` - Core agent with proxy and embedded DuckDB
- `Dockerfile.iceberg.pixi` - Docker image with hostname mapping
- `demo-data/test_complete_flow.py` - End-to-end test script
- `demo-data/lakekeeper_seed.sql` - Seed demo Iceberg tables
- `ICEBERG-ARCHITECTURE.md` - Detailed architecture documentation

## Troubleshooting

### External Path: Connection Error
```
IO Error: Could not establish connection error for HTTP GET
```
**Solution:** Ensure iceberg-agent is running and accessible.

### Embedded Path: MinIO Hostname Error
```
IO Error: Could not establish connection error for HTTP GET to 'http://minio:9000/...'
```
**Solution:** Ensure Dockerfile includes `RUN echo "127.0.0.1 minio" >> /etc/hosts`

### Catalog Error: Table Not Found
```
Catalog Error: Table with name X does not exist
```
**Solution:** Verify data is seeded and catalog is attached correctly.

## Next Steps

1. ✅ Test external DuckDB path locally
2. ✅ Update Dockerfile with hostname mapping
3. 🔲 Deploy to Snowflake Container Services
4. 🔲 Test with production Snowflake endpoint
5. 🔲 Create Snowflake UDFs for embedded path
6. 🔲 Configure IAM credentials for production MinIO

## References

- [DuckDB Iceberg Extension](https://duckdb.org/docs/extensions/iceberg.html)
- [Lakekeeper Documentation](https://lakekeeper.io/)
- [Snowflake Container Services](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)

---

**Status:** External DuckDB path ✅ TESTED | UDF path ✅ READY FOR DEPLOYMENT



