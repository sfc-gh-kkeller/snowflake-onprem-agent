"""
Iceberg Agent - REST API with TCP Tunnel to On-Premise Iceberg
Runs in Snowflake Container Services alongside tunnel-sidecar
Connects to Iceberg REST Catalog (port 8181) and MinIO S3 (port 9000) through tunnel
Uses DuckDB to query Iceberg tables
"""

import asyncio
import os
import logging
import json
import aiohttp
from aiohttp import web
import duckdb
from typing import Dict, Any

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class IcebergAgent:
    """REST API in Snowflake that queries Iceberg through tunnel"""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.host = config.get('host', '0.0.0.0')
        self.http_port = config.get('port', 8090)
        
        # Iceberg connection (through tunnel)
        self.iceberg_rest_url = f"http://localhost:{config.get('iceberg_port', 8181)}"
        self.s3_endpoint = f"http://localhost:{config.get('s3_port', 9000)}"
        
        # DuckDB connection (embedded)
        self.duckdb_conn = None
        
    async def start(self):
        """Start the HTTP server"""
        logger.info("============================================================")
        logger.info("  ICEBERG AGENT - Iceberg Queries via Tunnel")
        logger.info("============================================================")
        logger.info(f"Configuration: {self.config}")
        logger.info(f"🗄️  Iceberg REST (via tunnel): {self.iceberg_rest_url}")
        logger.info(f"📦 MinIO S3 (via tunnel): {self.s3_endpoint}")
        logger.info(f"🌐 REST API: {self.host}:{self.http_port}")
        logger.info("============================================================")
        
        # Initialize DuckDB with Iceberg extension
        await self.init_duckdb()
        
        # Start HTTP server
        app = web.Application()
        app.router.add_post('/query_iceberg', self.handle_query_request)
        app.router.add_get('/health', self.handle_health)
        # Local demo seeding (DuckDB writes via Lakekeeper + MinIO)
        app.router.add_post('/seed_demo', self.handle_seed_demo)
        
        # NEW: Iceberg REST Proxy endpoints (forward to on-premise catalog)
        # This allows external DuckDB to connect via Snowflake endpoint
        app.router.add_route('*', '/v1/{tail:.*}', self.handle_iceberg_rest_proxy)
        # Also support catalogs that expect '/catalog/*' paths (e.g., Lakekeeper docs examples)
        app.router.add_route('*', '/catalog/{tail:.*}', self.handle_iceberg_catalog_proxy)
        
        # NEW: Anonymous S3/MinIO proxy for object reads/writes
        # External DuckDB can set ENDPOINT to https://<endpoint>/s3
        app.router.add_route('*', '/s3/{tail:.*}', self.handle_s3_proxy)
        
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, self.host, self.http_port)
        await site.start()
        
        logger.info(f"✅ REST API started on port {self.http_port}")
        logger.info(f"📡 Endpoints:")
        logger.info(f"   • POST /query_iceberg - DuckDB embedded queries")
        logger.info(f"   • * /v1/* - Iceberg REST proxy (for external DuckDB)")
        logger.info("✅ Iceberg Agent ready")
        
        # Keep running
        await asyncio.Event().wait()
    
    async def init_duckdb(self):
        """Initialize DuckDB with Iceberg catalog configuration"""
        try:
            logger.info("📊 Initializing DuckDB with Iceberg extension...")
            
            # Create DuckDB connection
            self.duckdb_conn = duckdb.connect(':memory:')
            
            # Load pre-installed extensions (installed during Docker build)
            logger.info("📦 Loading pre-installed DuckDB extensions...")
            self.duckdb_conn.execute("LOAD iceberg")
            logger.info("✅ Iceberg extension loaded")
            
            self.duckdb_conn.execute("LOAD httpfs")
            logger.info("✅ HTTPFS extension loaded")
            
            # Configure Iceberg catalog (connects through tunnel)
            # The tunnel forwards localhost:8181 → on-premise Iceberg REST
            # The tunnel forwards localhost:9000 → on-premise MinIO
            # Note: DuckDB 1.4+ uses KEY_ID and SECRET (not ACCESS_KEY_ID and SECRET_ACCESS_KEY)
            # Configure S3 secret for both localhost:9000 AND minio:9000 (metadata may reference either)
            iceberg_config = f"""
            CREATE SECRET iceberg_secret (
                TYPE S3,
                KEY_ID 'admin',
                SECRET 'password',
                ENDPOINT '{self.s3_endpoint}',
                USE_SSL false,
                URL_STYLE 'path'
            );
            """
            self.duckdb_conn.execute(iceberg_config)
            
            # Also configure for minio:9000 (internal docker-compose reference that may appear in metadata)
            # DuckDB will use this when metadata references minio:9000
            try:
                self.duckdb_conn.execute("""
                    SET s3_endpoint='localhost:9000';
                    SET s3_use_ssl=false;
                    SET s3_url_style='path';
                    SET s3_access_key_id='admin';
                    SET s3_secret_access_key='password';
                """)
            except Exception as e:
                logger.warning(f"Could not set S3 global config: {e}")
            
            logger.info("✅ DuckDB initialized with Iceberg support")
            
        except Exception as e:
            logger.error(f"❌ Failed to initialize DuckDB: {e}")
            raise
    
    async def handle_health(self, request):
        """Health check endpoint"""
        return web.json_response({'status': 'healthy', 'service': 'iceberg-agent'})
    
    async def handle_iceberg_rest_proxy(self, request):
        """
        Proxy Iceberg REST API calls to on-premise catalog
        This allows external DuckDB to connect via: https://snowflake-endpoint/v1/...
        All Iceberg REST calls are forwarded through the tunnel to localhost:8181
        """
        try:
            # Build target URL (through tunnel)
            path = request.match_info['tail']
            target_url = f"{self.iceberg_rest_url}/v1/{path}"
            
            # Forward query parameters
            if request.query_string:
                target_url += f"?{request.query_string}"
            
            logger.info(f"🔄 Proxying Iceberg REST: {request.method} {target_url}")
            
            # Read request body
            body = await request.read() if request.can_read_body else None
            
            # Forward request to on-premise Iceberg REST (through tunnel)
            async with aiohttp.ClientSession() as session:
                # Force identity encoding to avoid compressed/chunked bodies
                forward_headers = {k: v for k, v in request.headers.items()
                                   if k.lower() not in ['host', 'content-length', 'accept-encoding', 'connection']}
                forward_headers['Accept-Encoding'] = 'identity'
                forward_headers['Connection'] = 'close'
                async with session.request(
                    method=request.method,
                    url=target_url,
                    headers=forward_headers,
                    data=body
                ) as resp:
                    # Read body and optionally decompress to return identity encoding
                    response_body = await resp.read()
                    encoding = resp.headers.get('Content-Encoding', '').lower()
                    if encoding == 'br':
                        try:
                            import brotli  # type: ignore
                            response_body = brotli.decompress(response_body)
                        except Exception:
                            pass
                    elif encoding == 'gzip':
                        try:
                            import gzip
                            response_body = gzip.decompress(response_body)
                        except Exception:
                            pass
                    # Rewrite MinIO host references to our S3 proxy base to ensure reachability
                    try:
                        ct = resp.headers.get('Content-Type', '')
                        if isinstance(response_body, (bytes, bytearray)) and 'application/json' in ct.lower():
                            text = response_body.decode('utf-8', errors='ignore')
                            base_url = f"{request.scheme}://{request.host}"
                            text = text.replace('http://minio:9000', f"{base_url}/s3")
                            response_body = text.encode('utf-8')
                    except Exception:
                        pass
                    safe_headers = {k: v for k, v in resp.headers.items()
                                    if k.lower() not in ['transfer-encoding', 'content-length', 'connection', 'keep-alive', 'content-encoding']}
                    safe_headers['Content-Length'] = str(len(response_body))
                    return web.Response(
                        body=response_body,
                        status=resp.status,
                        headers=safe_headers
                    )
        
        except Exception as e:
            logger.error(f"❌ Iceberg REST proxy error: {e}")
            return web.json_response({
                'error': str(e),
                'message': 'Failed to proxy Iceberg REST request'
            }, status=500)

    async def handle_seed_demo(self, request):
        """
        Seed demo data using embedded DuckDB through Lakekeeper + MinIO
        Creates demo namespace and two small tables if not exist.
        """
        try:
            # Ensure ICEBERG auth secret for Lakekeeper (dummy token)
            self.duckdb_conn.execute(
                """
                CREATE OR REPLACE SECRET iceberg_rest (
                  TYPE ICEBERG,
                  TOKEN 'dummy'
                );
                """
            )

            # Attach Lakekeeper catalog as 'demo' (warehouse name drives config)
            self.duckdb_conn.execute(
                f"""
                ATTACH 'demo' AS demo (
                  TYPE ICEBERG,
                  ENDPOINT '{self.iceberg_rest_url}/catalog/',
                  SECRET iceberg_rest
                );
                """
            )

            # Create schema and seed tables (idempotent style)
            self.duckdb_conn.execute("CREATE SCHEMA IF NOT EXISTS demo.demo;")

            # Use CREATE TABLE IF NOT EXISTS then INSERT to avoid CTAS limitations
            self.duckdb_conn.execute(
                """
                CREATE TABLE IF NOT EXISTS demo.demo.sales (
                  sale_id INTEGER,
                  product VARCHAR,
                  amount INTEGER,
                  sale_date DATE,
                  region VARCHAR
                );
                """
            )
            self.duckdb_conn.execute(
                """
                INSERT INTO demo.demo.sales VALUES
                  (1,'Laptop',1200,DATE '2025-01-01','North'),
                  (2,'Mouse',25,DATE '2025-01-02','South'),
                  (3,'Keyboard',75,DATE '2025-01-03','East'),
                  (4,'Monitor',350,DATE '2025-01-04','West'),
                  (5,'Headset',120,DATE '2025-01-05','Central')
                ON CONFLICT DO NOTHING;
                """
            )

            self.duckdb_conn.execute(
                """
                CREATE TABLE IF NOT EXISTS demo.demo.customers (
                  customer_id INTEGER,
                  name VARCHAR,
                  country VARCHAR
                );
                """
            )
            self.duckdb_conn.execute(
                """
                INSERT INTO demo.demo.customers VALUES
                  (1,'Alice','USA'),
                  (2,'Bob','UK'),
                  (3,'Carol','Germany')
                ON CONFLICT DO NOTHING;
                """
            )

            sales = self.duckdb_conn.execute("SELECT COUNT(*) FROM demo.demo.sales").fetchone()[0]
            cust  = self.duckdb_conn.execute("SELECT COUNT(*) FROM demo.demo.customers").fetchone()[0]

            return web.json_response({
                'success': True,
                'sales_rows': sales,
                'customers_rows': cust
            })
        except Exception as e:
            logger.error(f"❌ Seed demo error: {e}")
            return web.json_response({'success': False, 'error': str(e)}, status=500)
    
    async def handle_iceberg_catalog_proxy(self, request):
        """
        Proxy Iceberg Catalog calls for paths rooted at '/catalog/*'
        Some clients (and docs) use explicit '/catalog/' paths for the REST catalog
        """
        try:
            path = request.match_info['tail']
            target_url = f"{self.iceberg_rest_url}/catalog/{path}"
            
            if request.query_string:
                target_url += f"?{request.query_string}"
            
            logger.info(f"🔄 Proxying Iceberg Catalog: {request.method} {target_url}")
            body = await request.read() if request.can_read_body else None
            
            async with aiohttp.ClientSession() as session:
                forward_headers = {k: v for k, v in request.headers.items()
                                   if k.lower() not in ['host', 'content-length', 'accept-encoding', 'connection']}
                forward_headers['Accept-Encoding'] = 'identity'
                forward_headers['Connection'] = 'close'
                async with session.request(
                    method=request.method,
                    url=target_url,
                    headers=forward_headers,
                    data=body
                ) as resp:
                    response_body = await resp.read()
                    encoding = resp.headers.get('Content-Encoding', '').lower()
                    if encoding == 'br':
                        try:
                            import brotli  # type: ignore
                            response_body = brotli.decompress(response_body)
                        except Exception:
                            pass
                    elif encoding == 'gzip':
                        try:
                            import gzip
                            response_body = gzip.decompress(response_body)
                        except Exception:
                            pass
                    # Rewrite MinIO host references to our S3 proxy base
                    try:
                        ct = resp.headers.get('Content-Type', '')
                        if isinstance(response_body, (bytes, bytearray)) and 'application/json' in ct.lower():
                            text = response_body.decode('utf-8', errors='ignore')
                            base_url = f"{request.scheme}://{request.host}"
                            text = text.replace('http://minio:9000', f"{base_url}/s3")
                            response_body = text.encode('utf-8')
                    except Exception:
                        pass
                    safe_headers = {k: v for k, v in resp.headers.items()
                                    if k.lower() not in ['transfer-encoding', 'content-length', 'connection', 'keep-alive', 'content-encoding']}
                    safe_headers['Content-Length'] = str(len(response_body))
                    return web.Response(
                        body=response_body,
                        status=resp.status,
                        headers=safe_headers
                    )
        except Exception as e:
            logger.error(f"❌ Iceberg catalog proxy error: {e}")
            return web.json_response({
                'error': str(e),
                'message': 'Failed to proxy Iceberg catalog request'
            }, status=500)
    
    async def handle_s3_proxy(self, request):
        """
        Anonymous S3/MinIO proxy for object access via tunnel.
        External DuckDB should configure its S3 ENDPOINT to: https://<snowflake-endpoint>/s3
        """
        try:
            path = request.match_info['tail']
            # Preserve exact path for bucket/object style (path-style access)
            target_url = f"{self.s3_endpoint}/{path}"
            if request.query_string:
                target_url += f"?{request.query_string}"
            
            logger.info(f"🪣 Proxying S3: {request.method} {target_url}")
            body = await request.read() if request.can_read_body else None
            
            # Forward request to MinIO via tunnel
            async with aiohttp.ClientSession() as session:
                forward_headers = {k: v for k, v in request.headers.items()
                                   if k.lower() not in ['host', 'content-length', 'accept-encoding', 'connection']}
                forward_headers['Accept-Encoding'] = 'identity'
                forward_headers['Connection'] = 'close'
                async with session.request(
                    method=request.method,
                    url=target_url,
                    headers=forward_headers,
                    data=body
                ) as resp:
                    response_body = await resp.read()
                    encoding = resp.headers.get('Content-Encoding', '').lower()
                    if encoding == 'br':
                        try:
                            import brotli  # type: ignore
                            response_body = brotli.decompress(response_body)
                        except Exception:
                            pass
                    elif encoding == 'gzip':
                        try:
                            import gzip
                            response_body = gzip.decompress(response_body)
                        except Exception:
                            pass
                    safe_headers = {k: v for k, v in resp.headers.items()
                                    if k.lower() not in ['transfer-encoding', 'content-length', 'connection', 'keep-alive', 'content-encoding']}
                    safe_headers['Content-Length'] = str(len(response_body))
                    return web.Response(
                        body=response_body,
                        status=resp.status,
                        headers=safe_headers
                    )
        except Exception as e:
            logger.error(f"❌ S3 proxy error: {e}")
            return web.json_response({
                'error': str(e),
                'message': 'Failed to proxy S3 request'
            }, status=500)
    
    async def handle_query_request(self, request):
        """
        Handle Iceberg query requests from Snowflake
        Request body: {
            "query": "SELECT * FROM my_iceberg_table LIMIT 10",
            "catalog": "warehouse",
            "params": []
        }
        """
        try:
            body = await request.json()
            
            # Snowflake UDF sends batch requests with {"data": [[row_num, arg1, arg2, ...], ...]}
            # The first column is ALWAYS the row number (0-based index)
            data = body.get('data', [])
            all_results = []
            
            for row in data:
                # Extract row_num (first column) and query args (remaining columns)
                row_num = row[0] if len(row) > 0 else 0
                query = row[1] if len(row) > 1 else ''
                catalog = row[2] if len(row) > 2 else 'demo'
                
                logger.info(f"📝 Iceberg query request (row {row_num}): {query[:100]}...")
                
                # Execute query through DuckDB with Iceberg
                result = await self.execute_iceberg_query(query, catalog)
                # result['data'] is [[col0, col1, ...], ...] from DuckDB
                # Wrap as VARIANT and return with row number
                result_json = result.get('data', [])
                all_results.append([row_num, result_json])  # [row_num, return_value]
            
            return web.json_response({'data': all_results})
            
        except Exception as e:
            logger.error(f"❌ Query execution error: {e}")
            # Return error in Snowflake UDF format: {"data": [[row_num, error_message]]}
            # If we can't determine row_num, use 0
            return web.json_response({
                'data': [[0, str(e)]]
            })
    
    async def execute_iceberg_query(self, query: str, catalog: str):
        """
        Execute Iceberg query using DuckDB
        DuckDB will connect to Iceberg REST (localhost:8181) through the tunnel
        """
        try:
            # Ensure ICEBERG REST secret (dummy token for local dev)
            self.duckdb_conn.execute(
                """
                CREATE OR REPLACE SECRET iceberg_rest (
                  TYPE ICEBERG,
                  TOKEN 'dummy'
                );
                """
            )

            # Re-attach cleanly with explicit ENDPOINT (handle existing attachment)
            try:
                self.duckdb_conn.execute(f"DETACH {catalog}")
            except Exception:
                pass  # Ignore if not attached
            
            attach_sql = f"""
            ATTACH '{catalog}' AS {catalog} (
                TYPE ICEBERG,
                ENDPOINT '{self.iceberg_rest_url}/catalog/',
                SECRET iceberg_rest
            );
            """
            self.duckdb_conn.execute(attach_sql)
            
            # Execute the query
            result = self.duckdb_conn.execute(query).fetchall()
            columns = [desc[0] for desc in self.duckdb_conn.description]
            
            # Convert to Snowflake UDF format: {"data": [[row0_col0, row0_col1, ...], [row1_col0, ...]]}
            data_rows = []
            for row in result:
                row_values = []
                for value in row:
                    # Handle datetime serialization
                    if hasattr(value, 'isoformat'):
                        row_values.append(value.isoformat())
                    else:
                        row_values.append(value)
                data_rows.append(row_values)
            
            logger.info(f"✅ Query executed successfully, returned {len(data_rows)} rows")
            
            # Snowflake UDF response format: {"data": [[row0_col0, row0_col1], [row1_col0, row1_col1], ...]}
            return {
                'data': data_rows
            }
            
        except Exception as e:
            logger.error(f"❌ Query execution failed: {e}")
            raise


async def main():
    """Main entry point"""
    config = {
        'host': os.getenv('API_HOST', '0.0.0.0'),
        'port': int(os.getenv('API_PORT', '8090')),
        'iceberg_port': int(os.getenv('ICEBERG_PORT', '8181')),
        's3_port': int(os.getenv('S3_PORT', '9000')),
    }
    
    agent = IcebergAgent(config)
    await agent.start()


if __name__ == "__main__":
    asyncio.run(main())

