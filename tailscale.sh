#!/bin/bash

TAILSCALED_PID=""
SSHD_PID=""
STATUS_PID=""
STATUS_PORT=8088

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

echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

if [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

HOSTKEY_DIR=/etc/ssh/host-keys
mkdir -p "${HOSTKEY_DIR}"
chown root:root "${HOSTKEY_DIR}"
chmod 700 "${HOSTKEY_DIR}"
for t in ed25519 rsa; do
  k="${HOSTKEY_DIR}/ssh_host_${t}_key"
  if [ ! -s "${k}" ]; then
    rm -f "${k}" "${k}.pub"
    ssh-keygen -q -t "${t}" -N '' -f "${k}"
  fi
  chown root:root "${k}" "${k}.pub"
  chmod 600 "${k}"
  chmod 644 "${k}.pub"
done

chown root:root /root
chmod 700 /root
mkdir -p /root/.ssh
chown root:root /root/.ssh
chmod 700 /root/.ssh
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "${AUTHORIZED_KEYS}" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
else
  rm -f /root/.ssh/authorized_keys
  echo "WARNING: AUTHORIZED_KEYS not set; SSH login is disabled." >&2
fi

IFS=',' read -ra SUBNETS <<< "${ADVERTISE_ROUTES}"
for s in "${SUBNETS[@]}"; do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done

if [[ ! -z "${UPDATE_TAILSCALE+x}" ]]; then
  /usr/local/bin/tailscale update --yes
fi

if [[ -z "${LOGIN_SERVER}" ]]; then
	LOGIN_SERVER=https://controlplane.tailscale.com
fi

if [[ -n "${STARTUP_SCRIPT}" && -f "${STARTUP_SCRIPT}" ]]; then
       bash "${STARTUP_SCRIPT}" || exit $?
fi

if [[ "${STATUS_LISTEN}" != "off" ]]; then
  if [[ -z "${STATUS_LISTEN}" ]]; then
    STATUS_IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
    STATUS_LISTEN="${STATUS_IP:+${STATUS_IP}:}${STATUS_PORT}"
  fi
  if [[ -z "${STATUS_GATE_PREFIX}" ]]; then
    STATUS_GATE_PREFIX="${ADVERTISE_ROUTES%%,*}"
  fi
  printf 'ADVERTISE_ROUTES=%q\nGATE_PREFIX=%q\n' \
    "${ADVERTISE_ROUTES}" "${STATUS_GATE_PREFIX}" > /etc/ts-status.conf
  chmod 0644 /etc/ts-status.conf
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

/usr/local/bin/tailscaled ${TAILSCALED_ARGS} &
TAILSCALED_PID=$!
while :; do
  /usr/local/bin/tailscale up \
    --reset --authkey="${AUTH_KEY}" \
    --login-server "${LOGIN_SERVER}" \
    --advertise-routes="${ADVERTISE_ROUTES}" \
    ${TAILSCALE_ARGS} &
  wait $! && break
  if ! kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
    wait "${TAILSCALED_PID}"; rc=$?
    echo "tailscaled exited (${rc}) before tailscale up succeeded" >&2
    [[ -n "${STATUS_PID}" ]] && kill -TERM "${STATUS_PID}" 2>/dev/null
    exit "${rc:-1}"
  fi
  sleep 0.1
done
echo Tailscale started

EXISTS=`ip route show 100.64.0.0/10 | wc -l`
if [ $EXISTS -eq 0 ]; then
  ip route add 100.64.0.0/10 dev tailscale0
fi

EXISTSV6=`ip -6 route show fd7a:115c:a1e0::/48 | wc -l`
if [ $EXISTSV6 -eq 0 ]; then
  ip -6 route add fd7a:115c:a1e0::/48 dev tailscale0
fi

if [[ -n "${RUNNING_SCRIPT}" && -f "${RUNNING_SCRIPT}" ]]; then
       bash "${RUNNING_SCRIPT}" || exit $?
fi

/usr/sbin/sshd -D &
SSHD_PID=$!

while kill -0 "${TAILSCALED_PID}" 2>/dev/null; do
  wait "${TAILSCALED_PID}"; rc=$?
done
echo "tailscaled exited (${rc:-?}); stopping container" >&2
[[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
[[ -n "${STATUS_PID}" ]] && kill -TERM "${STATUS_PID}" 2>/dev/null
exit "${rc:-1}"
