-- ============================================================================
-- Snowflake WebSocket Tunnel Service - Creation Script
-- ============================================================================
-- Account: SFSENORTHAMERICA-SECFIELDKELLER
-- User: KEVIN.KELLER@SNOWFLAKESECLAB42OUTLOOK.ONMICROSOFT.COM
-- Image: websocket_images/snowflake-agent:latest
-- ============================================================================

-- Use your database and schema
USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

grant ownership on database websocket_test_db to role accountadmin;
grant ownership on schema websocket_test_schema to role accountadmin;

grant ownership on database websocket_test_db to role dockertest;
grant ownership on schema websocket_test_schema to role dockertest;

grant modify on database websocket_test_db to role accountadmin;
grant modify on schema websocket_test_schema to role accountadmin;

revoke modify on database websocket_test_db from role accountadmin;
revoke modify on schema websocket_test_schema from role accountadmin;

grant usage on database websocket_test_db to role accountadmin;
grant usage on schema websocket_test_schema to role accountadmin;

revoke usage on database websocket_test_db from role accountadmin;
revoke usage on schema websocket_test_schema from role accountadmin;

grant create table on schema websocket_test_schema to role accountadmin;
revoke  create table on schema websocket_test_schema from role accountadmin;

CREATE OR REPLACE NETWORK RULE duckdb_extensions_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('extensions.duckdb.org');

  alter network rule duckdb_extensions_network_rule set VALUE_LIST = ('0.0.0.0');

-- ============================================================================
-- Step 2: Create External Access Integration
-- ============================================================================

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION duckdb_extensions_access_integration
  ALLOWED_NETWORK_RULES = (duckdb_extensions_network_rule)
  ENABLED = true;

-- ============================================================================
-- Step 3: Grant Usage to your role
-- ============================================================================

GRANT USAGE ON INTEGRATION duckdb_extensions_access_integration TO ROLE dockertest;

-- ============================================================================
-- Step 1: Create Compute Pool
-- ============================================================================

CREATE COMPUTE POOL IF NOT EXISTS websocket_tunnel_pool
  MIN_NODES = 1
  MAX_NODES = 4
  INSTANCE_FAMILY = CPU_X64_S
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 3600;

    drop compute pool websocket_tunnel_pool;
   alter compute pool websocket_tunnel_pool set  MAX_NODES = 4;
   alter compute pool websocket_tunnel_pool set  INSTANCE_FAMILY= CPU_X64_S;

-- Wait for compute pool to be ready (run this until status is IDLE or ACTIVE)
DESCRIBE COMPUTE POOL websocket_tunnel_pool;


grant usage on compute pool websocket_tunnel_pool to role dockertest;
grant operate on compute pool websocket_tunnel_pool to role dockertest;
grant monitor on compute pool websocket_tunnel_pool to role dockertest;
grant modify on compute pool websocket_tunnel_pool to role dockertest;
grant ownership on compute pool websocket_tunnel_pool to role dockertest;

-- ============================================================================
-- Step 2: Create Service
-- ============================================================================


CREATE SERVICE websocket_tunnel_service
  IN COMPUTE POOL websocket_tunnel_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: snowflake-agent
      image: /websocket_test_db/websocket_test_schema/websocket_images/snowflake-agent:latest
      env:
        HOST: "0.0.0.0"
        PORT: "8080"
        WS_PORT: "8081"
        SNOWFLAKE_ACCOUNT: "SFSENORTHAMERICA-SECFIELDKELLER"
        HANDSHAKE_SECRET: "your-secret-key-here-change-in-production"
        # PostgreSQL connection settings (used by asyncpg driver through tunnel)
        # This defines WHERE the on-premise agent should connect
        PG_HOST: "localhost"
        PG_PORT: "5432"
        PG_DATABASE: "test_db"
        PG_USER: "test_user"
        PG_PASSWORD: "test_pass"
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 1Gi
          cpu: 1000m
    endpoints:
    - name: api
      port: 8080
      public: true
    - name: websocket
      port: 8081
      public: true
  $$;


  USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

drop SERVICE websocket_tunnel_service_v2;


-- Step 1 & 2: Redeploy the service
USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

ALTER SERVICE websocket_tunnel_service_v2 SUSPEND;
DROP SERVICE websocket_tunnel_service_v2;

USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

CREATE SERVICE websocket_tunnel_service_v2
  IN COMPUTE POOL  websocket_tunnel_pool
  FROM SPECIFICATION $$
    spec:
      containers:
      - name: tunnel-sidecar
        image: /websocket_test_db/websocket_test_schema/websocket_images/tunnel-sidecar:optimized
        env:
          WS_PORT: "8081"
          SNOWFLAKE_ACCOUNT: "SFSENORTHAMERICA-SECFIELDKELLER"
          HANDSHAKE_SECRET: "your-secret-key-here-change-in-production"
        resources:
          limits:
            memory: 512Mi
            cpu: "500m"
          requests:
            memory: 256Mi
            cpu: "250m"
      - name: snowflake-agent
        image: /websocket_test_db/websocket_test_schema/websocket_images/snowflake-agent:optimized
        env:
          API_PORT: "8080"
          USE_TUNNEL_SIDECAR: "true"
          PG_HOST: "localhost"
          PG_PORT: "5432"
          PG_DATABASE: "demo_db"
          PG_USER: "kevin"
          PG_PASSWORD: ""
        resources:
          limits:
            memory: 1Gi
            cpu: "1000m"
          requests:
            memory: 512Mi
            cpu: "500m"
      endpoints:
      - name: api
        port: 8080
        public: true
      - name: websocket
        port: 8081
        public: true
  MIN_INSTANCES=1
  MAX_INSTANCES=1
  AUTO_RESUME=TRUE;
  $$;




-- Check status (wait for READY)
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_tunnel_service_v2');

-- Get endpoints
SHOW ENDPOINTS IN SERVICE websocket_tunnel_service_v2;

-- Create function
CREATE OR REPLACE FUNCTION query_onpremise_v2(sql_query STRING)
RETURNS OBJECT
SERVICE=websocket_tunnel_service_v2
ENDPOINT=api
MAX_BATCH_ROWS=1
AS '/snowflake_function';

SELECT query_onpremise_v2('SELECT * FROM users ;');
SELECT query_onpremise_v2('SELECT version()');

SELECT query_onpremise_v2('SELECT COUNT(*) FROM users');

CALL SYSTEM$GET_SERVICE_LOGS('websocket_tunnel_service_v2', 0, 'tunnel-sidecar', 1000);

CALL SYSTEM$GET_SERVICE_LOGS('websocket_tunnel_service_v2', 0, 'snowflake-agent', 1000);

-- ============================================================================
-- Step 3: Check Service Status
-- ============================================================================


CREATE OR REPLACE FUNCTION query_onpremise(sql_query STRING)
RETURNS OBJECT
SERVICE=websocket_multi_db_service
ENDPOINT='postgres-api'
MAX_BATCH_ROWS=1
AS '/snowflake_function';

SELECT query_onpremise('SELECT 1 as test');
SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5');

-- Show all services
SHOW SERVICES;

-- Describe this specific service
DESCRIBE SERVICE websocket_tunnel_service_v2;
drop SERVICE websocket_tunnel_service_v2;

ALTER SERVICE websocket_tunnel_service SUSPEND;
ALTER SERVICE websocket_tunnel_service RESUME;

-- Check service status (should be "READY" when fully started)
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_tunnel_service');

CALL SYSTEM$GET_SERVICE_LOGS('websocket_tunnel_service', '0', 'snowflake-agent', 1000);
SHOW ENDPOINTS IN SERVICE websocket_tunnel_service;

SELECT PARSE_JSON(
    SYSTEM$HTTP_GET('http://websocket-tunnel-service:8080/health')
) as health_status;

-- ============================================================================
-- Step 4: Get Endpoint URLs (IMPORTANT!)
-- ============================================================================

SHOW ENDPOINTS IN SERVICE websocket_tunnel_service;

-- Note the ingress_url values:
-- - "api" endpoint for REST API (HTTPS)
-- - "websocket" endpoint for WebSocket tunnel (WSS)
-- You need the websocket endpoint URL for the on-premise agent config!

-- ============================================================================
-- Step 5: View Logs
-- ============================================================================

-- View recent logs
SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_tunnel_service', 0, 'snowflake-agent')
) ORDER BY TIMESTAMP DESC LIMIT 100;

-- View errors only
SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_tunnel_service', 0, 'snowflake-agent')
) WHERE SEVERITY = 'ERROR'
ORDER BY TIMESTAMP DESC;

-- ============================================================================
-- Useful Management Commands
-- ============================================================================

-- Suspend service (stops but keeps configuration)
-- ALTER SERVICE websocket_tunnel_service SUSPEND;

-- Resume service
-- ALTER SERVICE websocket_tunnel_service RESUME;

-- Drop service (if you need to recreate)
-- DROP SERVICE websocket_tunnel_service;

-- Drop compute pool (only after dropping all services using it)
-- DROP COMPUTE POOL websocket_tunnel_pool;

-- ============================================================================
-- Expected Output from SHOW ENDPOINTS
-- ============================================================================
-- You should see something like:
--
-- name       | port | protocol | ingress_url
-- -----------|------|----------|------------------------------------------
-- api        | 8080 | https    | https://abc-xyz.snowflakecomputing.com
-- websocket  | 8081 | https    | https://def-uvw.snowflakecomputing.com
--
-- Copy the websocket ingress_url and update your on-premise config:
-- SNOWFLAKE_URL=wss://def-uvw.snowflakecomputing.com
-- (Replace https:// with wss:// for WebSocket connection)
-- ============================================================================

drop service websocket_multi_db_service;

CREATE  SERVICE websocket_multi_db_service
  IN COMPUTE POOL websocket_tunnel_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    # ========================================================================
    # Container 1: Tunnel Sidecar (GENERIC - Database Agnostic)
    # ========================================================================
    - name: tunnel-sidecar
      image: /websocket_test_db/websocket_test_schema/websocket_images/tunnel-sidecar:optimized
      env:
        WS_PORT: "8081"
        SNOWFLAKE_ACCOUNT: "SFSENORTHAMERICA-SECFIELDKELLER"
        HANDSHAKE_SECRET: "your-secret-key-here-change-in-production"
      resources:
        requests:
          memory: 256Mi
          cpu: 250m
        limits:
          memory: 512Mi
          cpu: 500m
    
    # ========================================================================
    # Container 2: Snowflake Agent (PostgreSQL Logic)
    # ========================================================================
    - name: snowflake-agent
      image: /websocket_test_db/websocket_test_schema/websocket_images/snowflake-agent:optimized
      env:
        API_PORT: "8080"
        USE_TUNNEL_SIDECAR: "true"
        # Connect to PostgreSQL through tunnel (localhost:5432)
        PG_HOST: "localhost"
        PG_PORT: "5432"
        PG_DATABASE: "demo_db"
        PG_USER: "kevin"
        PG_PASSWORD: ""
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 1Gi
          cpu: 1000m
    
    # ========================================================================
    # Container 3: Iceberg Agent (Iceberg Logic) - NEW!
    # ========================================================================
    - name: iceberg-agent
      image: /websocket_test_db/websocket_test_schema/websocket_images/iceberg-agent:latest
      env:
        API_PORT: "8090"
        # Connect to Iceberg REST & MinIO through tunnel
        ICEBERG_PORT: "8181"
        S3_PORT: "9000"
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 1Gi
          cpu: 1000m
    
    # ========================================================================
    # Public Endpoints
    # ========================================================================
    endpoints:
    - name: postgres-api
      port: 8080
      public: true
    - name: iceberg-api
      port: 8090
      public: true
    - name: websocket
      port: 8081
      public: true
  $$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1
  AUTO_RESUME = TRUE
  EXTERNAL_ACCESS_INTEGRATIONS = (duckdb_extensions_access_integration);

alter service websocket_multi_db_service suspend;
alter service websocket_multi_db_service resume;


-- Wait 30 seconds for service to start
SELECT SYSTEM$WAIT(30);

-- Show service
SHOW SERVICES LIKE 'websocket_multi_db_service';

CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'snowflake-agent', 1000);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'tunnel-sidecar', 1000);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'iceberg-agent', 1000);

-- ============================================================================
-- Step 4: Get endpoints (SAVE THE WEBSOCKET ENDPOINT!)
-- ============================================================================

SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;

-- ============================================================================
-- Step 5: Create Iceberg UDF
-- ============================================================================

CREATE OR REPLACE FUNCTION query_iceberg(sql_query STRING, catalog_name STRING)
RETURNS VARIANT
SERVICE=websocket_multi_db_service  -- Update this to match your actual service name
ENDPOINT='iceberg-api'
MAX_BATCH_ROWS=1
AS '/query_iceberg';

-- ============================================================================
-- Step 6: Verify existing PostgreSQL UDF still works
-- ============================================================================

-- Check if query_onpremise_v2 exists
SHOW USER FUNCTIONS LIKE 'query_onpremise_v2';

-- If it doesn't exist, create it
CREATE OR REPLACE FUNCTION query_onpremise_v2(sql_query STRING)
RETURNS VARIANT
SERVICE=websocket_multi_db_service
ENDPOINT='postgres-api'
AS '/snowflake_function';

-- ============================================================================
-- SUCCESS!
-- ============================================================================
-- Next steps:
-- 1. Copy the WebSocket endpoint from Step 4 above
-- 2. Update onpremise-deployment/config.kevin.env with:
--    SNOWFLAKE_URL=wss://<endpoint>.snowflakecomputing.app
-- 3. Restart on-premise agent
-- 4. Test queries below
-- ============================================================================

-- Test PostgreSQL
SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5');
SELECT query_onpremise_v2('SELECT version()');

-- Test Iceberg
SELECT query_iceberg('SELECT 1 as test');
SELECT query_iceberg('SELECT * FROM demo.demo.sales');

-- View logs
SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', 0, 'iceberg-agent')
) ORDER BY TIMESTAMP DESC LIMIT 50;


