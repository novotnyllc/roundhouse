# roundhouse — the hostname a configured machine's identity binds to.
#
# `expected_hostname` is compared with what this host answers to. By default
# that is the OS hostname. A host whose OS hostname is not stable — a box
# that is replaced with a new instance (and a new hostname) while its
# Tailscale node and state carry over — sets `hostname_source: "tailscale"`
# on its (local) machine entry, and then answers with its Tailscale machine
# name: the first label of `tailscale status --self --json`'s Self.DNSName.
# A name that cannot be read answers nothing, so the identity check FAILS;
# it never falls back to the OS hostname.
#
# Sourced by scripts/roundhouse and scripts/collect-posix after
# lib/timeout.sh; definitions only.
# shellcheck shell=bash

host_identity_tailscale_name() {
  # This node's Tailscale machine name, or exit 1.
  command -v tailscale >/dev/null 2>&1 || return 1
  hi_status=$(run_bounded 15 tailscale status --self --json 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$hi_status" | jq -er '
    (.Self.DNSName // "") | split(".")[0] |
    select(test("^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"))' 2>/dev/null
}

host_identity_hostname() {
  # host_identity_hostname CONFIG TARGET -> the name this host answers to
  # for TARGET's expected_hostname (see above), or exit 1. An unreadable
  # config or an entry without `hostname_source` is the OS hostname, as
  # before this setting existed.
  hi_source=$(jq -r --arg t "$2" '.machines[$t].hostname_source // "os"' "$1" 2>/dev/null) ||
    hi_source=os
  case $hi_source in
    tailscale) host_identity_tailscale_name ;;
    *) hostname ;;
  esac
}
