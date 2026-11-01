#!/bin/bash
#
# Process model
# -------------
# PID 1 is tini (Dockerfile ENTRYPOINT): it reaps orphaned/zombie processes
# (e.g. CGI children left behind if httpd dies mid-request) and forwards the
# RouterOS stop-signal (SIGTERM by default) to this script.
#
# This script supervises three children and the container's lifetime follows
# tailscaled: if tailscaled exits, everything is stopped and the script exits
# with tailscaled's status (pair with RouterOS restart-policy=on-failure).
# On SIGTERM/SIGINT tailscaled is stopped gracefully so it can tell control it
# is going away (faster subnet-router failover than waiting for a timeout).
#
# Long-running steps run in the background + `wait`, because bash only runs a
# trap after the current foreground command returns; `wait` returns as soon
# as a trapped signal arrives.

TAILSCALED_PID=""
SSHD_PID=""
STATUS_PID=""

shutdown() {
  trap - TERM INT
  echo "Stop signal received; shutting down"
  [[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
  [[ -n "${STATUS_PID}" ]] && kill -TERM "${STATUS_PID}" 2>/dev/null
  if [[ -n "${TAILSCALED_PID}" ]] && kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
    kill -TERM "${TAILSCALED_PID}" 2>/dev/null
    wait "${TAILSCALED_PID}"
  fi
  exit 0
}
trap shutdown TERM INT

# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

# Prepare run dirs
if [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

# Generate SSH host keys on first start if missing (done at runtime rather than
# build time because RSA keygen under arm/v5 emulation is unreliable).
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi

# Set root password
echo "root:${PASSWORD}" | chpasswd

# Install routes
IFS=',' read -ra SUBNETS <<< "${ADVERTISE_ROUTES}"
for s in "${SUBNETS[@]}"; do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done

# Perform an update if set
if [[ ! -z "${UPDATE_TAILSCALE+x}" ]]; then
  /usr/local/bin/tailscale update --yes
fi

# Set login server for tailscale
if [[ -z "${LOGIN_SERVER}" ]]; then
	LOGIN_SERVER=https://controlplane.tailscale.com
fi

# Execute startup script if it exists
if [[ -n "${STARTUP_SCRIPT}" && -f "${STARTUP_SCRIPT}" ]]; then
       bash "${STARTUP_SCRIPT}" || exit $?
fi

# Start the read-only status endpoint (JSON at /cgi-bin/status).
# Started before tailscaled so RouterOS gets a fail-closed answer
# (gate.primary=false) while Tailscale is still coming up.
#   STATUS_LISTEN       [ip:]port to bind, or "off" to disable.
#                       Default: <first global IPv4 on the veth>:8088
#   STATUS_GATE_PREFIX  prefix whose primary-ness drives .gate.primary.
#                       Default: first entry of ADVERTISE_ROUTES.
if [[ "${STATUS_LISTEN}" != "off" ]]; then
  if [[ -z "${STATUS_LISTEN}" ]]; then
    STATUS_IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
    STATUS_LISTEN="${STATUS_IP:+${STATUS_IP}:}8088"
  fi
  if [[ -z "${STATUS_GATE_PREFIX}" ]]; then
    STATUS_GATE_PREFIX="${ADVERTISE_ROUTES%%,*}"
  fi
  # Only non-secret values go into the CGI's config file.
  printf 'ADVERTISE_ROUTES=%q\nGATE_PREFIX=%q\n' \
    "${ADVERTISE_ROUTES}" "${STATUS_GATE_PREFIX}" > /etc/ts-status.conf
  chmod 0644 /etc/ts-status.conf
  # env -i: httpd and its CGIs start with a clean environment, so AUTH_KEY /
  # PASSWORD are never visible to request handling. -u nobody: the CGI only
  # needs read-only LocalAPI access (tailscale status). Restart if it exits.
  (
    hp=""
    trap '[[ -n "$hp" ]] && kill -TERM "$hp" 2>/dev/null; exit 0' TERM INT
    while :; do
      env -i PATH=/usr/local/bin:/usr/bin:/bin \
        busybox httpd -f -u nobody -p "${STATUS_LISTEN}" -h /www &
      hp=$!
      wait "$hp"
      echo "status httpd exited ($?); restarting in 2s" >&2
      sleep 2 & wait $!
    done
  ) &
  STATUS_PID=$!
  echo "Status endpoint on http://${STATUS_LISTEN}/cgi-bin/status (gate ${STATUS_GATE_PREFIX})"
fi

# Start tailscaled and bring tailscale up
/usr/local/bin/tailscaled ${TAILSCALED_ARGS} &
TAILSCALED_PID=$!
while :; do
  /usr/local/bin/tailscale up \
    --reset --authkey="${AUTH_KEY}" \
    --login-server "${LOGIN_SERVER}" \
    --advertise-routes="${ADVERTISE_ROUTES}" \
    ${TAILSCALE_ARGS} &
  wait $! && break
  # Don't spin forever if tailscaled itself has died.
  if ! kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
    wait "${TAILSCALED_PID}"; rc=$?
    echo "tailscaled exited (${rc}) before tailscale up succeeded" >&2
    [[ -n "${STATUS_PID}" ]] && kill -TERM "${STATUS_PID}" 2>/dev/null
    exit "${rc:-1}"
  fi
  sleep 0.1
done
echo Tailscale started

# Check that a route exists for 100.64.0.0/10; if not, add
EXISTS=`ip route show 100.64.0.0/10 | wc -l`
if [ $EXISTS -eq 0 ]; then
  ip route add 100.64.0.0/10 dev tailscale0
fi

# Check that a route exists for fd7a:115c:a1e0::/48; if not, add
EXISTSV6=`ip -6 route show fd7a:115c:a1e0::/48 | wc -l`
if [ $EXISTSV6 -eq 0 ]; then
  ip -6 route add fd7a:115c:a1e0::/48 dev tailscale0
fi

# Execute running script if it exists
if [[ -n "${RUNNING_SCRIPT}" && -f "${RUNNING_SCRIPT}" ]]; then
       bash "${RUNNING_SCRIPT}" || exit $?
fi

# Start SSH
/usr/sbin/sshd -D &
SSHD_PID=$!

# Container lifetime follows tailscaled. `wait` is interrupted by the trap on
# SIGTERM/SIGINT (shutdown() then exits), so loop until tailscaled is gone.
while kill -0 "${TAILSCALED_PID}" 2>/dev/null; do
  wait "${TAILSCALED_PID}"; rc=$?
done
echo "tailscaled exited (${rc:-?}); stopping container" >&2
[[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
[[ -n "${STATUS_PID}" ]] && kill -TERM "${STATUS_PID}" 2>/dev/null
exit "${rc:-1}"
