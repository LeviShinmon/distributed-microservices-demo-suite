/*
 * API Gateway
 *
 * Single entry point. Routes incoming requests to the right downstream
 * service, logs request metadata to MongoDB, and fails fast when a
 * downstream is unreachable.
 *
 * Env vars:
 *   PORT                       (default 8080)
 *   MONGODB_URI                (default mongodb://localhost:27017/micro_logs)
 *   INVOICE_SERVICE_URL        (default http://localhost:8081)
 *   PERFORMANCE_MONITOR_URL    (default http://localhost:8082)
 *   HEALTH_NODE_URL            (default http://localhost:8083)
 *   PROXY_TIMEOUT_MS           (default 5000)
 */

const http = require('http');
const httpProxy = require('http-proxy');
const mongoose = require('mongoose');

const PORT = parseInt(process.env.PORT || '8080', 10);
const MONGO_URI = process.env.MONGODB_URI || 'mongodb://localhost:27017/micro_logs';
const PROXY_TIMEOUT_MS = parseInt(process.env.PROXY_TIMEOUT_MS || '5000', 10);

const routes = {
  '/generate': process.env.INVOICE_SERVICE_URL     || 'http://localhost:8081',
  '/metrics':  process.env.PERFORMANCE_MONITOR_URL || 'http://localhost:8082',
  '/status':   process.env.HEALTH_NODE_URL         || 'http://localhost:8083',
};

// ---------------------------------------------------------------------------
// MongoDB — connect once. If it never comes up, log it and keep serving.
// The gateway should not refuse traffic just because logging is down.
// ---------------------------------------------------------------------------
let logsReady = false;
let Log = null;

mongoose.connect(MONGO_URI, { serverSelectionTimeoutMS: 3000 })
  .then(() => {
    logsReady = true;
    Log = mongoose.model('Log', new mongoose.Schema({
      service:   String,
      method:    String,
      path:      String,
      timestamp: { type: Date, default: Date.now },
    }));
    console.log(`[gateway] connected to mongo at ${MONGO_URI}`);
  })
  .catch(err => {
    console.error(`[gateway] mongo connect failed (continuing without logging): ${err.message}`);
  });

async function safeLog(service, method, path) {
  if (!logsReady || !Log) return;
  try {
    await Log.create({ service, method, path });
  } catch (err) {
    console.error(`[gateway] log write failed: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// Proxy with timeout. http-proxy doesn't fire 'error' on every failure mode,
// so we belt-and-suspender it: bound the request with proxyTimeout, and also
// catch synchronous throws.
// ---------------------------------------------------------------------------
const proxy = httpProxy.createProxyServer({
  proxyTimeout: PROXY_TIMEOUT_MS,
  timeout:      PROXY_TIMEOUT_MS,
});

proxy.on('error', (err, req, res) => {
  console.error(`[gateway] proxy error for ${req.url}: ${err.message}`);
  if (res && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error:        'upstream unavailable',
      detail:       err.message,
      path:         req.url,
    }));
  }
});

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];

  // The gateway's own health endpoint. Doesn't proxy anywhere.
  if (path === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', logs_ready: logsReady }));
    return;
  }

  // Find a route prefix that matches (so /generate?name=x still routes).
  const target = routes[path];
  if (!target) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found', path }));
    return;
  }

  // Fire and forget the log write — we don't want logging latency to
  // become request latency. safeLog swallows its own errors.
  safeLog(path, req.method, req.url);

  proxy.web(req, res, { target });
});

server.listen(PORT, () => {
  console.log(`[gateway] listening on :${PORT}`);
  console.log(`[gateway] routes: ${JSON.stringify(routes)}`);
});

// Graceful shutdown so docker compose stop is clean.
function shutdown(signal) {
  console.log(`[gateway] received ${signal}, shutting down`);
  server.close(() => {
    mongoose.connection.close(false, () => process.exit(0));
  });
  // Last-resort hammer.
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));