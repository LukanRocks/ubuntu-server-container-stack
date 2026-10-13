# Ubuntu Home Server — Compose Conventions

This repo is a Docker Compose based home server. The root [docker-compose.yaml](docker-compose.yaml)
only declares shared resources (networks, the project name) and pulls in every
service via `include:`. Each service lives in its own file, grouped by folder:

- `compose/applications/` — user-facing apps
- `compose/infrastructure/` — platform services
- `compose/iot/` — home automation / IoT services

If asked to create a new compose file and the target folder isn't specified or
obvious from context, ask which of the three it belongs, or if a new folder needs to be created before creating it.

## Service file template

Use [compose/applications/homebox.yaml](compose/applications/homebox.yaml) as the
reference example. Structure every new service file as:

```yaml
# Short description of what the service does.
# Link to docs, e.g. https://example.com/docs

services:
  service-name:
    container_name: service-name
    image: registry/image:tag
    restart: unless-stopped
    depends_on:
      - service-name
    security_opt:
      - no-new-privileges:true
    env_file: # Password and Secrets only file
      - $DOCKER_SECRETS_DIR/service-name_secrets
    environment: # non-secret config only
      - TZ=$TZ
      - SOME_OPTION=value
    volumes:
      - $DOCKER_DATA_DIR/service-name:/data:rw
    networks:
      - traefik-proxy
    ports: # only when something outside Traefik must reach the container
      - 127.0.0.1:1234:1234
    healthcheck:
      test: ['...']
    labels:
      - traefik.enable=true
      - traefik.http.routers.service-name.rule=Host(`service-name.homeserver.lukan.rocks`)
      - traefik.http.services.service-name.loadbalancer.server.port=1234
    # anything else (command, extra labels, etc.) goes after labels
```

Key order within a service is fixed: `container_name`, `image`, `restart`, `depends_on`, `privileged`, `network_mode`, `extra_hosts`, `security_opt`, `env_file`, `environment`, `volumes`, `networks`, `ports`, `healthcheck`, `labels`, then anything else the service needs. `privileged` and `network_mode` are only present when the container genuinely requires them and replace `networks` when used — a service doesn't declare both. `extra_hosts` is only present when needed; it sits right after `network_mode`/`privileged` since it's networking-related config, whether or not the service actually uses `network_mode`.

Defaults — deviate only when the container genuinely requires it or otherwise specified:
- `restart: unless-stopped`
- `security_opt: [no-new-privileges:true]`
- `networks: [traefik-proxy]`
- `labels` at minimum enable Traefik routing for the service's web interface

`environment` and `env_file` entries use list form (`- KEY=value`), not map form
(`KEY: value`) and not a bare scalar.

## Traefik routing

Three labels, no more. Entrypoints, TLS and the certresolver are set once
globally on the `websecure` entrypoint in
[config/traefik/config.yaml](config/traefik/config.yaml), so no service repeats
them:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.<container-name>.rule=Host(`<host>.homeserver.lukan.rocks`)
  - traefik.http.services.<container-name>.loadbalancer.server.port=<port>
```

Name the router and the service after the container (no `-router`/`-services`
suffixes — the label path already distinguishes them). `<host>` is usually the
container name but not always (`ghv`, `ha`, `mqtt`, `z2m`, `esh`), which is why
the rule stays an explicit label rather than a `defaultRule` template.

Always include the port label, even when the image exposes exactly one port.
Without any `traefik.http.services.*` label Traefik builds a default service
from the container, which fails with `port is missing` for `network_mode: host`
containers and takes that container's whole config down with it.

Traefik runs with `network_mode: host`. That is load-bearing: it lets Traefik
reach bridge containers by IP *and* resolve host-network containers (bambuddy,
esphome, homeassistant) to `127.0.0.1`, which is the only reason those are
routable. Don't move it onto the bridge network.

Traefik's own dashboard is routed from
[config/traefik/dynamic/](config/traefik/dynamic/), not from labels, because
`api@internal` isn't a container the Docker provider can discover. That
directory is the file provider's — it must stay separate from the directory
holding the static `config.yaml`.

## Networks

Shared networks are declared in the root [docker-compose.yaml](docker-compose.yaml);
a network private to one stack is declared in that stack's own service file
(see [compose/applications/karakeep.yaml](compose/applications/karakeep.yaml)).

A service can join several networks — list them all under `networks:`. Traefik
picks the right address because `providers.docker.network: traefik-proxy` is set
globally. Avoid `internal: true` unless the containers on that network genuinely
need no outbound internet access.

Home Assistant runs host-network and so has no Docker DNS. Services it must
reach publish a port on `127.0.0.1` and get an `extra_hosts` alias pointing at
`127.0.0.1`, which keeps the hostnames stable inside Home Assistant without
pinning containers to static IPs.

## Secrets

Any env var holding a secret or password does **not** go in `environment:`.
Instead:

1. Create a file in `./secrets/` (referenced as `$DOCKER_SECRETS_DIR` in compose
   files), formatted as one or more `KEY=VALUE` lines — e.g.
   `secrets/service_secrets` contains `API_KEY=...`.
2. Reference it from the service with `env_file:`, not the Docker Compose
   top-level `secrets:` block:
   ```yaml
   env_file:
     - $DOCKER_SECRETS_DIR/service-name_secrets
   ```

Everything else (feature flags, log levels, hostnames, non-sensitive config)
stays inline under `environment:`.