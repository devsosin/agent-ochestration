# Exports the account tokens that compose mounts as secrets. Sourced by agent-run and bash shells.
if [ -s /run/secrets/claude_token ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_token)"; export CLAUDE_CODE_OAUTH_TOKEN
fi
if [ -s /run/secrets/gh_token ]; then
  GH_TOKEN="$(cat /run/secrets/gh_token)"; export GH_TOKEN
fi
