#!/bin/sh
# Idempotent Kanka setup replacing `artisan kanka:install` (its key:generate would overwrite the
# creds-supplied APP_KEY). Each step is gated on its own evidence, so a failure part-way is retried
# on the next start. Migrations already ran (50-*).
set -e
cd /var/www/html
count() { php -r 'require "vendor/autoload.php"; $app = require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); echo '"$1"';'; }

[ "$(count 'App\Models\EntityType::count()')" != "0" ] || php artisan db:seed --force

[ -f storage/oauth-private.key ] && [ -f storage/oauth-public.key ] || php artisan passport:keys --force >/dev/null
[ "$(count 'Laravel\Passport\Client::count()')" != "0" ] || php artisan passport:client --personal --name=Campaigns --no-interaction >/dev/null

# setup:meilisearch rebuilds from scratch, so only run it when the index or our done-marker is missing.
index=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $MEILISEARCH_KEY" "$MEILISEARCH_HOST/indexes/entities" || true)
if [ "$index" != "200" ] || [ ! -f storage/.search-indexed ]; then
    php artisan setup:meilisearch
    touch storage/.search-indexed
fi
