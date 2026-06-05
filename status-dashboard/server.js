/*
 * Status Dashboard — server
 *
 * Serves a browser page showing live health of the microservices suite, and
 * aggregates the suite's own endpoints server-side so the browser only ever
 * talks to this origin (avoids CORS, and mirrors how a real dashboard backend
 * fans out to upstreams).
 *
 * Endpoints it exposes:
 *   GET  /                       -> the dashboard page
 *   GET  /api/health             -> combined health of gateway, mongo, and the
 *                                   downstream services (from gateway /status)
 *   POST /api/invoice/simulate-down -> tell the invoice service to report unhealthy
 *   POST /api/invoice/simulate-up   -> restore it
 *
 * Env vars:
 *   PORT                 (default 8090)
 *   GATEWAY_URL          (default http://localhost:8080)
 *   INVOICE_ADMIN_URL    (default http://localhost:8081)  // direct, not via gateway
 */

const express = require("express");
const path = require("path");

const PORT = parseInt(process.env.PORT || "8090", 10);
const GATEWAY_URL = process.env.GATEWAY_URL || "http://localhost:8080";
const INVOICE_ADMIN_URL = process.env.INVOICE_ADMIN_URL || "http://localhost:8081";

const app = express();
app.use(express.static(path.join(__dirname, "public")));

// Small helper: fetch with a timeout, never throw. Returns { ok, status, body }
// or { ok:false, reachable:false } if the request couldn't complete at all.
async function safeFetch(url, opts = {}, timeoutMs = 2500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...opts, signal: controller.signal });
    let body = null;
    try { body = await res.json(); } catch (_) { /* non-JSON or empty */ }
    return { ok: res.ok, reachable: true, status: res.status, body };
  } catch (_) {
    return { ok: false, reachable: false, status: 0, body: null };
  } finally {
    clearTimeout(timer);
  }
}

// GET /api/health — the aggregator.
// The health node's /status (proxied via the gateway) is now the single source
// of truth: it reports api-gateway, invoice-service, performance-monitor, and
// mongo. We add only the health node's own reachability on top.
app.get("/api/health", async (_req, res) => {
  const statusRes = await safeFetch(`${GATEWAY_URL}/status`);

  const cards = [];

  // The health node is now the source of truth for every monitored service —
  // it reports api-gateway, invoice-service, performance-monitor, and mongo
  // (mongo derived from the gateway's logs_ready). We read those rows directly
  // from /status. The one thing the health node can't report is its OWN
  // reachability, so we add that card ourselves based on whether /status
  // answered at all.

  // --- services reported by the health node -------------------------------
  const services = (statusRes.body && Array.isArray(statusRes.body.services))
    ? statusRes.body.services
    : [];

  for (const svc of services) {
    cards.push({
      name: svc.name,
      healthy: !!svc.healthy,
      reachable: statusRes.reachable,
      note: svc.last_error || null,
      lastChecked: svc.last_checked || null,
    });
  }

  // --- health-node itself: did /status answer at all (even a 503 counts) --
  cards.push({
    name: "health-node",
    healthy: statusRes.reachable,
    reachable: statusRes.reachable,
    note: statusRes.reachable ? null : "unreachable",
  });

  // If the health node never answered, its services array is empty, so add
  // placeholder unknown rows for the services it would normally report — keeps
  // the UI shape stable instead of collapsing to a single card.
  if (!statusRes.reachable) {
    for (const name of ["api-gateway", "invoice-service", "performance-monitor", "mongo"]) {
      cards.push({ name, healthy: false, reachable: false, note: "unknown — health node unreachable" });
    }
  }

  const downCount = cards.filter((c) => !c.healthy).length;
  res.json({
    generatedAt: new Date().toISOString(),
    overallHealthy: downCount === 0,
    downCount,
    total: cards.length,
    cards,
  });
});

// POST /api/invoice/simulate-down and /simulate-up — proxy to the invoice
// service's admin endpoints (direct, not through the gateway, which doesn't
// route admin paths).
app.post("/api/invoice/simulate-down", async (_req, res) => {
  const r = await safeFetch(`${INVOICE_ADMIN_URL}/admin/simulate-down`, { method: "POST" });
  res.status(r.reachable ? 200 : 502).json({ ok: r.reachable, simulated_down: true });
});

app.post("/api/invoice/simulate-up", async (_req, res) => {
  const r = await safeFetch(`${INVOICE_ADMIN_URL}/admin/simulate-up`, { method: "POST" });
  res.status(r.reachable ? 200 : 502).json({ ok: r.reachable, simulated_down: false });
});

app.listen(PORT, () => {
  console.log(`[status-dashboard] listening on :${PORT}`);
  console.log(`[status-dashboard] gateway: ${GATEWAY_URL}, invoice admin: ${INVOICE_ADMIN_URL}`);
});
