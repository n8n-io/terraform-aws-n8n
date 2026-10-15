# Running n8n behind a TLS proxy

Two independent cases, which can be combined:

- **Outbound.** n8n's calls to the internet (workflow HTTP requests, license
  server, community-node registry, OAuth providers) pass through a
  TLS-inspecting egress proxy that re-signs certificates with a private CA.
- **Inbound.** A proxy, WAF or CDN sits in front of the module's ALB and
  terminates the client's TLS.

## Outbound: `n8n_extra_ca_pem`

```hcl
n8n_extra_ca_pem = file("${path.module}/proxy-ca.pem")

n8n_extra_env = [
  { name = "HTTPS_PROXY", value = "http://proxy.example.com:3128" },
  { name = "HTTP_PROXY", value = "http://proxy.example.com:3128" },
  { name = "NO_PROXY", value = ".svc,.cluster.local,.rds.amazonaws.com,.cache.amazonaws.com,169.254.170.23" },
]
```

The module stores the PEM in the Secret `n8n-ca-bundle-secret`, mounts it
read-only at `/etc/n8n-certs/ca-bundle.crt` on main, worker and
webhook-processor pods, and sets `NODE_EXTRA_CA_CERTS` to that path. Node adds
the certificates to its built-in roots; it does not replace them.

- Certificates only. A private key block is rejected at plan time.
- `NODE_EXTRA_CA_CERTS` is reserved against `n8n_extra_env`,
  `n8n_worker_extra_env` and `n8n_worker_pools[*].extra_env` while the input is
  set.
- Changing the PEM rolls every n8n pod through a `checksum/extra-ca` pod
  annotation, because Node reads the file once at start.
- The proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) stay in
  `n8n_extra_env`, which reaches the n8n containers on every role and not the
  task runner sidecars. They route HTTP(S) requests only. n8n's PostgreSQL and
  Redis connections are plain TCP and never go through them, so RDS and
  ElastiCache endpoints need no `NO_PROXY` entry.
- `NO_PROXY` takes comma-separated hostnames, domain suffixes (a leading `.` or
  `*.`), exact IP addresses, each with an optional `:port`. It does not parse
  CIDR notation, so an entry such as `10.0.0.0/8` is inert and an HTTP(S)
  request to a bare VPC IP still goes through the proxy. List every HTTP(S)
  destination that must bypass the proxy by hostname or exact IP, such as the
  cluster's service domains (`.svc`, `.cluster.local`). The module only sets
  these environment variables: whether a given client honors them is up to the
  client. Node's built-in HTTP stack does not read them on its own, and the AWS
  SDK for JavaScript needs a proxy agent configured explicitly. If a client is
  configured to proxy, keep the EKS Pod Identity agent address
  (`169.254.170.23`) in `NO_PROXY` so credential requests stay direct.
- Credentials can be embedded in the proxy URL, which keeps them in Terraform
  state.
- RDS and ElastiCache chains are unaffected: the database CA is delivered
  separately (`db_postgresdb_ssl_ca_pem`, see [postgresql-tls.md](./postgresql-tls.md))
  and the module sets no other `NODE_EXTRA_CA_CERTS`.

### Task runner sidecar

The task runner sidecar is a separate container. It does not get
`NODE_EXTRA_CA_CERTS` and this input does not mount anything into it. Code
nodes that make their own TLS connections from inside the runner therefore do
not trust the private CA. Making the runner trust it needs a custom runner
image (`n8n_task_runner_image_repository`) that carries the CA, plus a launcher
config that allows `NODE_EXTRA_CA_CERTS` through (`n8n_task_runner_custom_config`).
The Python runner is not covered.

## Inbound: `n8n_proxy_hops`

`n8n_proxy_hops` (default `1`, the module's own ALB) sets `N8N_PROXY_HOPS` on
every n8n pod. Count every proxy that adds an `X-Forwarded-For` entry. One
customer proxy in front of the ALB makes it `2`. Too low a value makes n8n
attribute the client to the nearest extra proxy instead of the real client. Too high a
value, or any request that bypasses the declared proxy chain, lets the caller forge
its `X-Forwarded-For` address at every hop count of `1` or more. Restrict direct
access to the ALB and n8n Services to the intended proxy path. See the README's
["Session stickiness and `N8N_PROXY_HOPS`"](../README.md#session-stickiness-and-n8n_proxy_hops)
section for the full table.

The proxy's own TLS to the origin is configured elsewhere:

- The ALB presents the ACM certificate for `n8n_domain`. If the proxy
  validates it against a private CA, bring a `certificate_arn` issued by that
  CA; the proxy must trust that CA.
- Restrict the ALB to the proxy's egress addresses with `alb_inbound_cidrs`.
- WebSocket upgrades must pass through the proxy, and the proxy must forward
  the original `Host` and `Origin` headers; n8n's push connection drops
  otherwise. Set the proxy's idle timeout above n8n's server ping interval.

## Both

Set all three: `n8n_extra_ca_pem`, `n8n_extra_env` with the proxy variables,
and `n8n_proxy_hops`. Every example exposes the three as variables.
