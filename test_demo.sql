-- SnowAgent Demo Test Script
-- Tests both PostgreSQL and Iceberg queries through the secure tunnel

-- Setup
USE ROLE dockertest;
USE DATABASE websocket_test_db;
USE SCHEMA websocket_test_schema;
USE WAREHOUSE S2;

-- Check service status
SHOW ENDPOINTS IN SERVICE websocket_multi_db_service;

-- Test 1: Query PostgreSQL
SELECT query_onpremise_v2('SELECT * FROM users LIMIT 5') AS postgres_result;

-- Test 2: Query Iceberg (count)
SELECT query_iceberg('SELECT COUNT(*) as count FROM demo.demo.sales') AS iceberg_count;

-- Test 3: Query Iceberg (full data)
SELECT query_iceberg('SELECT * FROM demo.demo.sales LIMIT 3') AS iceberg_data;

-- Test 4: Both queries in parallel
SELECT 
    query_onpremise_v2('SELECT COUNT(*) FROM users') AS postgres_count,
    query_iceberg('SELECT COUNT(*) FROM demo.demo.sales') AS iceberg_count;



