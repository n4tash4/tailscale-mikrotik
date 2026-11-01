#!/bin/bash
# =============================================================================
# ts-status.cgi — read-only Tailscale status endpoint (served by busybox httpd)
#
#   GET http://<container-ip>:8088/cgi-bin/status   ->  application/json
#
# Generated fresh on every request (no state written to disk, so no flash wear
# and no stale data). Consumed by the RouterOS "ts-primary" script, which only
# exports the tailnet return route (100.64.0.0/10) into BGP while
# .gate.primary == true, so BGP follows Tailscale's choice of primary subnet
# router.
#
# SECURITY: the output is built from an explicit ALLOWLIST of fields. Never
# pass the raw `tailscale status --json` through: it contains node keys, the
# auth URL, public WAN endpoints, user login names and capability maps. New
# fields added by future Tailscale versions are therefore excluded by default.
#
# Fail-closed: if tailscaled is down, wedged (3s timeout) or not Running,
# .gate.primary is false.
# =============================================================================

# Non-secret settings written by tailscale.sh at startup (ADVERTISE_ROUTES,
# GATE_PREFIX). The CGI never sees AUTH_KEY / PASSWORD.
CONF=/etc/ts-status.conf
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

st=$(timeout 3 /usr/local/bin/tailscale status --json 2>/dev/null) || st='{}'
[ -n "$st" ] || st='{}'

printf '%s' "$st" | jq -c \
  --arg gate "${GATE_PREFIX:-}" \
  --arg adv "${ADVERTISE_ROUTES:-}" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  . as $s
  | ($adv | split(",") | map(gsub("\\s"; "")) | map(select(length > 0))) as $advs
  # Hostnames of every node (self + peers) this node believes is primary for $p.
  # More than one entry = split brain; empty = nobody is primary.
  | def prim($p): [ ($s.Self // empty), ($s.Peer // {} | .[])
                    | select(any(.PrimaryRoutes[]?; . == $p)) | .HostName ];
  ((.BackendState // "unreachable") == "Running") as $running
  | (any(.Self.PrimaryRoutes[]?; . == $gate)) as $isPrimary
  | {
      schema: 1,
      generatedAt: $now,
      node: {
        hostname:        (.Self.HostName // null),
        tailscaleIPs:    (.TailscaleIPs // []),
        version:         (.Version // null),
        backendState:    (.BackendState // "unreachable"),
        homeDerp:        (.Self.Relay // null),
        exitNodeOffered: (.Self.ExitNodeOption // false)
      },
      health: (.Health // []),
      routes: {
        advertised: $advs,
        primary:    (.Self.PrimaryRoutes // [])
      },
      gate: {
        prefix:  $gate,
        primary: ($gate != "" and $running and $isPrimary),
        reason:  (if $gate == "" then "no gate prefix configured"
                  elif ($running | not) then "tailscaled not running"
                  elif ($isPrimary | not) then "standby"
                  else "primary" end)
      },
      tailnetView: {
        primaryFor:  ($advs | map({key: ., value: prim(.)}) | from_entries),
        peersOnline: ([.Peer // {} | .[] | select(.Online == true)] | length),
        peersTotal:  (.Peer // {} | length)
      }
    }' 2>/dev/null \
  || printf '{"schema":1,"gate":{"prefix":"%s","primary":false,"reason":"status render failed"}}\n' "${GATE_PREFIX:-}"
