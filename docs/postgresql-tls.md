# PostgreSQL TLS certificate verification

`db_postgresdb_ssl_enabled` (the default, `true`) encrypts the connection
between n8n and PostgreSQL, but encryption alone does not prove n8n is
talking to the server it thinks it is. Out of the box the module sets
`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false`, which negotiates TLS but skips
certificate validation entirely: a man-in-the-middle presenting any
certificate at all is accepted. `db_postgresdb_ssl_reject_unauthorized` and
`db_postgresdb_ssl_ca_pem` exist to close that gap.

## Why the default skips verification

The module-managed RDS instance's server certificate chains to Amazon's own
RDS-specific certificate authority (`rds-ca-rsa2048-g1` and the older
`rds-ca-2019`/`rds-ca-rsa4096-g1` families), not a publicly trusted root.
This is a different CA from Amazon Trust Services, the publicly trusted CA
Amazon operates for ACM certificates and other public-facing TLS: Amazon
Trust Services roots are preinstalled in Node.js's bundled CA list, but the
RDS-specific CA is not. Without that CA, turning on verification
(`db_postgresdb_ssl_reject_unauthorized = true`) makes every database
connection fail closed with a certificate-chain error, which is why the
module defaults to skipping verification rather than breaking every existing
deployment.

## Turning on verification

```hcl
db_postgresdb_ssl_reject_unauthorized = true
db_postgresdb_ssl_ca_pem              = file("${path.module}/us-east-1-bundle.pem")
```

1. Download the RDS CA bundle for your region from AWS's trust store
   endpoint:
   `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
   A regional bundle holds the root CAs RDS uses in that region, one per CA
   generation (for example RSA2048 G1, RSA4096 G1 and ECC384 G1), so it keeps
   working when your instance moves to another generation. The module never
   fetches it itself: Terraform has no HTTP data source for an arbitrary file
   download without an extra provider, and fetching a trust anchor at plan
   time from a URL the plan cannot pin a checksum against is exactly the kind
   of supply-chain surface this module avoids elsewhere. Download it once,
   commit it alongside your Terraform configuration (it is public
   information, safe to commit), and pass it in with `file()`.
2. Set `db_postgresdb_ssl_ca_pem` to the bundle's contents and
   `db_postgresdb_ssl_reject_unauthorized = true`. The module trims
   surrounding whitespace and passes the bundle to the n8n Helm chart's
   `database.ssl.ca` value. The chart renders it into its own ConfigMap as
   `DB_POSTGRESDB_SSL_CA`, which the main, worker, and webhook-processor pods
   read as an environment variable, and n8n passes it to the PostgreSQL
   connection as PEM content.
3. Both inputs default to the prior behavior (`false` / `null`), so setting
   neither changes an existing deployment's rendered Helm values at all.

Because the CA is part of the Helm release, a CA change rolls the pods
through the chart's own `checksum/config` annotation, and a failed upgrade's
rollback restores the previous CA (see [AWS's CA rotation](#awss-ca-rotation)).

### Bundle size limit

The trimmed bundle may be at most 131,050 bytes. The chart passes it to each
container as one environment variable, and Linux refuses to start a process
when a single environment string is longer than 128 KiB: the container fails
with `argument list too long`. The module checks the size at plan time.

This rules out the combined `global-bundle.pem` (about 170 KB, every region
and every CA generation). A regional bundle is about 5 KB. If n8n connects to
databases in more than one region, concatenate only those regional bundles:

```hcl
db_postgresdb_ssl_ca_pem = join("\n", [
  file("${path.module}/us-east-1-bundle.pem"),
  file("${path.module}/eu-west-1-bundle.pem"),
])
```

`db_postgresdb_ssl_ca_pem` applies on both the module-managed RDS path
(`create_database = true`) and the external `db_host` path
(`create_database = false`): the chart value does not depend on which path
provisioned the database, only on `db_postgresdb_ssl_enabled` and the CA
input itself. If `db_host` points at a non-RDS PostgreSQL server (e.g. a
self-managed instance or a different provider's managed database), supply
that server's own CA bundle instead of the RDS one.

Verification also checks the server's name, not only its CA. The host n8n
connects to (the module-managed RDS endpoint, or `db_host`) must match a name
in the server certificate. The RDS endpoint always does. A `db_host` set to a
custom DNS alias (for example a Route 53 CNAME pointing at the RDS endpoint)
or an IP address does not, and every connection fails with a hostname
mismatch once `db_postgresdb_ssl_reject_unauthorized = true`. Point `db_host`
at the endpoint name AWS gives you instead.

## Plan-time warnings

Two non-blocking `check` blocks in `database.tf` catch the ways these inputs
can be set to something that renders but does nothing:

- `db_postgresdb_ssl_reject_unauthorized_requires_ssl_enabled` warns if
  verification is requested while `db_postgresdb_ssl_enabled = false`: there
  is no TLS connection in that case for `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED`
  to apply to, and the module never renders the key at all when SSL is off.
- `db_postgresdb_ssl_ca_pem_requires_verification` warns if a CA bundle is
  supplied while verification is not actually turned on. What happens to
  the CA depends on which half is off:
  - `db_postgresdb_ssl_reject_unauthorized = false` (verification itself off,
    `db_postgresdb_ssl_enabled` still `true`): the CA still reaches the
    chart's `database.ssl.ca` value, but n8n never validates anything
    against it. The connection stays encrypted but unverified, because the
    module sets `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false` explicitly.
  - `db_postgresdb_ssl_enabled = false` (SSL itself off): the CA is not
    passed to the chart at all.

Neither check fails the plan. Both exist so a caller who sets one input and
forgets the other learns about it before the next `terraform apply`, not
after wondering why a supplied CA "did nothing."

## AWS's CA rotation

AWS periodically rotates the RDS certificate authority and schedules the
retirement of older CAs; see
[Using SSL/TLS to encrypt a connection to a DB instance or cluster](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
for the current rotation schedule, the certificate expiration dates for each
CA generation, and the `aws rds describe-certificates` CLI command that
reports which CA your instance currently presents. A regional bundle already
includes every CA generation RDS currently issues from in that region, so
switching your instance to another generation needs no change here. Track
that page and refresh the bundle file when AWS adds a CA your instance will
use, or verified connections fail closed once the certificate rotates to a
CA your bundle does not include.

`db_postgresdb_ssl_enabled = true` with `db_postgresdb_ssl_reject_unauthorized
= false` (the module's default) is unaffected by CA rotation: it never
validates the certificate chain, so a rotated CA changes nothing it checks.

### When a new bundle is wrong

A bundle that does not cover the server's certificate makes every new pod
fail to connect. The Helm release uses `atomic = true`, so the apply fails
when the upgrade reaches `n8n_helm_timeout` (600 seconds by default) and Helm
rolls the release back. The CA is part of the release, so the rollback also
restores the previous CA, and pods recreated after the rollback start with
it. No further apply is needed to recover. Applying the previous bundle file
again afterwards produces no change. The terraform-azurerm-n8n module, which
delivers its CA the same way, verified this in a live test
(n8n-io/terraform-azurerm-n8n#41); it has not been repeated on AWS.

While the failing upgrade runs, workers stop processing the queue. The
chart's worker readiness probe does not check the database connection, so a
new worker counts as ready before it fails, and the healthy old worker is
removed. This lasts until the rollback finishes and needs a chart change to
fix (n8n-io/n8n-hosting#225). Webhook-processor pods, and main pods in the
default multi-main topology, keep serving from their old replicas. With a
single main (`n8n_main_hpa_min_replicas = 1`) the main Deployment uses the
`Recreate` strategy, so the old main stops before the new one fails and the
editor is unavailable until the rollback. Roll out a new bundle in a non-production
environment first, and at a time when a queue stall of up to
`n8n_helm_timeout` is acceptable.

## Upgrading an existing deployment

Changing either input only changes what the n8n application containers send
as TLS connection parameters; it does not modify the RDS instance itself; no
engine version change, no storage change, no instance replacement. A
Helm-only rollout applies the new value on the next pod restart of the main,
worker, and webhook-processor Deployments, with no queue-draining
requirement specific to this change. As with any change to how n8n reaches
its database, confirm the new configuration in a non-production environment
first: setting `db_postgresdb_ssl_reject_unauthorized = true` without a CA
that covers the server's actual certificate chain fails every database
connection closed after the rollout completes, which takes down the main,
worker, and webhook-processor pods alike (there is no fallback to an
unverified connection once the setting is live).

### Upgrading from an unreleased build

This only applies if you deployed from unreleased `main` between PR #165 and
issue #178 with `db_postgresdb_ssl_ca_pem` set. That build delivered the CA through
a module-managed ConfigMap, `n8n-postgres-ssl-ca`, mounted into the pods.
The upgrade deletes that ConfigMap and moves the CA into the chart value in
the same apply. If that one Helm upgrade fails, `atomic = true` rolls back to
the previous release, whose pods still mount the deleted ConfigMap, and any
pod that starts afterwards waits in `ContainerCreating`.

- Run this upgrade while you can watch the apply finish.
- If it rolls back, recreate the ConfigMap the previous release mounts, then
  fix the cause and apply again:

  ```bash
  kubectl -n <namespace> create configmap n8n-postgres-ssl-ca \
    --from-file=ca.pem=<your-bundle>.pem
  ```

  Delete it again after the next successful apply, since the module no longer
  manages it.

No released module version created that ConfigMap, so upgrades from a
release are not affected.

## Removing the CA

Setting `db_postgresdb_ssl_ca_pem` back to `null`, or setting
`db_postgresdb_ssl_enabled = false`, removes `database.ssl` from the chart
values. This is a Helm-only change: there is no separate Kubernetes object
for Terraform to delete first, so a failed upgrade rolls back to a release
that still carries the CA.

## PgBouncer topologies (`examples/large`)

When `db_host` points at an in-cluster connection pooler rather than RDS
directly, the pattern `examples/large/pgbouncer.tf` uses, with
`db_postgresdb_ssl_enabled = false` because the n8n-to-PgBouncer leg is plain
TCP inside the cluster, `db_postgresdb_ssl_reject_unauthorized` and
`db_postgresdb_ssl_ca_pem` are inert for that leg by design: the warning
`check` above flags exactly this combination. This module only ever
configures the connection between n8n and `db_host`, so it has no visibility
into, and no inputs that reach, PgBouncer's own upstream connection to
Aurora.

`examples/large/pgbouncer.tf` sets `SERVER_TLS_SSLMODE=require` on that
upstream leg today: encrypted, but not verified, the same posture this
module's own default has on the direct path. Getting certificate
verification on the PgBouncer-to-Aurora leg means changing the example's own
PgBouncer configuration (`SERVER_TLS_SSLMODE=verify-full` plus mounting a CA
bundle into the PgBouncer pod spec), which is outside this module's inputs
entirely: it is infrastructure the example brings itself, not something
`db_postgresdb_ssl_ca_pem` can reach through a pooler.
