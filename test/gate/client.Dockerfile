FROM alpine:3.23
RUN apk add --no-cache curl
COPY test/gate/assertions.sh /assertions.sh
ENTRYPOINT ["sh", "/assertions.sh"]
