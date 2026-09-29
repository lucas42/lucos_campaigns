#!/bin/sh
# Kanka encrypts with AES-256-CBC, so APP_KEY must be "base64:" plus 32 bytes. A wrong one boots fine and only breaks the first logged-in request.
key="${APP_KEY:-}"
case "$key" in
    base64:?*) ;;
    *) echo "APP_KEY must be 'base64:' followed by 32 random bytes, base64-encoded (generate with: openssl rand -base64 32); it is unset, empty or lacks the 'base64:' prefix." >&2; exit 1 ;;
esac
encoded="${key#base64:}"
if ! printf %s "$encoded" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$'; then
    echo "APP_KEY is not valid base64 after the 'base64:' prefix (generate with: openssl rand -base64 32)." >&2
    exit 1
fi
bytes=$(printf %s "$encoded" | base64 -d 2>/dev/null | wc -c)
if [ "$bytes" -ne 32 ]; then
    echo "APP_KEY must decode to 32 bytes but decodes to $bytes (generate with: openssl rand -base64 32)." >&2
    exit 1
fi
