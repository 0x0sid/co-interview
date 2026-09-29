#!/bin/sh
# Release safety check — the "Release safety check" build phase of the app target.
#
# Fails a Release build (TestFlight / App Store) that would ship:
#   - no RevenueCat key, or a Test Store key (test_…) instead of the App Store key (appl_…);
#   - a billing mode other than app-store;
#   - no production backend URL (CopilotBackendURL, https) in the built Info.plist;
#   - a bundle identifier other than io.neverblank.app, an app name other than Neverblank, or no
#     https Privacy Policy / Terms of Use link (the paywall must show both for App Review);
#   - a backend or provider credential: token build settings, token-shaped Info.plist entries,
#     an OpenRouter-shaped key, or any operator token / provider key from the local backend/.env.
#
# Other configurations pass through untouched. It never prints a secret value.
set -u
[ "${CONFIGURATION:-}" = "Release" ] || exit 0

failed=0
fail() { echo "error: Release safety check: $1"; failed=1; }

key="${REVENUECAT_API_KEY:-}"
case "$key" in
  "") fail "REVENUECAT_API_KEY is empty. Set the RevenueCat App Store public SDK key (appl_…) in prompter/Config/Release.xcconfig or Local-Release.xcconfig." ;;
  test_*) fail "REVENUECAT_API_KEY is a RevenueCat Test Store key (test_…); Release needs the App Store key (appl_…)." ;;
  appl_*) ;;
  *) fail "REVENUECAT_API_KEY is not a RevenueCat App Store key (appl_…)." ;;
esac

[ "${BILLING_STORE_MODE:-}" = "app-store" ] || fail "BILLING_STORE_MODE is '${BILLING_STORE_MODE:-}', not app-store."

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
url=$(/usr/libexec/PlistBuddy -c "Print :CopilotBackendURL" "$plist" 2>/dev/null || true)
case "$url" in
  https://*localhost*|https://127.*|https://*.local|https://*.local/*|https://*ngrok*|https://*trycloudflare*)
    fail "the backend URL in the built Info.plist is a development host, not production." ;;
  https://?*.?*) ;;
  *) fail "the production backend URL (NEVERBLANK_BACKEND_HOST → CopilotBackendURL, https://…) is missing or invalid in the built Info.plist." ;;
esac

# Identity and App Review essentials.
[ "${PRODUCT_BUNDLE_IDENTIFIER:-}" = "io.neverblank.app" ] || fail "PRODUCT_BUNDLE_IDENTIFIER is '${PRODUCT_BUNDLE_IDENTIFIER:-}', not io.neverblank.app."
for entry in CFBundleDisplayName CFBundleName; do
  name=$(/usr/libexec/PlistBuddy -c "Print :$entry" "$plist" 2>/dev/null || true)
  [ "$name" = "Neverblank" ] || fail "$entry in the built Info.plist is '$name', not Neverblank."
done
for entry in NeverblankPrivacyURL NeverblankTermsURL; do
  link=$(/usr/libexec/PlistBuddy -c "Print :$entry" "$plist" 2>/dev/null || true)
  case "$link" in
    https://?*.?*) ;;
    *) fail "$entry is missing (an https URL is required on the paywall for App Review). Set the matching NEVERBLANK_*_URL setting for Release." ;;
  esac
done

# Build settings that must never carry a value in Release.
for name in COPILOT_DEV_BACKEND_HOST COPILOT_DEV_BACKEND_TOKEN COINTERVIEW_TOKEN COINTERVIEW_TOKENS \
            OPERATOR_TOKEN OPENROUTER_API_KEY; do
  eval "value=\${$name:-}"
  [ -z "$value" ] || fail "build setting $name is set for Release."
done

# Info.plist: no token-named entry, no provider- or Test-Store-shaped value.
if /usr/bin/plutil -p "$plist" 2>/dev/null | grep -iqE '"[^"]*token[^"]*" =>'; then
  fail "the built Info.plist has a token entry."
fi
if /usr/bin/plutil -p "$plist" 2>/dev/null | grep -qE '=> "(sk-|test_)'; then
  fail "the built Info.plist carries a provider-key or Test Store key value."
fi

# The app bundle: no OpenRouter-shaped key, and none of the operator tokens or provider keys this
# machine's backend uses (read from backend/.env, compared without printing).
app="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
if [ -d "$app" ] && grep -r -a -q -E 'sk-or-v1-[A-Za-z0-9]{20,}' "$app" 2>/dev/null; then
  fail "the app bundle contains an OpenRouter-shaped key."
fi
env_file="${SRCROOT}/backend/.env"
if [ -d "$app" ] && [ -f "$env_file" ]; then
  secrets=$(grep -E '^(COINTERVIEW_TOKENS|OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|REVENUECAT_SECRET_KEY|REVENUECAT_API_KEY_SECRET)=' "$env_file" \
            | sed -E 's/^[A-Z_]+=//' | tr ',' '\n' | tr -d '"'"'"' \r' | awk 'length($0) >= 16')
  found=0
  for secret in $secrets; do
    if grep -r -a -q -F -- "$secret" "$app" 2>/dev/null; then found=1; fi
  done
  [ "$found" -eq 0 ] || fail "the app bundle contains a token or key from backend/.env."
fi

if [ "$failed" -ne 0 ]; then exit 1; fi
echo "Release safety check passed: App Store billing, production backend, no bundled credentials."
