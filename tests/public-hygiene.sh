#!/usr/bin/env bash
set -euo pipefail

echo "🔐 Checking repository for obvious secrets or personal-email patterns..."

if grep -RInE   --exclude-dir=.git   'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}|ghp_[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|@gmail\.com|@outlook\.com|@icloud\.com' .; then
  echo "❌ Potential secret or personal email found."
  exit 1
fi

echo "✅ No obvious credential/private-email patterns found."
