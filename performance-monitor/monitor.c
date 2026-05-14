/*
 * Performance Monitor (C)
 *
 * Samples /proc/stat in a background thread and exposes the latest CPU load
 * reading as a tiny HTTP service on port 8082 (configurable via $PORT).
 *
 * Two endpoints:
 *   GET /metrics  -> { "cpu_load_pct": <float>, "samples": <int> }
 *   GET /health   -> { "status": "ok" }
 *
 * No external HTTP library on purpose: keeps the Docker image tiny and shows
 * that the service is doing the real work itself.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/* Shared sample state, guarded by a mutex.
   Reader (HTTP thread) and writer (sampler thread) only ever touch
   these two fields, so a single mutex covers it. */
static pthread_mutex_t sample_lock = PTHREAD_MUTEX_INITIALIZER;
static double  latest_load_pct = 0.0;
static long    sample_count    = 0;

/* Read the first line of /proc/stat into four counters.
   Returns 0 on success, -1 on failure. */
static int read_proc_stat(long double out[4]) {
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp) return -1;
    int n = fscanf(fp, "%*s %Lf %Lf %Lf %Lf",
                   &out[0], &out[1], &out[2], &out[3]);
    fclose(fp);
    return (n == 4) ? 0 : -1;
}

/* Background thread: samples CPU load once per second forever. */
static void *sampler_thread(void *arg) {
    (void)arg;
    long double a[4], b[4];

    while (1) {
        if (read_proc_stat(a) != 0) { sleep(1); continue; }
        sleep(1);
        if (read_proc_stat(b) != 0) { continue; }

        long double busy_delta  = (b[0] + b[1] + b[2]) - (a[0] + a[1] + a[2]);
        long double total_delta = (b[0] + b[1] + b[2] + b[3])
                                - (a[0] + a[1] + a[2] + a[3]);

        double load = (total_delta > 0) ? (double)(busy_delta / total_delta) : 0.0;

        pthread_mutex_lock(&sample_lock);
        latest_load_pct = load * 100.0;
        sample_count++;
        pthread_mutex_unlock(&sample_lock);
    }
    return NULL;
}

/* write() can short-return on a socket. Loop until everything's out or fail. */
static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

/* Write one HTTP response. Caller provides body; we add the status line + headers. */
static void send_response(int client_fd, const char *status, const char *body) {
    char header[256];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, strlen(body));
    if (write_all(client_fd, header, (size_t)header_len) < 0) return;
    (void)write_all(client_fd, body, strlen(body));
}

/* Parse out the request path from "GET /path HTTP/1.1\r\n..."
   into `path_out` (caller-allocated, at least 256 bytes). */
static int parse_path(const char *request, char *path_out, size_t path_cap) {
    if (strncmp(request, "GET ", 4) != 0) return -1;
    const char *start = request + 4;
    const char *end = strchr(start, ' ');
    if (!end) return -1;
    size_t len = (size_t)(end - start);
    if (len >= path_cap) return -1;
    memcpy(path_out, start, len);
    path_out[len] = '\0';
    return 0;
}

/* Handle one client connection, then close it. */
static void handle_client(int client_fd) {
    char buf[1024];
    ssize_t n = read(client_fd, buf, sizeof(buf) - 1);
    if (n <= 0) { close(client_fd); return; }
    buf[n] = '\0';

    char path[256];
    if (parse_path(buf, path, sizeof(path)) != 0) {
        send_response(client_fd, "400 Bad Request", "{\"error\":\"bad request\"}");
        close(client_fd);
        return;
    }

    char body[256];

    if (strcmp(path, "/metrics") == 0) {
        pthread_mutex_lock(&sample_lock);
        double load = latest_load_pct;
        long   n_samples = sample_count;
        pthread_mutex_unlock(&sample_lock);

        snprintf(body, sizeof(body),
                 "{\"cpu_load_pct\":%.2f,\"samples\":%ld}",
                 load, n_samples);
        send_response(client_fd, "200 OK", body);
    } else if (strcmp(path, "/health") == 0) {
        send_response(client_fd, "200 OK", "{\"status\":\"ok\"}");
    } else {
        send_response(client_fd, "404 Not Found", "{\"error\":\"not found\"}");
    }

    close(client_fd);
}

int main(void) {
    /* Don't die when a client closes the connection mid-write. */
    signal(SIGPIPE, SIG_IGN);

    const char *port_env = getenv("PORT");
    int port = port_env ? atoi(port_env) : 8082;

    /* Kick off the background sampler. */
    pthread_t tid;
    if (pthread_create(&tid, NULL, sampler_thread, NULL) != 0) {
        fprintf(stderr, "failed to start sampler thread\n");
        return 1;
    }
    pthread_detach(tid);

    /* Set up the listening socket. */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(port);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(server_fd, 16) < 0) {
        perror("listen");
        return 1;
    }

    printf("performance-monitor listening on :%d\n", port);
    fflush(stdout);

    /* Accept loop. One request at a time is plenty for a demo. */
    while (1) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        handle_client(client_fd);
    }

    close(server_fd);
    return 0;
}