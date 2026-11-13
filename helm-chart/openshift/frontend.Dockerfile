# Build a restricted-v2-compatible CVAT UI image from the pinned upstream UI.
# Build from the repository root so the OpenShift nginx configuration is in context.
FROM cvat/ui:v2.24.0

# The stock nginx config binds port 80 and writes its pid under /var/run.
# The Docker entrypoint's IPv6 helper edits the default config for port 80, so
# remove it; nginx then runs as the arbitrary UID assigned by OpenShift.
RUN rm -f /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
COPY helm-chart/openshift/nginx.conf /etc/nginx/nginx.conf
COPY helm-chart/openshift/default.conf /etc/nginx/conf.d/default.conf
