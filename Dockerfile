FROM nginx:1.24-alpine-slim

# Install additional packages
RUN apk add --no-cache \
    curl \
    bash \
    && rm -rf /var/cache/apk/*

# Create necessary directories
RUN mkdir -p /var/log/nginx \
    && mkdir -p /var/cache/nginx \
    && mkdir -p /docker-entrypoint.d

# Copy the entrypoint script
COPY entrypoint.sh /docker-entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /docker-entrypoint.sh

# Set default environment variables
# ENV ALLOWED_DOMAINS=yourapp.com,yourapp.dev
ENV POSTHOG_CLOUD=us
ENV CACHE_STATIC_DAYS=7

# Expose the proxy port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Set the entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
