#!/bin/sh
# One-off Kanka setup, replacing `artisan kanka:install` (whose key:generate would replace the
# creds-supplied APP_KEY). Skipped once entity types are seeded; migrations already ran (50-*).
set -e
cd /var/www/html
seeded=$(php -r 'require "vendor/autoload.php"; $app = require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); echo App\Models\EntityType::count();')
if [ "$seeded" = "0" ]; then
    php artisan db:seed --force
    php artisan passport:install --force
    php artisan setup:meilisearch
fi
