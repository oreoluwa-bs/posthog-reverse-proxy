# PostHog Nginx Reverse Proxy

This Docker container provides a secure nginx reverse proxy for PostHog analytics, configured to handle CORS issues and domain-based routing for multiple domains and all their subdomains.

## Fork

https://gist.github.com/hiteshjoshi/573beaab02e2937e45d92fc1da07d7e4

## Problem This Solves

When using PostHog from multiple domains or their subdomains, you may encounter:

- CORS policy blocks: `No 'Access-Control-Allow-Origin' header is present`
- 403 Forbidden errors due to referer validation
- SSL handshake failures
- DNS resolution issues with PostHog's rotating IPs

## Key Features

### Dynamic Multi-Domain CORS Support

The proxy automatically allows CORS requests from:

- **Multiple main domains** (e.g., `example.com`, `myapp.org`, `company.io`)
- **All subdomains** of each domain (e.g., `app.example.com`, `api.myapp.org`)
- **Nested subdomains** (e.g., `staging.api.example.com`)
- **Localhost for development**

No need to hardcode specific origins - just list your base domains!

## Quick Start

```bash
# Build and run the proxy
docker-compose up -d

# Check logs
docker-compose logs -f

# Test the proxy
curl -I http://localhost:8080/health
```

## Configuration

### Environment Variables

| Variable            | Default                  | Description                                                                        |
| ------------------- | ------------------------ | ---------------------------------------------------------------------------------- |
| `ALLOWED_DOMAINS`   | `google.com,example.com` | Comma-separated list of allowed domains. All subdomains are automatically allowed. |
| `POSTHOG_CLOUD`     | `us`                     | PostHog cloud region (`us` or `eu`).                                               |
| `CACHE_STATIC_DAYS` | `7`                      | Number of days to cache static assets.                                             |

### PostHog Client Configuration

Configure your PostHog client to use your proxy from any of your domains:

```javascript
// From any allowed domain (example.com, myapp.org, etc.)
posthog.init("YOUR_API_KEY", {
  api_host: "https://analytics.yourdomain.com", // Your proxy URL
  ui_host: "https://app.posthog.com",
});

// Works from all subdomains automatically
// app.example.com, api.myapp.org, staging.company.io, etc.
```

## How It Works

### Dynamic Multi-Domain CORS Origin Detection

The proxy uses nginx's `map` directive to dynamically validate origins:

1. Parses the comma-separated `ALLOWED_DOMAINS` list
2. Checks if the request origin matches any base domain or subdomain
3. If valid, sets appropriate CORS headers with that origin
4. Handles preflight OPTIONS requests automatically
5. Removes conflicting headers from upstream PostHog

### Allowed Origins Examples

For `ALLOWED_DOMAINS=example.com,myapp.org,company.io`, the following origins are automatically allowed:

**Main domains:**

- `https://example.com`
- `https://myapp.org`
- `https://company.io`

**All subdomains:**

- `https://*.example.com` (app.example.com, www.example.com, etc.)
- `https://*.myapp.org` (api.myapp.org, admin.myapp.org, etc.)
- `https://*.company.io` (dashboard.company.io, metrics.company.io, etc.)

**Nested subdomains:**

- `https://*.*.example.com` (staging.api.example.com, dev.app.example.com, etc.)
- `https://*.*.myapp.org` (test.backend.myapp.org, etc.)

**Development:**

- `http://localhost:3000` (any port)
- `http://127.0.0.1:8080` (any port)

## CORS Troubleshooting

### Issue: "Access to script blocked by CORS policy"

The proxy automatically handles CORS for all configured domains. If you still see this error:

1. **Verify your domain configuration**:

   ```bash
   # Check the container environment
   docker-compose exec posthog-proxy env | grep ALLOWED_DOMAINS
   ```

2. **Test with curl for each domain**:

   ```bash
   # Test from first domain
   curl -I -H "Origin: https://example.com" \
        -H "Referer: https://example.com" \
        http://localhost:8080/static/array.js

   # Test from second domain's subdomain
   curl -I -H "Origin: https://app.myapp.org" \
        -H "Referer: https://app.myapp.org/dashboard" \
        http://localhost:8080/static/array.js

   # Test from third domain
   curl -I -H "Origin: https://company.io" \
        -H "Referer: https://company.io" \
        http://localhost:8080/static/array.js
   ```

3. **Check response headers**:
   Look for these headers in the response:
   - `Access-Control-Allow-Origin: [matching origin]`
   - `Access-Control-Allow-Credentials: true`

### Issue: "403 Forbidden"

The proxy validates both referer and origin. It allows:

- Empty referer (direct access)
- Any request from your configured domains
- Any request from their subdomains
- Localhost for development
- All OPTIONS requests

### Debugging Steps

1. **Enable debug logging** and check the logs:

   ```bash
   docker-compose logs -f posthog-proxy | grep -E "(Origin:|Referer:)"
   ```

2. **Verify headers in browser**:
   - Open DevTools Network tab
   - Look for the failed request
   - Check Request Headers for Origin and Referer
   - Check Response Headers for CORS headers

3. **Test preflight request**:
   ```bash
   curl -I -X OPTIONS \
     -H "Origin: https://app.example.com" \
     -H "Access-Control-Request-Method: POST" \
     -H "Access-Control-Request-Headers: Content-Type" \
     http://localhost:8080/decide/
   ```

## Deployment Examples

### Basic Docker Compose (Multiple Domains)

```yaml
version: "3.8"
services:
  posthog-proxy:
    build: .
    ports:
      - "8080:8080"
    environment:
      - ALLOWED_DOMAINS=example.com,myapp.org,company.io
      - POSTHOG_CLOUD=us
    restart: unless-stopped
```

### Behind Traefik (Single Analytics Domain)

```yaml
services:
  posthog-proxy:
    build: .
    environment:
      - ALLOWED_DOMAINS=example.com,myapp.org,company.io
      - POSTHOG_CLOUD=us
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.posthog.rule=Host(`analytics.yourdomain.com`)"
      - "traefik.http.routers.posthog.tls=true"
      - "traefik.http.services.posthog.loadbalancer.server.port=8080"
```

### On Kubernetes (Multiple Domains)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: posthog-proxy-config
data:
  ALLOWED_DOMAINS: "example.com,myapp.org,company.io"
  POSTHOG_CLOUD: "us"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: posthog-proxy
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: nginx
          image: your-registry/posthog-proxy:latest
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: posthog-proxy-config
```

## Advanced Features

### Request Flow

1. Client makes request from any configured domain or subdomain
2. Nginx validates both Origin and Referer headers against all allowed domains
3. For valid origins, appropriate CORS headers are added
4. Static assets are cached for performance
5. All requests are proxied to PostHog with proper headers

### Security Features

- **Multi-domain validation**: Only your configured domains and their subdomains are allowed
- **No hardcoded origins**: Dynamically validates based on domain list
- **Header sanitization**: Removes conflicting upstream headers
- **Secure defaults**: Credentials required for CORS requests

### Performance Features

- **Static asset caching**: 7-day cache for JS/CSS files
- **Connection pooling**: Keepalive connections to PostHog
- **DNS caching**: 5-minute DNS cache with re-resolution
- **Stale content serving**: Serves cached content during outages

## Testing Different Scenarios

### Test from Different Domains

```bash
# First domain - main
curl -v -H "Origin: https://example.com" \
     -H "Referer: https://example.com" \
     http://localhost:8080/decide/

# First domain - subdomain
curl -v -H "Origin: https://app.example.com" \
     -H "Referer: https://app.example.com/dashboard" \
     http://localhost:8080/static/array.js

# Second domain - nested subdomain
curl -v -H "Origin: https://staging.api.myapp.org" \
     -H "Referer: https://staging.api.myapp.org" \
     http://localhost:8080/batch/

# Third domain - main
curl -v -H "Origin: https://company.io" \
     -H "Referer: https://company.io" \
     http://localhost:8080/static/recorder.js
```

### Test from Localhost (Development)

```bash
curl -v -H "Origin: http://localhost:3000" \
     -H "Referer: http://localhost:3000" \
     http://localhost:8080/static/recorder.js
```

## Monitoring

### Log Format

```
[01/Jan/2024:12:00:00 +0000] "GET /static/array.js HTTP/1.1" 200 "Referer: https://app.example.com/dashboard" "Origin: https://app.example.com" "Host: analytics.yourdomain.com" "Cache: HIT"
```

### Health Check

```bash
curl http://localhost:8080/health
# Returns: healthy
```

### Cache Status

- `HIT`: Served from cache
- `MISS`: Fetched from PostHog
- `UPDATING`: Serving stale while updating
- `STALE`: Serving stale due to error

## Migration Guide

### From Single Domain to Multiple Domains

If you're upgrading from the single-domain version:

1. **Change environment variable name**:

   ```yaml
   # Old
   ALLOWED_DOMAIN: "example.com"

   # New (supports multiple domains)
   ALLOWED_DOMAINS: "example.com,myapp.org,company.io"
   ```

2. **Single domain still works**:

   ```yaml
   # This works fine for backward compatibility
   ALLOWED_DOMAINS: "example.com"
   ```

3. **No client-side changes needed** - your existing PostHog configurations will continue to work

## Common Issues and Solutions

### 1. CORS Headers Not Appearing

**Check**: Ensure the Origin header is being sent by the browser

```bash
# This won't have CORS headers (no Origin)
curl http://localhost:8080/static/array.js

# This will have CORS headers
curl -H "Origin: https://example.com" http://localhost:8080/static/array.js
```

### 2. Works from Some Domains but Not Others

Verify all domains are in the comma-separated list:

```bash
# Check configuration
docker-compose exec posthog-proxy env | grep ALLOWED_DOMAINS

# Should show something like:
# ALLOWED_DOMAINS=example.com,myapp.org,company.io
```

### 3. Subdomain Not Working

All subdomains of configured domains work automatically. If not:

- Check for typos in the domain
- Ensure you're using HTTPS/HTTP consistently
- Verify the base domain is in ALLOWED_DOMAINS
- Check that there are no spaces in the comma-separated list

### 4. Development Environment Issues

For local development, the proxy allows:

- `http://localhost` (any port)
- `http://127.0.0.1` (any port)

No additional configuration needed!

## Support

For issues:

1. Check logs: `docker-compose logs -f posthog-proxy`
2. Verify all domains are correctly listed in ALLOWED_DOMAINS
3. Test with curl to isolate browser issues
4. Ensure PostHog services are operational

For PostHog-specific issues, refer to their documentation at https://posthog.com/docs
