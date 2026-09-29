#!/bin/sh
# storage/ is a named volume (uploads + Passport keys); recreate the dirs Laravel expects.
mkdir -p storage/app/public storage/logs storage/framework/cache/data storage/framework/sessions storage/framework/views
