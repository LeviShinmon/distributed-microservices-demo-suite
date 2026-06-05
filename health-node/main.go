// Health Node
//
// Watches the other services in the suite by polling their /health endpoints
// on a short interval. Serves the latest snapshot at /status.
//
// Env vars:
//   PORT                       (default 8083)
//   INVOICE_HEALTH_URL         (default http://localhost:8081/health)
//   PERFORMANCE_HEALTH_URL     (default http://localhost:8082/health)
//   CHECK_INTERVAL_SECONDS     (default 5)

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// ServiceHealth is one row in the status snapshot.
type ServiceHealth struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	Healthy     bool   `json:"healthy"`
	LastChecked string `json:"last_checked"`
	LastError   string `json:"last_error,omitempty"`
}

// Snapshot is what /status returns.
type Snapshot struct {
	OverallHealthy bool            `json:"overall_healthy"`
	GeneratedAt    string          `json:"generated_at"`
	Services       []ServiceHealth `json:"services"`
}

var (
	stateMu sync.RWMutex
	state   Snapshot
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

// checkOne does a single GET, returns a fresh ServiceHealth.
// Timeout is short so a slow downstream doesn't slow down the next round.
func checkOne(name, url string, client *http.Client) ServiceHealth {
	now := time.Now().UTC().Format(time.RFC3339)
	resp, err := client.Get(url)
	if err != nil {
		return ServiceHealth{
			Name: name, URL: url, Healthy: false,
			LastChecked: now, LastError: err.Error(),
		}
	}
	defer resp.Body.Close()

	healthy := resp.StatusCode >= 200 && resp.StatusCode < 300
	row := ServiceHealth{
		Name: name, URL: url, Healthy: healthy, LastChecked: now,
	}
	if !healthy {
		row.LastError = fmt.Sprintf("unexpected status %d", resp.StatusCode)
	}
	return row
}

// checkMongoViaGateway derives Mongo's health from the gateway's /health
// response, which includes a `logs_ready` flag indicating whether the gateway's
// own Mongo connection is alive. Mongo isn't an HTTP service we can GET directly,
// so rather than add a Mongo driver to this service, we trust the gateway's
// report of its own dependency. This mirrors a common real-world pattern:
// services report the health of their dependencies, and the monitor aggregates.
func checkMongoViaGateway(gatewayHealthURL string, client *http.Client) ServiceHealth {
	now := time.Now().UTC().Format(time.RFC3339)
	row := ServiceHealth{Name: "mongo", URL: gatewayHealthURL, LastChecked: now}

	resp, err := client.Get(gatewayHealthURL)
	if err != nil {
		// Can't reach the gateway, so we genuinely don't know Mongo's state.
		row.Healthy = false
		row.LastError = "unknown — gateway unreachable: " + err.Error()
		return row
	}
	defer resp.Body.Close()

	var body struct {
		Status    string `json:"status"`
		LogsReady bool   `json:"logs_ready"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		row.Healthy = false
		row.LastError = "could not parse gateway health response"
		return row
	}

	row.Healthy = body.LogsReady
	if !body.LogsReady {
		row.LastError = "gateway reachable, but its Mongo connection is not ready"
	}
	return row
}

// pollLoop checks every service once per interval and updates `state`.
// The gatewayHealthURL is used for the derived Mongo check (Mongo's health is
// read from the gateway's logs_ready flag rather than checked directly).
func pollLoop(targets []ServiceHealth, gatewayHealthURL string, interval time.Duration) {
	client := &http.Client{Timeout: 2 * time.Second}

	for {
		// One row per HTTP target, plus one derived Mongo row.
		results := make([]ServiceHealth, 0, len(targets)+1)
		allHealthy := true

		for _, t := range targets {
			row := checkOne(t.Name, t.URL, client)
			results = append(results, row)
			if !row.Healthy {
				allHealthy = false
			}
		}

		// Derived Mongo health (via the gateway's logs_ready).
		mongoRow := checkMongoViaGateway(gatewayHealthURL, client)
		results = append(results, mongoRow)
		if !mongoRow.Healthy {
			allHealthy = false
		}

		stateMu.Lock()
		state = Snapshot{
			OverallHealthy: allHealthy,
			GeneratedAt:    time.Now().UTC().Format(time.RFC3339),
			Services:       results,
		}
		stateMu.Unlock()

		time.Sleep(interval)
	}
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	stateMu.RLock()
	defer stateMu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	// If we haven't completed a poll cycle yet, report that honestly.
	if state.GeneratedAt == "" {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error": "no health data collected yet",
		})
		return
	}
	if !state.OverallHealthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	_ = json.NewEncoder(w).Encode(state)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	// The health node's own health is just "I'm answering."
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func main() {
	port := envOr("PORT", "8083")
	intervalSec := envInt("CHECK_INTERVAL_SECONDS", 5)

	gatewayHealthURL := envOr("GATEWAY_HEALTH_URL", "http://localhost:8080/health")

	targets := []ServiceHealth{
		{Name: "api-gateway",         URL: gatewayHealthURL},
		{Name: "invoice-service",     URL: envOr("INVOICE_HEALTH_URL",     "http://localhost:8081/health")},
		{Name: "performance-monitor", URL: envOr("PERFORMANCE_HEALTH_URL", "http://localhost:8082/health")},
	}

	go pollLoop(targets, gatewayHealthURL, time.Duration(intervalSec)*time.Second)

	http.HandleFunc("/status", statusHandler)
	http.HandleFunc("/health", healthHandler)

	addr := ":" + port
	log.Printf("health-node listening on %s, polling every %ds", addr, intervalSec)
	log.Fatal(http.ListenAndServe(addr, nil))
}
