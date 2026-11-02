## Kernel support

### Version

Your host should have kernel version 5.4 or higher or a kernel with the necessary backports (like RHEL 4.18).

### Modules

Your kernel needs to be compiled with the necessary modules.  
Those modules should be available:
```
Module             Used by

nft_ct             
nft_chain_nat      
nf_nat             xt_nat,nft_chain_nat,xt_MASQUERADE
nf_conntrack       nft_ct,xt_nat,xt_conntrack,xt_MASQUERADE,nf_nat
nf_defrag_ipv6     nf_conntrack
nf_defrag_ipv4     nf_conntrack
nf_tables          nft_ct,nft_chain_nat,nft_compat
nfnetlink          nft_compat,nf_tables
```

Because they depend on the others, it should be enough to check for `nft_ct` and `nft_chain_nat`.

The firewall is set up with nftables only. Hosts whose kernel lacks `nf_tables` are not supported; the former `LEGACY_IPTABLES` iptables fallback has been removed.

### Typical errors:

`Error: Could not process rule: No such file or directory` [(Issue)](https://github.com/Trigus42/alpine-qbittorrentvpn/issues/66)  
`Error: Could not process rule: Invalid argument` [(Issue)](https://github.com/Trigus42/alpine-qbittorrentvpn/issues/50)  
`netlink: Error: cache initialization failed: Invalid argument` [(Issue)](https://github.com/Trigus42/alpine-qbittorrentvpn/issues/52)  

## Sonarr, Radarr or other containers cannot reach the WebUI

Symptoms: the *arr client reports "Unable to communicate with qBittorrent" or "Failed to connect", the WebUI works from a browser on the LAN, and the qBittorrent log shows no request from the client at all. From the client container, `curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://<host-ip>:8080/api/v2/app/version` prints `000` (timeout) instead of `403`.

Cause: `WEBUI_ALLOWED_NETWORKS` is set and does not cover the docker gateway address the client arrives from (see [WebUI access from other containers](../../README.md#webui-access-from-other-containers)), either because `WEBUI_ALLOW_DOCKER_GATEWAY=no` is set or because the image predates that variable. Listing the client's own network (for example `172.24.0.0/16`) does not help, the traffic never carries that source address.

Fix: remove `WEBUI_ALLOW_DOCKER_GATEWAY=no` or update the image, or add the gateway address to `WEBUI_ALLOWED_NETWORKS` by hand. Check what is currently allowed with:
```sh
docker exec qbittorrent nft list set inet qbt-firewall webui_allowed_networks_ipv4
```

## Wrong date due to outdated seccomp
```sh
/ # date
Mon Jul 26 15:00:00 UTC 2036
```

This can lead to several commands failing. For example:
```
/ # apk update
fetch https://dl-cdn.alpinelinux.org/alpine/v3.14/main/armv7/APKINDEX.tar.gz
ERROR: https://dl-cdn.alpinelinux.org/alpine/v3.14/main: temporary error (try again later)
...
```

### Solution:  
Update the libseccomp2 package on your host machine to version 2.4 or newer. If no never version is available from your sources, try to manually download and install a newer version. If you are using a Debian based distro you can find packages [here](http://ftp.debian.org/debian/pool/main/libs/libseccomp/).

Example commands for the RPi:
```
$ wget http://ftp.debian.org/debian/pool/main/libs/libseccomp/libseccomp2_2.5.1-1_armhf.deb
$ dpkg -i libseccomp2_2.5.1-1_armhf.deb
```
