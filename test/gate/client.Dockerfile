FROM alpine:3.24
RUN apk add --no-cache curl jq
COPY test/gate/assertions.sh /assertions.sh
COPY test/full/assertions.sh /full-assertions.sh
ENTRYPOINT ["sh", "/assertions.sh"]
