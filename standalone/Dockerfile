# Alfresco ActiveMQ 6.2.6 with the active/standby (shared-store) config baked in,
# for installs without the Helm chart (plain Docker, Compose, VMs running containers).
#
#   docker build -t alfresco-activemq-ha:6.2.6 standalone
#
# Run the same image on every broker host with one shared directory mounted at
# /mnt/amq-shared (NFSv4/EFS/Filestore/CephFS: it needs POSIX locks across hosts):
#
#   docker run -d --name amq1 -p 61616:61616 \
#     -v /mnt/amq-shared:/mnt/amq-shared \
#     -e ADMIN_PASSWORD=<admin-pw> -e ALFRESCO_PASSWORD=<alfresco-pw> \
#     -e ACTIVEMQ_ADMIN_LOGIN=admin -e ACTIVEMQ_ADMIN_PASSWORD=<admin-pw> \
#     alfresco-activemq-ha:6.2.6
#
# ADMIN_* / ALFRESCO_* fill ${admin.*} / ${alfresco.*} in activemq.xml (Spring maps
# FOO_BAR to foo.bar). ACTIVEMQ_ADMIN_* is read by the base image's entrypoint for the
# web console login. The broker refuses to start if a password is missing.
FROM alfresco/alfresco-activemq:6.2.6-jre17-rockylinux8

ENV ADMIN_USERNAME=admin \
    ALFRESCO_USERNAME=alfresco

COPY --chown=amq:Alfresco --chmod=644 activemq.xml /opt/activemq/conf/activemq.xml

# Mount point for the shared store; the kahadb directory is created by the broker.
USER root
RUN mkdir -p /mnt/amq-shared && chown amq:Alfresco /mnt/amq-shared
USER amq
VOLUME /mnt/amq-shared

# No HEALTHCHECK on purpose: a standby does not listen until it gets the store lock,
# so a port check would report every healthy standby as unhealthy.
