#!/bin/sh
set -e

# Environment variables with defaults
ALLOWED_DOMAINS=${ALLOWED_DOMAINS:-oreoluwabs.com,notloudstudios.com}
POSTHOG_CLOUD=${POSTHOG_CLOUD:-us}
CACHE_STATIC_DAYS=${CACHE_STATIC_DAYS:-7}

echo "=========================================="
echo "NGINX PostHog Proxy Configuration"
echo "=========================================="
echo "Environment Variables:"
echo "  - ALLOWED_DOMAINS: $ALLOWED_DOMAINS"
echo "  - POSTHOG_CLOUD: $POSTHOG_CLOUD"
echo "  - CACHE_STATIC_DAYS: $CACHE_STATIC_DAYS"
echo "=========================================="

# Build regex pattern for multiple domains
build_domain_regex() {
    local domains="$1"
    local regex=""

    # Split domains by comma and build regex
    IFS=',' read -r -a domain_array <<< "$domains"

    for domain in "${domain_array[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | xargs)
        # Escape dots for regex
        escaped_domain=$(echo "$domain" | sed "s/\./\\\\./g")

        if [ -z "$regex" ]; then
            regex="($escaped_domain)"
        else
            regex="$regex|($escaped_domain)"
        fi
    done

    echo "$regex"
}

# Generate domain regex pattern
DOMAIN_REGEX=$(build_domain_regex "$ALLOWED_DOMAINS")

echo "  - DOMAIN_REGEX: $DOMAIN_REGEX"
echo "=========================================="

# Generate nginx configuration
cat > /etc/nginx/nginx.conf << EOF
events {
    worker_connections 1024;
}
http {
    # Include mime types for proper content-type headers
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    # Logging configuration
    log_format detailed '[\$time_local] "\$request" \$status '
                        '"Referer: \$http_referer" '
                        '"Origin: \$http_origin" '
                        '"Host: \$host" '
                        '"Cache: \$upstream_cache_status"';
    access_log /var/log/nginx/access.log detailed;
    error_log /var/log/nginx/error.log debug;
    # Cache configuration for static files
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=static_cache:10m max_size=1g inactive=7d use_temp_path=off;
    # Upstream keepalive connections
    upstream posthog_main {
        server $POSTHOG_CLOUD.i.posthog.com:443;
        keepalive 10;
    }
    upstream posthog_assets {
        server $POSTHOG_CLOUD-assets.i.posthog.com:443;
        keepalive 10;
    }
    # Map to determine valid CORS origin
    map \$http_origin \$cors_origin {
        default "";
        # Allow configured domains and their subdomains
        ~^https?://(([a-zA-Z0-9-]+\\.)*)?($DOMAIN_REGEX)\$ \$http_origin;
        # Allow localhost for development
        ~^https?://localhost(:[0-9]+)?\$ \$http_origin;
        ~^https?://127\\.0\\.0\\.1(:[0-9]+)?\$ \$http_origin;
    }
    # Map for referer validation
    map \$http_referer \$valid_referer {
        default 0;
        "" 1;  # Allow empty referer
        # Allow configured domains and their subdomains
        ~^https?://(([a-zA-Z0-9-]+\\.)*)?($DOMAIN_REGEX) 1;
        # Allow localhost for development
        ~^https?://localhost 1;
        ~^https?://127\\.0\\.0\\.1 1;
    }
    server {
        listen 8080;
        server_name _;
        # DNS resolver configuration with timeout
        resolver 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 valid=300s;
        resolver_timeout 5s;
        # Check referer validation (except for OPTIONS)
        set \$check_referer \$valid_referer;
        if (\$request_method = 'OPTIONS') {
            set \$check_referer 1;
        }
        if (\$check_referer = 0) {
            return 403;
        }
        # Handle CORS preflight requests
        location / {
            if (\$request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' \$cors_origin always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH' always;
                add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Posthog-Version' always;
                add_header 'Access-Control-Allow-Credentials' 'true' always;
                add_header 'Access-Control-Max-Age' '86400' always;
                add_header 'Content-Type' 'text/plain; charset=utf-8' always;
                add_header 'Content-Length' '0' always;
                return 204;
            }
            # Default location handling - proxy to main PostHog
            set \$posthog_main "https://$POSTHOG_CLOUD.i.posthog.com/";
            # Proxy settings
            proxy_pass \$posthog_main\$uri\$is_args\$args;
            proxy_set_header Host "$POSTHOG_CLOUD.i.posthog.com";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            # SSL settings
            proxy_ssl_server_name on;
            proxy_ssl_name "$POSTHOG_CLOUD.i.posthog.com";
            proxy_ssl_session_reuse on;
            # Connection settings
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            # Timeouts
            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
            # Buffer settings
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 4k;
            proxy_busy_buffers_size 8k;
            # Remove upstream CORS headers
            proxy_hide_header Access-Control-Allow-Origin;
            proxy_hide_header Access-Control-Allow-Credentials;
            proxy_hide_header Access-Control-Allow-Methods;
            proxy_hide_header Access-Control-Allow-Headers;
            proxy_hide_header Access-Control-Expose-Headers;
            # CORS headers
            add_header 'Access-Control-Allow-Origin' \$cors_origin always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH' always;
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Posthog-Version' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
        }
        # Static assets location with caching
        location ^~ /static/ {
            if (\$request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' \$cors_origin always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH' always;
                add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Posthog-Version' always;
                add_header 'Access-Control-Allow-Credentials' 'true' always;
                add_header 'Access-Control-Max-Age' '86400' always;
                add_header 'Content-Type' 'text/plain; charset=utf-8' always;
                add_header 'Content-Length' '0' always;
                return 204;
            }
            set \$posthog_static "https://$POSTHOG_CLOUD-assets.i.posthog.com";
            # Proxy settings
            proxy_pass \$posthog_static\$uri\$is_args\$args;
            proxy_set_header Host "$POSTHOG_CLOUD-assets.i.posthog.com";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            # SSL settings
            proxy_ssl_server_name on;
            proxy_ssl_name "$POSTHOG_CLOUD-assets.i.posthog.com";
            proxy_ssl_session_reuse on;
            # Cache configuration
            proxy_cache static_cache;
            proxy_cache_key "\$scheme\$proxy_host\$request_uri";
            proxy_cache_valid 200 ${CACHE_STATIC_DAYS}d;
            proxy_cache_valid 404 1h;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            proxy_cache_background_update on;
            proxy_cache_lock on;
            # Connection settings
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            # Timeouts
            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
            # Remove upstream CORS headers
            proxy_hide_header Access-Control-Allow-Origin;
            proxy_hide_header Access-Control-Allow-Credentials;
            proxy_hide_header Access-Control-Allow-Methods;
            proxy_hide_header Access-Control-Allow-Headers;
            proxy_hide_header Access-Control-Expose-Headers;
            # CORS headers
            add_header 'Access-Control-Allow-Origin' \$cors_origin always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH' always;
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Posthog-Version' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
            # Cache headers
            add_header X-Cache-Status \$upstream_cache_status always;
            add_header Cache-Control "public, max-age=604800, immutable" always;
        }
        # Health check endpoint
        location /health {
            access_log off;
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Content-Type' 'text/plain' always;
            return 200 "healthy\n";
        }
    }
}
EOF

echo "=========================================="
echo "Generated nginx.conf:"
echo "=========================================="
cat /etc/nginx/nginx.conf
echo "=========================================="

# Create cache directory
mkdir -p /var/cache/nginx

echo "Testing nginx configuration..."
nginx -t

echo "Starting nginx..."
exec nginx -g "daemon off;"
