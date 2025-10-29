-- ============================================================================
-- Snowflake Multi-Database Service - v3.0 with Iceberg Support
-- ============================================================================
-- PostgreSQL + Iceberg queries through a single generic tunnel
-- ============================================================================

USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

-- ============================================================================
-- Create Multi-Container Service (v3.0: PostgreSQL + Iceberg)
-- ============================================================================

CREATE OR REPLACE SERVICE websocket_multi_db_service
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
  AUTO_RESUME = TRUE;

-- ============================================================================
-- How This Works
-- ============================================================================
--
-- ON-PREMISE:
-- -----------
-- - PostgreSQL running on localhost:5432
-- - Iceberg REST Catalog on localhost:8181
-- - MinIO S3 Storage on localhost:9000
-- - On-premise agent pushes port mappings: [5432, 8181, 9000]
--
-- TUNNEL (GENERIC - No Database Knowledge):
-- -----------------------------------------
-- - Receives port mappings from on-premise agent
-- - Opens TCP listeners: 5432, 8181, 9000
-- - Forwards all traffic through encrypted WebSocket
-- - RSA-2048 key exchange + AES-256 encryption
--
-- SNOWFLAKE CONTAINERS:
-- ---------------------
-- 1. snowflake-agent:
--    - Connects to localhost:5432 (PostgreSQL via tunnel)
--    - Uses asyncpg driver
--    - Exposes /snowflake_function endpoint
--
-- 2. iceberg-agent:
--    - Connects to localhost:8181 (Iceberg REST via tunnel)
--    - Connects to localhost:9000 (MinIO S3 via tunnel)
--    - Uses DuckDB with Iceberg extension
--    - Exposes /query_iceberg endpoint
--
-- BENEFITS:
-- ---------
-- ✅ One tunnel serves multiple databases
-- ✅ Tunnel is completely database-agnostic
-- ✅ Each agent has database-specific logic
-- ✅ Clean separation of concerns
-- ✅ RSA key exchange for security
--
-- ============================================================================

-- Check service status
SHOW SERVICES LIKE 'websocket_multi_db_service';

-- Get endpoints (IMPORTANT - save these!)
SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;

-- View logs
SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', 0, 'tunnel-sidecar')
) ORDER BY TIMESTAMP DESC LIMIT 50;

SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', 0, 'snowflake-agent')
) ORDER BY TIMESTAMP DESC LIMIT 50;

SELECT * FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', 0, 'iceberg-agent')
) ORDER BY TIMESTAMP DESC LIMIT 50;



