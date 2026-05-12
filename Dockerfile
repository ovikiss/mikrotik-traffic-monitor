FROM alpine:3.20

RUN apk add --no-cache \
  net-snmp-tools \
  sqlite \
  tzdata \
  python3

WORKDIR /app
COPY app/mt-traffic.sh /app/mt-traffic.sh
RUN chmod +x /app/mt-traffic.sh

EXPOSE 8080
ENTRYPOINT ["/app/mt-traffic.sh"]
