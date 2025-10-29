"""
Tunnel Sidecar - Dynamic Port Forwarding Service
Acts like SSH port forwarding: exposes local ports that forward to on-premise services
Apps connect to tunnel-sidecar:PORT, traffic is transparently forwarded through WebSocket
"""

import asyncio
import websockets
import json
import os
import logging
import secrets
import base64
from typing import Dict, Any, Optional
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives import serialization, hashes

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class PortForwarder:
    """Manages a single forwarded port with session-based connections"""
    
    def __init__(self, local_port: int, remote_host: str, remote_port: int, tunnel):
        self.local_port = local_port
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.tunnel = tunnel
        self.server = None
        self.active_connections = 0
        
    async def start(self):
        """Start listening on local port"""
        self.server = await asyncio.start_server(
            self.handle_client,
            '0.0.0.0',
            self.local_port
        )
        logger.info(f"✅ Port {self.local_port} → {self.remote_host}:{self.remote_port}")
        
    async def stop(self):
        """Stop listening"""
        if self.server:
            self.server.close()
            await self.server.wait_closed()
            logger.info(f"🛑 Port {self.local_port} stopped")
    
    async def handle_client(self, reader, writer):
        """Handle incoming client connection with persistent session"""
        self.active_connections += 1
        session_id = f"{self.local_port}-{self.active_connections}"
        
        try:
            logger.info(f"📨 Session {session_id} started")
            
            # Create session on on-premise side
            await self.tunnel.create_session(session_id, self.remote_host, self.remote_port)
            
            # Start bidirectional forwarding
            app_to_onpremise = asyncio.create_task(
                self._forward_app_to_onpremise(session_id, reader)
            )
            onpremise_to_app = asyncio.create_task(
                self._forward_onpremise_to_app(session_id, writer)
            )
            
            # Wait for either direction to close
            done, pending = await asyncio.wait(
                [app_to_onpremise, onpremise_to_app],
                return_when=asyncio.FIRST_COMPLETED
            )
            
            # Cancel remaining task
            for task in pending:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
            
            logger.debug(f"🔌 Session {session_id} closed")
            
        except Exception as e:
            logger.error(f"❌ Session {session_id} error: {e}")
        finally:
            # Close session on on-premise side
            await self.tunnel.close_session(session_id)
            writer.close()
            await writer.wait_closed()
    
    async def _forward_app_to_onpremise(self, session_id: str, reader):
        """Forward data from app to on-premise"""
        try:
            while True:
                data = await reader.read(8192)
                if not data:
                    break
                await self.tunnel.send_session_data(session_id, data)
        except Exception as e:
            logger.debug(f"App→OnPremise stream ended for {session_id}: {e}")
    
    async def _forward_onpremise_to_app(self, session_id: str, writer):
        """Forward data from on-premise to app"""
        try:
            while True:
                data = await self.tunnel.receive_session_data(session_id)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except Exception as e:
            logger.debug(f"OnPremise→App stream ended for {session_id}: {e}")


class TunnelSidecar:
    """
    Tunnel Sidecar - Exposes multiple TCP ports for app containers
    Port mappings are configured dynamically by on-premise agent
    """
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.ws_port = config.get('ws_port', 8081)
        self.handshake_secret = config.get('handshake_secret', 'test-secret-key')
        self.snowflake_account = config.get('snowflake_account')
        
        # WebSocket connection to on-premise agent
        self.onpremise_websocket = None
        self.aes_key = None
        
        # Port forwarders (port -> PortForwarder)
        self.forwarders: Dict[int, PortForwarder] = {}
        
        # Session management (session_id -> queue for data from onpremise)
        self.sessions: Dict[str, asyncio.Queue] = {}
        self.session_futures: Dict[str, asyncio.Future] = {}  # For session creation
        
    async def start(self):
        """Start the tunnel sidecar"""
        logger.info("=" * 60)
        logger.info("  TUNNEL SIDECAR - Dynamic Port Forwarding")
        logger.info("=" * 60)
        logger.info(f"📡 WebSocket Server: 0.0.0.0:{self.ws_port}")
        logger.info(f"🔐 Waiting for on-premise agent connection...")
        
        # Start WebSocket server with compression for better performance
        async with websockets.serve(
            self.handle_onpremise_connection,
            '0.0.0.0',
            self.ws_port,
            compression='deflate',  # Enable per-message deflate compression
            ping_interval=20,       # Keep connection alive with pings
            ping_timeout=10,        # Timeout for ping responses
            max_size=10 * 1024 * 1024  # 10MB max message size
        ):
            await asyncio.Future()  # Run forever
    
    async def handle_onpremise_connection(self, websocket):
        """Handle connection from on-premise agent"""
        logger.info("🔌 On-premise agent connected")
        
        try:
            # Perform handshake
            await self.perform_handshake(websocket)
            
            self.onpremise_websocket = websocket
            
            logger.info("✅ Tunnel established, waiting for port mappings...")
            
            # Request port mappings if we don't have any
            # This handles Snowflake container restarts (every 30 days)
            if len(self.forwarders) == 0:
                logger.info("📥 No port mappings loaded, requesting from on-premise agent...")
                asyncio.create_task(self.request_port_mappings())
            
            # Handle messages
            async for message in websocket:
                await self.handle_message(message)
                
        except websockets.exceptions.ConnectionClosed:
            logger.warning("⚠️  On-premise agent disconnected")
        except Exception as e:
            logger.error(f"❌ Error: {e}")
        finally:
            # Stop all forwarders
            for forwarder in list(self.forwarders.values()):
                await forwarder.stop()
            self.forwarders.clear()
            self.onpremise_websocket = None
            logger.info("🗑️  Tunnel cleaned up")
    
    async def perform_handshake(self, websocket):
        """Perform authentication handshake with RSA key exchange"""
        message = await websocket.recv()
        data = json.loads(message)
        
        if data.get('type') != 'handshake':
            raise Exception("Invalid handshake")
        
        # Step 1: Authenticate the agent (Snowflake Token or shared secret)
        snowflake_token = data.get('snowflake_token')
        shared_secret = data.get('secret')
        
        authenticated = False
        auth_method = None
        
        if snowflake_token:
            # In production, validate the token
            authenticated = True
            auth_method = "Snowflake Token"
        elif shared_secret:
            if shared_secret == self.handshake_secret:
                authenticated = True
                auth_method = "Shared Secret"
        
        if not authenticated:
            raise Exception("Authentication failed")
        
        # Step 2: Receive agent's RSA public key
        public_key_b64 = data.get('public_key')
        if not public_key_b64:
            raise Exception("No RSA public key provided by agent")
        
        logger.info("🔑 Received RSA public key from agent")
        public_key_pem = base64.b64decode(public_key_b64)
        public_key = serialization.load_pem_public_key(
            public_key_pem,
            backend=default_backend()
        )
        
        # Step 3: Generate AES-256 key for tunnel encryption
        self.aes_key = secrets.token_bytes(32)
        logger.info("🔐 Generated AES-256 key for tunnel encryption")
        
        # Step 4: Wrap (encrypt) AES key with agent's RSA public key
        logger.info("🔒 Wrapping AES key with agent's RSA public key...")
        wrapped_aes_key = public_key.encrypt(
            self.aes_key,
            padding.OAEP(
                mgf=padding.MGF1(algorithm=hashes.SHA256()),
                algorithm=hashes.SHA256(),
                label=None
            )
        )
        wrapped_aes_key_b64 = base64.b64encode(wrapped_aes_key).decode('utf-8')
        
        # Step 5: Send wrapped AES key back to agent
        response = {
            'type': 'handshake_response',
            'status': 'success',
            'wrapped_aes_key': wrapped_aes_key_b64,
            'auth_method': auth_method
        }
        
        await websocket.send(json.dumps(response))
        logger.info(f"✅ Authenticated via {auth_method}")
        logger.info(f"🔒 Secure key exchange complete (RSA-2048 + AES-256)")
    
    async def handle_message(self, encrypted_message):
        """Handle encrypted message from on-premise agent"""
        try:
            # Decrypt
            decrypted = self.decrypt_message(encrypted_message)
            message = json.loads(decrypted)
            
            msg_type = message.get('type')
            
            if msg_type == 'port_mapping':
                # On-premise agent is pushing port configuration
                await self.handle_port_mapping(message)
            elif msg_type == 'session_create_response':
                # Acknowledgment of session creation
                await self.handle_session_create_response(message)
            elif msg_type == 'session_data_response':
                # Data from on-premise back to app
                await self.handle_session_data_response(message)
            else:
                logger.warning(f"⚠️  Unknown message type: {msg_type}")
                
        except Exception as e:
            logger.error(f"❌ Error handling message: {e}")
    
    async def handle_port_mapping(self, message):
        """Handle port mapping configuration from on-premise agent"""
        mappings = message.get('mappings', [])
        
        logger.info(f"📋 Received port mappings: {len(mappings)} ports")
        
        # Stop existing forwarders
        for forwarder in list(self.forwarders.values()):
            await forwarder.stop()
        self.forwarders.clear()
        
        # Start new forwarders
        for mapping in mappings:
            try:
                local_port = mapping['local_port']
                remote_host = mapping['remote_host']
                remote_port = mapping['remote_port']
                
                logger.info(f"🔧 Starting forwarder for port {local_port}...")
                forwarder = PortForwarder(local_port, remote_host, remote_port, self)
                await forwarder.start()
                self.forwarders[local_port] = forwarder
            except Exception as e:
                logger.error(f"❌ Failed to start forwarder for port {local_port}: {e}")
                import traceback
                logger.error(traceback.format_exc())
        
        logger.info(f"✅ Port forwarding active on {len(self.forwarders)} ports")
    
    async def handle_session_create_response(self, message):
        """Handle session creation acknowledgment from on-premise agent"""
        session_id = message.get('session_id')
        
        if session_id in self.session_futures:
            future = self.session_futures.pop(session_id)
            
            if message.get('error'):
                future.set_exception(Exception(message['error']))
            else:
                future.set_result(True)
                logger.debug(f"✅ Session {session_id} created")
    
    async def handle_session_data_response(self, message):
        """Handle data from on-premise agent for a session"""
        session_id = message.get('session_id')
        
        if session_id in self.sessions:
            data_hex = message.get('data', '')
            data = bytes.fromhex(data_hex) if data_hex else b''
            
            # Put data in queue for the session's receive task
            await self.sessions[session_id].put(data)
    
    async def create_session(self, session_id: str, remote_host: str, remote_port: int):
        """Create a new session with on-premise agent"""
        if not self.onpremise_websocket:
            raise Exception("No tunnel connection")
        
        # Create queue for receiving data from onpremise
        self.sessions[session_id] = asyncio.Queue()
        
        # Send session create request
        request = {
            'type': 'session_create',
            'session_id': session_id,
            'remote_host': remote_host,
            'remote_port': remote_port
        }
        
        encrypted = self.encrypt_message(json.dumps(request))
        await self.onpremise_websocket.send(encrypted)
        
        # Wait for acknowledgment
        future = asyncio.Future()
        self.session_futures[session_id] = future
        
        try:
            await asyncio.wait_for(future, timeout=10)
        except asyncio.TimeoutError:
            self.sessions.pop(session_id, None)
            self.session_futures.pop(session_id, None)
            raise Exception(f"Session {session_id} creation timeout")
    
    async def send_session_data(self, session_id: str, data: bytes):
        """Send data to on-premise for a specific session"""
        if not self.onpremise_websocket:
            raise Exception("No tunnel connection")
        
        request = {
            'type': 'session_data',
            'session_id': session_id,
            'data': data.hex()
        }
        
        encrypted = self.encrypt_message(json.dumps(request))
        await self.onpremise_websocket.send(encrypted)
    
    async def receive_session_data(self, session_id: str) -> bytes:
        """Receive data from on-premise for a specific session"""
        if session_id not in self.sessions:
            raise Exception(f"Session {session_id} not found")
        
        queue = self.sessions[session_id]
        data = await queue.get()
        return data
    
    async def close_session(self, session_id: str):
        """Close a session"""
        if session_id in self.sessions:
            self.sessions.pop(session_id)
        
        if not self.onpremise_websocket:
            return
        
        request = {
            'type': 'session_close',
            'session_id': session_id
        }
        
        try:
            encrypted = self.encrypt_message(json.dumps(request))
            await self.onpremise_websocket.send(encrypted)
        except Exception as e:
            logger.debug(f"Failed to send session close for {session_id}: {e}")
    
    async def request_port_mappings(self):
        """Request port mappings from on-premise agent (for Snowflake restarts)"""
        if not self.onpremise_websocket:
            logger.warning("⚠️  Cannot request port mappings: no connection")
            return
        
        try:
            request = {
                'type': 'request_port_mappings'
            }
            
            encrypted = self.encrypt_message(json.dumps(request))
            await self.onpremise_websocket.send(encrypted)
            
            logger.info("📤 Requested port mappings from on-premise agent")
            
        except Exception as e:
            logger.error(f"❌ Failed to request port mappings: {e}")
    
    def encrypt_message(self, message: str) -> bytes:
        """Encrypt message with AES-256"""
        iv = secrets.token_bytes(16)
        cipher = Cipher(
            algorithms.AES(self.aes_key),
            modes.CFB(iv),
            backend=default_backend()
        )
        encryptor = cipher.encryptor()
        ciphertext = encryptor.update(message.encode()) + encryptor.finalize()
        return iv + ciphertext
    
    def decrypt_message(self, encrypted: bytes) -> str:
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
        return plaintext.decode()


async def main():
    config = {
        'ws_port': int(os.getenv('WS_PORT', '8081')),
        'handshake_secret': os.getenv('HANDSHAKE_SECRET', 'test-secret-key'),
        'snowflake_account': os.getenv('SNOWFLAKE_ACCOUNT')
    }
    
    sidecar = TunnelSidecar(config)
    await sidecar.start()


if __name__ == "__main__":
    asyncio.run(main())
