#!/bin/bash
# Installs the standalone test dependencies in a Claude Code on the web session, so that
# `bundle exec rspec spec/lib spec/repo` works from the first turn instead of costing
# turns of setup. Local sessions manage their own gems. Idempotent: bundler is a no-op
# when the bundle is already satisfied. The Discourse-tier specs need a Discourse
# checkout and are not set up here.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"
if ! command -v bundle >/dev/null 2>&1; then
  echo "session-start: bundler is not installed; run the tests after installing it" >&2
  exit 0
fi
bundle install --quiet >&2
