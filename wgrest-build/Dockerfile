# Use Go 1.21 to support modern syntax (generics, etc.)
FROM golang:1.21-alpine as build-env
LABEL maintainer="ForestVPN.com <support@forestvpn.com>"

RUN apk add --no-cache git gcc

WORKDIR /app

# Clone the wgrest repository
RUN git clone https://github.com/suquant/wgrest.git .

# Build using the correct structure with compatible Go version
RUN export appVersion=$(git describe --tags `git rev-list -1 HEAD` 2>/dev/null || echo "unknown") && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -ldflags "-X main.appVersion=$appVersion" \
      -o wgrest cmd/wgrest-server/main.go

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies including envsubst
RUN apk add --no-cache \
        ca-certificates \
        wireguard-tools \
        gettext \
        iptables && \
    rm -rf /var/cache/apk/*

WORKDIR /app

# Copy built binary from builder stage
COPY --from=build-env /app/wgrest /app/wgrest

# Make executable - keep as root for WireGuard access
RUN chmod +x /app/wgrest

# Create data directories that wgrest needs
RUN mkdir -p /app/data /var/lib/wgrest

# DO NOT switch to non-root user - wgrest needs root to manage WireGuard

EXPOSE 8080

# Use the same entrypoint style as original
ENTRYPOINT ["/app/wgrest"]