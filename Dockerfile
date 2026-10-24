# pg_dump 18 can dump both production servers (emr-be's is 17, admin-api's is 18).
FROM postgres:18-alpine

RUN apk add --no-cache age aws-cli curl

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Run as the image's unprivileged user and skip the image's server entrypoint.
USER postgres
ENTRYPOINT []
CMD ["/usr/local/bin/backup.sh"]
