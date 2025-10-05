FROM nginx:alpine

COPY nginx.conf /etc/nginx/nginx.conf.template

CMD ["sh", "-c", "envsubst '\\$POSTHOG_CLOUD_REGION' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
