
-- ============================================================================
-- Step 1: Create Database, Schema, Role & Compute Pool
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Create database and schema
CREATE DATABASE IF NOT EXISTS websocket_test_db;
CREATE SCHEMA IF NOT EXISTS websocket_test_schema;

-- Create compute pool for container services
CREATE COMPUTE POOL IF NOT EXISTS websocket_tunnel_pool
  MIN_NODES = 1
  MAX_NODES = 4
  INSTANCE_FAMILY = CPU_X64_S
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 3600;

-- Wait for compute pool to be ready (run this until status is IDLE or ACTIVE)
DESCRIBE COMPUTE POOL websocket_tunnel_pool;

-- Create role for container service management
CREATE ROLE IF NOT EXISTS DOCKERTEST;
// If you want to check your username
SELECT CURRENT_USER(); 


GRANT ROLE DOCKERTEST TO USER <YOUR_USERNAME>;


-- Grant necessary permissions
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE dockertest;

GRANT OWNERSHIP ON DATABASE websocket_test_db TO ROLE dockertest;

USE ROLE DOCKERTEST;
GRANT OWNERSHIP ON SCHEMA websocket_test_schema TO ROLE dockertest;
GRANT USAGE ON DATABASE websocket_test_db TO ROLE accountadmin;
GRANT USAGE ON SCHEMA websocket_test_schema TO ROLE accountadmin;
GRANT CREATE TABLE ON SCHEMA websocket_test_schema TO ROLE accountadmin;
GRANT USAGE ON COMPUTE POOL websocket_tunnel_pool TO ROLE dockertest;
GRANT OPERATE ON COMPUTE POOL websocket_tunnel_pool TO ROLE dockertest;
GRANT MONITOR ON COMPUTE POOL websocket_tunnel_pool TO ROLE dockertest;
GRANT MODIFY ON COMPUTE POOL websocket_tunnel_pool TO ROLE dockertest;

-- ============================================================================
-- Step 2: Create Image Repository
-- ============================================================================

USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;

CREATE IMAGE REPOSITORY IF NOT EXISTS websocket_images;
SHOW IMAGE REPOSITORIES IN SCHEMA;

-- Copy the repository URL from the output above
-- Example: myorg-myaccount.registry.snowflakecomputing.com/websocket_test_db/websocket_test_schema/websocket_images

-- ============================================================================
-- STOP HERE: Build and Push Docker Images
-- ============================================================================
-- Before proceeding, you must build and push the Docker images:
--  docker login <YOUR_REGISTRY_HOST>  --> USER: SNOWFLAKE LOGIN_NAME + PASSWORD: PAT
--
--
-- ./build-and-push.sh <YOUR_REGISTRY_URL>
--
-- Example:
-- ./build-and-push.sh myorg-myaccount.registry.snowflakecomputing.com/websocket_test_db/websocket_test_schema/websocket_images
--
-- This will build and push:
-- - postgresql-query:latest
-- - tunnel-sidecar:latest
-- - pgadmin-test:latest
-- ============================================================================

-- ============================================================================
-- Step 3: Create WebSocket Tunnel Service
-- ============================================================================
-- This service runs two containers:
-- 1. tunnel-sidecar: Handles WebSocket tunnel connections
-- 2. postgresql-query: Executes PostgreSQL queries through the tunnel

CREATE  SERVICE websocket_multi_db_service
  IN COMPUTE POOL websocket_tunnel_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    # ========================================================================
    # Container 1: Tunnel Sidecar (GENERIC - Database Agnostic)
    # ========================================================================
    - name: tunnel-sidecar
      image: /websocket_test_db/websocket_test_schema/websocket_images/tunnel-sidecar:latest
      env:
        WS_PORT: "8081"
        DISCOVERY_PORT: "8082"
        SNOWFLAKE_ACCOUNT: "<YOUR_ORG>-<YOUR_ACCOUNT>"
      resources:
        requests:
          memory: 256Mi
          cpu: 250m
        limits:
          memory: 512Mi
          cpu: 500m
    
    # ========================================================================
    # Container 2: PostgreSQL Query Service
    # ========================================================================
    - name: postgresql-query
      image: /websocket_test_db/websocket_test_schema/websocket_images/postgresql-query:latest
      env:
        API_PORT: "8080"
        USE_TUNNEL_SIDECAR: "true"
        # Connect to PostgreSQL through tunnel (localhost:5432)
        PG_HOST: "localhost"
        PG_PORT: "5432"
        PG_DATABASE: "test_db"
        PG_USER: "<YOUR_PG_USER>"
        PG_PASSWORD: ""
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 1Gi
          cpu: 1000m
    
    # ========================================================================
    # Endpoints
    # ========================================================================
    endpoints:
    - name: postgres-api
      port: 8080
      public: false
      
    - name: websocket
      port: 8081
      public: true
      
    - name: discovery
      port: 8082
      public: false

    # Pre-exposed tunnel ports (dynamically mapped by on-premise agent)
    - name: tunnel-port-5432
      port: 5432
      public: false
      # Default PostgreSQL
    
    - name: tunnel-port-5433
      port: 5433
      public: false
      # Alternative PostgreSQL instance
    
    - name: tunnel-port-3306
      port: 3306
      public: false
      # MySQL
    
    - name: tunnel-port-6379
      port: 6379
      public: false
      # Redis
    
    - name: tunnel-port-27017
      port: 27017
      public: false
      # MongoDB
    
    - name: tunnel-port-8181
      port: 8181
      public: false
      # Iceberg REST catalog
    
    - name: tunnel-port-9000
      port: 9000
      public: false
      # MinIO/S3
    
    - name: tunnel-port-8888
      port: 8888
      public: false
      # Generic HTTP service
  $$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1
  AUTO_RESUME = TRUE;

-- Verify service creation
SHOW SERVICES LIKE 'websocket_multi_db_service';
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');

-- Check container logs
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'postgresql-query', 100);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'tunnel-sidecar', 100);

-- ============================================================================
-- Step 4: Get WebSocket Endpoint (SAVE THIS!)
-- ============================================================================

SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;

-- Copy the 'websocket' endpoint URL (should start with https://)
-- Example: https://xyz123-myorg-myaccount.snowflakecomputing.app
--
-- IMPORTANT: Change 'https://' to 'wss://' in your .env file!
-- Example: wss://xyz123-myorg-myaccount.snowflakecomputing.app

-- ============================================================================
-- STOP HERE: Configure and Start On-Premise Agent
-- ============================================================================
-- Before proceeding, you must:
--
-- 1. Create on-premise configuration:
--    cp onpremise-deployment/config.template.env onpremise-deployment/.env
--
-- 2. Edit onpremise-deployment/.env with:
--    - SNOWFLAKE_URL (the wss:// endpoint from above)
--    - SNOWFLAKE_ACCOUNT (your account name)
--    - SNOWFLAKE_PAT (your Personal Access Token)
--
-- 3. Start the on-premise agent and PostgreSQL:
--    ./start-postgres-demo.sh
-- ============================================================================

-- ============================================================================
-- Step 5: Create Service Function to Query On-Premise PostgreSQL
-- ============================================================================

CREATE OR REPLACE FUNCTION query_onpremise(sql_query STRING)
RETURNS OBJECT
SERVICE=websocket_multi_db_service
ENDPOINT='postgres-api'
MAX_BATCH_ROWS=1
AS '/snowflake_function';

-- Test the tunnel connection
SELECT query_onpremise('SELECT version()');
SELECT query_onpremise('SELECT 1 as test');
SELECT query_onpremise('SELECT * FROM users LIMIT 5');

-- ============================================================================
-- Step 6 (OPTIONAL): Deploy pgAdmin for Visual Testing
-- ============================================================================

CREATE  SERVICE pgadmin_test_service
  IN COMPUTE POOL websocket_tunnel_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: pgadmin
      image: /websocket_test_db/websocket_test_schema/websocket_images/pgadmin-test:latest
      env:
        PGADMIN_DEFAULT_EMAIL: "admin@snowflake.com"
        PGADMIN_DEFAULT_PASSWORD: "admin123"
        PGADMIN_LISTEN_PORT: "80"
        PGADMIN_CONFIG_SERVER_MODE: "True"
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 1Gi
          cpu: 1000m
    
    endpoints:
    - name: pgadmin-web
      port: 80
      public: true
  $$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1
  AUTO_RESUME = TRUE;

-- Check pgAdmin service status
SELECT SYSTEM$GET_SERVICE_STATUS('pgadmin_test_service');
SHOW ENDPOINTS IN SERVICE pgadmin_test_service;

SHOW SERVICES;

-- Access pgAdmin at the public endpoint shown above
-- Login: admin@snowflake.com / admin123

-- ============================================================================
-- Step 7: Connect to On-Premise PostgreSQL from pgAdmin
-- ============================================================================
-- In pgAdmin, create a new server connection with:
--
-- Host: websocket-multi-db-service.mssi.svc.spcs.internal
-- Port: 5432
-- Database: test_db
-- Username: <your_pg_user>
-- Password: (leave empty)
--
-- This connects pgAdmin (running in Snowflake) to your on-premise PostgreSQL
-- through the secure WebSocket tunnel!
-- ============================================================================

-- ============================================================================
-- Troubleshooting Commands
-- ============================================================================

-- Check service status
SELECT SYSTEM$GET_SERVICE_STATUS('websocket_multi_db_service');
SHOW SERVICES;

-- View recent logs
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'tunnel-sidecar', 500);
CALL SYSTEM$GET_SERVICE_LOGS('websocket_multi_db_service', '0', 'postgresql-query', 500);

-- Restart service if needed
ALTER SERVICE websocket_multi_db_service SUSPEND;
ALTER SERVICE websocket_multi_db_service RESUME;

-- Check compute pool
DESCRIBE COMPUTE POOL websocket_tunnel_pool;
SHOW COMPUTE POOLS;

-- Drop and recreate service (if configuration changes are needed)
-- DROP SERVICE websocket_multi_db_service;
-- Then re-run Step 3

-- ============================================================================
-- Cleanup (Optional)
-- ============================================================================
-- Run these commands to remove all resources:
--
-- DROP SERVICE IF EXISTS pgadmin_test_service;
-- DROP SERVICE IF EXISTS websocket_multi_db_service;
-- DROP FUNCTION IF EXISTS query_onpremise(STRING);
-- DROP IMAGE REPOSITORY IF EXISTS websocket_images;
-- DROP COMPUTE POOL IF EXISTS websocket_tunnel_pool;
-- DROP SCHEMA IF EXISTS websocket_test_schema;
-- DROP DATABASE IF EXISTS websocket_test_db;
-- DROP ROLE IF EXISTS DOCKERTEST;
-- ============================================================================

