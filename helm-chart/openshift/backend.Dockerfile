FROM cvat/server:v2.24.0

# Make the application entrypoint and immutable application files traversable
# by OpenShift's namespace-assigned UID. Writable application data remains on
# the mounted EFS volume; supervisor runtime files use /tmp.
USER 0
RUN chmod -R a+rX /home/django \
    && chmod 1777 /home/django/static \
    && mkdir -p /tmp/supervisord \
    && chmod 1777 /tmp/supervisord
USER 1000
