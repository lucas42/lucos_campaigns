# Kanka has no production image upstream (docs/running.md): we build it from a pinned source tag.
# Bumping means changing BOTH args: the commit check catches a moved tag.
ARG KANKA_VERSION=3.15
ARG KANKA_COMMIT=79d951798fead551dfbd60d293a6c4695c31c42d

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS source
ARG KANKA_VERSION
ARG KANKA_COMMIT
RUN apk add --no-cache git
RUN git clone --quiet --depth 1 --branch "$KANKA_VERSION" https://github.com/owlchester/kanka.git /kanka \
 && test "$(git -C /kanka rev-parse HEAD)" = "$KANKA_COMMIT" \
 && rm -rf /kanka/.git

FROM composer:2@sha256:9715c7f69044da2a212a5fbde29ee7da24e364d426560ae6367b060236f847d7 AS composer

FROM serversideup/php:8.5-fpm-nginx-v4.5.1@sha256:531f20f5e74eb834de878ea8b5bcb6fd43923828b20e96783e97445273a705a5 AS vendor
USER root
RUN install-php-extensions gd intl bcmath exif
COPY --from=composer /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
COPY --from=source /kanka/ ./
# Advisory only: upstream's lockfile is invisible to Dependabot here (ADR-0001).
RUN composer audit || true
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS assets
WORKDIR /kanka
COPY --from=source /kanka/ ./
RUN yarn audit || true
RUN yarn install --frozen-lockfile && yarn build

FROM serversideup/php:8.5-fpm-nginx-v4.5.1@sha256:531f20f5e74eb834de878ea8b5bcb6fd43923828b20e96783e97445273a705a5
ARG VERSION
ENV VERSION=$VERSION
USER root
RUN install-php-extensions gd intl bcmath exif
COPY docker/php-lucos.ini /usr/local/etc/php/conf.d/99-lucos.ini
COPY docker/php-fpm-lucos.conf /usr/local/etc/php-fpm.d/zzz-lucos.conf
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY docker/45-kanka-storage.sh docker/60-kanka-first-run.sh /etc/entrypoint.d/
RUN chmod +x /etc/entrypoint.d/45-kanka-storage.sh /etc/entrypoint.d/60-kanka-first-run.sh
WORKDIR /var/www/html
COPY --from=vendor --chown=www-data:www-data /var/www/html/ ./
COPY --from=assets --chown=www-data:www-data /kanka/public/build ./public/build
COPY --chown=www-data:www-data docker/_info.php ./public/_info.php
RUN chown -R www-data:www-data bootstrap/cache storage
# Icon fallback for the Free-only stylesheet Kanka loads without a kit. Fails the build if an upgrade moves these files.
COPY docker/fontawesome-free-fallback.css /tmp/fontawesome-free-fallback.css
RUN fa=public/vendor/fontawesome/6.0.0 \
 && test -f "$fa/css/all.min.css" && test -f "$fa/webfonts/fa-solid-900.woff2" \
 && { echo; cat /tmp/fontawesome-free-fallback.css; } >> "$fa/css/all.min.css" \
 && rm /tmp/fontawesome-free-fallback.css
USER www-data
