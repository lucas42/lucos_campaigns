# Stub app: the real gate config in front of an empty webroot, so the gate can be tested without building Kanka.
FROM serversideup/php:8.4-fpm-nginx-v4.5.1@sha256:8e0864511c48a943b59c59c2845eb8de1dc402b6d549a3b2e0e45018f1b99567
ENV SSL_MODE=off
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=www-data:www-data test/gate/favicon.ico /var/www/html/public/favicon.ico
