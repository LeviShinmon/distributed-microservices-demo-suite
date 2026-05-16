# --- build stage ---
FROM golang:1.22-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY main.go ./

# CGO off so we get a static binary that runs in scratch/distroless.
RUN mkdir -p /out && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/health-node .

# --- run stage ---
FROM gcr.io/distroless/static-debian12

COPY --from=build /out/health-node /health-node

EXPOSE 8083
USER 65532:65532
ENTRYPOINT ["/health-node"]