# Stub app: the real gate config in front of an empty webroot, so the gate can be tested without building Kanka.
FROM serversideup/php:8.5-fpm-nginx-v4.5.1@sha256:531f20f5e74eb834de878ea8b5bcb6fd43923828b20e96783e97445273a705a5
ENV SSL_MODE=off
COPY docker/php-fpm-lucos.conf /usr/local/etc/php-fpm.d/zzz-lucos.conf
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=www-data:www-data test/gate/favicon.ico /var/www/html/public/favicon.ico
# The real script with no Kanka behind it: exercises routing and the app-failed-to-boot path.
COPY --chown=www-data:www-data docker/_info.php /var/www/html/public/_info.php
# Stub front controller: lets the authenticated phase see a request reach PHP.
COPY --chown=www-data:www-data test/gate/index.php /var/www/html/public/index.php
# Authenticated phase points the gate at a stub auth backend instead of the real sidecar.
ARG AUTH_UPSTREAM=http://lucos_campaigns_auth:4180
RUN sed -i "s#http://lucos_campaigns_auth:4180#${AUTH_UPSTREAM}#" /etc/nginx/conf.d/default.conf
