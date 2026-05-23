# Self-Hosted GraphQL Hive — Docker Compose Deployment Guide

<!-- Companion docs: ../../docs/09-schema-governance/, ../../docs/14-observability/ -->

This document covers running GraphQL Hive on your own infrastructure using Docker Compose. It
includes the complete compose file, initial setup steps, OIDC/SSO configuration, database
migrations, backup strategy, and production sizing recommendations for a team of 20 engineers with
5 Federation v2 subgraphs.

---

## 1. Architecture Overview

A self-hosted Hive deployment consists of several services:

| Service | Image | Purpose |
|---------|-------|---------|
| `app` | `ghcr.io/kamilkisiela/graphql-hive/app` | Next.js web dashboard |
| `server` | `ghcr.io/kamilkisiela/graphql-hive/server` | GraphQL API for the dashboard and CLI |
| `schema` | `ghcr.io/kamilkisiela/graphql-hive/schema-worker` | Schema composition and validation worker |
| `usage` | `ghcr.io/kamilkisiela/graphql-hive/usage-ingestor` | Receives and aggregates operation usage reports |
| `usage-api` | `ghcr.io/kamilkisiela/graphql-hive/usage-estimator` | Serves pre-aggregated usage data to the API |
| `tokens` | `ghcr.io/kamilkisiela/graphql-hive/tokens` | Token validation service (hot path) |
| `cdn` | `ghcr.io/kamilkisiela/graphql-hive/cdn-worker` | Serves composed supergraph SDL to routers |
| `postgres` | `postgres:15` | Primary persistent store (schema history, organizations, tokens) |
| `clickhouse` | `clickhouse/clickhouse-server:23` | Column-store for operation usage analytics |
| `redis` | `redis:7` | Session storage, job queues, token caching |
| `s3` | `minio/minio` | S3-compatible object storage for schema artifacts |

**Dependency graph:**

```
           app ──────► server ──────► postgres
                          │             redis
                          │
                          ├──────► schema-worker ──► postgres
                          │
                          ├──────► usage-api ──────► clickhouse
                          │
                          └──────► tokens ──────────► redis
                                                       postgres

           usage-ingestor ──────────────────────────► clickhouse
                          ──────────────────────────► redis

           cdn-worker ─────────────────────────────► s3
                      ─────────────────────────────► postgres (token validation)
```

---

## 2. Docker Compose File

This compose file runs a minimal but complete Hive deployment suitable for a team. It is not
production-scale (no horizontal scaling, no external load balancer) but it is persistent and
suitable for running on a single VM or a small Kubernetes node.

```yaml
# docker-compose.yml
# Self-hosted GraphQL Hive — minimal team deployment.
# Tested with Docker Compose v2.24+ and Hive v0.34+.

version: "3.9"

# ---------------------------------------------------------------------------
# Shared configuration via extension fields.
# Using YAML anchors reduces duplication across service definitions.
# ---------------------------------------------------------------------------
x-hive-image: &hive-image
  # Pin to a specific Hive release. Update this pin deliberately after reviewing
  # the Hive changelog for breaking changes in self-hosted deployments.
  image: ghcr.io/kamilkisiela/graphql-hive/server:0.34.0

x-hive-environment: &hive-common-env
  # The public URL of the Hive app. Used for generating links in emails and
  # OAuth2 redirect URIs. Must be accessible from your users' browsers.
  APP_BASE_URL: "${APP_BASE_URL:-http://localhost:3000}"

  # Secret used for signing JSON Web Tokens. Generate with:
  #   openssl rand -hex 32
  # Rotating this secret invalidates all active sessions.
  SECRET: "${HIVE_SECRET}"

  # PostgreSQL connection URL for the primary database.
  # All Hive services share the same PostgreSQL instance in this deployment.
  POSTGRES_CONNECTION_STRING: "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"

  # Redis connection URL for session storage and job queues.
  REDIS_CONNECTION_STRING: "redis://redis:6379"

  # Environment label — appears in the Hive dashboard and log lines.
  # Helps distinguish production from staging in multi-environment setups.
  ENVIRONMENT: "${ENVIRONMENT:-production}"

x-logging: &default-logging
  # JSON log format for structured log ingestion (Loki, CloudWatch, etc.).
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"

services:
  # -------------------------------------------------------------------------
  # PostgreSQL — primary persistent store
  # -------------------------------------------------------------------------
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    logging: *default-logging
    environment:
      POSTGRES_USER: "${POSTGRES_USER:-hive}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DB: "${POSTGRES_DB:-hive}"
    volumes:
      # Named volume for PostgreSQL data. This is the most critical data in the deployment —
      # it contains all schema history, organization data, and tokens.
      # Back up this volume daily. See section 6 (Backup Strategy).
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-hive} -d ${POSTGRES_DB:-hive}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # Redis — session storage and job queues
  # -------------------------------------------------------------------------
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    logging: *default-logging
    command:
      # Enable Redis persistence via Append-Only File (AOF).
      # "always" durability: every write is fsynced to disk.
      # For teams where losing session data is acceptable, use "everysec" instead.
      - redis-server
      - --appendonly
      - "yes"
      - --appendfsync
      - "everysec"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # ClickHouse — operation usage analytics
  # -------------------------------------------------------------------------
  clickhouse:
    image: clickhouse/clickhouse-server:23.8-alpine
    restart: unless-stopped
    logging: *default-logging
    environment:
      # Default ClickHouse user and password.
      # In production, use ClickHouse's users.xml to create a dedicated hive user
      # with limited permissions (INSERT on usage_*, SELECT on all).
      CLICKHOUSE_USER: "${CLICKHOUSE_USER:-hive}"
      CLICKHOUSE_PASSWORD: "${CLICKHOUSE_PASSWORD}"
      CLICKHOUSE_DB: "${CLICKHOUSE_DB:-hive}"
    volumes:
      # ClickHouse data contains operation usage analytics. This data is valuable for
      # usage-informed breaking change detection. Back up weekly (see section 6).
      - clickhouse_data:/var/lib/clickhouse
      # ClickHouse logs separate from Docker logs for query analysis.
      - clickhouse_logs:/var/log/clickhouse-server
    ulimits:
      # ClickHouse requires a high file descriptor limit for concurrent queries.
      # The default Docker ulimit (1024) causes ClickHouse to refuse connections under load.
      nofile:
        soft: 262144
        hard: 262144
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # MinIO — S3-compatible object storage for schema artifacts
  # -------------------------------------------------------------------------
  minio:
    image: minio/minio:latest
    restart: unless-stopped
    logging: *default-logging
    environment:
      MINIO_ROOT_USER: "${MINIO_ROOT_USER:-hive}"
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
    command: server /data --console-address ":9001"
    volumes:
      # MinIO stores compiled schema artifacts (supergraph SDL) for the CDN service.
      # These artifacts can be regenerated from PostgreSQL schema history if lost,
      # but losing them causes CDN outages until they are regenerated.
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # Schema migrations — runs once and exits
  # -------------------------------------------------------------------------
  migrations:
    image: ghcr.io/kamilkisiela/graphql-hive/schema-migrations:0.34.0
    restart: "no"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      <<: *hive-common-env
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # Hive server — core API
  # -------------------------------------------------------------------------
  server:
    <<: *hive-image
    image: ghcr.io/kamilkisiela/graphql-hive/server:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      migrations:
        condition: service_completed_successfully
    environment:
      <<: *hive-common-env

      # Port the server listens on inside the container.
      PORT: "3001"

      # Enable rate limiting on token authentication to prevent brute-force attacks.
      # Rate limits are stored in Redis.
      RATE_LIMIT_ENABLED: "true"

      # SMTP configuration for email verification and invitation emails.
      # Without SMTP, users cannot verify email addresses. Use a transactional
      # email provider (SendGrid, Postmark, SES) rather than a raw SMTP relay.
      EMAIL_FROM: "${EMAIL_FROM:-noreply@example.com}"
      EMAIL_PROVIDER: "${EMAIL_PROVIDER:-smtp}"
      SMTP_HOST: "${SMTP_HOST}"
      SMTP_PORT: "${SMTP_PORT:-587}"
      SMTP_SECURE: "${SMTP_SECURE:-false}"
      SMTP_USER: "${SMTP_USER}"
      SMTP_PASSWORD: "${SMTP_PASSWORD}"

      # S3 configuration for schema artifact storage.
      S3_ENDPOINT: "http://minio:9000"
      S3_ACCESS_KEY_ID: "${MINIO_ROOT_USER:-hive}"
      S3_SECRET_ACCESS_KEY: "${MINIO_ROOT_PASSWORD}"
      S3_BUCKET_NAME: "hive-artifacts"
      # Force path-style S3 URLs for MinIO compatibility.
      # AWS S3 uses virtual-hosted-style by default; MinIO requires path-style.
      S3_FORCE_PATH_STYLE: "true"

      # Internal service URLs — all traffic stays within the Docker network.
      TOKENS_ENDPOINT: "http://tokens:3003"
      SCHEMA_ENDPOINT: "http://schema:3002"
      USAGE_ESTIMATOR_ENDPOINT: "http://usage-api:3006"
    networks:
      - hive-internal
      - hive-external

  # -------------------------------------------------------------------------
  # Schema composition worker
  # -------------------------------------------------------------------------
  schema:
    image: ghcr.io/kamilkisiela/graphql-hive/schema-worker:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      <<: *hive-common-env
      PORT: "3002"
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # Token validation service
  # -------------------------------------------------------------------------
  tokens:
    image: ghcr.io/kamilkisiela/graphql-hive/tokens:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      <<: *hive-common-env
      PORT: "3003"
      # Token cache TTL in Redis. Tokens are cached to avoid a PostgreSQL lookup
      # on every CLI command and router poll. 300 seconds = 5 minutes.
      # Revoking a token takes up to this long to take effect.
      TOKEN_CACHE_TTL: "300"
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # Usage ingestor — receives operation reports from routers/servers
  # -------------------------------------------------------------------------
  usage:
    image: ghcr.io/kamilkisiela/graphql-hive/usage-ingestor:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      clickhouse:
        condition: service_started
      redis:
        condition: service_healthy
      tokens:
        condition: service_started
    environment:
      <<: *hive-common-env
      PORT: "3005"

      # ClickHouse connection details for writing usage data.
      CLICKHOUSE_HOST: "clickhouse"
      CLICKHOUSE_PORT: "8123"
      CLICKHOUSE_USERNAME: "${CLICKHOUSE_USER:-hive}"
      CLICKHOUSE_PASSWORD: "${CLICKHOUSE_PASSWORD}"
      CLICKHOUSE_DATABASE: "${CLICKHOUSE_DB:-hive}"

      # Usage ingestion batch size. Operations are buffered in Redis before being
      # flushed to ClickHouse in batches. Larger batches are more efficient but
      # increase latency between operation execution and dashboard visibility.
      USAGE_BATCH_SIZE: "1000"
      USAGE_FLUSH_INTERVAL_MS: "5000"
    networks:
      - hive-internal
      - hive-external

  # -------------------------------------------------------------------------
  # Usage API — serves aggregated usage data to the server
  # -------------------------------------------------------------------------
  usage-api:
    image: ghcr.io/kamilkisiela/graphql-hive/usage-estimator:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      clickhouse:
        condition: service_started
    environment:
      <<: *hive-common-env
      PORT: "3006"
      CLICKHOUSE_HOST: "clickhouse"
      CLICKHOUSE_PORT: "8123"
      CLICKHOUSE_USERNAME: "${CLICKHOUSE_USER:-hive}"
      CLICKHOUSE_PASSWORD: "${CLICKHOUSE_PASSWORD}"
      CLICKHOUSE_DATABASE: "${CLICKHOUSE_DB:-hive}"
    networks:
      - hive-internal

  # -------------------------------------------------------------------------
  # CDN worker — serves supergraph SDL to routers
  # -------------------------------------------------------------------------
  cdn:
    image: ghcr.io/kamilkisiela/graphql-hive/cdn-worker:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      minio:
        condition: service_healthy
      tokens:
        condition: service_started
    environment:
      <<: *hive-common-env
      PORT: "3007"
      S3_ENDPOINT: "http://minio:9000"
      S3_ACCESS_KEY_ID: "${MINIO_ROOT_USER:-hive}"
      S3_SECRET_ACCESS_KEY: "${MINIO_ROOT_PASSWORD}"
      S3_BUCKET_NAME: "hive-artifacts"
      S3_FORCE_PATH_STYLE: "true"
      TOKENS_ENDPOINT: "http://tokens:3003"
    networks:
      - hive-internal
      - hive-external

  # -------------------------------------------------------------------------
  # Web dashboard (Next.js)
  # -------------------------------------------------------------------------
  app:
    image: ghcr.io/kamilkisiela/graphql-hive/app:0.34.0
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      - server
    environment:
      # The public URL of the Hive API (server service).
      # This must be accessible from users' browsers — not the internal Docker network URL.
      GRAPHQL_PUBLIC_ENDPOINT: "${APP_BASE_URL:-http://localhost:3000}/graphql"
      PORT: "3000"
    ports:
      # Expose the dashboard on port 3000. In production, front this with nginx or a
      # cloud load balancer that terminates TLS.
      - "3000:3000"
    networks:
      - hive-internal
      - hive-external

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------
networks:
  # Internal network: service-to-service communication only.
  # Services on this network are not directly reachable from outside Docker.
  hive-internal:
    driver: bridge
    internal: true

  # External network: services that need to be reached from outside Docker
  # (app, server, usage ingestor, CDN) are attached to this network.
  hive-external:
    driver: bridge

# ---------------------------------------------------------------------------
# Volumes — persistent data
# ---------------------------------------------------------------------------
volumes:
  postgres_data:
  redis_data:
  clickhouse_data:
  clickhouse_logs:
  minio_data:
```

**Environment file (`.env`):**

```dotenv
# .env — Required environment variables for self-hosted Hive.
# Copy to .env, fill in values, and add .env to .gitignore.

# Public URL of the Hive dashboard (must be externally accessible).
APP_BASE_URL=https://hive.example.com

# JWT signing secret — generate with: openssl rand -hex 32
HIVE_SECRET=changeme-replace-with-32-byte-hex-string

# PostgreSQL credentials
POSTGRES_USER=hive
POSTGRES_PASSWORD=changeme-strong-password
POSTGRES_DB=hive

# ClickHouse credentials
CLICKHOUSE_USER=hive
CLICKHOUSE_PASSWORD=changeme-strong-password
CLICKHOUSE_DB=hive

# MinIO (S3-compatible storage) credentials
MINIO_ROOT_USER=hive
MINIO_ROOT_PASSWORD=changeme-strong-password

# SMTP for email delivery
EMAIL_FROM=noreply@example.com
EMAIL_PROVIDER=smtp
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=apikey
SMTP_PASSWORD=SG.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Environment label
ENVIRONMENT=production
```

---

## 3. Initial Setup After First Boot

**Starting the deployment:**

```bash
# Create the MinIO bucket before starting services that depend on it.
# MinIO auto-creates buckets configured in its environment, but explicit creation
# ensures the bucket exists with the correct policy before the CDN service starts.
docker compose up -d postgres redis clickhouse minio

# Wait for dependencies to be healthy, then run migrations.
docker compose up migrations

# Start all remaining services.
docker compose up -d
```

**Verifying the deployment:**

```bash
# Check all services are running and healthy.
docker compose ps

# Verify the dashboard is accessible.
curl -s http://localhost:3000 | grep -c "GraphQL Hive"

# Check the server API is responding.
curl -s http://localhost:3001/health
# Expected: {"status":"ok"}
```

**Creating the first organization:**

1. Navigate to `http://localhost:3000` (or your configured `APP_BASE_URL`).
2. Click "Sign Up" and create an admin account.
3. Create an organization (e.g., "my-company").
4. Create a project of type "Federation" (for Apollo Federation v2).
5. Create targets: "production", "staging", "development".
6. For each target, create a "Registry Write" token (for CI/CD) and a "CDN Access" token
   (for Apollo Router).

---

## 4. OIDC / SSO Integration

Hive supports OIDC-based SSO for team authentication. This is essential for a team environment
where you want to avoid per-engineer Hive password management and enforce your organization's
existing identity provider (GitHub OAuth2, Google Workspace, Okta, etc.).

**GitHub OAuth2 setup:**

1. Create a GitHub OAuth App at github.com > Settings > Developer settings > OAuth Apps.
   - Homepage URL: your `APP_BASE_URL`
   - Callback URL: `${APP_BASE_URL}/auth/callback/github`
2. Add these environment variables to the `server` service:

```dotenv
# GitHub OAuth2 credentials for SSO.
AUTH_GITHUB_CLIENT_ID=your-github-oauth-app-client-id
AUTH_GITHUB_CLIENT_SECRET=your-github-oauth-app-client-secret

# Require users to be members of a specific GitHub organization.
# Without this, any GitHub user can sign up. Set to your org's GitHub login.
AUTH_GITHUB_ALLOWED_ORGANIZATION=your-github-org-name
```

**Google Workspace setup:**

1. Create OAuth2 credentials in the Google Cloud Console.
   - Authorized redirect URI: `${APP_BASE_URL}/auth/callback/google`
2. Add these environment variables:

```dotenv
AUTH_GOOGLE_CLIENT_ID=your-google-client-id.apps.googleusercontent.com
AUTH_GOOGLE_CLIENT_SECRET=your-google-client-secret

# Restrict sign-in to users from a specific Google Workspace domain.
AUTH_GOOGLE_ALLOWED_DOMAIN=example.com
```

**Generic OIDC provider (Okta, Auth0, Keycloak):**

```dotenv
AUTH_OIDC_CLIENT_ID=your-oidc-client-id
AUTH_OIDC_CLIENT_SECRET=your-oidc-client-secret
AUTH_OIDC_DISCOVERY_URL=https://your-idp.example.com/.well-known/openid-configuration
AUTH_OIDC_ALLOWED_EMAIL_DOMAIN=example.com
```

---

## 5. PostgreSQL Migrations

Hive uses a dedicated `schema-migrations` container to apply database migrations. Migrations must
be run before starting the `server`, `tokens`, or `schema` services for the first time, and after
every Hive version upgrade.

**Running migrations manually:**

```bash
# Run migrations as a one-off container.
docker compose run --rm migrations

# Verify migrations applied successfully.
docker compose exec postgres psql -U hive -d hive -c "\dt" | grep -c "hive_"
```

**Running migrations as part of Kubernetes deployment:**

In a Kubernetes deployment, run migrations as an `initContainer` in the server Deployment:

```yaml
initContainers:
  - name: migrations
    image: ghcr.io/kamilkisiela/graphql-hive/schema-migrations:0.34.0
    env:
      - name: POSTGRES_CONNECTION_STRING
        valueFrom:
          secretKeyRef:
            name: hive-postgres
            key: connection-string
```

The `initContainer` ensures migrations complete before the server container starts, and Kubernetes
will restart the pod if migrations fail.

**After upgrading Hive:**

1. Update the image tags in `docker-compose.yml` to the new version.
2. Pull the new images: `docker compose pull`.
3. Run migrations: `docker compose run --rm migrations`.
4. Restart services: `docker compose up -d`.

Never run a new Hive server version against an unmigrated database — the server will fail to start
or produce schema corruption errors.

---

## 6. Backup Strategy

| Data Store | Data | Backup Method | Frequency | Retention |
|------------|------|--------------|-----------|-----------|
| PostgreSQL | Schema history, orgs, tokens, projects | pg_dump to S3 | Daily | 30 days |
| ClickHouse | Operation usage analytics | clickhouse-backup to S3 | Weekly | 12 weeks |
| MinIO | Schema SDL artifacts | MinIO mirror to secondary S3 | Daily | 7 days |
| Redis | Sessions, token cache | Not critical — data is derived | None | — |

**PostgreSQL backup script:**

```bash
#!/bin/bash
# backup-postgres.sh — Run as a cron job (e.g., 02:00 UTC daily).

set -euo pipefail

BACKUP_BUCKET="s3://your-backup-bucket/hive/postgres"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="hive_pg_${TIMESTAMP}.dump"

# pg_dump creates a custom-format dump, which is smaller and faster to restore
# than plain SQL format. Use pg_restore to restore from this format.
docker compose exec -T postgres pg_dump \
  -U "${POSTGRES_USER:-hive}" \
  -d "${POSTGRES_DB:-hive}" \
  --format=custom \
  > "/tmp/${BACKUP_FILE}"

# Upload to S3 (requires AWS CLI or compatible tool).
aws s3 cp "/tmp/${BACKUP_FILE}" "${BACKUP_BUCKET}/${BACKUP_FILE}"

# Remove local temp file.
rm "/tmp/${BACKUP_FILE}"

echo "PostgreSQL backup completed: ${BACKUP_BUCKET}/${BACKUP_FILE}"
```

**Restoring PostgreSQL:**

```bash
# Stop Hive services that write to PostgreSQL.
docker compose stop server schema tokens

# Restore from backup.
docker compose exec -T postgres pg_restore \
  -U hive \
  -d hive \
  --clean \
  --if-exists \
  < /path/to/hive_pg_backup.dump

# Restart services.
docker compose start server schema tokens
```

---

## 7. Production Sizing

The following resource recommendations are for a team of 20 engineers with 5 Federation subgraphs
and an estimated operation volume of 1 million operations per day.

| Service | CPU | Memory | Notes |
|---------|-----|--------|-------|
| `server` | 0.5 CPU | 512 MB | Scales horizontally if >50 concurrent dashboard users |
| `schema` | 1.0 CPU | 1 GB | Schema composition is CPU-intensive; scale up first |
| `tokens` | 0.25 CPU | 256 MB | Mostly Redis lookups; very low resource usage |
| `usage` | 0.5 CPU | 512 MB | Scales with operation volume; add replicas if ingestion lags |
| `usage-api` | 0.25 CPU | 256 MB | Read-only ClickHouse queries; minimal load |
| `cdn` | 0.25 CPU | 256 MB | Mostly S3 proxying; minimal CPU |
| `app` | 0.25 CPU | 256 MB | Next.js SSR; scales with dashboard users |
| `postgres` | 2.0 CPU | 4 GB | All schema history; size generously |
| `clickhouse` | 2.0 CPU | 8 GB | Analytical queries are memory-intensive; do not undersize |
| `redis` | 0.5 CPU | 1 GB | Session storage + job queues; size for peak concurrent users |
| `minio` | 0.5 CPU | 1 GB | Artifact storage; I/O-bound not CPU-bound |

**Total minimum:** 8 CPUs, 18 GB RAM (single host or small VM cluster).

**Disk sizing:**

| Service | Growth Rate | 1 Year Estimate |
|---------|-------------|-----------------|
| PostgreSQL | ~50 MB/month (schema versions) | ~1 GB |
| ClickHouse | ~2 GB/month (1M ops/day) | ~25 GB |
| MinIO | ~10 MB/month (SDL artifacts) | ~150 MB |

**Scaling recommendations:**

- At >10M operations/day, run 2-3 replicas of the `usage` service behind a load balancer.
- At >50 concurrent dashboard users, run 2 replicas of `server` and `app`.
- ClickHouse does not need horizontal scaling at this volume but benefits from SSDs.
- PostgreSQL can run as a single primary with a streaming replica for read scaling and failover.

---

## Related Documentation

- `../../docs/09-schema-governance/` — Schema governance policies that Hive enforces.
- `../../docs/14-observability/` — Observability strategy, including Hive usage analytics.
- `hive-cli-usage.md` — Using the Hive CLI to publish schemas to this self-hosted instance.
- `hive-router-config.md` — Configuring Apollo Router to pull schemas from the self-hosted CDN.

---

## Key Design Decisions

**MinIO instead of AWS S3**
Using MinIO keeps the deployment fully self-contained and avoids a dependency on AWS services.
For organizations that already use AWS, replacing MinIO with a real S3 bucket reduces operational
overhead — simply swap the S3 endpoint and credentials in the environment configuration. MinIO
supports the same AWS S3 API, so no code changes are required.

**ClickHouse for usage analytics**
ClickHouse is purpose-built for append-heavy, aggregation-heavy analytical workloads. The
operation usage data generated by GraphQL requests is exactly this pattern: high-volume inserts,
low-volume aggregation queries. A PostgreSQL-only Hive deployment would not scale beyond a few
hundred thousand operations per day due to PostgreSQL's row-oriented storage being inefficient
for wide aggregation scans.

**Separate internal and external networks**
PostgreSQL, ClickHouse, Redis, and the internal Hive services are on the `hive-internal` network
which has `internal: true`. Docker bridges with this flag block all outbound internet traffic
from those containers, providing defense-in-depth: even if a service were compromised, it could
not exfiltrate data to an external server. Only services that need external reach (app, server,
usage, CDN) are attached to the `hive-external` network.
