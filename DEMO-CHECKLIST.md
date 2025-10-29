# Demo Checklist

Quick reference checklist to verify the demo is ready to run.

## ✅ Pre-Demo Checklist

### 1. Local Services Running
```bash
# Check Docker containers
docker ps | grep -E "iceberg|minio|postgres|lakekeeper"
# Should show 3 healthy containers:
# - iceberg-postgres
# - iceberg-minio  
# - iceberg-lakekeeper
```

### 2. Demo Data Seeded
```bash
# Verify Iceberg table exists
pixi run duckdb << EOF
ATTACH 'demo' AS demo (TYPE iceberg, ENDPOINT 'http://lakekeeper:8181/catalog/');
SELECT * FROM demo.demo.sales LIMIT 3;
EOF
# Should return 3 rows of sales data
```

### 3. PostgreSQL Database Setup
```bash
# Verify test_user and test_db exist with data
pixi run psql -d test_db -U test_user -c "SELECT * FROM users LIMIT 5;"
# Should return 5 users (John Doe, Jane Smith, Bob Johnson, Alice Williams, Charlie Brown)

# Check orders table
pixi run psql -d test_db -U test_user -c "SELECT COUNT(*) FROM orders;"
# Should return 12 orders
```

### 4. Snowflake Service Running
```sql
-- In Snowflake
USE ROLE dockertest;
USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

SHOW SERVICES;
-- Should show websocket_multi_db_service as READY

SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;
-- Note the websocket endpoint (port 8081)
```

### 5. On-Premise Agent Connected
```bash
# Check agent is running and connected
tail -20 /tmp/onpremise-agent.log | grep "authenticated and ready"
# Should show: ✅ Agent authenticated and ready

# Verify port mappings
grep -A 3 "Port Mappings:" /tmp/onpremise-agent.log | tail -4
# Should show:
#    5432 → localhost:5432
#    8181 → localhost:8181
#    9000 → localhost:9000
```

## 🚀 Demo Flow

### Test 1: PostgreSQL Query
```sql
USE WAREHOUSE S2;
SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5') AS result;
```
**Expected**: JSON array with 5 user records

### Test 2: Iceberg Count
```sql
SELECT query_iceberg('SELECT COUNT(*) as count FROM demo.demo.sales') AS result;
```
**Expected**: `[[10]]` (count of sales records)

### Test 3: Iceberg Full Query
```sql
SELECT query_iceberg('SELECT * FROM demo.demo.sales LIMIT 3') AS result;
```
**Expected**: JSON array with 3 sales records (id, product, quantity, price, sale_date)

### Test 4: Parallel Queries
```sql
SELECT 
    query_onpremise_v2('SELECT COUNT(*) FROM users') AS postgres_count,
    query_iceberg('SELECT COUNT(*) FROM demo.demo.sales') AS iceberg_count;
```
**Expected**: Two counts side by side

## 🔧 Troubleshooting

### Service Not Ready
```sql
-- Check service status
CALL SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');

-- Check logs
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'iceberg-agent', 20);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'snowflake-agent', 20);
```

### Agent Not Connected
```bash
# Check agent logs
tail -50 /tmp/onpremise-agent.log

# Restart agent
pkill -f onpremise_agent.py
cd /Users/kevin/DevWork/Snowflake/SnowAgent
.pixi/envs/default/bin/python onpremise-deployment/onpremise_agent.py > /tmp/onpremise-agent.log 2>&1 &
```

### Local Services Down
```bash
# Restart Iceberg stack
pixi run iceberg-down
pixi run iceberg-up

# Re-seed data
pixi run duckdb < demo-data/lakekeeper_seed.sql
```

## 📊 Demo Talking Points

1. **Security**: RSA-2048 key exchange + AES-256-GCM encryption
2. **Dual Database**: Single tunnel serves both PostgreSQL and Iceberg
3. **Zero Network Changes**: No firewall modifications needed
4. **DuckDB Integration**: Embedded DuckDB queries Lakekeeper-managed tables
5. **Production Ready**: Automatic reconnection, connection pooling, error handling

## 🎯 Key Files for Demo

- `README.md` - Overview and quick start
- `ICEBERG-ARCHITECTURE.md` - Architecture deep dive
- `test_demo.sql` - All demo queries in one file
- `CREATE-SERVICE-V3-ICEBERG.sql` - Service definition
- `onpremise-deployment/config.kevin.env` - Configuration reference

