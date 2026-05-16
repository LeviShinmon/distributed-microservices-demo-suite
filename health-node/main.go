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

// pollLoop checks every service once per interval and updates `state`.
func pollLoop(targets []ServiceHealth, interval time.Duration) {
	client := &http.Client{Timeout: 2 * time.Second}

	for {
		results := make([]ServiceHealth, len(targets))
		allHealthy := true
		for i, t := range targets {
			results[i] = checkOne(t.Name, t.URL, client)
			if !results[i].Healthy {
				allHealthy = false
			}
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

	targets := []ServiceHealth{
		{Name: "invoice-service",     URL: envOr("INVOICE_HEALTH_URL",     "http://localhost:8081/health")},
		{Name: "performance-monitor", URL: envOr("PERFORMANCE_HEALTH_URL", "http://localhost:8082/health")},
	}

	go pollLoop(targets, time.Duration(intervalSec)*time.Second)

	http.HandleFunc("/status", statusHandler)
	http.HandleFunc("/health", healthHandler)

	addr := ":" + port
	log.Printf("health-node listening on %s, polling every %ds", addr, intervalSec)
	log.Fatal(http.ListenAndServe(addr, nil))
}