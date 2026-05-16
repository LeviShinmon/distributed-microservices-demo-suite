# Distributed Microservices Demo Suite

This project demos a system built as independent, interconnected services. It shows an organized network, with secure traffic through a single point, which manages service failures.

## The Microservices

* Gateway (Node.js): handles all incoming requests and routes them to the correct service. 

* Health Node (Go): keeps track of the other services and works in tandem with Gateway to ensure the entire system is online and responsive.
      
* Invoice Service (Python): generates full-page invoice PDFs. 

* Performance Monitor (C): tracks raw system resources.  

* mongodb — request log store.

Only the gateway is reachable from your machine. The other services talk to
each other across an internal Docker network.

**Note
In this basic setup, the Gateway and Health Node are "single points of failure." To fix this in a real-world version:
  
  * Redundancy: I would run multiple Gateways. If one fails, another takes over instantly.
  
  * Consensus: I would use a cluster of Health Nodes that "vote" on a leader. If the leader crashes, the others elect       a new one, so the monitoring never stops.

## Run it
 
You only need Docker Desktop (or Docker Engine + Compose on Linux). Every language toolchain lives inside its container.
 
From the repo root, `docker compose up --build`. The first run pulls images
and builds each service (2–3 minutes); after that it caches and is much
faster. When you see `[gateway] listening on :8080`, everything is up.
 
Use a second terminal for the steps below. To stop everything, `Ctrl-C` in the first terminal,
then `docker compose down` (or `docker compose down -v` to also wipe the
Mongo data volume).
 
A note on platforms:
 
- **Linux:** works as-is, runs directly on your kernel.
- **Windows:** works, but Docker runs Linux containers inside a small VM.
  The performance-monitor reads CPU from inside that VM, so the number you
  see is the VM's view, not Task Manager's view of your whole machine.
  See step 2 below for how to actually make the number move.
- **macOS:** *probably* works the same way as Windows, but I built and
  tested this on Windows and Linux only. If you're on a Mac and something
  is off, that's why
  
## Try it
 
The four services each do real work. Here's how to see it.
 
**1. Generate a real invoice.** Run `curl "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf` and open the file. It's a full-page PDF with an issuer header, the bill-to Acme Corp, an invoice number, dates, an itemized table with quantities and prices, subtotal/tax/total, and payment terms.
 
You can also supply your own line items with one or more `item=description:qty:unit_price`params like below:
 
`curl "http://localhost:8080/generate?name=Acme%20Corp&item=Backend%20work:40:125&item=Hosting:1:312.40" -o invoice.pdf`

Feel free to input your own parameters for an invoice, following the format. And if you get confused, run `curl http://localhost:8080/example` to see the input format spelled out, a sample request, and the defaults used when you don't supply items.
 
**2. Watch real CPU load.** Run `curl http://localhost:8080/metrics` and you'll get something like `{"cpu_load_pct":0.50,"samples":12}`. That's a live `/proc/stat` reading from inside the C service's container, measured as a single percentage across all the cores the Docker VM has access to.
 
To convince yourself the number isn't faked, you want to see it move in lockstep with another measurement of the same thing. Open two more terminals:
 
- One running `docker stats` (Docker's own per-container CPU view, in percent of one core)
- One running a load generator: `while true; do curl -s http://localhost:8080/health > /dev/null; done`
Now hit `/metrics` repeatedly. With the loop running, you'll see two things happen at the same time: `cpu_load_pct` rises (the monitor noticed the VM got busier) and the `api-gateway` and `mongo` rows in `docker stats` rise (those are the containers actually doing the work). When you `Ctrl-C` the loop, both drop back. That correlation is the proof.
 
The numbers won't be *equal* — they're measuring different scopes (`cpu_load_pct` is the whole VM as one percent; `docker stats` is per-container as percent-of-one-core), and they sample at different moments. What matters is that they move together. On Linux there's no VM layer, so the monitor reads your machine's real CPU and you can compare directly against `top`.
 
**3. Break a service and watch the health node notice.** Stop the invoice service with `docker compose stop invoice-service`, wait about 10 seconds (so health-node finishes its next poll cycle), then run `curl http://localhost:8080/status`. The response now reports invoice-service unhealthy with a real connection-error message, and the endpoint returns HTTP 503. Try generating an invoice in that state — `curl "http://localhost:8080/generate?name=Acme%20Corp" -o invoice.pdf` — and the gateway returns 502 with a JSON body explaining the upstream is unreachable. It doesn't hang.
 
Bring the service back with `docker compose start invoice-service`. After ~10 seconds, `/status` flips to healthy and invoice generation works again.
Try `curl "http://localhost:8080/generate?name=Acmeme%20Corp" -o invoice.pdf` to confirm
 
**4. See the gateway's request log.** Every request you've made above was logged to MongoDB by the gateway. Two ways to look at the logs, take your pick:
 
- **Command line:** `docker compose exec mongo mongosh micro_logs --quiet --eval 'db.logs.find().sort({timestamp:-1}).limit(10).pretty()'`
- **MongoDB Compass:** connect to `mongodb://localhost:27017`, open the `micro_logs` database, browse the `logs` collection. The compose file already exposes Mongo's port for you.
Note: that port mapping makes Mongo reachable only on your own localhost,
which is fine for running this demo. A real production deployment would
keep Mongo internal to the Docker network and add authentication.
 
**One-shot walkthrough.** `scripts/demo.sh` runs steps 1–3 in sequence with
formatted output. On Windows, run it via Git Bash, WSL, or `bash scripts/demo.sh`.
 

## Future Resilience Work

* Timeouts and Retries: To stop the Gateway from hanging when a service is slow.

* Circuit Breakers: To automatically "trip" and stop sending requests to a service that is failing repeatedly.

* Database Fallbacks: So the Gateway can still function even if MongoDB is temporarily down.
