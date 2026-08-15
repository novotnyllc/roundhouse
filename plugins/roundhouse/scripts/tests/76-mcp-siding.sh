# roundhouse self-check — mcp-siding.mjs's own built-in self-test as a gate.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

# mcp-siding.mjs carries its own real assertions (timeouts, SSE
# correlation, cache integrity, the resolver, a hostile --name, a path
# containing a space) behind `--selftest`, but nothing ran it as part of
# the release gate until this section - use $real_node, not a bare `node`,
# since other sections in this suite stub PATH.
mcp_siding_out=$("$real_node" "$script_dir/mcp-siding.mjs" --selftest 2>&1) ||
  fail "mcp-siding.mjs --selftest failed:
$mcp_siding_out"
assert_contains "$mcp_siding_out" 'selftest ok'
