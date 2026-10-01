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
# Kanka's mail config hardcodes verify_peer=false and never requires TLS; fail the build if this edit stops matching.
RUN sed -i "s/^    'verify_peer' => false,\$/    'verify_peer' => true,\\n    'require_tls' => true,\\n    'timeout' => 10,/" /kanka/config/mail.php \
 && grep -q "^    'verify_peer' => true,\$" /kanka/config/mail.php \
 && grep -q "^    'require_tls' => true,\$" /kanka/config/mail.php \
 && grep -q "^    'timeout' => 10,\$" /kanka/config/mail.php \
 && ! grep -q "'verify_peer' => false" /kanka/config/mail.php

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

FROM node:26-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80 AS assets
# node 25+ images no longer bundle yarn; pin the classic version node:24 shipped.
RUN npm install --global yarn@1.22.22
WORKDIR /kanka
COPY --from=source /kanka/ ./
RUN yarn audit || true
RUN yarn install --frozen-lockfile
# Pinned-property stat block (docker/lucos-statblock.css) and the pencil's Free font fallback. Fails the build if upstream moves any markup or CSS these rely on.
COPY docker/lucos-statblock.css /kanka/resources/css/lucos-statblock.css
RUN a=resources/css/attributes/attributes.css m=resources/css/app.css \
      p=resources/views/entities/components/pins.blade.php b=resources/views/entities/components/attributes.blade.php \
 && test "$(grep -c 'font-family: "Font Awesome 6 Pro";' $a)" = 1 \
 && test "$(grep -c '^@import "./attributes/attributes.css";' $m)" = 1 \
 && test "$(grep -c 'class="pins flex flex-col gap-2"' $p)" = 1 \
 && test "$(grep -cF 'data-attribute="{{ $attribute->name }}"' $b)" = 1 \
 && grep -q 'pinned-attribute-section' $b \
 && sed -i 's/font-family: "Font Awesome 6 Pro";/font-family: "Font Awesome 6 Pro", "Font Awesome 6 Free";/' $a \
 && sed -i 's#^@import "./attributes/attributes.css";#&\n@import "./lucos-statblock.css";#' $m \
 && grep -q '"Font Awesome 6 Free";' $a && grep -q 'lucos-statblock.css' $m
RUN yarn build \
 && grep -lq 'data-attribute="STR mod"' public/build/assets/app-*.css \
 && grep -q 'font-family:"Font Awesome 6 Pro","Font Awesome 6 Free"' public/build/assets/app-*.css

FROM serversideup/php:8.5-fpm-nginx-v4.5.1@sha256:531f20f5e74eb834de878ea8b5bcb6fd43923828b20e96783e97445273a705a5
ARG VERSION
ENV VERSION=$VERSION
USER root
RUN install-php-extensions gd intl bcmath exif
COPY docker/php-lucos.ini /usr/local/etc/php/conf.d/99-lucos.ini
COPY docker/php-fpm-lucos.conf /usr/local/etc/php-fpm.d/zzz-lucos.conf
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY docker/2-kanka-check-app-key.sh docker/45-kanka-storage.sh docker/60-kanka-first-run.sh /etc/entrypoint.d/
RUN chmod +x /etc/entrypoint.d/2-kanka-check-app-key.sh /etc/entrypoint.d/45-kanka-storage.sh /etc/entrypoint.d/60-kanka-first-run.sh
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
# Kanka's command search lists the plugins page even though its route only exists with the marketplace on (ADR-0001 leaves it off). Fails the build if upstream changes or fixes it.
RUN f=app/Services/Search/AdminPageService.php \
 && test "$(grep -c "route('campaign_plugins.index', \$campaign)" "$f")" = 1 \
 && perl -0pi -e "s/(\n\s*)(\[\n[^\[\]]*?campaign_plugins\.index[^\[\]]*?\]),/\$1...(config('marketplace.enabled') ? [\$2] : []),/" "$f" \
 && grep -q "config('marketplace.enabled')" "$f" && php -l "$f"
# Kanka's tooltip allow-list strips list markup, leaving mentions as loose flex items on their own line. Fails the build if upstream changes or fixes it.
RUN f=config/purify.php \
 && test "$(grep -c "^ *'p', 'div', 'span',\$" "$f")" = 1 \
 && sed -i "s/^\( *\)'p', 'div', 'span',\$/&\n\1'ul', 'ol', 'li', 'em', 'blockquote',/" "$f" \
 && grep -q "'ul', 'ol', 'li', 'em', 'blockquote'," "$f" && php -l "$f"
# Kanka's Relations table "Location" column looks up Location by the target's entity_id, so non-location targets show an unrelated location. Render their real entity_locations instead. Fails the build if upstream changes or fixes it.
RUN l=app/Renderers/Layouts/Entity/Relation.php c=app/Http/Controllers/Entity/RelationController.php \
 && test "$(grep -c "'render' => Standard::LOCATION," "$l")" = 1 \
 && test "$(grep -c "'target.location' => fn" "$c")" = 1 \
 && test "$(grep -c "'target.location.entity' => fn" "$c")" = 1 \
 && sed -i "s/'render' => Standard::LOCATION,/'render' => Standard::ENTITY_LOCATIONS,/" "$l" \
 && sed -i "/'target.location.entity' => fn/d; s/'target.location' => fn (\$sub) => \$sub->select('id'),/'target.locations',/" "$c" \
 && grep -q "'target.locations'," "$c" && grep -q "Standard::ENTITY_LOCATIONS" "$l" && php -l "$l" && php -l "$c"
USER www-data
