# Kanka has no production image upstream (docs/running.md): we build it from a pinned source tag.
# Bumping means changing BOTH args: the commit check catches a moved tag.
ARG KANKA_VERSION=3.15
ARG KANKA_COMMIT=79d951798fead551dfbd60d293a6c4695c31c42d

FROM alpine:3.23 AS source
ARG KANKA_VERSION
ARG KANKA_COMMIT
RUN apk add --no-cache git
RUN git clone --quiet --depth 1 --branch "$KANKA_VERSION" https://github.com/owlchester/kanka.git /kanka \
 && test "$(git -C /kanka rev-parse HEAD)" = "$KANKA_COMMIT" \
 && rm -rf /kanka/.git

FROM composer:2 AS composer

FROM serversideup/php:8.4-fpm-nginx-v4.5.1@sha256:8e0864511c48a943b59c59c2845eb8de1dc402b6d549a3b2e0e45018f1b99567 AS vendor
USER root
RUN install-php-extensions gd intl bcmath exif
COPY --from=composer /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
COPY --from=source /kanka/ ./
# Advisory only: upstream's lockfile is invisible to Dependabot here (ADR-0001).
RUN composer audit || true
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

FROM node:24-alpine AS assets
WORKDIR /kanka
COPY --from=source /kanka/ ./
RUN yarn audit || true
RUN yarn install --frozen-lockfile && yarn build

FROM serversideup/php:8.4-fpm-nginx-v4.5.1@sha256:8e0864511c48a943b59c59c2845eb8de1dc402b6d549a3b2e0e45018f1b99567
ARG VERSION
ENV VERSION=$VERSION
USER root
RUN install-php-extensions gd intl bcmath exif
COPY docker/php-lucos.ini /usr/local/etc/php/conf.d/99-lucos.ini
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY docker/45-kanka-storage.sh docker/60-kanka-first-run.sh /etc/entrypoint.d/
RUN chmod +x /etc/entrypoint.d/45-kanka-storage.sh /etc/entrypoint.d/60-kanka-first-run.sh
WORKDIR /var/www/html
COPY --from=vendor --chown=www-data:www-data /var/www/html/ ./
COPY --from=assets --chown=www-data:www-data /kanka/public/build ./public/build
RUN chown -R www-data:www-data bootstrap/cache storage
USER www-data
