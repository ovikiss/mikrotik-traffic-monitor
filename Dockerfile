# Stage 1: Build the Go server
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder

WORKDIR /src
RUN apk add --no-cache git

COPY . /src
ARG TARGETOS TARGETARCH
ARG UI_SHARED_REPO=https://github.com/ovikiss/mikrotik-ui-shared.git
ARG UI_SHARED_REF=main
ARG UI_SHARED_REV=unknown
ARG APP_VERSION=dev
RUN UI_SHARED_REPO="$UI_SHARED_REPO" UI_SHARED_REF="$UI_SHARED_REF" UI_SHARED_REV="$UI_SHARED_REV" sh scripts/sync-ui-shared.sh
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w -X main.Version=${APP_VERSION}" -o server app/server.go

# Stage 2: Final minimal image
FROM alpine:3.20

RUN apk add --no-cache \
  net-snmp-tools \
  sqlite \
  tzdata

WORKDIR /app
COPY --from=builder /src/server /app/server
COPY --from=builder /src/app /app
RUN chmod +x /app/mt-traffic.sh /app/server

EXPOSE 8080
ENTRYPOINT ["/app/mt-traffic.sh"]
