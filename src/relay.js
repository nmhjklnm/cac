#!/usr/bin/env node
// cac-relay — Local TCP relay that forwards to upstream proxy (bypasses TUN)
// Usage: node relay.js <listen_port> <upstream_proxy_url> [pid_file]
//
// Listens on 127.0.0.1:<port> as an HTTP proxy, forwards upstream via:
//   - HTTP CONNECT (for http:// upstream)
//   - SOCKS5 (for socks5:// upstream)
'use strict';

const net = require('net');
const url = require('url');

// ── Parse CLI args ──────────────────────────────────────────────

const listenPort = parseInt(process.argv[2], 10);
const upstreamUrl = process.argv[3];
const pidFile = process.argv[4];

if (!listenPort || !upstreamUrl) {
  process.stderr.write('Usage: node relay.js <port> <upstream_proxy_url> [pid_file]\n');
  process.exit(1);
}

const upstream = new URL(upstreamUrl);
const upstreamHost = upstream.hostname;
const upstreamPort = parseInt(upstream.port, 10);
const upstreamUser = decodeURIComponent(upstream.username || '');
const upstreamPass = decodeURIComponent(upstream.password || '');
const isSocks5 = upstream.protocol === 'socks5:';

function log(msg) { process.stderr.write('[cac-relay] ' + msg + '\n'); }

// ── SOCKS5 handshake ────────────────────────────────────────────

function socks5Connect(targetHost, targetPort, cb) {
  const sock = net.connect(upstreamPort, upstreamHost, () => {
    const hasAuth = upstreamUser && upstreamPass;

    // Greeting: version=5, nmethods=1, method=(0x02 if auth, 0x00 if none)
    sock.write(Buffer.from([0x05, 0x01, hasAuth ? 0x02 : 0x00]));

    let state = 'greeting';
    let buf = Buffer.alloc(0);

    sock.on('data', onData);

    function onData(chunk) {
      buf = Buffer.concat([buf, chunk]);
      if (state === 'greeting') {
        if (buf.length < 2) return;
        const method = buf[1];
        buf = buf.slice(2);

        if (method === 0x02 && hasAuth) {
          // Sub-negotiation: version=1, ulen, username, plen, password
          const uBuf = Buffer.from(upstreamUser);
          const pBuf = Buffer.from(upstreamPass);
          const authReq = Buffer.alloc(3 + uBuf.length + pBuf.length);
          authReq[0] = 0x01;
          authReq[1] = uBuf.length;
          uBuf.copy(authReq, 2);
          authReq[2 + uBuf.length] = pBuf.length;
          pBuf.copy(authReq, 3 + uBuf.length);
          sock.write(authReq);
          state = 'auth';
        } else if (method === 0x00) {
          sendConnectRequest();
        } else {
          sock.destroy();
          cb(new Error('SOCKS5 unsupported auth method: ' + method));
        }
      } else if (state === 'auth') {
        if (buf.length < 2) return;
        if (buf[1] !== 0x00) {
          sock.destroy();
          cb(new Error('SOCKS5 auth failed'));
          return;
        }
        buf = buf.slice(2);
        sendConnectRequest();
      } else if (state === 'connect') {
        if (buf.length < 4) return;
        if (buf[1] !== 0x00) {
          sock.destroy();
          cb(new Error('SOCKS5 connect failed: reply=' + buf[1]));
          return;
        }
        // Parse variable-length address to consume the full reply
        const atyp = buf[3];
        let addrLen;
        if (atyp === 0x01) addrLen = 4;        // IPv4
        else if (atyp === 0x04) addrLen = 16;   // IPv6
        else if (atyp === 0x03) addrLen = 1 + (buf[4] || 0); // Domain
        else addrLen = 0;
        const totalLen = 4 + addrLen + 2; // header + addr + port
        if (buf.length < totalLen) return;

        const remaining = buf.slice(totalLen);
        sock.removeListener('data', onData);
        cb(null, sock, remaining);
      }
    }

    function sendConnectRequest() {
      // CONNECT request: ver=5, cmd=1(connect), rsv=0, atyp=3(domain)
      const hostBuf = Buffer.from(targetHost);
      const req = Buffer.alloc(5 + hostBuf.length + 2);
      req[0] = 0x05; // version
      req[1] = 0x01; // connect
      req[2] = 0x00; // reserved
      req[3] = 0x03; // domain name
      req[4] = hostBuf.length;
      hostBuf.copy(req, 5);
      req.writeUInt16BE(targetPort, 5 + hostBuf.length);
      sock.write(req);
      state = 'connect';
    }
  });

  sock.on('error', (err) => cb(err));
}

// ── HTTP CONNECT upstream ───────────────────────────────────────

function httpConnect(targetHost, targetPort, cb) {
  const sock = net.connect(upstreamPort, upstreamHost, () => {
    let connectReq = 'CONNECT ' + targetHost + ':' + targetPort + ' HTTP/1.1\r\n' +
                     'Host: ' + targetHost + ':' + targetPort + '\r\n';
    if (upstreamUser) {
      const cred = Buffer.from(upstreamUser + ':' + upstreamPass).toString('base64');
      connectReq += 'Proxy-Authorization: Basic ' + cred + '\r\n';
    }
    connectReq += '\r\n';
    sock.write(connectReq);

    let buf = '';
    sock.on('data', function onData(chunk) {
      buf += chunk.toString();
      const idx = buf.indexOf('\r\n\r\n');
      if (idx === -1) return;

      const statusLine = buf.substring(0, buf.indexOf('\r\n'));
      const statusCode = parseInt(statusLine.split(' ')[1], 10);
      const remaining = Buffer.from(buf.substring(idx + 4));

      sock.removeListener('data', onData);

      if (statusCode === 200) {
        cb(null, sock, remaining);
      } else {
        sock.destroy();
        cb(new Error('Upstream CONNECT failed: ' + statusLine));
      }
    });
  });

  sock.on('error', (err) => cb(err));
}

// ── Connect to upstream (protocol dispatch) ─────────────────────

function connectUpstream(targetHost, targetPort, cb) {
  if (isSocks5) {
    socks5Connect(targetHost, targetPort, cb);
  } else {
    httpConnect(targetHost, targetPort, cb);
  }
}

// ── Local HTTP proxy server ─────────────────────────────────────

const MAX_CONNECTIONS = 128;
let activeConnections = 0;

const server = net.createServer({ pauseOnConnect: true }, (clientSock) => {
  if (activeConnections >= MAX_CONNECTIONS) {
    clientSock.destroy();
    return;
  }
  activeConnections++;
  clientSock.on('close', () => { activeConnections--; });

  clientSock.setTimeout(120000, () => clientSock.destroy());
  clientSock.resume();

  let headerBuf = '';
  clientSock.on('data', function onHeader(chunk) {
    headerBuf += chunk.toString();
    const idx = headerBuf.indexOf('\r\n');
    if (idx === -1) return;

    clientSock.removeListener('data', onHeader);

    const firstLine = headerBuf.substring(0, idx);
    const rest = headerBuf.substring(idx + 2);

    // CONNECT host:port HTTP/1.1
    const match = firstLine.match(/^CONNECT\s+([^\s:]+):(\d+)\s+HTTP/i);
    if (match) {
      handleConnect(clientSock, match[1], parseInt(match[2], 10), rest);
    } else {
      // Plain HTTP proxy request — forward entire request
      handlePlainHttp(clientSock, firstLine, rest);
    }
  });
});

function handleConnect(clientSock, targetHost, targetPort, headerRest) {
  // Consume remaining headers until \r\n\r\n
  let restBuf = headerRest;
  const consumeHeaders = () => {
    const endIdx = restBuf.indexOf('\r\n\r\n');
    if (endIdx !== -1) {
      const trailing = restBuf.substring(endIdx + 4);
      doConnect(trailing);
      return;
    }
    clientSock.once('data', (chunk) => {
      restBuf += chunk.toString();
      consumeHeaders();
    });
  };

  function doConnect(trailingData) {
    connectUpstream(targetHost, targetPort, (err, upstreamSock, upstreamExtra) => {
      if (err) {
        clientSock.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        clientSock.destroy();
        return;
      }
      clientSock.write('HTTP/1.1 200 Connection Established\r\n\r\n');

      // Pipe bidirectionally
      clientSock.pipe(upstreamSock);
      upstreamSock.pipe(clientSock);

      // Send any extra data that came in after handshake
      // upstreamExtra is data from the target server; write it to the client.
      if (upstreamExtra && upstreamExtra.length > 0) {
        clientSock.write(upstreamExtra);
      }
      if (trailingData && trailingData.length > 0) {
        upstreamSock.write(trailingData);
      }

      clientSock.on('error', () => upstreamSock.destroy());
      upstreamSock.on('error', () => clientSock.destroy());
    });
  }

  consumeHeaders();
}

function handlePlainHttp(clientSock, firstLine, headerRest) {
  // For plain HTTP requests, forward directly to upstream proxy
  const sock = net.connect(upstreamPort, upstreamHost, () => {
    sock.write(firstLine + '\r\n' + headerRest);
    clientSock.pipe(sock);
    sock.pipe(clientSock);
  });
  sock.on('error', () => clientSock.destroy());
  clientSock.on('error', () => sock.destroy());
}

// ── Lifecycle ───────────────────────────────────────────────────

const fs = require('fs');

function writePid() {
  if (pidFile) {
    try { fs.writeFileSync(pidFile, String(process.pid)); } catch (_) {}
  }
}

function cleanup() {
  if (pidFile) {
    try { fs.unlinkSync(pidFile); } catch (_) {}
  }
  server.close();
  process.exit(0);
}

process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);

server.listen(listenPort, '127.0.0.1', () => {
  writePid();
  log('listening on 127.0.0.1:' + listenPort + ' → ' + upstreamHost + ':' + upstreamPort +
      (isSocks5 ? ' (socks5)' : ' (http)'));
});

server.on('error', (err) => {
  log('server error: ' + err.message);
  process.exit(1);
});
