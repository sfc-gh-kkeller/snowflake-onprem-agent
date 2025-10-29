-- Seed Lakekeeper via DuckDB REST inside docker-compose network
-- Usage: docker run --network <compose_net> -v "$PWD/demo-data:/sql" duckdb/duckdb -c ".read /sql/lakekeeper_seed.sql"

INSTALL iceberg; LOAD iceberg;
INSTALL httpfs;  LOAD httpfs;

-- MinIO credentials (internal compose endpoints)
CREATE OR REPLACE SECRET minio_s3 (
  TYPE S3,
  KEY_ID 'admin',
  SECRET 'password',
  ENDPOINT 'http://minio:9000',
  URL_STYLE 'path',
  USE_SSL false
);

-- Lakekeeper REST (dummy ok for local)
CREATE OR REPLACE SECRET iceberg_rest (
  TYPE ICEBERG,
  TOKEN 'dummy'
);

-- Attach catalog via Lakekeeper REST
ATTACH 'demo' AS demo (
  TYPE ICEBERG,
  ENDPOINT 'http://lakekeeper:8181/catalog/',
  SECRET iceberg_rest
);

-- Create namespace
CREATE SCHEMA IF NOT EXISTS demo.demo;

-- Create and populate sales
CREATE TABLE IF NOT EXISTS demo.demo.sales (
  sale_id INTEGER,
  product VARCHAR,
  amount INTEGER,
  sale_date DATE,
  region VARCHAR
);
INSERT INTO demo.demo.sales VALUES
  (1,'Laptop',1200,DATE '2025-01-01','North'),
  (2,'Mouse',25,DATE '2025-01-02','South'),
  (3,'Keyboard',75,DATE '2025-01-03','East'),
  (4,'Monitor',350,DATE '2025-01-04','West'),
  (5,'Headset',120,DATE '2025-01-05','Central');

-- Create and populate customers
CREATE TABLE IF NOT EXISTS demo.demo.customers (
  customer_id INTEGER,
  name VARCHAR,
  country VARCHAR
);
INSERT INTO demo.demo.customers VALUES
  (1,'Alice','USA'),
  (2,'Bob','UK'),
  (3,'Carol','Germany');

-- Verify
SHOW TABLES FROM demo.demo;
SELECT COUNT(*) AS sales_rows FROM demo.demo.sales;
SELECT COUNT(*) AS customers_rows FROM demo.demo.customers;
