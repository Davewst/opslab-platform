FROM alpine:3.21
RUN apk add --no-cache tinyproxy=1.11.2-r0 || apk add --no-cache tinyproxy
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter /etc/tinyproxy/filter
USER tinyproxy
EXPOSE 8888
CMD ["tinyproxy","-d"]
