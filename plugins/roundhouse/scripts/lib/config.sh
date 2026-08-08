# roundhouse — configuration location and validation, privilege policy and
# constraint validation, and the remote worker configuration.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

config_path() {
  if [ -n "${ROUNDHOUSE_CONFIG:-}" ]; then
    printf '%s\n' "$ROUNDHOUSE_CONFIG"
  else
    printf '%s/roundhouse/config.json\n' "${XDG_CONFIG_HOME:-"$HOME/.config"}"
  fi
}

validate_privilege_policy_file() (
  policy=$1
  label=${2:-privilege policy}
  [ -f "$policy" ] && [ ! -L "$policy" ] || {
    printf 'roundhouse: %s must be a regular non-symlink file\n' "$label" >&2
    return 64
  }
  [ "$(wc -c <"$policy" | tr -d ' ')" -le 4096 ] &&
    [ "$(tail -c 1 "$policy" | wc -l | tr -d ' ')" -eq 1 ] &&
    LC_ALL=C awk -F '|' '
      BEGIN {
        expected["apt.autoremove.v1"] = "posix-root-v1|none"
        expected["apt.install-package-version.v1"] = "posix-root-v1|package-source-version-closure-set-sha256"
        expected["apt.update-metadata.v1"] = "posix-root-v1|none"
        expected["apt.upgrade-package.v1"] = "posix-root-v1|package-source-channel-set-sha256"
        expected["macos.apply-system-setting.v1"] = "macos-root-v1|macos-system-setting-sha256"
        expected["macos.install-signed-pkg.v1"] = "macos-root-v1|macos-signed-pkg-sha256"
        expected["profile.apply-managed-bundle.v1"] = "windows-user-s4u-v1|profile-bundle-set-sha256"
        expected["profile.inventory-managed-state.v1"] = "windows-user-s4u-v1|profile-bundle-set-sha256"
        expected["winget.install-machine-package.v1"] = "windows-system-v1|winget-package-version-set-sha256"
        expected["winget.inventory-machine.v1"] = "windows-system-v1|none"
        expected["winget.upgrade-machine-package.v1"] = "windows-system-v1|winget-package-channel-set-sha256"
      }
      $0 !~ /^[ -~]+$/ { exit 1 }
      NR == 1 { if ($0 != "policy|1|catalog=1") exit 1; next }
      {
        if (NF != 6 || $1 != "action" || !($2 in expected) || seen[$2]++) exit 1
        if (($3 "|" $5) != expected[$2] || ($4 != "enabled" && $4 != "disabled")) exit 1
        if ($5 == "none") { if ($6 != "-") exit 1 }
        else if ($6 != "-" && (length($6) != 64 || $6 !~ /^[0-9a-f]+$/)) exit 1
        if (previous != "" && previous >= $2) exit 1
        previous = $2
      }
      END { if (NR != 12) exit 1; for (id in expected) if (!seen[id]) exit 1 }
    ' "$policy" || {
      printf 'roundhouse: invalid %s\n' "$label" >&2
      return 64
    }
)

validate_privilege_constraints_file() (
  policy=$1
  constraints=$2
  label=${3:-privilege constraints}
  validate_privilege_policy_file "$policy" "active privilege policy" || exit $?
  [ -f "$constraints" ] && [ ! -L "$constraints" ] || {
    printf 'roundhouse: %s must be a regular non-symlink file\n' "$label" >&2
    exit 64
  }
  if ! {
    [ "$(wc -c <"$constraints" | tr -d ' ')" -le 32768 ] &&
      [ "$(tail -c 1 "$constraints" | wc -l | tr -d ' ')" -eq 1 ] &&
      LC_ALL=C awk -F '|' '
      function token(value) { return value ~ /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/ }
      function atom(value) { return value ~ /^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$/ }
      function digest(value) { return length(value) == 64 && value ~ /^[0-9a-f]+$/ }
      function version(value) { return value ~ /^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,127}$/ }
      function package_id(value) { return value ~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/ }
      function team_id(value) { return value ~ /^[A-Z0-9]{10}$/ }
      function app_name(value) { return length(value) <= 128 && value ~ /^[A-Za-z0-9][A-Za-z0-9._+() -]*[.]app$/ && value !~ /[.][.]/ }
      function setting_value(id, value) {
        if (id == "timezone") return value ~ /^[A-Za-z0-9._+-]+(\/[A-Za-z0-9._+-]+){0,2}$/ && length(value) <= 255
        if (id == "network-time-server") return value ~ /^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/ && value !~ /\.\./
        if (id == "wake-on-network-access" || id == "restart-after-power-failure") return value == "on" || value == "off"
        if (id == "computer-sleep" || id == "display-sleep") return value == "Never" || (value ~ /^[1-9][0-9]{0,2}$/ && (value + 0) <= 180)
        return 0
      }
      function uint(value, maximum) {
        return value ~ /^(0|[1-9][0-9]*)$/ && (value + 0) <= maximum
      }
      $0 !~ /^[ -~]+$/ || length($0) > 2048 { exit 1 }
      NR == 1 {
        if (NF != 4 || $1 != "constraints" || $2 != "1" ||
            $3 !~ /^generation=[1-9][0-9]{0,9}$/ ||
            $4 !~ /^policy-sha256=[0-9a-f]{64}$/) exit 1
        generation = substr($3, 12) + 0
        if (generation < 1 || generation > 2147483647) exit 1
        next
      }
      {
        if (previous != "" && previous >= $0) exit 1
        previous = $0
        membership_action = ($1 == "profile" ? "profile" : $2)
        membership_token = ($1 == "profile" ? $2 : $3)
        if (seen_membership[membership_action SUBSEP membership_token]++) exit 1
      }
      $1 == "apt-install" {
        if (NF != 8 || $2 != "apt.install-package-version.v1" || !token($3) ||
            !atom($4) || !atom($5) || !version($6) || !digest($7) || !digest($8)) exit 1
        next
      }
      $1 == "apt-upgrade" {
        if (NF != 9 || $2 != "apt.upgrade-package.v1" || !token($3) ||
            !atom($4) || !atom($5) || !version($6) || !version($7) ||
            !uint($8, 2147483647) || !digest($9)) exit 1
        next
      }
      $1 == "macos-pkg" {
        if (NF != 12 || $2 != "macos.install-signed-pkg.v1" || !token($3) ||
            ($4 != "script-free" && $4 != "sealed-cask-payload-v1") ||
            !uint($5, 2147483647) || $5 == "0" || !digest($6) || !package_id($7) ||
            !version($8) || !team_id($9) || !digest($10) || !package_id($11) ||
            !version($12)) exit 1
        next
      }
      $1 == "macos-cask-app" {
        if (NF != 4 || $2 != "macos.install-signed-pkg.v1" || !token($3) || !app_name($4)) exit 1
        next
      }
      $1 == "macos-setting" {
        if (NF != 5 || $2 != "macos.apply-system-setting.v1" || !token($3) ||
            !setting_value($4, $5)) exit 1
        next
      }
      $1 == "profile" {
        if (NF != 9 || !token($2) || $3 !~ /^S-[0-9]+(-[0-9]+){1,14}$/ || !digest($4) ||
            !digest($5) || !digest($6) || ($7 != "managed-only" && $7 != "managed-and-prune") ||
            !uint($8, 100000) || $8 == "0" || !uint($9, 1073741824) || $9 == "0") exit 1
        next
      }
      $1 == "winget-install" {
        if (NF != 14 || $2 != "winget.install-machine-package.v1" || !token($3) ||
            !atom($4) || !atom($5) || !atom($6) || !digest($7) || $8 != "machine" ||
            !atom($9) || !atom($10) || !atom($11) || !version($12) ||
            $13 != "provider-enforced-manifest-hash" || $14 != "source-delegated-all") exit 1
        next
      }
      $1 == "winget-upgrade" {
        if (NF != 16 || $2 != "winget.upgrade-machine-package.v1" || !token($3) ||
            !atom($4) || !atom($5) || !atom($6) || !digest($7) || $8 != "machine" ||
            !atom($9) || !atom($10) || !atom($11) || !version($12) || !version($13) ||
            !uint($14, 2147483647) || $15 != "provider-enforced-manifest-hash" ||
            $16 != "source-delegated-all") exit 1
        next
      }
      { exit 1 }
      ' "$constraints"
  }; then
      printf 'roundhouse: invalid %s\n' "$label" >&2
      exit 64
  fi

  policy_digest=$(sha256_file "$policy")
  [ "$(LC_ALL=C sed -n '1s/^constraints|1|generation=[^|]*|policy-sha256=//p' "$constraints")" = "$policy_digest" ] || {
    printf 'roundhouse: %s does not bind the active policy digest\n' "$label" >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-constraints.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  for action in \
    apt.install-package-version.v1 apt.upgrade-package.v1 \
    macos.apply-system-setting.v1 macos.install-signed-pkg.v1 \
    profile.apply-managed-bundle.v1 profile.inventory-managed-state.v1 \
    winget.install-machine-package.v1 winget.upgrade-machine-package.v1; do
    LC_ALL=C awk -F '|' -v action="$action" '
      NR == 1 { next }
      ($1 == "profile" && action ~ /^profile[.]/) || ($1 != "profile" && $2 == action) { print }
    ' "$constraints" >"$tmp/$action"
    expected=$(LC_ALL=C awk -F '|' -v action="$action" '$1 == "action" && $2 == action { print $6 }' "$policy")
    if [ "$expected" = - ]; then
      case $action in
        profile.*)
          other_profile=$(LC_ALL=C awk -F '|' '$1 == "action" && $2 ~ /^profile[.]/ && $6 != "-" { print $6 }' "$policy" | head -1)
          [ -n "$other_profile" ] || [ ! -s "$tmp/$action" ] || exit 1
          ;;
        *) [ ! -s "$tmp/$action" ] || exit 1 ;;
      esac
    else
      [ -s "$tmp/$action" ] && [ "$(sha256_file "$tmp/$action")" = "$expected" ] || {
        printf 'roundhouse: %s has missing or digest-mismatched records for %s\n' "$label" "$action" >&2
        exit 64
      }
    fi
  done
)

inspect_privilege_constraints_file() (
  policy=$1
  constraints=$2
  validate_privilege_constraints_file "$policy" "$constraints"
  generation=$(LC_ALL=C sed -n '1s/^constraints|1|generation=\([^|]*\)|.*/\1/p' "$constraints")
  constraints_digest=$(sha256_file "$constraints")
  jq -Rsc --argjson generation "$generation" --arg constraints_digest "$constraints_digest" '
    split("\n") | .[1:] | map(select(length > 0) | split("|")) as $records |
    {
      schema:"roundhouse.privilege-constraints",schema_version:1,
      generation:$generation,digest:{algorithm:"sha256",value:$constraints_digest},
      actions:[
        "apt.autoremove.v1","apt.install-package-version.v1","apt.update-metadata.v1",
        "apt.upgrade-package.v1","macos.apply-system-setting.v1",
        "macos.install-signed-pkg.v1","profile.apply-managed-bundle.v1",
        "profile.inventory-managed-state.v1","winget.install-machine-package.v1",
        "winget.inventory-machine.v1","winget.upgrade-machine-package.v1"
      ] | map(. as $action | {
        action_id:$action,
        policy_tokens:([$records[] |
          if (.[0] == "profile" and ($action | startswith("profile."))) then .[1]
          elif (.[0] != "profile" and .[1] == $action) then .[2]
          else empty end] | sort | unique)
      })
    }
  ' "$constraints"
)

materialize_policy_proposal() (
  config=$1
  target=$2
  output=$3
  if jq -e --arg target "$target" '.machines[$target].privilege_broker.policy_proposal != null' \
    "$config" >/dev/null; then
    jq -r --arg target "$target" '.machines[$target].privilege_broker.policy_proposal[]' \
      "$config" >"$output"
  else
    cp "$plugin_root/references/privilege-policy.default" "$output"
  fi
  validate_privilege_policy_file "$output" "policy proposal for $target"
)

validate_config_file() {
  require_jq
  path=$(config_path)
  [ -f "$path" ] || {
    printf 'roundhouse: configuration not found: %s\n' "$path" >&2
    exit 64
  }
  jq -e '
    def valid_capability_provider:
      (.provider | IN("plugin","skills-cli","jsm","manual","plugin-source")) and
      (.source | type == "string" and length > 0) and
      (.source | contains("?") | not) and
      (.source | test("^[A-Za-z][A-Za-z0-9+.-]*://(?!git@)[^/@]+@") | not) and
      (if .provider == "plugin" then
        (.source | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and (.source != ".") and (.source != "..")
      else true end) and
      ((.skill // null) == null or (.skill | type == "string" and test("^[A-Za-z0-9._-]+$"))) and
      ((.name // null) == null or (.name | type == "string" and test("^[A-Za-z0-9._-]+$")));
    . as $config |
    .version == 1 and
    ((.worker // null) == null or
      ((.worker | type == "object") and
       (.worker.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
       (.worker.controller_configuration_digest | type == "string" and test("^[0-9a-f]{64}$")) and
       ((.worker.policy_proposal_source // null) == null or
         (.worker.policy_proposal_source | IN("packaged-default","user-configuration"))) and
       ((.worker.policy_proposal_digest // null) == null or
         (.worker.policy_proposal_digest | type == "string" and test("^[0-9a-f]{64}$"))) and
       ((.worker.node_identity_projected // false) == false) and
       ((.worker.originating_node_identity // null) as $origin |
         ($origin == null or
          (($origin | type == "object") and
           ($origin | keys | sort) == (["ca_generation","certificate_principals",
             "certificate_serial","certificate_source_addresses","certificate_valid_after",
             "certificate_valid_before","fleet_ca_fingerprint","fleet_domain","node_id",
             "node_key_fingerprint","schema","schema_version"] | sort) and
           $origin.schema == "roundhouse.originating-node-identity" and
           $origin.schema_version == 1 and
           ($origin.node_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
           ($origin.fleet_domain | test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$")) and
           ($origin.node_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
           ($origin.fleet_ca_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
           ($origin.ca_generation | type == "number" and floor == . and . >= 1) and
           ($origin.certificate_serial | test("^(0|[1-9][0-9]{0,19})$")) and
           ($origin.certificate_valid_after | fromdateiso8601 > 0 and fromdateiso8601 <= now) and
           ($origin.certificate_valid_before | fromdateiso8601 > now) and
           ($origin.certificate_principals | type == "array" and length >= 2 and length <= 16 and
             unique == . and index($origin.node_id + "@" + $origin.fleet_domain) != null) and
           ($origin.certificate_source_addresses | type == "array" and length <= 16 and unique == .))) and
         (if ($config.machines[$config.worker.target].privilege_broker.automation_transport // null) != null
          then $origin != null else true end)) and
       (.machines | keys == [$config.worker.target]))) and
    (.machines | type == "object") and
    (.machines | length > 0) and
    ([.machines | keys[] | test("^[A-Za-z0-9._-]+$")] | all) and
    ([.machines[] | . as $machine |
      (.platform | IN("macos","linux","wsl","windows")) and
      (.transport | IN("local","ssh","codex-remote-control")) and
      ((.codex_host // null) == null or (.codex_host | type == "string" and length > 0)) and
      ((.codex_control_project // null) == null or
        (.codex_control_project | type == "string" and test("^[A-Za-z0-9._-]+$") and
          $config.projects[$machine.codex_control_project] != null)) and
      ((.expected_hostname // null) == null or
        (.expected_hostname | type == "string" and test("^[A-Za-z0-9._-]+$"))) and
      ((.expected_user // null) == null or
        (.expected_user | type == "string" and test("^[A-Za-z0-9._@-]+$"))) and
      (if .platform == "windows" then .transport == "codex-remote-control" else true end) and
      (if .transport == "codex-remote-control" then
        .platform == "windows" and (.codex_host | type == "string" and length > 0)
      else true end) and
      (if .transport == "ssh" then
        (.ssh_alias | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      else true end) and
      ((.groups // []) | type == "array") and
      ([.groups[]? | type == "string" and test("^[A-Za-z0-9._-]+$")] | all) and
      ((.package_managers // []) | type == "array") and
      ([.package_managers[]? | IN("homebrew","linuxbrew","apt","winget")] | all) and
      (if any(.package_managers[]?; . == "winget") then .platform == "windows" else true end) and
      (if any(.package_managers[]?; . == "apt") then (.platform == "linux" or .platform == "wsl") else true end) and
      ((.privilege_broker // null) == null or
        ((.privilege_broker | type == "object") and
         ([.privilege_broker | keys[] | select(IN("automation_transport","policy_proposal") | not)] | length == 0) and
         ((.privilege_broker.policy_proposal // null) == null or
           (.platform | IN("linux","macos","windows")) and
           (.privilege_broker.policy_proposal | type == "array" and length == 12) and
           ([.privilege_broker.policy_proposal[] |
             type == "string" and length > 0 and length <= 512 and test("^[ -~]+$")
           ] | all)) and
         ((.privilege_broker.automation_transport // null) == null or
           (.platform != "wsl") and
           (.privilege_broker.automation_transport | type == "object") and
           (.privilege_broker.automation_transport.host |
             type == "string" and length <= 255 and test("^[A-Za-z0-9][A-Za-z0-9.:-]{0,254}$")) and
           (.privilege_broker.automation_transport.port |
             type == "number" and floor == . and . >= 1 and . <= 65535) and
           (.privilege_broker.automation_transport.request_user |
             type == "string" and test("^[A-Za-z0-9._-]{1,128}$")) and
           (.privilege_broker.automation_transport.pinned_host_key_fingerprint |
             type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
           (.privilege_broker.automation_transport.management_networks |
             type == "array" and length > 0 and length <= 32 and unique == .) and
           ([.privilege_broker.automation_transport.management_networks[] |
             type == "string" and length <= 128 and
             (if contains(":") then
               test("^[0-9A-Fa-f:]+/[0-9]{1,3}$") and ((split("/")[-1] | tonumber) <= 128)
              else
               test("^[0-9.]+/[0-9]{1,2}$") and ((split("/")[-1] | tonumber) <= 32)
               and (split("/")[0] | split(".") | length == 4 and
                 all(.[]; test("^(0|[1-9][0-9]{0,2})$") and ((tonumber) <= 255)))
              end)
           ] | all) and
           (if .platform == "windows" then
              (.privilege_broker.automation_transport | keys | sort) ==
                ((if ($config.worker // null) == null then
                    ["host","management_networks","mode","pinned_host_key_fingerprint","port","request_sid","request_user"]
                  else ["host","management_networks","mode","pinned_host_key_fingerprint","port","request_user"] end) | sort) and
              .privilege_broker.automation_transport.mode == "windows-sftp" and
              .privilege_broker.automation_transport.port == 22 and
              .privilege_broker.automation_transport.request_user == "RoundhouseRequest" and
              (if ($config.worker // null) == null then
                 (.privilege_broker.automation_transport.request_sid | type == "string" and
                   test("^S-[0-9]+(?:-[0-9]+){1,14}$"))
               else true end)
            else
              (.privilege_broker.automation_transport | keys | sort) ==
                (["host","management_networks","mode","pinned_host_key_fingerprint","port","request_user"] | sort) and
              .privilege_broker.automation_transport.mode == "posix-ssh"
            end))))
    ] | all) and
    ((.projects // {}) | type == "object") and
    ([.projects // {} | to_entries[] |
      (.key | test("^[A-Za-z0-9._-]+$")) and
      (.value.source | type == "string" and length > 0) and
      (.value.source | contains("?") | not) and
      (.value.source | test("^[A-Za-z][A-Za-z0-9+.-]*://(?!git@)[^/@]+@") | not) and
      (.value.path | type == "string" and length > 0) and
      (.value.path | startswith("/") | not) and
      (.value.path | contains("\\") | not) and
      (.value.path | test("^[A-Za-z]:") | not) and
      (.value.path | test("(^|/)\\.\\.(/|$)") | not)
    ] | all) and
    ((.handoff_project // null) == null or
      (.handoff_project | type == "string" and test("^[A-Za-z0-9._-]+$") and
        $config.projects[.] != null)) and
    ((.capabilities // {}) | type == "object") and
    ([.capabilities // {} | to_entries[] |
      (.key | test("^[A-Za-z0-9._-]+$")) and
      ((.value.groups // []) | type == "array") and
      ([.value.groups[]? | type == "string" and test("^[A-Za-z0-9._-]+$")] | all) and
      ((.value.requires_auth // []) | type == "array") and
      ((.value.requires_auth // [] | unique | length) == (.value.requires_auth // [] | length)) and
      ([.value.requires_auth[]? |
        type == "string" and test("^[A-Za-z0-9._-]+$") and
        ($config.auth_artifacts[.] != null)
      ] | all) and
      ((.value.requires_artifacts // []) | type == "array") and
      ((.value.requires_artifacts // [] | unique | length) == (.value.requires_artifacts // [] | length)) and
      ([.value.requires_artifacts[]? |
        type == "string" and test("^[A-Za-z0-9._-]+$") and
        (. as $id | any($config.agent_artifacts[]?; .id == $id))
      ] | all) and
      (if (.value.agents // null) != null then
        ((.value.agents | type == "array") and
          (.value.agents | length > 0) and
          ((.value.agents | unique | length) == (.value.agents | length)) and
          ([.value.agents[] | IN("codex","claude")] | all) and
          ([.value | keys[] | select(. == "codex" or . == "claude")] | length == 0) and
          (.value | valid_capability_provider))
      else
        ([.value | to_entries[] | select(.key == "codex" or .key == "claude") |
          (.value | type == "object") and (.value | valid_capability_provider)
        ] | all) and
        ([.value | keys[] | select(. == "codex" or . == "claude")] | length > 0)
      end)
    ] | all) and
    ((.skill_roots // []) | type == "array") and
    ((.skill_roots // [] | map(.id) | unique | length) == (.skill_roots // [] | length)) and
    ([.skill_roots[]? |
      (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (.path | type == "string" and length > 0) and
      ((.manager // "manual") | IN("manual","mixed","skills-cli","jsm","plugin-source")) and
      ((.agents // []) | type == "array") and
      ([.agents[]? | IN("codex","claude")] | all) and
      ((.groups // []) | type == "array")
    ] | all) and
    ((.agent_artifacts // []) | type == "array") and
    ((.agent_artifacts // [] | map(.id) | unique | length) == (.agent_artifacts // [] | length)) and
    ([.agent_artifacts[]? |
      (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (((.path // null) | type == "string" and length > 0) or
       ((.paths // {}) | type == "object" and length > 0) or
       (($config.worker // null) != null)) and
      ((.paths // {}) | type == "object") and
      ([.paths // {} | to_entries[] |
        (.key | test("^[A-Za-z0-9._-]+$")) and ($config.machines[.key] != null) and
        (.value | type == "string" and length > 0)
      ] | all) and
      (.kind | IN("agent-definition","instruction","config")) and
      ((.agents // []) | type == "array") and
      ([.agents[]? | IN("codex","claude")] | all) and
      ((.groups // []) | type == "array") and
      ([.groups[]? | type == "string" and test("^[A-Za-z0-9._-]+$")] | all) and
      ((.settings // {}) | type == "object") and
      (if ((.settings // {}) | length) > 0 then
        (.kind == "config") and
        (.format | IN("json","toml")) and
        ((.format == "json" and .agents == ["claude"]) or
         (.format == "toml" and .agents == ["codex"])) and
        (. as $artifact | [.settings | to_entries[] |
          (($artifact.format == "json" and
            (.key | IN("remoteControlAtStartup","switchModelsOnFlag","model","effortLevel",
              "availableModels","fallbackModel","autoUpdatesChannel","agentPushNotifEnabled"))) or
           ($artifact.format == "toml" and
            (.key | IN("model","model_reasoning_effort","service_tier",
              "check_for_update_on_startup","cli_auth_credentials_store")))) and
          (. as $setting |
            ($setting.value | tojson | utf8bytelength <= 8192) and
            (($setting.value == null) or
             (if $setting.key | IN("remoteControlAtStartup","switchModelsOnFlag",
                "agentPushNotifEnabled","check_for_update_on_startup") then
               ($setting.value | type == "boolean")
             elif $setting.key == "availableModels" then
               ($setting.value | type == "array") and
               ([$setting.value[] | type == "string" and length > 0] | all)
             elif $setting.key == "autoUpdatesChannel" then
               ($setting.value | IN("latest","stable"))
             elif $setting.key == "cli_auth_credentials_store" then
               ($setting.value | IN("file","keyring","auto"))
              else ($setting.value | type == "string" and length > 0) end)))
        ] | all)
      else ((.format // null) == null or (.format | IN("json","toml"))) end)
    ] | all) and
    ((.auth_artifacts // {}) | type == "object") and
    ([.auth_artifacts // {} | to_entries[] |
      (.key | test("^[A-Za-z0-9._-]+$")) and
      (((.value.path // null) | type == "string" and length > 0) or
       ((.value.paths // {}) | type == "object" and length > 0) or
       (((.value.portability // "per-machine") | IN("native-store","per-machine")) and
        ((.value.verify // []) | length) > 0)) and
      ((.value.paths // {}) | type == "object") and
      ([.value.paths // {} | to_entries[] |
        (.key | test("^[A-Za-z0-9._-]+$")) and (.value | type == "string" and length > 0)
      ] | all) and
      ((.value.strategy // "ignore") | IN("chezmoi","encrypted-install","reauth","ignore")) and
      (if ((.value.strategy // "ignore") == "encrypted-install") then
        (.value.secret_ref | type == "string" and startswith("op://") and length > 5) and
        ((.value.mode // "0600") | IN("600","0600")) and
        ((.value.verify // []) | length > 0)
      else true end) and
      ((.value.portability // "per-machine") | IN(
        "declarative","secret-reference","portable-session","native-store","per-machine","regenerable-cache"
      )) and
      ((.value.mode // "0600") | type == "string" and test("^0?[0-7]{3}$")) and
      ((.value.max_bytes // 10485760) | type == "number" and . > 0 and . <= 104857600) and
      ((.value.verify // []) | type == "array") and
      ((.value.verify // []) | length <= 32) and
      (if (((.value.portability // "per-machine") | IN("native-store","per-machine")) and
           ((.value.path // null) == null) and ((.value.paths // {}) | length) == 0) then
        (((.value.strategy // "ignore") | IN("reauth","ignore")) and
         ((.value.verify // []) | length) > 0)
      else true end) and
      (if ((.value.verify // []) | length) > 0 then
        (.value.verify[0] | type == "string" and test("^[A-Za-z0-9._+-]+$")) and
        ([.value.verify[] | type == "string"] | all)
      else true end)
      and
      ((.value.reauth // []) | type == "array") and
      ((.value.reauth // []) | length <= 32) and
      (if ((.value.strategy // "ignore") == "reauth") then
        ((.value.reauth // []) | length) > 0
      else true end) and
      (if ((.value.reauth // []) | length) > 0 then
        (.value.reauth[0] | type == "string" and test("^[A-Za-z0-9._+-]+$")) and
        ([.value.reauth[] | type == "string" and length > 0] | all)
      else true end)
    ] | all) and
    ([.. | strings |
      length <= 8192 and (test("[[:cntrl:]]") | not)
    ] | all)
  ' "$path" >/dev/null || {
    printf 'roundhouse: invalid version 1 configuration: %s\n' "$path" >&2
    exit 64
  }
  validate_privilege_policy_file "$plugin_root/references/privilege-policy.default" "packaged privilege policy"
  proposal_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-policy.XXXXXX")
  trap 'rm -rf "$proposal_tmp"' EXIT HUP INT TERM
  while IFS= read -r proposal_host; do
    [ -n "$proposal_host" ] || continue
    jq -r --arg host "$proposal_host" '.machines[$host].privilege_broker.policy_proposal[]' \
      "$path" >"$proposal_tmp/$proposal_host"
    validate_privilege_policy_file "$proposal_tmp/$proposal_host" "policy proposal for $proposal_host"
  done <<EOF
$(jq -r '.machines | to_entries[] | select(.value.privilege_broker.policy_proposal != null) | .key' "$path")
EOF
  rm -rf "$proposal_tmp"
  trap - EXIT HUP INT TERM
  identity=$(identity_path)
  [ ! -e "$identity" ] || validate_node_identity_file "$identity" "$path"
}

worker_config_command() (
  target=$1
  domain=$2
  output=$3
  require_jq
  validate_config_file
  config=$(config_path)
  case $domain in
    inventory|updates|agents|auth|chezmoi|projects) ;;
    *) printf 'roundhouse: unsupported worker domain: %s\n' "$domain" >&2; exit 64 ;;
  esac
  jq -e --arg target "$target" '.machines[$target] != null' "$config" >/dev/null || {
    printf 'roundhouse: unknown worker target: %s\n' "$target" >&2
    exit 64
  }
  controller_digest=$(sha256_file "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-worker-config.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  materialize_policy_proposal "$config" "$target" "$tmp/policy-proposal"
  policy_proposal_digest=$(sha256_file "$tmp/policy-proposal")
  identity=$(identity_path)
  if [ -e "$identity" ]; then
    public_node_identity "$identity" "$config" >"$tmp/originating-node.json"
  else
    printf 'null\n' >"$tmp/originating-node.json"
  fi
  if jq -e --arg target "$target" '.machines[$target].privilege_broker.automation_transport != null' \
      "$config" >/dev/null && jq -e '. == null' "$tmp/originating-node.json" >/dev/null; then
    printf 'roundhouse: broker-routed worker configuration requires a validated originating node identity\n' >&2
    exit 64
  fi
  if jq -e --arg target "$target" '.machines[$target].privilege_broker.policy_proposal != null' \
    "$config" >/dev/null; then
    policy_proposal_source=user-configuration
  else
    policy_proposal_source=packaged-default
  fi
  jq -S \
    --arg target "$target" \
    --arg domain "$domain" \
    --arg controller_digest "$controller_digest" \
    --arg policy_proposal_source "$policy_proposal_source" \
    --arg policy_proposal_digest "$policy_proposal_digest" \
    --slurpfile origin "$tmp/originating-node.json" '
    {
      version,
      worker:{
        target:$target,
        controller_configuration_digest:$controller_digest,
        policy_proposal_source:$policy_proposal_source,
        policy_proposal_digest:$policy_proposal_digest,
        node_identity_projected:false,
        originating_node_identity:$origin[0]
      },
      machines:{($target):(.machines[$target] |
        if .platform == "windows" then del(.privilege_broker.automation_transport.request_sid) else . end)},
      projects:(
        if ($domain == "projects" or $domain == "inventory") then
          (.projects // {})
        elif (.machines[$target].codex_control_project // null) != null then
          .machines[$target].codex_control_project as $control |
          {($control):.projects[$control]}
        else {} end
      ),
      handoff_project:(
        if ($domain == "projects" or $domain == "inventory") then
          (.handoff_project // null)
        else null end
      ),
      capabilities:(if ($domain == "agents" or $domain == "inventory") then (.capabilities // {}) else {} end),
      skill_roots:(if ($domain == "agents" or $domain == "inventory") then (.skill_roots // []) else [] end),
      agent_artifacts:(if ($domain == "agents" or $domain == "inventory") then
        (.agent_artifacts // [] | map(. as $artifact |
          $artifact + {paths:(if ($artifact.paths[$target] // null) != null then
            {($target):$artifact.paths[$target]} else {} end)}))
      else [] end),
      auth_artifacts:(if ($domain == "auth" or $domain == "agents") then
        (.auth_artifacts // {})
      elif $domain == "inventory" then
        (.auth_artifacts // {})
      else {} end),
      policy:(.policy // {})
    }' "$config" >"$tmp/config.json"
  ROUNDHOUSE_CONFIG="$tmp/config.json" validate_config_file
  safe_output "$tmp/config.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)
