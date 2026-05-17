# Distributed Microservices Demo Suite

This project demos a system built as independent but interconnected services. 

## The Microservices

* Gateway (Node.js): handles all incoming requests and routes them to the correct service. 

* Health Node (Go): works in tandem with Gateway to ensure the entire system is online and responsive.
      
* Invoice Service (Python): generates full-page invoice PDFs. 

* Performance Monitor (C): tracks raw system resources.  

Only the gateway is reachable from your machine. The other services communicate with each other over an internal Docker network.

**Note
In this basic setup, the Gateway and Health Node are "single points of failure." To fix this in a real-world version, I would run multiple Gateways so that if one fails, another takes over instantly, and I would use a Raft-inspired system to conduct leader elections and maintain health-node consensus

## Run it
 
You only need Docker Desktop (or Docker Engine + Compose on Linux). Every language toolchain lives inside its container.
 
From the repo root, `docker compose up --build`. The first run pulls images
and builds each service (2–3 minutes); after that it caches and is much
faster. When you see `[gateway] listening on :8080`, everything is up.
 
Use a second terminal for the steps below. To stop everything, `Ctrl-C` in the first terminal,
then `docker compose down` (or `docker compose down -v` to also wipe the
Mongo data volume).
 
**A note on platforms: Should work on Windows and Linux, but I didn't fully test on mac
  
## Try it
 
Here's how to see the microservices work:

If you'd rather watch one script run through everything instead of typing it yourself, run `./scripts/demo.sh` (on Windows: Git Bash, WSL, or `bash scripts/demo.sh`). It calls each endpoint through the gateway in order, prints a short explanation of what each call is doing, saves the generated invoice as `demo_invoice.pdf` in the current directory, and ends with a per-service summary. Otherwise, walk through the steps below to do similar things.
 
**1. Generate a real invoice.** Run one of these and open the file. It's a full-page PDF with an issuer header, the bill-to Acme Corp, an invoice number, dates, an itemized table with quantities and prices, subtotal/tax/total, and payment terms:

- macOS / Linux / Git Bash: `curl "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`
- Windows PowerShell / cmd: `curl.exe "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`
 
You can also customize your own line items with one or more `item=description:qty:unit_price` params, for example:

- macOS / Linux / Git Bash: `curl "http://localhost:8080/generate?name=Acme%20Corp&item=Backend%20work:40:125&item=Hosting:1:312.40" -o invoice.pdf`
- Windows PowerShell / cmd: `curl.exe "http://localhost:8080/generate?name=Acme%20Corp&item=Backend%20work:40:125&item=Hosting:1:312.40" -o invoice.pdf`

**2. Watch real CPU load.** Run the right command for your shell:

- macOS / Linux / Git Bash: `curl http://localhost:8080/metrics`
- Windows PowerShell / cmd: `curl.exe http://localhost:8080/metrics`

You'll get something like `{"cpu_load_pct":0.50,"samples":12}`. That's a live `/proc/stat` reading from inside the C service's container, measured as a single percentage across all the cores the Docker VM has access to.
 
To convince yourself the number isn't faked, you want to see it move in lockstep with another measurement of the same thing. Open two more terminals:
 
- One running `docker stats` (Docker's own per-container CPU view)
- One running a load generator. The exact command depends on your shell:
  - **Bash / Git Bash / WSL / macOS / Linux:** `while true; do curl -s http://localhost:8080/health > /dev/null; done`
  - **Windows PowerShell:** `while ($true) { curl.exe -s http://localhost:8080/health > $null }`

Put the original terminal where you ran the metrics command and the terminal you ran `docker stats` next to each other. Now run the metrics commands for your system (the command is listed at the start of this step) repeatedly. With the loop running, you should see two things happen at the same time: `cpu_load_pct` rises (the monitor noticed the VM got busier), and the `api-gateway` and `mongo` rows in the terminal you ran `docker stats` rise. Observe for a while for best results. When you `Ctrl-C` the loop, both drop back gradually. That correlation is the proof of functionality.
 
The numbers won't be equal because they're measuring different scopes, and they sample at different moments. What matters is that they move (up or down) together. On Linux, there's no VM layer, so the monitor reads your machine's real CPU, and you can compare directly.
 
**3. Break a service and watch the health node notice.** Stop the invoice service with `docker compose stop invoice-service`, wait about 10 seconds (so health-node finishes its next poll cycle), then hit `/status`:

- macOS / Linux / Git Bash: `curl http://localhost:8080/status`
- Windows PowerShell / cmd: `curl.exe http://localhost:8080/status`

The response body now reports `"overall_healthy":false` and shows invoice-service with `"healthy":false` and a real connection-error message in `last_error` (something like `context deadline exceeded`). The HTTP status code on the response is 503, though PowerShell's `Invoke-WebRequest` wrapper hides that — `curl.exe -i` will show it on the first line.

Now try generating an invoice while it's down:

- macOS / Linux / Git Bash: `curl "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`
- Windows PowerShell / cmd: `curl.exe "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf`

The gateway fails fast (give it a couple of seconds)rather than hanging forever. Exactly what you see depends on timing and your client: most often, the gateway returns a 502 with a JSON body explaining that the upstream is unreachable, but you may instead see a connection-closed error if the proxy drops the request before headers go out. Either way, the call returns immediately instead of sitting there waiting for invoice-service to respond.

Bring the service back with `docker compose start invoice-service`. After ~10 seconds, hitting `/status` flips to healthy, and invoice generation works again. Delete the `invoice.pdf` file if one exists and re-run the generate command to confirm.

**4. See the gateway's request log.** Every request you've made above was logged to MongoDB by the gateway. Two ways to look at the logs, the first is easier:
 
- **Command line:** run `docker compose exec mongo mongosh micro_logs --quiet --eval 'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'` in the project's directory
- **MongoDB Compass:** connect to `mongodb://127.0.0.1:27017`, open the `micro_logs` database, browse the `logs` collection. The compose file already exposes Mongo's port for you. If Compass returns `ECONNREFUSED`, first check `docker compose ps` and confirm the `mongo-1` row shows `0.0.0.0:27017->27017/tcp` under PORTS. If it doesn't, run `docker compose down && docker compose up --build` so the new compose config is applied.
  
**Note: that port mapping makes Mongo reachable only on your own localhost, which is fine for running this demo. A real production deployment would keep Mongo internal to the Docker network and add authentication.
 
## Future Resilience Work

* Timeouts and Retries: To stop the Gateway from hanging when a service is slow.

* Circuit Breakers: To automatically "trip" and stop sending requests to a service that is failing repeatedly.

* Database Fallbacks: So the Gateway can still function even if MongoDB is temporarily down.
