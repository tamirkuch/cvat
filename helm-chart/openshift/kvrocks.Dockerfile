FROM apache/kvrocks:2.7.0

# Kvrocks writes its PID file in /var/lib/kvrocks while its data directory is
# mounted separately at /var/lib/kvrocks/data. Permit the SCC-assigned UID to
# create that runtime file without changing the PVC ownership.
USER 0
RUN chmod 0777 /var/lib/kvrocks \
    && chmod 1777 /var/run/kvrocks /tmp
USER 1001
