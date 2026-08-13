# The gateway. Serves the landing page and routes everything else.
ARG BASE_IMAGE=ghcr.io/Davewst/opslab-base:latest
FROM ${BASE_IMAGE}
COPY --chown=101:101 landing/ /usr/share/nginx/html/
COPY deploy/gateway.nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy/proxy-common.conf /etc/nginx/proxy-common.conf
USER 101
