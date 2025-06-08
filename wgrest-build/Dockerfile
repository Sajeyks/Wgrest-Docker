# Use the official wgrest Dockerfile structure
FROM golang:1.17.3-alpine3.14 as build-env
LABEL maintainer="ForestVPN.com <support@forestvpn.com>"

RUN apk add --no-cache git gcc

WORKDIR /app

# Clone the wgrest repository
RUN git clone https://github.com/suquant/wgrest.git .

# Build using the correct structure
RUN export appVersion=$(git describe --tags `git rev-list -1 HEAD`) && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -ldflags "-X main.appVersion=$appVersion" \
      -o wgrest cmd/wgrest-server/main.go

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
        ca-certificates \
        wireguard-tools && \
    rm -rf /var/cache/apk/*

# Create non-root user (same as original but with specific shell)
RUN addgroup -g 1001 wgrest && \
    adduser -D -s /bin/sh -u 1001 -G wgrest wgrest

WORKDIR /app

# Copy built binary from builder stage
COPY --from=build-env /app/wgrest /app/wgrest

# Make executable and change ownership
RUN chmod +x /app/wgrest && \
    chown wgrest:wgrest /app/wgrest

# Create data directory
RUN mkdir -p /app/data && chown -R wgrest:wgrest /app

# Switch to non-root user
USER wgrest

EXPOSE 8080

# Use the same entrypoint style as original
ENTRYPOINT ["/app/wgrest"]