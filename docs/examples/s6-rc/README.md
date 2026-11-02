# Custom s6-rc Extensions

The folders in this directory are examples of complete native `s6-rc` service definitions. They offer complete control compared to simply dropping a flat bash script somewhere.

If you mount custom native folders correctly, a container hook will merge them directly into the s6 supervision tree just before boot.
The folders are read on every start, so edits take effect after a restart. A component that cannot be merged (no `type` file, a `longrun` without `run`, a failed copy) parks the container: it stays up but reports `unhealthy`, and `docker inspect` names the component at fault.

### `/custom-init` (Oneshot Tasks)
Components dropped here run predictably before the rest of your core stack runs. Use them to cleanly install software or set configuration parameters exactly where you need them in the dependency chain.

### `/custom-services` (Long-running Daemons)
Components dropped here will run natively supervised. If your script crashes, s6 will immediately restart it. This is highly recommended for tasks like VPN port forwarding monitors, proxies, or companion UI daemons.

### Dependencies and the kill switch
The kill switch (the nftables rules that drop everything not going through the tunnel) only exists once the `init-network` oneshot has run, after the tunnel is up. Before that, traffic leaves over the docker interface unprotected.

* `/custom-services` components always start behind the kill switch: the hook adds `dependencies.d/init` to each of them (the `init` bundle contains every `init-*` oneshot and all `/custom-init` components). Your own `dependencies.d` entries are kept on top of it.
* `/custom-init` components are part of `init` themselves, so they cannot depend on it. One that depends only on `base` (see `my-startup-task`) runs as early as possible, before the VPN and the kill switch. Make it depend on `init-network` instead if it talks to the network and must do so through the tunnel.
* Components are merged into the tree as `custom-<folder name>`, so a dependency on another custom component is spelled `dependencies.d/custom-<folder name>`.
