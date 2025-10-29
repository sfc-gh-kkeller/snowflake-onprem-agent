# Iceberg Agent Architecture

## Overview

The `iceberg_agent.py` provides two modes of querying Lakekeeper-managed Iceberg tables through a secure tunnel:

1. **Embedded DuckDB (UDF Path)**: Snowflake UDFs call `/query_iceberg` REST API, which uses embedded DuckDB
2. **External DuckDB (Proxy Path)**: External DuckDB clients (Python, CLI) use catalog and S3 proxy endpoints

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Snowflake Container Services (SPCS)                        │
│                                                             │
│  ┌──────────────────────────────────────────┐              │
│  │ iceberg-agent Container                  │              │
│  │                                          │              │
│  │  ┌────────────────────────────────┐     │              │
│  │  │ REST API (port 8090)           │     │              │
│  │  │                                │     │              │
│  │  │ • POST /query_iceberg         │     │              │
│  │  │   ↓                            │     │              │
│  │  │ [Embedded DuckDB + Iceberg]   │     │              │
│  │  │                                │     │              │
│  │  │ • GET /catalog/* (proxy)      │     │              │
│  │  │ • GET /s3/* (S3 proxy)        │     │              │
│  │  └────────────────────────────────┘     │              │
│  │           ↓ ↓ (via tunnel)              │              │
│  └──────────────────────────────────────────┘              │
│               ↓ ↓                                          │
│  ┌──────────────────────────────────────────┐              │
│  │ tunnel-sidecar Container                 │              │
│  │  • TCP Tunnel (WebSocket + RSA/AES)     │              │
│  └──────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────┘
                 ↓ ↓ (secure tunnel)
┌─────────────────────────────────────────────────────────────┐
│ On-Premise (Laptop)                                        │
│                                                             │
│  ┌──────────────────────────────────────────┐              │
│  │ onpremise_agent.py                      │              │
│  │  • Tunnel Server                        │              │
│  │  • Port Mappings:                       │              │
│  │    - 8181 → Lakekeeper                 │              │
│  │    - 9000 → MinIO                      │              │
│  └──────────────────────────────────────────┘              │
│               ↓ ↓                                          │
│  ┌────────────────────┐  ┌────────────────────┐          │
│  │ Lakekeeper         │  │ MinIO (S3)        │          │
│  │ (Iceberg Catalog)  │  │ (Object Storage)  │          │
│  │ :8181              │  │ :9000             │          │
│  └────────────────────┘  └────────────────────┘          │
│               ↓                    ↓                       │
│  ┌────────────────────────────────────────────┐          │
│  │ PostgreSQL                                 │          │
│  │ (Lakekeeper Metadata)                     │          │
│  └────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

## Usage Modes

### Mode 1: Embedded DuckDB (Snowflake UDF)

**Snowflake UDF calls the iceberg-agent REST API:**

```sql
-- Create UDF in Snowflake
CREATE OR REPLACE FUNCTION query_iceberg(query STRING, catalog STRING)
RETURNS VARIANT
SERVICE=iceberg_service
ENDPOINT='iceberg-agent'
AS '/query_iceberg';

-- Query Iceberg table through UDF
SELECT query_iceberg('SELECT COUNT(*) FROM demo.sales', 'demo');
```

**How it works:**
1. Snowflake UDF sends POST request to `http://iceberg-agent:8090/query_iceberg`
2. Agent's embedded DuckDB connects to:
   - Iceberg REST catalog at `localhost:8181/catalog/` (via tunnel → Lakekeeper)
   - S3 at `localhost:9000` (via tunnel → MinIO)
3. DuckDB executes query and returns results as JSON

**Current Limitation:**
- When Iceberg metadata contains `http://minio:9000` references (from Docker Compose seeding), the embedded DuckDB cannot resolve `minio` hostname
- **Workaround:** Use Docker's `--add-host minio:127.0.0.1` or seed data with `localhost:9000` instead

### Mode 2: External DuckDB (Direct Proxy)

**External Python/CLI DuckDB connects through proxy:**

```python
import duckdb

conn = duckdb.connect()
conn.execute("INSTALL iceberg; LOAD iceberg;")
conn.execute("INSTALL httpfs; LOAD httpfs;")

# Configure S3 access through /s3 proxy
conn.execute(f"""
CREATE SECRET iceberg_secret (
    TYPE S3,
    ENDPOINT 'https://<snowflake-endpoint>/s3',
    ACCESS_KEY_ID 'admin',
    SECRET_ACCESS_KEY 'password',
    USE_SSL true,  # Use false for local http testing
    URL_STYLE 'path'
);
""")

# Configure Iceberg REST secret
conn.execute("""
CREATE SECRET iceberg_rest (
    TYPE ICEBERG,
    TOKEN 'dummy'
);
""")

# Attach catalog through /catalog proxy
conn.execute(f"""
ATTACH 'demo' AS demo (
    TYPE ICEBERG,
    ENDPOINT 'https://<snowflake-endpoint>/catalog/',
    SECRET iceberg_rest
);
""")

# Query!
result = conn.execute("SELECT * FROM demo.demo.sales LIMIT 5").fetchall()
```

**How it works:**
1. External DuckDB sends catalog requests to `https://<snowflake-endpoint>/catalog/*`
   - Agent proxies to `localhost:8181/catalog/*` (tunnel → Lakekeeper)
   - **Response rewriting**: Agent replaces `http://minio:9000` with `https://<endpoint>/s3` in JSON responses
2. External DuckDB sends S3 requests to `https://<snowflake-endpoint>/s3/*`
   - Agent proxies to `localhost:9000/*` (tunnel → MinIO)
3. Data files are fetched through the tunnel

**Advantages:**
- Works with external clients (no hostname resolution issues)
- URL rewriting ensures all S3 references go through `/s3` proxy
- MinIO bucket can be anonymous (no credentials needed in metadata)

## Key Implementation Details

### URL Rewriting for External Clients

The catalog proxy automatically rewrites MinIO references in Iceberg metadata:

```python
# In handle_catalog_rest_proxy()
if 'application/json' in content_type:
    text = response_body.decode('utf-8')
    base_url = f"{request.scheme}://{request.host}"
    text = text.replace('http://minio:9000', f"{base_url}/s3")
    response_body = text.encode('utf-8')
```

This ensures external clients always use the S3 proxy path.

### MinIO Anonymous Access

For local development, MinIO is configured with anonymous read access:

```bash
mc anonymous set public myminio/warehouse
```

This allows the `/s3` proxy to serve data without requiring credentials in every request.

### Seeding Data

Data should be seeded from within the Docker Compose network using internal hostnames:

```bash
docker run --network snowagent_default \
  -v "$PWD/demo-data:/sql" \
  duckdb/duckdb:v1.4.1 \
  -c ".read /sql/lakekeeper_seed.sql"
```

The seed script references `http://minio:9000` and `http://lakekeeper:8181/catalog/` (internal DNS).

## Deployment to Snowflake

1. **Build and push Docker image:**
   ```bash
   ./build-and-push-v3.sh
   ```

2. **Create service in Snowflake:**
   ```sql
   -- See CREATE-SERVICE-V3-ICEBERG.sql
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
           TUNNEL_TOKEN: "..."
   $$;
   ```

3. **Get public endpoint:**
   ```sql
   SHOW ENDPOINTS IN SERVICE iceberg_service;
   -- Use the ingress_url for external DuckDB clients
   ```

4. **Create UDFs for embedded path:**
   ```sql
   CREATE FUNCTION query_iceberg(query STRING, catalog STRING)
   RETURNS VARIANT
   SERVICE=iceberg_service
   ENDPOINT='iceberg-agent'
   AS '/query_iceberg';
   ```

## Security Considerations

- **Tunnel Encryption**: RSA-2048 + AES-256-GCM for all tunnel traffic
- **MinIO Access**: Currently anonymous for demo; use IAM roles in production
- **Snowflake External Access**: Configure network rules to allow agent → tunnel communication
- **Token Authentication**: Tunnel requires pre-shared token for connection establishment

## Limitations

1. **Embedded DuckDB hostname resolution**: Cannot resolve `minio:9000` from metadata
   - Use `--add-host` in Docker or seed with `localhost:9000`
2. **Write operations**: External clients cannot write through proxy (metadata points to internal `minio:9000`)
   - Writes must originate from Docker Compose network
3. **Performance**: Proxy adds latency vs direct S3 access
4. **Metadata caching**: DuckDB may cache Iceberg metadata; restart agent to clear

## Future Enhancements

- [ ] Add hostname rewriting in Docker (`/etc/hosts` injection)
- [ ] Support IAM credential forwarding for S3
- [ ] Add result caching for embedded UDF queries
- [ ] Support Iceberg table writes through proxy
- [ ] Add metrics and observability endpoints



