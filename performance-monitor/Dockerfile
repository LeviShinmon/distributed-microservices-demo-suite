# --- build stage ---
FROM gcc:13 AS build

WORKDIR /src
COPY monitor.c ./

RUN gcc -Wall -Wextra -O2 -pthread -o /out/monitor monitor.c

# --- run stage ---
FROM debian:bookworm-slim

# Copy the static-enough binary. Debian-slim has the libc we built against.
COPY --from=build /out/monitor /usr/local/bin/monitor

# Non-root user.
RUN useradd --create-home --shell /bin/bash app
USER app

EXPOSE 8082

CMD ["/usr/local/bin/monitor"]