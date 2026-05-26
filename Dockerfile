# Stage 1: Build the Go server
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder

WORKDIR /src
COPY app/server.go /src/
ARG TARGETOS TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o server server.go

# Stage 2: Final minimal image
FROM alpine:3.20

RUN apk add --no-cache \
  net-snmp-tools \
  sqlite \
  tzdata

WORKDIR /app
COPY app/mt-traffic.sh /app/mt-traffic.sh
COPY --from=builder /src/server /app/server
COPY app/www /app/www
COPY app/i18n /app/i18n
COPY app/images /app/images
RUN chmod +x /app/mt-traffic.sh /app/server

EXPOSE 8080
ENTRYPOINT ["/app/mt-traffic.sh"]
