#!/bin/sh
# Kanka encrypts with AES-256-CBC, so APP_KEY must be "base64:" plus 32 bytes. A wrong one boots fine and only breaks the first logged-in request.
# Decode with PHP's base64_decode, as Laravel's EncryptionServiceProvider does, so this can never reject a key Laravel would accept.
case "${APP_KEY:-}" in
    base64:?*) ;;
    *) echo "APP_KEY must be 'base64:' followed by 32 random bytes, base64-encoded (generate with: openssl rand -base64 32); it is unset, empty or lacks the 'base64:' prefix." >&2; exit 1 ;;
esac
bytes=$(php -r 'echo strlen((string) base64_decode(substr(getenv("APP_KEY"), 7)));')
if [ "$bytes" != 32 ]; then
    echo "APP_KEY must decode to 32 bytes but decodes to ${bytes:-?} (generate with: openssl rand -base64 32)." >&2
    exit 1
fi
