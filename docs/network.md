# Network layers

Three things on this box touch networking: **Traefik**, the **Tailscale sidecar**, and
**gluetun**. They never fight each other, because each governs a different *direction* of
traffic and each container has exactly one network stack.

| Layer | Direction it governs | Which containers | Mechanism |
| --- | --- | --- | --- |
| Traefik | inbound, LAN only | any container carrying `traefik.*` labels | runs in the host netns; terminates TLS and routes on `Host()` |
| Tailscale sidecar | inbound, from the internet | `jellyfin` only | its own tailnet node, `tailscale serve` over a private bridge network |
| gluetun | outbound | only containers declaring `network_mode: service:gluetun` | replaces the tenant's netns: `tun0` is the default route, plus a kill-switch firewall |

```
   INBOUND from the LAN                             INBOUND from the internet
   you @ 192.168.1.x                                a friend's device
   https://*.homeserver.lukan.rocks                 jellyfin.<tailnet>.ts.net
   (UDM DNS rule -> 192.168.1.4; public DNS         (shared node, funnel off)
    answers Vercel's IPs, not the house)
            |                                                |
            v                                                v
   +---------------------------+                   +----------------------------+
   | traefik (host netns)      |                   | jellyfin-tailscale         |
   | :80 -> :443, TLS, Host()  |                   | userspace, tailscale serve |
   +------------+--------------+                   +------------+---------------+
                |                                               | 172.20.0.x
                | 172.18.0.x:<port>                             v
                |                                        jellyfin :8096
                +--> homebox, karakeep, ... (traefik-proxy, 172.18.0.0/16)
                |
                +--> gluetun  172.18.0.x  <-- inbound only on FIREWALL_INPUT_PORTS
                       |  tun0 -> Surfshark  --> ALL tenant egress leaves here
                       |  (shares its netns)
                       +--> qbittorrent  (no networks:, no ports: of its own)
```

## Invariants

1. One netns per container, so no container is ever governed by two of these layers.
2. Traefik and Tailscale never change where traffic *leaves* from. Only gluetun does.
3. gluetun affects nothing that hasn't explicitly opted in.
4. A tunneled service still gets its LAN hostname and certificate. Inbound over `eth0` and
   outbound over `tun0` are different directions through different interfaces.

## How each layer is reached

**Traefik.** `homeserver.lukan.rocks` and `*.homeserver.lukan.rocks` resolve to
`192.168.1.4` because of a DNS rule on the UniFi Dream Machine — not from public DNS,
which answers with Vercel's addresses for the `lukan.rocks` zone. Certificates come from
Let's Encrypt over the DNS-01 challenge against that Vercel-hosted zone, so no inbound
port from the internet is ever needed. Everything Traefik serves is LAN-only.

**Tailscale sidecar.** `jellyfin-tailscale` is a separate container with its own identity
on the tailnet, sharing the private `jellyfin-tailscale` bridge with Jellyfin and proxying
tailnet requests to `jellyfin:8096`. Funnel is off; access is granted per-person by sharing
the node from the Tailscale admin console. It is ingress only and does not touch Jellyfin's
outbound traffic.

**gluetun.** Tenants declare `network_mode: service:gluetun` and therefore have no
interface of their own — their only route out is `tun0`. gluetun's firewall drops
everything that didn't arrive over the VPN, except the ports listed in
`FIREWALL_INPUT_PORTS`. Traefik (host netns) connects to the tenant's UI at gluetun's
`traefik-proxy` address with source `172.18.0.1`, which is inside the `172.18.0.0/16`
subnet gluetun auto-allows. Traefik's Docker provider resolves a `service:` container by
inspecting the parent container, so the tenant keeps its own three Traefik labels.

## Host firewall, and why the subnets are pinned

`ufw` is active on the host and defaults to **deny incoming**, so a container cannot reach a
host-network service unless a rule allows it. There is exactly one such rule:

```
8123/tcp   ALLOW IN   172.18.0.0/16        # Home Assistant, from traefik-proxy only
```

It matches on the **source** subnet, which makes the Docker subnet assignment load-bearing.
That's why all three networks pin their range explicitly:

| Network | Subnet | Declared in |
| --- | --- | --- |
| traefik-proxy | `172.18.0.0/16` | [../docker-compose.yaml](../docker-compose.yaml) |
| karakeep-internal | `172.19.0.0/16` | [../compose/applications/karakeep.yaml](../compose/applications/karakeep.yaml) |
| jellyfin-tailscale | `172.20.0.0/16` | [../compose/arr/jellyfin.yaml](../compose/arr/jellyfin.yaml) |

Without the pins, `docker compose down` releases the subnets and the next `up` hands out
whatever is free, in whatever order the networks happen to be created. **The symptom is
nasty: every container starts and reports healthy, while anything that talks to Home
Assistant times out.** `docker network inspect traefik-proxy` is what reveals it. This
happened once — `traefik-proxy` came back as `172.19.0.0/16` and two services crash-looped
for half an hour. Only `traefik-proxy`'s range actually matters, but the other two are
pinned so they can't claim `172.18.0.0/16` first and make the pinned create fail with
`Pool overlaps with other one on this address space`.

A gluetun tenant has no address on `traefik-proxy`, so it cannot reach Home Assistant at
all. That's intended.

**Reaching Home Assistant from a container:** add
`extra_hosts: - host.docker.internal:host-gateway` and use
`http://host.docker.internal:8123`. Never hardcode a gateway IP — `speech-to-phrase` used
to point at `172.18.0.1` and broke the moment the subnet moved.

**The reverse direction** (Home Assistant → a container) doesn't touch any of this: HA runs
host-network with no Docker DNS, so a service it needs publishes a port on `127.0.0.1` and
gets an `extra_hosts` alias in `homeassistant.yaml` pointing there.

## Why Jellyfin stays outside the tunnel

- A container cannot have both `network_mode: service:` and `networks:`. Tunneling Jellyfin
  would pull it off `jellyfin-tailscale`, and the sidecar would have nothing to resolve or
  reach — outside access breaks outright.
- Tunneling the sidecar too is worse. `tailscaled` would reach the tailnet through
  Surfshark, and since Surfshark offers no port forwarding, NAT traversal fails and every
  session falls back to DERP relays. A friend's stream would travel via a relay and the VPN
  exit, both ways.
- Streaming is the heaviest traffic on this box. A consumer VPN caps throughput, adds
  latency, and sustained streaming is generally against provider AUP.
- There is nothing to hide. Jellyfin's only egress is TMDB/TVDB metadata and plugin
  updates; it never announces itself to strangers.

**The rule:** gluetun is for containers that *initiate* connections to strangers — torrent
peers, trackers, indexers. Traefik and Tailscale are for containers that *accept*
connections from people you trust.

## Adding the next tenant behind gluetun

1. Remove `networks:` and `ports:` from the service; add
   `network_mode: service:gluetun`.
2. Add `depends_on: {gluetun: {condition: service_healthy}}`.
3. Give it a port no other tenant uses — they share one netns, so ports collide.
4. Append that port to `FIREWALL_INPUT_PORTS` in
   [compose/infrastructure/gluetun.yaml](../compose/infrastructure/gluetun.yaml).
5. Keep the three Traefik labels on the service itself.
6. Recreate **every** tenant whenever gluetun is recreated — a netns belongs to a
   container ID, and tenants of the old one are left with no network:
   `docker compose up -d --force-recreate <tenants>`.

### Addressing between services

- Tenant → tenant: `http://127.0.0.1:<port>`. They share a netns, so no DNS is involved.
- Non-tenant → tenant: `http://gluetun:<port>` on `traefik-proxy`. The address is
  gluetun's, not the tenant's.
- Tenant → non-tenant: tenants have no Docker DNS, so they cannot resolve `sonarr` or
  `radarr` by name. A tenant that must call out to a container on `traefik-proxy` needs
  `FIREWALL_OUTBOUND_SUBNETS=172.18.0.0/16` on gluetun and an IP or an `extra_hosts` alias.
- Reaching a tenant straight from a LAN machine (bypassing Traefik) needs
  `FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24`.

### NAS access is not network access

`library` is a CIFS mount made by the **host** kernel against `192.168.1.6`. A tenant
writing to `/data/Torrents` sends no SMB packets through its own netns, so the tunnel is
irrelevant to it and needs no outbound-subnet rule. qBittorrent (inside the tunnel) and
Jellyfin (outside it) meet on the filesystem, not on the network — see
[storage.md](storage.md) for the layout.

## Failure modes

| What breaks | Effect |
| --- | --- |
| Traefik down | No web UIs on the LAN. Containers keep running, egress unaffected. |
| Tailscale sidecar down | Friends lose Jellyfin. LAN access unaffected. |
| gluetun down | Its tenants have no network at all — that is the kill switch working. Everything else is unaffected. |
| gluetun recreated | Tenants keep running but hold a dead netns. Recreate them. |
| VPN credentials expired | gluetun stays unhealthy, so tenants never start (`depends_on: service_healthy`). |
