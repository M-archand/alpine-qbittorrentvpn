# qBittorrentVPN
[![Publish Docker image](https://github.com/M-archand/alpine-qbittorrentvpn/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/M-archand/alpine-qbittorrentvpn/actions/workflows/docker-publish.yml)
[![Container image](https://img.shields.io/badge/ghcr.io-m--archand%2Falpine--qbittorrentvpn-blue)](https://github.com/M-archand/alpine-qbittorrentvpn/pkgs/container/alpine-qbittorrentvpn)

Docker container which runs the latest qBittorrent-nox client while connecting to WireGuard or OpenVPN with netfilter killswitch to prevent IP leakage when the tunnel goes down.

## Features

* Netfilter **killswitch** to prevent IP leaking when VPN connection fails
* Selectively enable or disable **WireGuard** or **OpenVPN** support
* **IPv6** support
* Configurable **UID** and **GID** for config files and /downloads for qBittorrent
* Built for **amd64**, **arm64**, **armv7** and **armv6**
* ...

# Run container:

* Modify one of the [example compose files](docs/examples/compose) to your needs.
* [Create the necessary VPN config files](#vpn-configuration).

Then start the container by running:

```sh
docker compose up -d
```

Keep a restart policy such as `restart: unless-stopped` (set in all examples). When the tunnel stops passing traffic the container halts itself and relies on Docker to start it again with a fresh tunnel; without a restart policy it simply stays stopped.

&NewLine;

## Image Tags

Images are published to the GitHub Container Registry as `ghcr.io/m-archand/alpine-qbittorrentvpn`.

| Tag | Description |
|----------|----------|
| `ghcr.io/m-archand/alpine-qbittorrentvpn:latest` | Built from `master` on every push, and rebuilt daily when a new qBittorrent release is detected |
| `ghcr.io/m-archand/alpine-qbittorrentvpn:X.Y.Z` | Manual release, built once from a chosen qBittorrent release and never changed afterwards |
| `ghcr.io/m-archand/alpine-qbittorrentvpn:stable` | Always points at the most recent `X.Y.Z` manual release |

`latest` and `stable` move; pin `X.Y.Z` to stay on one exact build.

## Environment Variables
| Variable | Function | Example | Default |
|----------|----------|----------|----------|
|`DEBUG`| Print information useful for debugging in log |`yes`|`no`|
|`DOWNLOAD_DIR_CHOWN`| Whether or not to chown files in the `/downloads` directory to `PUID` and `PGID` |`no`|`yes`|
|`ENABLE_SSL`| Let the container handle SSL |`yes`|`no`|
|`FIREWALL_CHECK_HOST`| Host or IP that must stay unreachable over the docker interface (ICMP echo and TCP port 53 are probed) to prove the kill switch works | `9.9.9.9` | `8.8.8.8`|
|`FIREWALL_CHECK_INTERVAL`| Interval in seconds between kill-switch (firewall) checks |`5`|`5`|
|`HEALTH_CHECK_HOST`| Host or IP that will be used to check if the connection is still up |`8.8.8.8`|`1.1.1.1`|
|`HEALTH_CHECK_INTERVAL`| Interval in seconds between connection checks |`5`|`5`|
|`HEALTH_CHECK_TIMEOUT`| Time in seconds to wait for the internet connection to be restored before restarting |`30`|`15`|
|`PGID`| GID that qBt will be run as and to be applied to /config files and /downloads |`100`|`1000`|
|`PUID`| UID that qBt will be run as and to be applied to /config files and /downloads |`99`|`1000`|
|`TZ`| Specify a timezone to use |`Europe/London`|`UTC`|
|`UMASK`| Set file mode creation mask |`002`|`002`|
|`VPN_ENABLED`| Enable VPN (yes/no)?|`yes`|`yes`|
|`VPN_PASSWORD`| If username and password provided, configures all ovpn files automatically |`ac98df79ed7fb`||
|`VPN_TYPE`| WireGuard or OpenVPN (wireguard/openvpn)?|`openvpn`|`wireguard`|
|`VPN_USERNAME`| If username and password provided, configures all ovpn files automatically |`ad8f64c02a2de`||
|`WEBUI_ALLOWED_NETWORKS`| Comma delimited networks in CIDR notation. If set, only networks in this list (plus the docker gateway, see below) can access the WebUI. |`192.168.0.0/16,fd5e:d5b:760a:4796::/64`||
|`WEBUI_ALLOW_DOCKER_GATEWAY`| Also allow the docker gateway address when `WEBUI_ALLOWED_NETWORKS` is set, so the host and other containers on it (Sonarr, Radarr, a reverse proxy, ...) can reach the WebUI. Set to `no` to allow the listed networks only. See [WebUI access from other containers](#webui-access-from-other-containers). |`no`|`yes`|
|`WEBUI_PASSWORD`| Set WebUI password if none is set (won't change it) |`mypassword`||

## Volumes
| Volume | Required | Function | Example |
|----------|----------|----------|----------|
| `config` | Yes | qBittorrent, WireGuard and OpenVPN config files | `/your/config/path/:/config`|
| `downloads` | No | Default downloads path for saving downloads | `/your/downloads/path/:/downloads`|

## Ports
| Port | Proto | Required | Function | Example |
|----------|----------|----------|----------|----------|
| `8080` | TCP | Yes | qBittorrent WebUI | `8080:8080`|

## WebUI access from other containers
Other containers on the same host (Sonarr, Radarr, Prowlarr, a reverse proxy, ...) reach qBittorrent through the port you publish on the host, for example `http://192.168.1.10:8080`. Docker does not forward that traffic into the container directly: it ends at `docker-proxy` on the host, which opens its own connection to qBittorrent from the gateway address of the container's network (`172.17.0.1` on the default bridge, `172.18.0.1` or similar on a compose network). qBittorrent and the firewall therefore see the gateway address, not the address of the calling container or of its network. Browsers on your LAN keep their real address. The same applies to `curl http://localhost:8080` run on the host.

Without `WEBUI_ALLOWED_NETWORKS` nothing changes: the WebUI accepts every source and qBittorrent's login protects it. With `WEBUI_ALLOWED_NETWORKS` set, the firewall drops every other source, and a list such as `192.168.1.0/24` would silently cut off every container on the host. The container therefore adds its docker gateway address to the allow list automatically (`WEBUI_ALLOW_DOCKER_GATEWAY=yes`, the default). The startup log shows the address it added.

What that opens: the host itself and every container running on it can reach the WebUI login page and API. qBittorrent's username/password or API key still applies. Everything outside the listed networks stays blocked. Set `WEBUI_ALLOW_DOCKER_GATEWAY=no` if you want the WebUI reachable from the listed networks only, for example when the host also runs containers you do not trust and nothing on the host needs the qBittorrent API. In that mode Sonarr and friends on the same host cannot connect unless you add the gateway address (`172.17.0.1/32`) to `WEBUI_ALLOWED_NETWORKS` yourself.

Do not put the gateway address into qBittorrent's "Bypass authentication for clients in whitelisted IP subnets": every container on the host would then skip the login. Use an API key or credentials in Sonarr/Radarr instead.

If the Docker daemon runs with `"userland-proxy": false`, there is no `docker-proxy`: containers on the same network as qBittorrent connect with their own address (add that network to `WEBUI_ALLOWED_NETWORKS`), and containers on other networks cannot reach a published port through the host at all in that mode.

## Host header validation (DNS rebinding)
qBittorrent's "Enable Host header validation" (Options, Web UI, Security) is left on, as in qBittorrent itself. On its own it blocks nothing: the default "Server domains" value `*` accepts every `Host` header. To stop a malicious web page from reaching the WebUI through DNS rebinding, put the names and addresses you use in the browser into "Server domains", separated by `;` and without spaces, for example `qbt.home.lan;192.168.1.10`. Requests that carry another `Host` header are answered with `401 Unauthorized`, so a reverse proxy in front of the WebUI must send one of the listed names (for nginx: `proxy_set_header Host $host;` and list the public name). `WEBUI_ALLOWED_NETWORKS` is a different layer: it filters by source address, Host header validation by the name the browser asked for.

Installs created by older versions of this image have `HostHeaderValidation=false` in `/config/qBittorrent/config/qBittorrent.conf`; the setting is kept across updates, switch it on in Options, Web UI, Security.

## Health check
The image ships a Docker `HEALTHCHECK`. The container is `healthy` while qBittorrent is running and `unhealthy` when it is not: after a failed start (no VPN config, invalid `PUID`/`PGID`, host network mode, firewall setup failure, ...) and after the kill switch tripped. In both cases the container is parked on purpose: qBittorrent is stopped so nothing can leak, and the container keeps running so a restart policy does not loop it. Get the reason with:

```sh
docker inspect --format '{{json .State.Health}}' qbittorrent
docker logs qbittorrent
```

Fix the cause and restart the container. Tools that act on the health status (`autoheal`, Compose `depends_on` with `condition: service_healthy`) work out of the box. Override the timing with a `healthcheck:` block in your compose file if needed.

## VPN Configuration
If there are multiple config files present, one will be choosen randomly.
The chosen file is not modified: the container works on a copy under `/run`, so the config can be mounted read-only.

## WireGuard 
The container will fail to boot if `VPN_ENABLED` is set and there is no valid `INTERFACE.conf` file present in the `/config/wireguard` directory. Drop a `.conf` file from your VPN provider into `/config/wireguard` and start the container again.

> Recommended INTERFACE names include `wg0` or `wgvpn0` or even `wgmgmtlan0`. However, the number at the end is in fact optional, and really any free-form string `[a-zA-Z0-9_=+.-]{1,15}` will work. So even interface names corresponding to geographic locations would suffice, such as `cincinnati`, `nyc`, or `paris`, if that's somehow desirable. 
[[source]](https://www.man7.org/linux/man-pages/man8/wg-quick.8.html)

## OpenVPN
The container will fail to boot if `VPN_ENABLED` is set and there is no valid `FILENAME.ovpn` file present in the `/config/openvpn` directory. Drop a `.ovpn` file from your VPN provider into `/config/openvpn` (if necessary with additional files like certificates) and start the container.  

You can either use the environment variables `VPN_USERNAME` and `VPN_PASSWORD` or store your credentials in `openvpn/credentials.conf`. Those credentials will be used to create credential files for all VPN configs initially. 
If you manually store your VPN credentials in `openvpn/FILENAME_credentials.conf`, those will be used for the particular VPN config.

#### Example credentials file
```
YOURUSERNAME
YOURPASSWORD
```

## DNS
Before the tunnel is up the container uses the DNS settings Docker gives it (`--dns` / Compose `dns:` / Kubernetes `dnsConfig`), see the [example compose files](docs/examples/compose).
Once connected, the resolvers provided by the VPN replace them: the `DNS=` line of a WireGuard config, or the `dhcp-option DNS`/`DNS6`/`DOMAIN` options pushed by an OpenVPN server. If the VPN provides no resolvers, the Docker DNS settings stay in place.

## PUID/PGID
User ID (PUID) and Group ID (PGID) can be found by issuing the following command for the user you want to run the container as:

```sh
id <username>
```

# Customization

The container natively supports s6-rc extensibility. If you want to run a custom init script or you want to run long-lived background daemons, you can provide native `s6-rc` service directories! 

* **`/custom-init`**: Any valid `s6-rc` component directory placed here will be added to the `init` bundle automatically. This is ideal for run-once setup scripts (like firewall rules or fetching configurations). A component that depends only on `base` runs before the VPN and the kill switch exist; make it depend on `init-network` if it must run behind them.
* **`/custom-services`**: Any valid `s6-rc` component directory placed here will be added to the `user` bundle automatically (run alongside qBittorrent). This is ideal for background applications (like a custom application or a VPN port forwarding daemon). Every component here is made to depend on `init`, so it starts only once the tunnel is up and the kill switch is loaded, whatever its own `dependencies.d` says.

For an example of the structure these folders must have, see [docs/examples/s6-rc](docs/examples/s6-rc).

# Build it yourself
&NewLine;
You can use the `Dockerfile` with all architectures and versions of qBT that are listed [here](https://github.com/userdocs/qbittorrent-nox-static/releases).

If you don't specify any tags, the latest release version will be used.

&NewLine;
```sh
$ git clone https://github.com/M-archand/alpine-qbittorrentvpn.git
$ cd alpine-qbittorrentvpn
$ QBITTORRENT_TAG={TAG} docker build -f Dockerfile -t qbittorrentvpn .
```

Build for all supported architectures:
```
$ QBITTORRENT_TAG={TAG} docker buildx bake -f bake.yml
```

Lint the shell scripts (the same check CI runs, needs Docker):
```sh
$ bash tests/shellcheck.sh
```

If you want to use this command to push the images to a registry (append `--push` to the above command), you have to modify the `image` setting in `bake.yml`.

# Reporting Issues

When encountering an issue, please first attempt to reproduce it using the most up-to-date stable versions of Docker, your operating system, kernel, and the container itself.

Before opening a new issue, please refer to previously reported issues as well as the [common issues](docs/troubleshooting/common-issues.md). Your issue might have already been addressed, or there may be ongoing discussions that you can join.

Upon opening an issue, kindly provide the following details:

- Full logs from container boot to exit, preferably with the `DEBUG=yes` environment variable set.
- Your Docker compose file or Docker run command.
- Depending on your situation, other relevant information such as:
  - The image where the issue first arose: its tag and the `Image build from commit ...` line printed at the top of the container log. This is immensely useful if you suspect that a recent change introduced the problem.
  - Your VPN config file, with any keys and other sensitive information removed.
  - Any additional details that may be relevant to your specific situation.

While logs should not display passwords and keys, it is highly recommended to review them for any sensitive information. Depending on your particular case, you might also want to redact IP addresses and domain names.

# Credits:

## Software
* [alpine](https://hub.docker.com/_/alpine) (base image)
* [qBittorrent](https://github.com/qbittorrent/qBittorrent)
* [WireGuard](https://www.wireguard.com/) / [OpenVPN](https://github.com/OpenVPN/openvpn)
* ...

## Inspiration
This image was inspired by and is partially based on [DyonR/docker-qbittorrentvpn](https://github.com/DyonR/docker-qbittorrentvpn), [MarkusMcNugen/docker-qBittorrentvpn](https://github.com/MarkusMcNugen/docker-qBittorrentvpn) and [binhex/arch-qbittorrentvpn](https://github.com/binhex/arch-qbittorrentvpn).
