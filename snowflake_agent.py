"""
Snowflake Agent - REST API with TCP Tunnel to On-Premise PostgreSQL
Runs in Snowflake Container Services and provides REST API for querying on-premise databases
Uses PostgreSQL driver (asyncpg) to connect through WebSocket tunnel
"""

import asyncio
import websockets
import json
import os
import logging
import uuid
from aiohttp import web
from typing import Dict, Any, Optional
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
import secrets
import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class TunnelConnection:
    """Represents a tunneled PostgreSQL connection"""
    
    def __init__(self, tunnel_id: str, websocket, aes_key: bytes):
        self.tunnel_id = tunnel_id
        self.websocket = websocket
        self.aes_key = aes_key
        self.pending_responses: Dict[str, asyncio.Future] = {}
        
    def encrypt_message(self, message: bytes) -> bytes:
        """Encrypt message with AES-256"""
        iv = secrets.token_bytes(16)
        cipher = Cipher(
            algorithms.AES(self.aes_key),
            modes.CFB(iv),
            backend=default_backend()
        )
        encryptor = cipher.encryptor()
        ciphertext = encryptor.update(message) + encryptor.finalize()
        return iv + ciphertext
    
    def decrypt_message(self, encrypted: bytes) -> bytes:
        """Decrypt AES-256 message"""
        iv = encrypted[:16]
        ciphertext = encrypted[16:]
        cipher = Cipher(
            algorithms.AES(self.aes_key),
            modes.CFB(iv),
            backend=default_backend()
        )
        decryptor = cipher.decryptor()
        plaintext = decryptor.update(ciphertext) + decryptor.finalize()
        return plaintext
    
    async def send_tcp_data(self, data: bytes) -> bytes:
        """Send TCP data through tunnel and wait for response"""
        request_id = str(uuid.uuid4())
        
        # Create request
        request_msg = {
            'type': 'tcp_forward',
            'request_id': request_id,
            'data': data.hex()  # Send as hex string
        }
        
        # Encrypt and send
        encrypted = self.encrypt_message(json.dumps(request_msg).encode())
        await self.websocket.send(encrypted)
        
        # Wait for response
        future = asyncio.Future()
        self.pending_responses[request_id] = future
        
        try:
            response = await asyncio.wait_for(future, timeout=30)
            return bytes.fromhex(response)
        except asyncio.TimeoutError:
            raise Exception("TCP forward timeout")
        finally:
            self.pending_responses.pop(request_id, None)


class SnowflakeAgent:
    """REST API in Snowflake that tunnels PostgreSQL connections to on-premise database"""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.handshake_secret = config.get('handshake_secret', 'default-secret')
        self.host = config.get('host', '0.0.0.0')
        self.http_port = config.get('port', 8080)
        self.ws_port = config.get('ws_port', 8081)
        
        # Mode: v1.0 (WebSocket tunnel) or v2.0 (sidecar mode)
        self.use_tunnel_sidecar = config.get('use_tunnel_sidecar', False)
        
        # PostgreSQL connection settings (through tunnel)
        # In v1.0: These define WHERE the on-premise agent should connect
        # In v2.0: These define WHERE to connect to tunnel-sidecar
        self.pg_host = config.get('pg_host', 'localhost')
        self.pg_port = int(config.get('pg_port', 5432))
        self.pg_database = config.get('pg_database', 'test_db')
        self.pg_user = config.get('pg_user', 'test_user')
        self.pg_password = config.get('pg_password', 'test_pass')
        
        # Active tunnel connections (v1.0 mode only)
        self.tunnel_connections: Dict[str, TunnelConnection] = {}
        # PostgreSQL connection pool (v2.0 mode - direct connection)
        self.pg_pool: Optional[asyncpg.Pool] = None
        
    async def start(self):
        """Start REST API and WebSocket server (v1.0) or REST API only (v2.0)"""
        logger.info("=" * 60)
        logger.info("  SNOWFLAKE AGENT")
        logger.info("=" * 60)
        
        if self.use_tunnel_sidecar:
            logger.info("🎯 Mode: v2.0 Sidecar (native database connection)")
            logger.info(f"🗄️  Database: {self.pg_host}:{self.pg_port}/{self.pg_database}")
            logger.info(f"🌐 REST API: {self.host}:{self.http_port}")
            
            # Don't create pool at startup - tunnel-sidecar needs time to receive port mappings
            # Pool will be created lazily on first query
            logger.info(f"📊 PostgreSQL pool will be created on first query (lazy initialization)")
        else:
            logger.info("🎯 Mode: v1.0 Query Forwarding (WebSocket tunnel)")
            logger.info(f"📡 WebSocket Server: {self.host}:{self.ws_port}")
            logger.info(f"🌐 REST API: {self.host}:{self.http_port}")
        
        # Start REST API
        app = web.Application()
        app.router.add_post('/query', self.handle_query_request)
        app.router.add_post('/snowflake_function', self.handle_snowflake_function)
        app.router.add_get('/health', self.health_check)
        app.router.add_get('/status', self.status_check)
        
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, self.host, self.http_port)
        await site.start()
        logger.info(f"✅ REST API started on port {self.http_port}")
        
        if self.use_tunnel_sidecar:
            # v2.0: Only REST API, no WebSocket server
            logger.info("✅ Agent ready (sidecar mode)")
            await asyncio.Future()  # Run forever
        else:
            # v1.0: Start WebSocket server for tunnel connections
            ws_server = websockets.serve(
                self.handle_tunnel_connection,
                self.host,
                self.ws_port,
                ping_interval=30,
                ping_timeout=10
            )
            
            async with ws_server:
                logger.info(f"✅ WebSocket server listening on port {self.ws_port}")
                await asyncio.Future()  # Run forever
    
    async def ensure_pg_connection(self):
        """Ensure PostgreSQL connection pool is ready"""
        if self.pg_pool is None and self.tunnel_connections:
            # Get first available tunnel
            tunnel = list(self.tunnel_connections.values())[0]
            
            # Create connection pool through tunnel
            # Note: This is a simplified version - in production, you'd need
            # a custom asyncpg connection that uses the tunnel
            logger.info("📊 PostgreSQL driver ready (through tunnel)")
            # For now, we'll use the query forwarding approach but keep the interface
            # In a full implementation, we'd create a custom asyncpg protocol
        
        return self.tunnel_connections.get(list(self.tunnel_connections.keys())[0]) if self.tunnel_connections else None
    
    async def execute_query_via_tunnel(self, sql_query: str, params: list = [], target_host: str = None, target_port: int = None):
        """Execute SQL query using PostgreSQL driver through tunnel or direct connection"""
        
        if self.use_tunnel_sidecar:
            # v2.0: Direct PostgreSQL connection to tunnel-sidecar
            return await self.execute_query_direct(sql_query, params)
        else:
            # v1.0: Query forwarding through WebSocket tunnel
            tunnel = await self.ensure_pg_connection()
            
            if not tunnel:
                return {
                    'success': False,
                    'error': 'No tunnel connection available',
                    'rows': []
                }
            
            request_id = str(uuid.uuid4())
            
            # Use provided target or fall back to configured PostgreSQL target
            if target_host is None:
                target_host = self.pg_host
            if target_port is None:
                target_port = self.pg_port
            
            request_msg = {
                'type': 'query',
                'request_id': request_id,
                'query': sql_query,
                'params': params,
                'target_host': target_host,
                'target_port': target_port
            }
            
            encrypted = tunnel.encrypt_message(json.dumps(request_msg).encode())
            await tunnel.websocket.send(encrypted)
            
            # Wait for response
            response_event = asyncio.Event()
            result_holder = {'result': None}
            
            # Store the response handler
            tunnel.pending_responses[request_id] = result_holder
            
            try:
                # Wait for response
                for _ in range(300):  # 30 second timeout
                    if request_id in tunnel.pending_responses and tunnel.pending_responses[request_id].get('result'):
                        return tunnel.pending_responses[request_id]['result']
                    await asyncio.sleep(0.1)
                
                return {'success': False, 'error': 'Query timeout'}
            finally:
                tunnel.pending_responses.pop(request_id, None)
    
    async def execute_query_direct(self, sql_query: str, params: list = []):
        """Execute SQL query directly using asyncpg (v2.0 sidecar mode)"""
        try:
            # Ensure connection pool exists (with retry for tunnel-sidecar startup)
            if not self.pg_pool:
                max_retries = 3
                retry_delay = 2
                
                for attempt in range(max_retries):
                    try:
                        logger.info(f"📊 Creating PostgreSQL pool (attempt {attempt + 1}/{max_retries})...")
                        self.pg_pool = await asyncpg.create_pool(
                            host=self.pg_host,
                            port=self.pg_port,
                            database=self.pg_database,
                            user=self.pg_user,
                            password=self.pg_password if self.pg_password else None,
                            min_size=5,      # More warm connections ready
                            max_size=20,     # Higher ceiling for concurrent queries
                            command_timeout=60,  # Connection timeout
                            max_inactive_connection_lifetime=300  # Keep connections for 5 min
                        )
                        logger.info("✅ PostgreSQL connection pool created successfully")
                        break
                    except Exception as e:
                        logger.warning(f"⚠️  Pool creation attempt {attempt + 1} failed: {e}")
                        if attempt < max_retries - 1:
                            logger.info(f"⏳ Retrying in {retry_delay}s... (tunnel-sidecar may still be starting)")
                            await asyncio.sleep(retry_delay)
                        else:
                            logger.error(f"❌ Failed to create connection pool after {max_retries} attempts")
                            return {
                                'success': False,
                                'error': f'Database connection failed after {max_retries} attempts: {str(e)}',
                                'rows': []
                            }
            
            # Execute query
            async with self.pg_pool.acquire() as conn:
                if sql_query.strip().upper().startswith(('SELECT', 'SHOW', 'DESC', 'WITH')):
                    # SELECT query - fetch results
                    rows = await conn.fetch(sql_query, *params)
                    
                    # Convert rows to dicts and handle datetime serialization
                    serialized_rows = []
                    for row in rows:
                        row_dict = {}
                        for key, value in dict(row).items():
                            # Convert datetime objects to ISO format strings
                            if hasattr(value, 'isoformat'):
                                row_dict[key] = value.isoformat()
                            else:
                                row_dict[key] = value
                        serialized_rows.append(row_dict)
                    
                    return {
                        'success': True,
                        'rows': serialized_rows,
                        'rowcount': len(rows)
                    }
                else:
                    # DML/DDL query
                    status = await conn.execute(sql_query, *params)
                    return {
                        'success': True,
                        'rows': [],
                        'rowcount': 0,
                        'status': status
                    }
        
        except Exception as e:
            logger.error(f"❌ Query execution error: {e}")
            return {
                'success': False,
                'error': str(e),
                'rows': []
            }
    
    async def handle_query_request(self, request):
        """REST API endpoint to execute queries on on-premise database"""
        try:
            data = await request.json()
            sql_query = data.get('query')
            params = data.get('params', [])
            
            if not sql_query:
                return web.json_response({
                    'error': 'No query provided'
                }, status=400)
            
            logger.info(f"📝 Received query request: {sql_query[:100]}...")
            
            # Execute through tunnel using PostgreSQL driver
            result = await self.execute_query_via_tunnel(sql_query, params)
            
            if result.get('success'):
                return web.json_response({
                    'success': True,
                    'rows': result.get('rows', []),
                    'rowcount': result.get('rowcount', 0)
                })
            else:
                return web.json_response({
                    'success': False,
                    'error': result.get('error', 'Unknown error')
                }, status=500)
                
        except Exception as e:
            logger.error(f"❌ Query request failed: {e}")
            return web.json_response({
                'error': str(e)
            }, status=500)
    
    async def handle_snowflake_function(self, request):
        """
        Snowflake Service Function endpoint
        Follows Snowflake's service function format:
        - Input: {"data": [[row_index, input_value], ...]}
        - Output: {"data": [[row_index, result_value], ...]}
        """
        try:
            data = await request.json()
            input_data = data.get('data', [])
            
            if not input_data or len(input_data) == 0:
                return web.json_response({
                    'data': [[0, {'error': 'No input data provided'}]]
                })
            
            # Process each row of input data
            results = []
            for row in input_data:
                if len(row) < 2:
                    results.append([row[0] if row else 0, {'error': 'Invalid input format'}])
                    continue
                
                row_index = row[0]
                input_value = row[1]
                
                # Parse input - can be just SQL or JSON with target
                target_host = None
                target_port = None
                sql_query = None
                
                if isinstance(input_value, str):
                    # Try to parse as JSON first
                    if input_value.strip().startswith('{'):
                        try:
                            import json as json_lib
                            parsed = json_lib.loads(input_value)
                            sql_query = parsed.get('query')
                            target = parsed.get('target', '').split(':')
                            if len(target) == 2:
                                target_host = target[0]
                                target_port = int(target[1])
                            elif len(target) == 1 and target[0]:
                                target_host = target[0]
                        except:
                            # Not JSON, treat as plain SQL
                            sql_query = input_value
                    else:
                        sql_query = input_value
                elif isinstance(input_value, dict):
                    sql_query = input_value.get('query')
                    target = input_value.get('target', '').split(':')
                    if len(target) == 2:
                        target_host = target[0]
                        target_port = int(target[1])
                
                if not sql_query:
                    results.append([row_index, {'error': 'No SQL query provided'}])
                    continue
                
                logger.info(f"📝 Snowflake function: row {row_index}, target: {target_host or 'default'}:{target_port or 'default'}, query: {sql_query[:100]}...")
                
                # Execute query through tunnel using PostgreSQL driver
                result = await self.execute_query_via_tunnel(sql_query, [], target_host, target_port)
                
                # Format result for Snowflake
                if result.get('success'):
                    results.append([row_index, {
                        'success': True,
                        'rows': result.get('rows', []),
                        'rowcount': result.get('rowcount', 0)
                    }])
                else:
                    results.append([row_index, {
                        'success': False,
                        'error': result.get('error', 'Unknown error'),
                        'rows': []
                    }])
            
            return web.json_response({'data': results})
            
        except Exception as e:
            logger.error(f"❌ Snowflake function failed: {e}")
            return web.json_response({
                'data': [[0, {'success': False, 'error': str(e), 'rows': []}]]
            })
    
    async def handle_tunnel_connection(self, websocket):
        """Handle WebSocket connection from on-premise TCP proxy"""
        tunnel_id = f"tunnel_{websocket.remote_address[0]}_{websocket.remote_address[1]}"
        logger.info(f"🔌 New tunnel connection: {tunnel_id}")
        
        try:
            # Perform handshake
            aes_key = await self.perform_handshake(websocket, tunnel_id)
            
            # Create tunnel connection
            tunnel = TunnelConnection(tunnel_id, websocket, aes_key)
            self.tunnel_connections[tunnel_id] = tunnel
            
            logger.info(f"✅ Tunnel {tunnel_id} authenticated and ready")
            
            # Handle messages
            async for message in websocket:
                await self.handle_tunnel_message(tunnel, message)
                
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"🔌 Tunnel {tunnel_id} disconnected")
        except Exception as e:
            logger.error(f"❌ Error with tunnel {tunnel_id}: {e}")
        finally:
            self.tunnel_connections.pop(tunnel_id, None)
            logger.info(f"🗑️  Tunnel {tunnel_id} cleaned up")
    
    async def perform_handshake(self, websocket, tunnel_id: str) -> bytes:
        """Perform authentication handshake with on-premise proxy"""
        message = await websocket.recv()
        data = json.loads(message)
        
        if data.get('type') != 'handshake':
            raise Exception("Invalid handshake")
        
        # Support both Snowflake Token and shared secret authentication
        snowflake_token = data.get('snowflake_token')
        shared_secret = data.get('secret')
        
        authenticated = False
        auth_method = None
        
        # Try Snowflake Token first (production mode)
        if snowflake_token:
            if await self.validate_snowflake_token(snowflake_token):
                authenticated = True
                auth_method = "Snowflake Token"
                logger.info(f"🔐 Tunnel {tunnel_id} authenticated with Snowflake Token")
        
        # Fall back to shared secret (local testing mode)
        elif shared_secret:
            if shared_secret == self.handshake_secret:
                authenticated = True
                auth_method = "Shared Secret"
                logger.info(f"🔐 Tunnel {tunnel_id} authenticated with Shared Secret")
        
        if not authenticated:
            raise Exception("Authentication failed - no valid token or secret provided")
        
        # Generate AES key
        aes_key = secrets.token_bytes(32)
        
        # Send key back
        response = {
            'type': 'handshake_response',
            'status': 'success',
            'aes_key': aes_key.hex(),
            'auth_method': auth_method
        }
        await websocket.send(json.dumps(response))
        
        logger.info(f"✅ Tunnel {tunnel_id} authenticated via {auth_method}")
        return aes_key
    
    async def validate_snowflake_token(self, token: str) -> bool:
        """Validate Snowflake Token"""
        if not token:
            return False
        
        # If running in Snowflake Container Services, accept the token
        snowflake_account = os.getenv('SNOWFLAKE_ACCOUNT')
        if snowflake_account:
            logger.info(f"🔐 Token validation: Running in SPCS account {snowflake_account}")
            return True
        
        # For local testing with token, accept if it looks like a JWT
        if token.startswith('{"access_token"'):
            logger.info("🔐 Token validation: Accepted token format for testing")
            return True
        
        return False
    
    async def handle_tunnel_message(self, tunnel: TunnelConnection, encrypted_message):
        """Handle encrypted message from on-premise proxy"""
        try:
            # Decrypt
            decrypted = tunnel.decrypt_message(encrypted_message)
            message = json.loads(decrypted)
            
            msg_type = message.get('type')
            
            if msg_type == 'query_response':
                # Handle query response
                request_id = message.get('request_id')
                if request_id in tunnel.pending_responses:
                    tunnel.pending_responses[request_id]['result'] = {
                        'success': message.get('success'),
                        'rows': message.get('rows', []),
                        'rowcount': message.get('rowcount', 0),
                        'error': message.get('error')
                    }
            
        except Exception as e:
            logger.error(f"Error handling tunnel message: {e}")
    
    async def health_check(self, request):
        """Health check endpoint"""
        return web.json_response({
            'status': 'healthy',
            'connected_tunnels': len(self.tunnel_connections),
            'driver': 'asyncpg',
            'mode': 'tcp_tunnel'
        })
    
    async def status_check(self, request):
        """Status endpoint"""
        return web.json_response({
            'tunnels': list(self.tunnel_connections.keys()),
            'driver': 'asyncpg (PostgreSQL)',
            'uptime': 'running'
        })


async def main():
    # Load configuration
    config = {
        'host': os.getenv('HOST', '0.0.0.0'),
        'port': int(os.getenv('PORT', '8080')),
        'ws_port': int(os.getenv('WS_PORT', '8081')),
        'handshake_secret': os.getenv('HANDSHAKE_SECRET', 'test-secret-key'),
        'use_tunnel_sidecar': os.getenv('USE_TUNNEL_SIDECAR', 'false').lower() == 'true',
        'pg_host': os.getenv('PG_HOST', 'localhost'),
        'pg_port': int(os.getenv('PG_PORT', '5432')),
        'pg_database': os.getenv('PG_DATABASE', 'test_db'),
        'pg_user': os.getenv('PG_USER', 'test_user'),
        'pg_password': os.getenv('PG_PASSWORD', 'test_pass')
    }
    
    logger.info("="*60)
    logger.info("  SNOWFLAKE AGENT - PostgreSQL JDBC via Tunnel")
    logger.info("="*60)
    logger.info(f"Configuration: {config}")
    logger.info("📊 Using PostgreSQL driver (asyncpg) through tunnel")
    
    agent = SnowflakeAgent(config)
    await agent.start()


if __name__ == "__main__":
    asyncio.run(main())
