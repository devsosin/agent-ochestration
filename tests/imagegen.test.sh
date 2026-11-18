#!/bin/bash
# imagegen/server.py against a fake codex (no ChatGPT quota). Runs under macOS /bin/bash 3.2.
set -euo pipefail
T="$(mktemp -d)"; PORT=$((17000 + RANDOM % 1000))
trap 'kill $pid 2>/dev/null && wait $pid 2>/dev/null; rm -rf "$T"' EXIT

# Fake codex: prints thread.started and leaves an image where codex does, or fails if the prompt says so.
cat > "$T/codex" <<'EOF'
#!/bin/bash
for a; do last="$a"; done
case "$last" in *FAIL*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"policy refusal"}}'; exit 0 ;; esac
mkdir -p "$CODEX_HOME/generated_images/t1" && printf 'PNG' > "$CODEX_HOME/generated_images/t1/exec-1.png"
echo '{"type":"thread.started","thread_id":"t1"}'
EOF
chmod +x "$T/codex"
IMAGEGEN_PORT=$PORT IMAGEGEN_DIR="$T/out" CODEX_BIN="$T/codex" CODEX_HOME="$T/codex-home" \
  /usr/bin/python3 "$(dirname "$0")/../imagegen/server.py" 2>"$T/log" & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.3; done

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi; }
call() { curl -fsS "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' -d "$1"; }

check "initialize echoes protocol" "2025-06-18" "$(call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' | jq -r .result.protocolVersion)"
check "notification gets 202" 202 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/mcp" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
check "tools/list" generate_image "$(call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[0].name')"
r="$(call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"generate_image","arguments":{"prompt":"a cup"}}}')"
check "generate ok" false "$(echo "$r" | jq -r .result.isError)"
url="$(echo "$r" | jq -r '.result.content[0].text' | grep -oE "/files/[0-9a-f]{32}\.png" | head -1)"
check "download serves the image" PNG "$(curl -fsS "http://127.0.0.1:$PORT$url")"
check "codex output moved away" no "$([ -e "$T/codex-home/generated_images/t1" ] && echo yes || echo no)"
r="$(call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"generate_image","arguments":{"prompt":"FAIL"}}}')"
check "no image is an error" true "$(echo "$r" | jq -r .result.isError)"
check "error carries codex reply" yes "$(echo "$r" | jq -r '.result.content[0].text' | grep -q 'policy refusal' && echo yes || echo no)"
check "empty prompt rejected" true "$(call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"generate_image","arguments":{}}}' | jq -r .result.isError)"
check "path traversal 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/files/..%2F..%2Fetc%2Fpasswd")"
check "unknown method error" -32601 "$(call '{"jsonrpc":"2.0","id":6,"method":"resources/list"}' | jq -r .error.code)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; cat "$T/log"; exit 1; }
