# tailscale-mikrotik

[Tailscale](https://tailscale.com/) in a [RouterOS container](https://help.mikrotik.com/docs/display/ROS/Container). The container advertises subnets to your tailnet as a subnet router, and can also act as an exit node.

`build.sh` builds Tailscale from source at a pinned version for two MikroTik CPU families. The container also serves a read-only status endpoint. A RouterOS script can poll it to learn whether this node is the primary subnet router.

The examples use a container on `172.17.0.2` behind a bridge with the gateway `172.17.0.1`, and a LAN of `10.0.1.0/24`. Replace these with your own values.

## Requirements

- RouterOS 7.6 or later with the `container` package and container mode enabled.
- An ext4 disk mounted at `/storage`.
- A Tailscale auth key.
- To build: Docker with Buildx, `skopeo`, and `git`. To build arm32 on another architecture, register QEMU once:

	```sh
	docker run --privileged --rm tonistiigi/binfmt --install all
	```

## Build

```sh
./build.sh          # writes tailscale-arm32.tar and tailscale-arm64.tar
./build.sh arm64    # arm64 only
./build.sh arm32    # arm32 only
NO_CACHE=1 ./build.sh
```

`build.sh` clones Tailscale into `./tailscale` at the tag `v$TAILSCALE_VERSION`. If `./tailscale` already holds another version, the script checks out the pinned tag, but it stops if the clone has local changes. To change the version, edit `TAILSCALE_VERSION` in `build.sh`. Docker cross-compiles Tailscale in a Go build stage.

After each build, the script fails if the image has a duplicate or empty layer, because RouterOS cannot mount such an image. The Dockerfile also starts the status endpoint during the build and fails if the response is not valid.

| File | Platform | Base image | Devices |
|---|---|---|---|
| `tailscale-arm64.tar` | `linux/arm64` | `arm64v8/debian:bookworm-slim` | arm64 boards, such as the RB5009. |
| `tailscale-arm32.tar` | `linux/arm/v5` | `arm32v5/debian:bookworm-slim` | EN7562CT boards, such as the hAP ax S and hEX Refresh. |

The EN7562CT container runtime raises `SIGILL` on ARMv7 hard-float code, so the arm32 build uses `GOARM=5` and Debian's soft-float `armel` port.

To find a device's architecture, run `/system/resource/print` and read `architecture-name`.

## Paths on the device

| Path | Purpose |
|---|---|
| `/storage/tailscale-<arch>.tar` | Image file. |
| `/storage/containers/tailscale` | Container root-dir. RouterOS deletes it when you remove the container. |
| `/storage/container-data/tailscale/state` | Mounted at `/var/lib/tailscale`. Holds `tailscaled.state`, the node identity. |
| `/storage/container-data/tailscale/ssh-host-keys` | Mounted at `/etc/ssh/host-keys`. Holds the SSH host keys. |

If you lose `tailscaled.state`, the node needs a new auth key and gets a new tailnet address.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AUTH_KEY` | Yes | | Tailscale auth key. Treat it as a secret. |
| `ADVERTISE_ROUTES` | Yes | | Comma-separated subnets to advertise, for example `10.0.1.0/24`. |
| `CONTAINER_GATEWAY` | Yes | | The bridge gateway, for example `172.17.0.1`. The container routes each advertised subnet through it. |
| `AUTHORIZED_KEYS` | No | | OpenSSH public keys for `root`, one per line. If unset, nobody can log in over SSH. |
| `TAILSCALE_ARGS` | No | | Extra arguments for `tailscale up`, for example `--advertise-exit-node --snat-subnet-routes=false`. |
| `TAILSCALED_ARGS` | No | | Extra arguments for `tailscaled`. |
| `LOGIN_SERVER` | No | `https://controlplane.tailscale.com` | Control server URL, for example a Headscale server. |
| `UPDATE_TAILSCALE` | No | | If set, even to an empty value, the container runs `tailscale update --yes` at start. |
| `STARTUP_SCRIPT` | No | | Path to a script to run before `tailscaled` starts. The container exits if the script fails. |
| `RUNNING_SCRIPT` | No | | Path to a script to run after `tailscale up` succeeds. The container exits if the script fails. |
| `STATUS_LISTEN` | No | `<container-ip>:8088` | Address and port for the status endpoint. The container IP is the first global IPv4 address. `off` turns the endpoint off. |
| `STATUS_GATE_PREFIX` | No | First entry of `ADVERTISE_ROUTES` | Subnet whose primary state sets `gate.primary`. |

Each start runs `tailscale up --reset`, so put every `tailscale up` flag you need in `TAILSCALE_ARGS`. To make the node an exit node, add `--advertise-exit-node` there, then approve the exit node in the Tailscale admin console.

## Ports

| Port | Use |
|---|---|
| 8088/tcp | Status endpoint. Changes if you set `STATUS_LISTEN`. |
| 22/tcp | SSH, public key only. |

## Status endpoint

`GET http://<container-ip>:8088/cgi-bin/status` returns JSON.

The CGI builds each response from an allowlist of fields, so node keys, user names, and WAN endpoints never appear in it.

`gate.primary` is `true` only if the `tailscaled` backend state is `Running` and this node is primary for `STATUS_GATE_PREFIX`. If `tailscaled` is not running, or does not answer within 3 seconds, `gate.primary` is `false`. `gate.reason` says why.

A RouterOS script can poll the endpoint, for example to advertise the tailnet route into BGP only from the primary node.

`busybox httpd` runs as `nobody` and starts with a cleared environment that holds only `PATH`, so the CGI cannot see `AUTH_KEY` or `AUTHORIZED_KEYS`. The script restarts `httpd` 2 seconds after it exits.

## Deploy

Run these commands on each device. The commands use the arm64 image. For a hAP, use `tailscale-arm32.tar`.

1. Upload the tar to the device:

	```sh
	scp -O tailscale-arm64.tar admin@<device>:storage/tailscale-arm64.tar
	```

2. Create the network, the settings, and the container:

	```
	/interface/veth/add name=veth1 address=172.17.0.2/16 gateway=172.17.0.1
	/interface/bridge/add name=containers
	/ip/address/add address=172.17.0.1/16 interface=containers
	/interface/bridge/port/add bridge=containers interface=veth1
	/container/envs/add list=tailscale key=AUTH_KEY value="<tailscale-auth-key>"
	/container/envs/add list=tailscale key=ADVERTISE_ROUTES value="10.0.1.0/24"
	/container/envs/add list=tailscale key=CONTAINER_GATEWAY value="172.17.0.1"
	/container/envs/add list=tailscale key=AUTHORIZED_KEYS value="<your-ssh-public-key>"
	/container/mounts/add list=tailscale src=/storage/container-data/tailscale/state dst=/var/lib/tailscale
	/container/mounts/add list=tailscale src=/storage/container-data/tailscale/ssh-host-keys dst=/etc/ssh/host-keys
	/container/add file=storage/tailscale-arm64.tar interface=veth1 envlists=tailscale mountlists=tailscale \
		root-dir=/storage/containers/tailscale hostname=<device-name> \
		start-on-boot=yes logging=yes restart-policy=on-failure
	```

3. Wait until the container's status is `stopped`, then start it:

	```
	/container/start [find where hostname="<device-name>"]
	```

4. Approve the advertised routes in the Tailscale admin console.

5. To reach the tailnet from the LAN, route `100.64.0.0/10` to the container.

## Verify

1. Check that the container is running:

	```
	/container/print where hostname="<device-name>"
	```

2. Read the container log. The log shows `Tailscale started` after `tailscale up` succeeds:

	```
	/log/print where topics~"container"
	```

3. From a host on the LAN, read the status endpoint:

	```sh
	curl -s http://172.17.0.2:8088/cgi-bin/status | jq '{backendState: .node.backendState, gate}'
	```

	`backendState` is `Running` when the node has joined the tailnet.

4. Open a shell in the container and check the node:

	```
	/container/shell [find where hostname="<device-name>"]
	# tailscale status
	```

## Upgrade

If other containers on the device use the same Debian base, stop all of them before you add the new image. When a running container shares a layer with the new image, extraction fails with `Text file busy`.

1. Upload the new tar.
2. Stop every container: `/container/stop [find]`.
3. Remove the tailscale container.
4. Add it again with the same settings. Wait until its status is `stopped`.
5. Start all containers.

The node keeps its identity, because `tailscaled.state` is on a data mount.

## Remove

1. Stop and remove the container:

	```
	/container/stop [find where hostname="<device-name>"]
	/container/remove [find where hostname="<device-name>"]
	```

2. Remove the settings and the network:

	```
	/container/envs/remove [find where list=tailscale]
	/container/mounts/remove [find where list=tailscale]
	/interface/bridge/port/remove [find where interface=veth1]
	/interface/veth/remove veth1
	```

3. Delete `/storage/tailscale-<arch>.tar` and `/storage/container-data/tailscale`. Deleting the data directory destroys the node identity.
4. Delete the machine in the Tailscale admin console.

If you created the `containers` bridge and its address only for this container, remove them too.

## Process model

```
ts-init (PID 1)
└── tailscale.sh
    ├── tailscaled
    ├── busybox httpd (status endpoint)
    └── sshd -D
```

`ts-init` ([init/main.go](init/main.go)) adopts orphaned processes and reaps them. It forwards `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT`, `SIGUSR1`, `SIGUSR2`, and `SIGWINCH` to `tailscale.sh`, and exits with the script's exit code.

RouterOS sends the stop signal only if PID 1 has a signal handler installed. Without one, RouterOS sends `SIGKILL`.

On `SIGTERM`, `tailscale.sh` stops `sshd`, the status server, and `tailscaled`. A clean `tailscaled` shutdown lets it tell the control server that it is leaving, so another subnet router takes over sooner.

If `tailscaled` exits, the script exits with its status. Use `restart-policy=on-failure` so RouterOS restarts the container.

## SSH

`sshd` accepts public keys only. At start, `tailscale.sh` writes `AUTHORIZED_KEYS` to `/root/.ssh/authorized_keys`. If `AUTHORIZED_KEYS` is unset, the script deletes that file and logs a warning.

The script creates each SSH host key in `/etc/ssh/host-keys` if it is missing. The keys persist on the `ssh-host-keys` mount, so the fingerprints survive a container rebuild.

`sshd_config` sets `AllowTcpForwarding no`, so you cannot jump through the container. To reach its SSH from another host, enable forwarding on the device and use the device as a jump host:

```
/ip/ssh/set forwarding-enabled=local
```

```sh
ssh -J admin@<device> root@172.17.0.2
```
