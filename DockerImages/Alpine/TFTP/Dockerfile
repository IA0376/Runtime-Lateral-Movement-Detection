FROM alpine:3.20

RUN apk add --no-cache tftp-hpa

CMD ["in.tftpd", "--foreground", "--verbose", "--secure", "/opt/pxe/tftp"]