#!/usr/bin/env bash
# Expose local Phoenix (default http://127.0.0.1:4000) for Paystack / Safaricom webhooks.
#
# Prerequisites: install one of:
#   - ngrok:   https://ngrok.com/download
#   - cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/
#
# Usage:
#   ./scripts/webhook-dev.sh ngrok
#   ./scripts/webhook-dev.sh cloudflared
#
# Then set (example):
#   export MPESA_STK_CALLBACK_URL="https://YOUR_TUNNEL.ngrok-free.app/webhooks/mpesa"
#   Configure the same URL in Safaricom Daraja (validation may differ per environment).
#
# Paystack: set dashboard webhook URL to https://YOUR_TUNNEL.ngrok-free.app/webhooks/paystack

set -euo pipefail

MODE="${1:-}"

if [[ "$MODE" != "ngrok" && "$MODE" != "cloudflared" ]]; then
  echo "Usage: $0 ngrok|cloudflared"
  exit 1
fi

PORT="${PORT:-4000}"

if [[ "$MODE" == "ngrok" ]]; then
  exec ngrok http "$PORT"
else
  exec cloudflared tunnel --url "http://127.0.0.1:$PORT"
fi
