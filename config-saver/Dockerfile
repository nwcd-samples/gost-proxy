FROM alpine:3.20
RUN apk add --no-cache curl yq busybox-extras
COPY entrypoint.sh /app/entrypoint.sh
COPY cgi-bin /app/cgi-bin
RUN chmod +x /app/entrypoint.sh /app/cgi-bin/*
EXPOSE 8888
ENTRYPOINT ["/app/entrypoint.sh"]
