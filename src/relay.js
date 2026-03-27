#!/usr/bin/env node
// cac-relay — Local TCP relay that forwards to upstream proxy (bypasses TUN)
// Usage: node relay.js <listen_port> <upstream_proxy_url> [pid_file]
//
// Listens on 127.0.0.1:<port> as an HTTP proxy, forwards upstream via:
//   - HTTP CONNECT (for http:// upstream)
//   - SOCKS5 (for socks5:// upstream)
//
// Safety: fail-closed design — if relay dies, HTTPS_PROXY points to dead port,
// connections refuse (no IP leak). Watchdog in wrapper auto-restarts relay.
'use strict';

var net = require('net');
var fs = require('fs');

// ── Parse CLI args ──────────────────────────────────────────────

var listenPort = parseInt(process.argv[2], 10);
var upstreamUrl = process.argv[3];
var pidFile = process.argv[4];

if (!listenPort || !upstreamUrl) {
  process.stderr.write('Usage: node relay.js <port> <upstream_proxy_url> [pid_file]\n');
  process.exit(1);
}

var upstream = new URL(upstreamUrl);
var upstreamHost = upstream.hostname;
var upstreamPort = parseInt(upstream.port, 10);
var upstreamUser = decodeURIComponent(upstream.username || '');
var upstreamPass = decodeURIComponent(upstream.password || '');
var isSocks5 = upstream.protocol === 'socks5:';

function log(msg) { process.stderr.write('[cac-relay] ' + msg + '\n'); }

// ── Global error handlers (never crash from unhandled errors) ───

process.on('uncaughtException', function(err) {
  log('uncaught exception: ' + (err && err.message || err));
});
process.on('unhandledRejection', function(reason) {
  log('unhandled rejection: ' + (reason && reason.message || reason));
});

// ── Upstream heartbeat ──────────────────────────────────────────

var _upstreamHealthy = true;
var HEARTBEAT_INTERVAL = 30000; // 30s
var HEARTBEAT_TIMEOUT = 5000;   // 5s connect timeout

function heartbeat() {
  var sock = net.connect({ port: upstreamPort, host: upstreamHost, timeout: HEARTBEAT_TIMEOUT });
  sock.on('connect', function() {
    if (!_upstreamHealthy) log('upstream recovered: ' + upstreamHost + ':' + upstreamPort);
    _upstreamHealthy = true;
    sock.destroy();
  });
  sock.on('error', function() {
    if (_upstreamHealthy) log('upstream unreachable: ' + upstreamHost + ':' + upstreamPort);
    _upstreamHealthy = false;
    sock.destroy();
  });
  sock.on('timeout', function() {
    if (_upstreamHealthy) log('upstream timeout: ' + upstreamHost + ':' + upstreamPort);
    _upstreamHealthy = false;
    sock.destroy();
  });
}

var _heartbeatTimer = setInterval(heartbeat, HEARTBEAT_INTERVAL);

// ── SOCKS5 handshake ────────────────────────────────────────────

function socks5Connect(targetHost, targetPort, cb) {
  var sock = net.connect(upstreamPort, upstreamHost, function() {
    var hasAuth = upstreamUser && upstreamPass;

    // Greeting: version=5, nmethods=1, method=(0x02 if auth, 0x00 if none)
    sock.write(Buffer.from([0x05, 0x01, hasAuth ? 0x02 : 0x00]));

    var state = 'greeting';
    var buf = Buffer.alloc(0);

    sock.on('data', onData);

    function onData(chunk) {
      buf = Buffer.concat([buf, chunk]);
      if (state === 'greeting') {
        if (buf.length < 2) return;
        var method = buf[1];
        buf = buf.slice(2);

        if (method === 0x02 && hasAuth) {
          // Sub-negotiation: version=1, ulen, username, plen, password
          var uBuf = Buffer.from(upstreamUser);
          var pBuf = Buffer.from(upstreamPass);
          var authReq = Buffer.alloc(3 + uBuf.length + pBuf.length);
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
        var atyp = buf[3];
        var addrLen;
        if (atyp === 0x01) addrLen = 4;        // IPv4
        else if (atyp === 0x04) addrLen = 16;   // IPv6
        else if (atyp === 0x03) addrLen = 1 + (buf[4] || 0); // Domain
        else addrLen = 0;
        var totalLen = 4 + addrLen + 2; // header + addr + port
        if (buf.length < totalLen) return;

        var remaining = buf.slice(totalLen);
        sock.removeListener('data', onData);
        cb(null, sock, remaining);
      }
    }

    function sendConnectRequest() {
      // CONNECT request: ver=5, cmd=1(connect), rsv=0, atyp=3(domain)
      var hostBuf = Buffer.from(targetHost);
      var req = Buffer.alloc(5 + hostBuf.length + 2);
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

  sock.on('error', function(err) { cb(err); });
}

// ── HTTP CONNECT upstream ───────────────────────────────────────

function httpConnect(targetHost, targetPort, cb) {
  var sock = net.connect(upstreamPort, upstreamHost, function() {
    var connectReq = 'CONNECT ' + targetHost + ':' + targetPort + ' HTTP/1.1\r\n' +
                     'Host: ' + targetHost + ':' + targetPort + '\r\n';
    if (upstreamUser) {
      var cred = Buffer.from(upstreamUser + ':' + upstreamPass).toString('base64');
      connectReq += 'Proxy-Authorization: Basic ' + cred + '\r\n';
    }
    connectReq += '\r\n';
    sock.write(connectReq);

    var buf = Buffer.alloc(0);
    sock.on('data', function onData(chunk) {
      buf = Buffer.concat([buf, chunk]);
      var idx = buf.indexOf('\r\n\r\n');
      if (idx === -1) return;

      var statusLine = buf.slice(0, buf.indexOf('\r\n')).toString();
      var statusCode = parseInt(statusLine.split(' ')[1], 10);
      var remaining = buf.slice(idx + 4);

      sock.removeListener('data', onData);

      if (statusCode === 200) {
        cb(null, sock, remaining);
      } else {
        sock.destroy();
        cb(new Error('Upstream CONNECT failed: ' + statusLine));
      }
    });
  });

  sock.on('error', function(err) { cb(err); });
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

var MAX_CONNECTIONS = 128;
var IDLE_TIMEOUT = 1800000; // 30 min — streaming responses can be very long
var activeConnections = 0;

var server = net.createServer({ pauseOnConnect: true }, function(clientSock) {
  if (activeConnections >= MAX_CONNECTIONS) {
    clientSock.destroy();
    return;
  }
  activeConnections++;
  clientSock.on('close', function() { activeConnections--; });

  // Idle timeout: only kill truly idle sockets, not active streaming ones
  clientSock.setTimeout(IDLE_TIMEOUT, function() { clientSock.destroy(); });
  clientSock.on('error', function() {}); // per-connection error: don't crash
  clientSock.resume();

  var headerBuf = '';
  clientSock.on('data', function onHeader(chunk) {
    headerBuf += chunk.toString();
    var idx = headerBuf.indexOf('\r\n');
    if (idx === -1) return;

    clientSock.removeListener('data', onHeader);

    var firstLine = headerBuf.substring(0, idx);
    var rest = headerBuf.substring(idx + 2);

    // CONNECT host:port HTTP/1.1
    var match = firstLine.match(/^CONNECT\s+([^\s:]+):(\d+)\s+HTTP/i);
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
  var restBuf = Buffer.from(headerRest);
  var consumeHeaders = function() {
    var endIdx = restBuf.indexOf('\r\n\r\n');
    if (endIdx !== -1) {
      var trailing = restBuf.slice(endIdx + 4);
      doConnect(trailing);
      return;
    }
    clientSock.once('data', function(chunk) {
      restBuf = Buffer.concat([restBuf, chunk]);
      consumeHeaders();
    });
  };

  function doConnect(trailingData) {
    connectUpstream(targetHost, targetPort, function(err, upstreamSock, upstreamExtra) {
      if (err) {
        try { clientSock.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch(_) {}
        clientSock.destroy();
        return;
      }
      clientSock.write('HTTP/1.1 200 Connection Established\r\n\r\n');

      // Reset idle timeout on data activity (keeps streaming alive)
      upstreamSock.on('data', function() {
        try { clientSock.setTimeout(IDLE_TIMEOUT); } catch(_) {}
      });
      clientSock.on('data', function() {
        try { upstreamSock.setTimeout(IDLE_TIMEOUT); } catch(_) {}
      });

      // Pipe bidirectionally
      clientSock.pipe(upstreamSock);
      upstreamSock.pipe(clientSock);

      // Send any extra data that came in after handshake
      if (upstreamExtra && upstreamExtra.length > 0) {
        clientSock.write(upstreamExtra);
      }
      if (trailingData && trailingData.length > 0) {
        upstreamSock.write(trailingData);
      }

      // Per-connection errors: destroy peer, don't crash relay
      clientSock.on('error', function() { upstreamSock.destroy(); });
      upstreamSock.on('error', function() { clientSock.destroy(); });

      // Upstream idle timeout
      upstreamSock.setTimeout(IDLE_TIMEOUT, function() { upstreamSock.destroy(); });
    });
  }

  consumeHeaders();
}

function handlePlainHttp(clientSock, firstLine, headerRest) {
  // For plain HTTP requests, forward directly to upstream proxy
  var sock = net.connect(upstreamPort, upstreamHost, function() {
    var authHeader = '';
    if (upstreamUser) {
      var cred = Buffer.from(upstreamUser + ':' + upstreamPass).toString('base64');
      authHeader = 'Proxy-Authorization: Basic ' + cred + '\r\n';
    }
    sock.write(firstLine + '\r\n' + authHeader + headerRest);
    clientSock.pipe(sock);
    sock.pipe(clientSock);
  });
  sock.on('error', function() { clientSock.destroy(); });
  clientSock.on('error', function() { sock.destroy(); });
}

// ── Lifecycle ───────────────────────────────────────────────────

function writePid() {
  if (pidFile) {
    try { fs.writeFileSync(pidFile, String(process.pid)); } catch (_) {}
  }
}

function cleanup() {
  clearInterval(_heartbeatTimer);
  if (pidFile) {
    try { fs.unlinkSync(pidFile); } catch (_) {}
  }
  server.close();
  process.exit(0);
}

process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);

// ── Server start with self-restart on transient errors ──────────

function startServer() {
  server.listen(listenPort, '127.0.0.1', function() {
    writePid();
    log('listening on 127.0.0.1:' + listenPort + ' \u2192 ' + upstreamHost + ':' + upstreamPort +
        (isSocks5 ? ' (socks5)' : ' (http)'));
  });
}

server.on('error', function(err) {
  log('server error: ' + err.message);
  if (err.code === 'EADDRINUSE') {
    // Port taken — fatal, let watchdog restart us on a new port
    process.exit(1);
  }
  // Transient error — try to restart after 1s
  setTimeout(function() {
    try { server.close(); } catch(_) {}
    startServer();
  }, 1000);
});

startServer();
