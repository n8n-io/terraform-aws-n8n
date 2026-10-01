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

Node.js 18 and earlier bundled a wider set of CAs in some distributions;
Node 20 and later load only the CAs Node ships with by default, and the RDS
CA was never one of them on any version. Supplying the bundle yourself is
the supported path on every Node version this module's pinned n8n image
runs.

## Turning on verification

```hcl
db_postgresdb_ssl_reject_unauthorized = true
db_postgresdb_ssl_ca_pem              = file("${path.module}/global-bundle.pem")
```

1. Download the RDS CA bundle from AWS's trust store endpoint:
   `https://truststore.pki.rds.amazonaws.com/global-bundle.pem` is the
   combined bundle covering every AWS region and every CA generation RDS has
   issued from, so it works regardless of which region or CA your instance
   currently uses. Per-region bundles
   (`https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`)
   are also published if you would rather pin to a smaller, region-scoped
   file. The module never fetches this itself: Terraform has no HTTP data
   source for an arbitrary file download without an extra provider, and
   fetching a trust anchor at plan time from a URL the plan cannot pin a
   checksum against is exactly the kind of supply-chain surface this module
   avoids elsewhere. Download it once, commit it alongside your Terraform
   configuration (it is public information, safe to commit), and pass it in
   with `file()`.
2. Set `db_postgresdb_ssl_ca_pem` to the bundle's contents and
   `db_postgresdb_ssl_reject_unauthorized = true`. The module renders the PEM
   into a module-managed `kubernetes_config_map_v1`
   (`kubernetes_config_map_v1.postgres_ssl_ca` in `n8n.tf`), mounts it
   read-only at `/etc/n8n/postgres-ssl-ca/ca.pem` on the main, worker, and
   webhook-processor pods, and sets `DB_POSTGRESDB_SSL_CA_FILE` to that path
   (n8n's Postgres driver reads either the certificate's literal content or a
   file path from this variable; the module always uses the file path form).
3. Both inputs default to the prior behavior (`false` / `null`), so setting
   neither changes an existing deployment's rendered Helm values at all.

`db_postgresdb_ssl_ca_pem` applies on both the module-managed RDS path
(`create_database = true`) and the external `db_host` path
(`create_database = false`): the ConfigMap, mount, and
`DB_POSTGRESDB_SSL_CA_FILE` wiring do not depend on which path provisioned
the database, only on `db_postgresdb_ssl_enabled` and the CA input itself.
If `db_host` points at a non-RDS PostgreSQL server (e.g. a self-managed
instance or a different provider's managed database), supply that server's
own CA bundle instead of the RDS one.

## Plan-time warnings

Two non-blocking `check` blocks in `database.tf` catch the ways these inputs
can be set to something that renders but does nothing:

- `db_postgresdb_ssl_reject_unauthorized_requires_ssl_enabled` warns if
  verification is requested while `db_postgresdb_ssl_enabled = false`: there
  is no TLS connection in that case for `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED`
  to apply to, and the module never renders the key at all when SSL is off.
- `db_postgresdb_ssl_ca_pem_requires_verification` warns if a CA bundle is
  supplied while verification is not actually turned on
  (`db_postgresdb_ssl_enabled = false`, or
  `db_postgresdb_ssl_reject_unauthorized = false`): the ConfigMap and mount
  still render, but n8n never validates anything against the file they carry.

Neither check fails the plan. Both exist so a caller who sets one input and
forgets the other learns about it before the next `terraform apply`, not
after wondering why a supplied CA "did nothing."

## AWS's CA rotation

AWS periodically rotates the RDS certificate authority and schedules the
retirement of older CAs; see
[Using SSL/TLS to encrypt a connection to a DB instance or cluster](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
for the current rotation schedule, the certificate expiration dates for each
CA generation, and the `aws rds describe-certificates` CLI command that
reports which CA your instance currently presents. If you pin
`db_postgresdb_ssl_ca_pem` to a bundle fetched at a point in time rather than
re-fetching the combined `global-bundle.pem` on every apply, track that page
and refresh the input before your instance's CA is retired, or verified
connections will start failing closed once the certificate rotates to a CA
your bundle does not include. The combined `global-bundle.pem` is
AWS-maintained and already includes every CA generation still valid, so
re-downloading it occasionally (rather than hand-picking a single
region/generation bundle) is the lower-maintenance option if you are not
tracking a specific pinned CA for other reasons.

`db_postgresdb_ssl_enabled = true` with `db_postgresdb_ssl_reject_unauthorized
= false` (the module's default) is unaffected by CA rotation: it never
validates the certificate chain, so a rotated CA changes nothing it checks.

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
