# Build wgrest from source
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Install git and build dependencies
RUN apk add --no-cache git

# Clone wgrest repository
RUN git clone https://github.com/suquant/wgrest.git .

# Build the application
RUN go mod download && \
    go build -o wgrest ./cmd/wgrest

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
        ca-certificates \
        wireguard-tools && \
    rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 wgrest && \
    adduser -D -s /bin/sh -u 1000 -G wgrest wgrest

WORKDIR /app

# Copy built binary from builder stage
COPY --from=builder /app/wgrest /usr/local/bin/wgrest

# Create data directory
RUN mkdir -p /app/data && chown -R wgrest:wgrest /app

# Switch to non-root user
USER wgrest

EXPOSE 8080

CMD ["wgrest", "-config", "/app/config.yaml"]