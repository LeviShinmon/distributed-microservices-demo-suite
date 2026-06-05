# Distributed Microservices Demo Suite

This project demos a system built as independent but interconnected services. 

## The Microservices

**Gateway (Node.js)**: handles all incoming requests and routes them to the
correct service.

**Health Node (Go)**: works in tandem with Gateway to ensure the entire system
is online and responsive. Monitors all four other services: the gateway
itself, the invoice service, the performance monitor, and (indirectly, via
the gateway's `logs_ready` flag) the MongoDB connection.

**Invoice Service (Python)**: generates full-page invoice PDFs.

**Performance Monitor (C)**: tracks raw system resources.

**Status Dashboard (Node.js)**: a browser-facing page at
`http://localhost:8090` that polls the system's own health endpoints and
renders live status per service, with a button to inject a simulated failure
into the invoice service for demoing graceful degradation.

Only the gateway and the dashboard are reachable from your machine. The
other services communicate with each other over an internal Docker network.

> **Note** In this basic setup, the Gateway and Health Node are "single
> points of failure." To fix this in a real-world version, I would run
> multiple Gateways so that if one fails, another takes over instantly, and
> I would use a Raft-inspired system to conduct leader elections and
> maintain health-node consensus.

## Run it

You only need Docker Desktop (or Docker Engine + Compose on Linux). Every
language toolchain lives inside its container.

From the repo root, `docker compose up --build`. The first run pulls images
and builds each service (2–3 minutes); after that it caches and is much
faster. When you see `[gateway] listening on :8080`, everything is up.

Use a second terminal for the steps below. To stop everything, Ctrl-C in
the first terminal, then `docker compose down` (or `docker compose down -v`
to also wipe the Mongo data volume).

> **A note on platforms**: Should work on Windows and Linux, but I didn't
> fully test on macOS.

## Try it

Here's how to see the microservices work. If you'd rather watch one script
run through everything instead of typing it yourself, run
`./scripts/demo.sh` (on Windows: Git Bash, WSL, or `bash scripts/demo.sh`).
It calls each endpoint through the gateway, fires a burst of varied traffic
so the request log shows balanced cross-service activity, prints a per-path
count straight out of MongoDB, and saves the generated invoice as
`demo_invoice.pdf`. Otherwise, walk through the steps below.

### 0. Open the live status dashboard (easiest place to start)

Open `http://localhost:8090` in your browser. You should see five status
cards: `api-gateway`, `invoice-service`, `performance-monitor`,
`health-node`, and `mongo`, all green, with a top banner reading "All
systems operational." The dashboard polls the system's own health endpoints
every few seconds, so leave the tab open and it will reflect any change in
the system without you refreshing.

The dashboard's data comes from the health node's `/status` snapshot,
proxied through the gateway. It's the same data you'd see by hitting
`http://localhost:8080/status` directly, the dashboard just renders it.

### 1. Generate a real invoice

Run one of these and open the file. It's a full-page PDF with an issuer
header, the bill-to Acme Corp, an invoice number, dates, an itemized table
with quantities and prices, subtotal/tax/total, and payment terms:

- macOS / Linux / Git Bash: `curl "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`
- Windows PowerShell / cmd: `curl.exe "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`

You can also customize your own line items with one or more
`item=description:qty:unit_price` params, for example:

- macOS / Linux / Git Bash: `curl "http://localhost:8080/generate?name=Acme%20Corp&item=Backend%20work:40:125&item=Hosting:1:312.40" -o invoice.pdf`
- Windows PowerShell / cmd: `curl.exe "http://localhost:8080/generate?name=Acme%20Corp&item=Backend%20work:40:125&item=Hosting:1:312.40" -o invoice.pdf`

### 2. Watch real CPU load

Run the right command for your shell:

- macOS / Linux / Git Bash: `curl http://localhost:8080/metrics`
- Windows PowerShell / cmd: `curl.exe http://localhost:8080/metrics`

You'll get something like `{"cpu_load_pct":0.50,"samples":12}`. That's a
live `/proc/stat` reading from inside the C service's container, measured
as a single percentage across all the cores the Docker VM has access to.

To convince yourself the number isn't faked, you want to see it move in
lockstep with another measurement of the same thing. Open two more
terminals:

- One running `docker stats` (Docker's own per-container CPU view)
- One running a load generator. The exact command depends on your shell:
  - Bash / Git Bash / WSL / macOS / Linux: `while true; do curl -s http://localhost:8080/health > /dev/null; done`
  - Windows PowerShell: `while ($true) { curl.exe -s http://localhost:8080/health > $null }`

Put the original terminal where you ran the metrics command and the
terminal running `docker stats` next to each other. With the loop running,
re-run the metrics command repeatedly. You should see two things happen at
the same time: `cpu_load_pct` rises (the monitor noticed the VM got
busier), and the `api-gateway` and `mongo` rows in the `docker stats`
terminal rise. Observe for a while for best results. When you Ctrl-C the
loop, both drop back gradually. That correlation is the proof of
functionality.

The numbers won't be equal because they're measuring different scopes, and
they sample at different moments. What matters is that they move (up or
down) together. On Linux, there's no VM layer, so the monitor reads your
machine's real CPU and you can compare directly.

### 3. Break a service and watch the health node notice

There are two ways to do this. Both demonstrate the same thing: the health node detects an unhealthy service, and the gateway fails fast on calls that depend on it.

**Option A — simulate a failure from the dashboard (easiest).** On the
status dashboard at `localhost:8090`, click **"simulate invoice-service failure."**
Within a poll cycle, the invoice card flips red and the overall banner
reads "Degraded." The invoice service's process keeps running, it just
reports itself unhealthy via its `/health` endpoint, the same as a real
failure would look. Click "restore" to bring it back. This is a
chaos-engineering / readiness-probe pattern: deliberately injectable
failure modes for testing.

**Option B — actually stop the container.** A real outage instead of a
simulated one. Stop the invoice service with
`docker compose stop invoice-service`, wait about 10 seconds (so health
node finishes its next poll cycle), then hit `/status`:

- macOS / Linux / Git Bash: `curl http://localhost:8080/status`
- Windows PowerShell / cmd: `curl.exe http://localhost:8080/status`

The response body now reports `"overall_healthy":false` and shows
invoice-service with `"healthy":false` and a real connection-error message
in `last_error` (something like `context deadline exceeded`). The HTTP
status code on the response is 503, though PowerShell's `Invoke-WebRequest`
wrapper hides that — `curl.exe -i` will show it on the first line.

Now try generating an invoice while it's down. The gateway fails fast
(give it a couple of seconds) rather than hanging forever. Exactly what
you see depends on timing and your client: most often, the gateway returns
a 502 with a JSON body explaining that the upstream is unreachable, but
you may instead see a connection-closed error if the proxy drops the
request before headers go out. Either way, the call returns immediately
instead of sitting there waiting for invoice-service to respond.

Bring the service back with `docker compose start invoice-service`. After
~10 seconds, hitting `/status` flips to healthy, and invoice generation
works again.

You can also stop Mongo (`docker compose stop mongo`) or the gateway
itself (`docker compose stop api-gateway`) for real degradation demos
involving the infrastructure pieces. The dashboard reflects either within
a poll cycle.

### 4. See the gateway's request log

Every request you've made above was logged to MongoDB by the gateway. Two
ways to look at the logs:

- **Command line**: `docker compose exec mongo mongosh micro_logs --quiet --eval 'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'`
- **MongoDB Compass**: connect to `mongodb://127.0.0.1:27017`, open the
  `micro_logs` database, browse the `logs` collection. The compose file
  already exposes Mongo's port for you. If Compass returns ECONNREFUSED,
  first check `docker compose ps` and confirm the `mongo-1` row shows
  `0.0.0.0:27017->27017/tcp` under PORTS. If it doesn't, run
  `docker compose down && docker compose up --build` so the new compose
  config is applied.

If your terminal output looks invoice-heavy when you skim it, that's
because Flask narrates every request to stdout while the C and Go services
stay quiet — that's container stdout, not the request log. The Mongo
collection is the authoritative cross-service record. The demo script's
final step queries it for a per-service count so you can see balanced
activity at a glance.

> **Note**: that port mapping makes Mongo reachable only on your own
> localhost, which is fine for running this demo. A real production
> deployment would keep Mongo internal to the Docker network and add
> authentication.

## Future Resilience Work

- **Timeouts and Retries**: To stop the Gateway from hanging when a
  service is slow.
- **Circuit Breakers**: To automatically "trip" and stop sending requests
  to a service that is failing repeatedly.
- **Database Fallbacks**: So the Gateway can still function even if
  MongoDB is temporarily down.
