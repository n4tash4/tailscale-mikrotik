#!/bin/bash

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
                  elif ($running | not) then "backend " + (.BackendState // "unreachable")
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
