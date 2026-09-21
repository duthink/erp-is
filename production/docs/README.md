# Production ERPNext Deployment

Production deployment for ERPNext/Frappe using Docker Compose, Traefik, MariaDB, Redis, and immutable custom application images.

This directory contains the deployment configuration and operational scripts for the ERPNext environments.

> **Public repository rule:** This README documents reusable deployment patterns. Live site names, server paths, environment names, storage locations, release digests, and other deployment-specific identifiers belong in private deployment documentation.

## 1. Architecture

The deployment consists of separate Docker Compose projects:

```text
                         Internet
                            │
                            ▼
                    ┌───────────────┐
                    │    Traefik    │
                    │ TLS + routing │
                    └───────┬───────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
              ▼                           ▼
       ERPNext Staging             ERPNext Production
       Docker project              Docker project
              │                           │
              └─────────────┬─────────────┘
                            │
                            ▼
                    Shared MariaDB
```

The current host intentionally runs staging and production on the same physical server, but they remain isolated at the Docker/application-data level.

### Application isolation

Staging and production have separate:

- Docker Compose projects
- ERPNext site volumes
- assets volumes
- Redis services
- ERPNext application containers
- site databases

MariaDB is shared as a database server/container, but staging and production use different MariaDB databases.

Do not treat the shared MariaDB container as meaning the application environments share the same database.

## 2. Deployment Model

The repository follows this promotion model:

```text
LOCAL VS CODE
     │
     │ commit + push
     ▼
GitHub / staging
     │
     │ deploy
     ▼
SERVER / staging
     │
     │ UAT
     ▼
GitHub / main
     │
     │ deploy
     ▼
SERVER / production
```

### Git rules

Git operations happen in the local development checkout.

Do not use the staging or production server to:

- merge branches
- rebase branches
- develop application changes
- resolve repository conflicts
- create release commits

Servers are deployment targets.

The repository uses:

| Branch    | Purpose                            |
| --------- | ---------------------------------- |
| `main`    | Production-approved state          |
| `staging` | UAT/release-candidate state        |
| `dev`     | Local feature and development work |

The normal promotion is:

```text
local work
  ↓
push staging
  ↓
staging deployment
  ↓
UAT
  ↓
GitHub staging → main
  ↓
production deployment
```

## 3. Application Image Strategy

Production uses immutable custom application images.

The image is built from:

```text
images/layered/Containerfile
```

and receives applications through:

```text
production/apps.json
```

The build uses Docker BuildKit:

```text
production/apps.json
        │
        │ --secret id=apps_json
        ▼
images/layered/Containerfile
        │
        ├── Frappe Framework
        ├── ERPNext
        ├── HRMS
        └── additional Frappe apps
        │
        ▼
<IMAGE_REGISTRY>/<IMAGE_NAME>:<immutable-tag>
```

### Important

The current image build does **not** use `APPS_JSON_BASE64`.

Use:

```bash
docker buildx build \
  --load \
  --secret id=apps_json,src=production/apps.json \
  --build-arg=FRAPPE_IMAGE_PREFIX=frappe \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --tag="$IMAGE_TAG" \
  --file=images/layered/Containerfile \
  .
```

For the complete image-build procedure, see:

[`custom-image-workflow.md`](custom-image-workflow.md)

## 4. Verified v16 Example Stack

A verified v16 application stack can be recorded as:

| Component        | Version |
| ---------------- | ------: |
| Frappe Framework |    16.x |
| ERPNext          |    16.x |
| HRMS             |    16.x |
| India Compliance |    16.x |
| Python           |     3.x |

For a specific deployment, record exact versions, image tag, and registry digest in the private release/deployment record.

## 5. Repository Structure

```text
erp-is/
├── compose.yaml
├── docker-bake.hcl
├── images/
│   └── layered/
│       └── Containerfile
├── overrides/
│   ├── compose.redis.yaml
│   ├── compose.multi-bench.yaml
│   ├── compose.multi-bench-ssl.yaml
│   ├── compose.mariadb-shared.yaml
│   └── compose.traefik*.yaml
└── production/
    ├── apps.json
    ├── *.env.example
    ├── scripts/
    │   ├── deploy.sh
    │   ├── create-site.sh
    │   ├── backup-site.sh
    │   ├── validate-env.sh
    │   ├── logs.sh
    │   └── stop.sh
    ├── backup/
    │   ├── backup-to-s3.sh
    │   ├── compose.backup-runner.yaml
    │   ├── run-backup.sh
    │   ├── README.md
    │   ├── erpnext-backup-db@.service
    │   ├── erpnext-backup-db@.timer
    │   ├── erpnext-backup-full@.service
    │   └── erpnext-backup-full@.timer
    └── docs/
        ├── README.md
        ├── custom-image-workflow.md
        ├── erpnext-v16-upgrade-plan.md
        ├── operations-runbook.md
        └── pre-update-safety-checklist.md
```

`production.yaml` is generated and should not be edited manually.

## 6. Environment Files

The production application project uses:

```text
production/production.env
production/mariadb.env
production/traefik.env
```

These files contain environment-specific configuration and secrets and must not be committed to Git.

### Application environment

Important values include:

```env
SITES='`<SITE>`'
SITES_RULE='Host(`<SITE>`)'
ROUTER=erpnext-<ENVIRONMENT>
BENCH_NETWORK=erpnext-<ENVIRONMENT>

DB_HOST=mariadb-database
DB_PORT=3306

CUSTOM_IMAGE=<IMAGE_REGISTRY>/<IMAGE_NAME>
CUSTOM_TAG=<immutable-image-tag>
PULL_POLICY=always
```

For production, `CUSTOM_TAG` should reference an immutable image tag.

Do not use:

```text
latest
production-latest
```

as the production release identity.

### Shell-safe site routing values

When `production.env` is sourced by Bash, values containing backticks must be quoted.

Use:

```env
SITES='`<SITE>`'
SITES_RULE='Host(`<SITE>`)'
```

Do not leave either value unquoted. An unquoted `SITES_RULE` can be interpreted by the shell as command substitution/syntax rather than as a literal environment value.

Before deployment, verify the file is sourceable:

```bash
bash -c 'set -e; source production/production.env; printf "SITES=%s\nSITES_RULE=%s\nCUSTOM_TAG=%s\n" "$SITES" "$SITES_RULE" "$CUSTOM_TAG"'
```

### Database environment

`production.env` and `mariadb.env` must use the same MariaDB root password.

### Traefik environment

`traefik.env` contains the dashboard and Let's Encrypt configuration.

Keep all environment files protected:

```bash
chmod 600 production/*.env
```

## 7. Initial Setup

From the `production/` directory:

```bash
./scripts/deploy.sh --setup
```

This creates the environment files from their `.example` templates.

Edit the generated files before deployment.

Then validate:

```bash
./scripts/validate-env.sh
```

Do not proceed if validation fails.

## 8. Deploying the Stack

### Production

For a production deployment, regenerate the complete Compose configuration and then deploy:

```bash
./scripts/deploy.sh --regenerate
./scripts/deploy.sh
```

For a normal production release, inspect the generated image reference before containers are updated.

### Staging on the same host

When staging uses the host's already-running shared Traefik and MariaDB:

```bash
./scripts/deploy.sh --regenerate
./scripts/deploy.sh --skip-infra
```

`--skip-infra` is important on the current host because staging and production share the MariaDB and Traefik infrastructure.

Do not stop or recreate shared infrastructure merely to deploy the staging application project.

## 9. Generated Compose Configuration

`production.yaml` is generated from the repository's Compose files and the environment:

```text
compose.yaml
       +
overrides/compose.redis.yaml
       +
overrides/compose.multi-bench.yaml
       +
overrides/compose.multi-bench-ssl.yaml
       +
production.env
       ↓
production/production.yaml
```

Regenerate after changing environment or Compose inputs:

```bash
./scripts/deploy.sh --regenerate
```

The generated file is the source of truth for the actual deployment configuration. It assembles the base Compose file with the required Redis, multi-bench, SSL/Traefik, environment, networking, and site-routing inputs.

Inspect at least the image, router/rule, Redis settings, and site/network values before a release:

```bash
grep -nE 'image:|traefik.http.routers|REDIS_|SITES' production/production.yaml
```

A plain:

```bash
docker compose --env-file production.env config
```

is not a substitute for `deploy.sh --regenerate` in this repository because it does not necessarily include the full override set used by the deployment.

Do not edit `production.yaml` manually.

## 10. Creating a Site

Create a site using:

```bash
./scripts/create-site.sh <SITE>
```

The script creates the site and installs ERPNext.

Applications such as HRMS and India Compliance are installed separately at the site level when required.

An application being present in the Docker image does not mean it is installed in an existing site's database. Always verify an existing site's application set with `bench --site <site> list-apps` before installing anything during an upgrade.

Example:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> install-app hrms
```

and:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> install-app india_compliance
```

Then:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> migrate
```

An application being present in the Docker image does not automatically activate it in an existing site's database.

## 11. Backups

There are two backup paths.

### Manual migration/recovery backup

For a migration or an operator-triggered recovery point, use the site backup script:

```bash
./scripts/backup-site.sh <SITE> --with-files --auto-copy
```

For a major migration, create a fresh backup immediately before the migration.

See:

```bash
./scripts/backup-site.sh --help
```

Never commit database backups to Git.

For major upgrades, the pre-migration backup is the primary database rollback mechanism.

### Automated production backups

Automated production backups do **not** use the ERPNext scheduler and do **not** depend on a replaceable scheduler container.

The current design is:

```text
systemd timer
      ↓
backup/run-backup.sh
      ↓
docker compose run --rm backup-runner
      ↓
same immutable ERPNext application image
      ↓
bench backup
      ↓
DigitalOcean Spaces
```

The backup runner uses the same ERPNext sites volume as the application stack and uploads the resulting backups to DigitalOcean Spaces.

Production schedule:

| Backup                      | Schedule           |
| --------------------------- | ------------------ |
| Database backup             | Hourly             |
| Full backup including files | Daily at 03:00 UTC |

The production systemd units are:

```text
erpnext-backup-db@<INSTANCE>.timer
erpnext-backup-full@<INSTANCE>.timer
```

Staging currently has **no automated backup timers**.

To run the backup manually from the ERP installation directory:

Database-only backup:

```bash
./backup/run-backup.sh 0
```

Full backup including files:

```bash
./backup/run-backup.sh 1
```

The automated backup procedure and S3 layout are documented in:

[`backup/README.md`](../backup/README.md)

Do not disable or recreate production backup timers during staging maintenance. The systemd timers are host-wide, not scoped to the directory from which you are working.

## 12. Logs

Interactive:

```bash
./scripts/logs.sh
```

Specific service:

```bash
./scripts/logs.sh backend
./scripts/logs.sh frontend
./scripts/logs.sh websocket
./scripts/logs.sh queue-short
./scripts/logs.sh queue-long
./scripts/logs.sh scheduler
```

Tail recent logs:

```bash
./scripts/logs.sh --tail 200
```

All services:

```bash
./scripts/logs.sh all
```

## 13. Stopping Services

Stop the ERPNext application project:

```bash
./scripts/stop.sh
```

This may prompt about shared infrastructure.

Stopping everything:

```bash
./scripts/stop.sh --all
```

is a host-level operation because it can also stop shared MariaDB and Traefik.

Use `--all` deliberately when staging and production share the same host.

## 14. Validate Configuration

Run:

```bash
./scripts/validate-env.sh
```

The validation checks environment files, required variables, placeholders, password configuration, and related consistency checks.

Also verify Bash sourceability when `SITES`, `SITES_RULE`, or related routing values change:

```bash
bash -c 'set -e; source production/production.env; printf "SITES=%s\nSITES_RULE=%s\nCUSTOM_TAG=%s\n" "$SITES" "$SITES_RULE" "$CUSTOM_TAG"'
```

Run these checks before deployments and after configuration changes.

## 15. Application Updates

For an application release:

```text
local change
   ↓
prepare the approved application manifest
   ↓
build immutable image
   ↓
verify image locally
   ↓
push image
   ↓
staging
   ↓
UAT
   ↓
same image → production
```

Do not update production by simply changing `ERPNEXT_VERSION`.

For custom images, the application versions are frozen into the image at build time.

See:

[`custom-image-workflow.md`](custom-image-workflow.md)

## 16. Frappe Docker Infrastructure Updates

The repository is a fork of `frappe/frappe_docker`.

Infrastructure updates and ERPNext application updates are separate changes.

An upstream integration may affect:

- Compose configuration
- container startup
- networking
- images
- assets
- Docker build behavior
- Traefik integration

Do not assume an upstream `frappe_docker` merge is equivalent to an ERPNext application upgrade.

Upstream integration should be performed in the local development checkout, tested locally, and then promoted through the normal staging/UAT process.

The current v3.2.2 integration is recorded in the repository's Git history.

## 17. v15 → v16 Upgrade

The v15 → v16 upgrade requires additional planning because it involves both application and database migration.

The sequence is:

```text
v15 production
      │
      │ untouched
      ▼
local v16 image
      │
      ▼
local fresh-site test
      │
      ▼
local real-data migration test
      │
      ▼
GitHub staging
      │
      ▼
staging migration
      │
      ▼
UAT
      │
      ▼
GitHub main
      │
      ▼
production migration
```

Do not skip the real-data local migration test.

See:

[`erpnext-v16-upgrade-plan.md`](erpnext-v16-upgrade-plan.md)

## 18. Immutable Image Promotion

Build the application image once:

```text
<IMAGE_REGISTRY>/<IMAGE_NAME>:<immutable-tag>
```

After staging UAT, production must use the same image artifact.

Prefer recording the registry digest in the release record.

Example:

```text
image:
<IMAGE_REGISTRY>/<IMAGE_NAME>:20260910-abc1234

digest:
sha256:...
```

Do not rebuild from `main` after staging UAT and call the resulting image equivalent.

## 19. Applying a Release to an Existing Site

For a normal application release, create a fresh pre-release backup:

```bash
./scripts/backup-site.sh <SITE> --with-files --auto-copy
```

Then deploy the approved immutable image.

After containers are healthy:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> migrate
```

Then:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> clear-cache
```

Verify:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> list-apps
```

Do not automatically run `bench build` in production when using the immutable layered image workflow.

## 20. Rollback

There are two different rollback mechanisms.

### Image rollback

For an application/container problem where the database remains compatible:

```text
current immutable tag
        ↓
previous approved immutable tag
```

Update:

```env
CUSTOM_TAG=<previous-approved-tag>
```

Then:

```bash
./scripts/deploy.sh --regenerate
./scripts/deploy.sh
```

### Database rollback

A major-version migration can change the database schema.

Reverting the image does not undo those database changes.

If a database rollback is required, restore the pre-migration backup and associated files using the documented backup/restore procedure.

## 21. Docker / OS Update Safety

Before and after an OS or Docker Engine update, run:

```bash
./scripts/check-docker-compat.sh
```

This repository includes a dedicated compatibility check because Docker/Traefik API compatibility can affect routing.

The update process is:

```text
local
  ↓
compatibility check
  ↓
OS/Docker update
  ↓
compatibility check
  ↓
application smoke test
  ↓
burn-in
  ↓
production
```

See:

[`pre-update-safety-checklist.md`](pre-update-safety-checklist.md)

## 22. Shared Infrastructure Warning

Traefik and MariaDB are shared infrastructure on the current host.

Therefore:

```bash
./scripts/stop.sh --all
```

can affect both staging and production.

Before performing host-level maintenance, confirm:

```bash
docker ps
```

and identify which Compose projects are running.

Do not stop shared infrastructure during routine staging application deployments unless that is intentional.

### Systemd timers are also host-wide

The current host runs both staging and production application environments.

The production backup timers:

```text
erpnext-backup-db@<INSTANCE>.timer
erpnext-backup-full@<INSTANCE>.timer
```

are host-level systemd units. They remain production timers even when the shell is currently in the staging checkout.

Staging has no automated backup timers.

Do not disable `@production` backup timers while performing staging maintenance. Always confirm the target unit before enabling, disabling, starting, or stopping a systemd timer.

## 23. Common Commands

### Check running services

```bash
docker compose -f production/production.yaml ps
```

### Check image versions

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench version
```

### Check installed site apps

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> list-apps
```

### Clear cache

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> clear-cache
```

### Migrate site

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <SITE> migrate
```

### Regenerate Compose

```bash
./scripts/deploy.sh --regenerate
```

### Validate environment

```bash
./scripts/validate-env.sh
```

## Verified Release Record

For a specific deployment, record the exact release artifact in the private deployment/release record.

Example:

```text
image: <IMAGE_REGISTRY>/<IMAGE_NAME>:<IMMUTABLE_TAG>
digest: sha256:<REGISTRY_DIGEST>
```

Do not use the public README as the live production release register.

## 24. Production Release Checklist

Before deployment:

- [ ] Correct Git commit identified
- [ ] Application versions pinned
- [ ] Custom image built locally
- [ ] `bench version` verified
- [ ] Local tests passed
- [ ] Real-data migration tested where applicable
- [ ] Immutable image pushed
- [ ] Registry digest recorded
- [ ] Staging deployed
- [ ] Staging migration completed
- [ ] UAT approved
- [ ] GitHub `staging` promoted to `main`
- [ ] Production backup completed
- [ ] Docker compatibility check passed
- [ ] Production `CUSTOM_TAG` points to the approved image
- [ ] `SITES` and `SITES_RULE` are shell-safe and correct
- [ ] Generated `production.yaml` reviewed
- [ ] Production site installed-app set verified
- [ ] Production migration completed
- [ ] Critical workflows verified
- [ ] HTTPS endpoint returns HTTP 200
- [ ] Login and critical workflows verified
- [ ] Logs reviewed
- [ ] Previous image and backup retained

## 25. Files and Responsibilities

| File                                  | Responsibility                                 |
| ------------------------------------- | ---------------------------------------------- |
| `production.env`                      | ERPNext environment configuration              |
| `mariadb.env`                         | Shared MariaDB configuration                   |
| `traefik.env`                         | Traefik configuration                          |
| `apps.json`                           | Production application manifest                |
| `scripts/deploy.sh`                   | Deployment and Compose generation              |
| `scripts/create-site.sh`              | Site creation                                  |
| `scripts/backup-site.sh`              | Site backups                                   |
| `scripts/validate-env.sh`             | Configuration validation                       |
| `scripts/logs.sh`                     | Application log viewing                        |
| `scripts/stop.sh`                     | Application/infrastructure shutdown            |
| `scripts/check-docker-compat.sh`      | Docker/Traefik compatibility check             |
| `backup/backup-to-s3.sh`              | Backup creation and S3 upload                  |
| `backup/compose.backup-runner.yaml`   | Backup runner Compose definition               |
| `backup/run-backup.sh`                | Operator entry point for automated backup runs |
| `backup/erpnext-backup-*.service`     | Systemd backup execution units                 |
| `backup/erpnext-backup-*.timer`       | Systemd backup schedules                       |
| `backup/README.md`                    | Automated backup architecture and operations   |
| `docs/custom-image-workflow.md`       | Custom image build/release procedure           |
| `docs/erpnext-v16-upgrade-plan.md`    | v15 → v16 migration procedure                  |
| `docs/operations-runbook.md`          | Environment-specific operational runbook       |
| `docs/pre-update-safety-checklist.md` | OS/Docker update safety                        |

## 26. Security

Never commit:

- passwords
- API tokens
- private repository credentials
- database backups
- encrypted backup passphrases
- environment-specific secrets

Check:

```bash
git check-ignore production/production.env
git check-ignore production/mariadb.env
git check-ignore production/traefik.env
```

Keep environment files restricted:

```bash
chmod 600 production/*.env
```

Do not embed GitHub credentials directly into application manifests committed to the repository.

## 27. Maintenance

Routine operations should use the provided scripts rather than ad-hoc container commands where a script exists.

Recommended:

```bash
./scripts/logs.sh
./scripts/backup-site.sh ...
./scripts/validate-env.sh
./scripts/deploy.sh
```

For automated backup runs, use the dedicated backup runner:

```bash
./backup/run-backup.sh 0
./backup/run-backup.sh 1
```

Database maintenance scripts that directly manipulate internal Frappe tables should not be considered part of the standard v16 maintenance procedure unless they have been explicitly validated for the target Frappe release.

## 28. Documentation Map

Use the document appropriate to the task:

### Building application images

[`custom-image-workflow.md`](custom-image-workflow.md)

### v15 → v16 upgrade

[`erpnext-v16-upgrade-plan.md`](erpnext-v16-upgrade-plan.md)

### Day-to-day staging/production operations

[`operations-runbook.md`](operations-runbook.md)

### Automated backups

[`../backup/README.md`](../backup/README.md)

### OS/Docker updates

[`pre-update-safety-checklist.md`](pre-update-safety-checklist.md)

## 29. Support and Upstream References

- [Frappe Docker](https://github.com/frappe/frappe_docker)
- [Frappe Framework](https://github.com/frappe/frappe)
- [ERPNext](https://github.com/frappe/erpnext)
- [HRMS](https://github.com/frappe/hrms)
- [India Compliance](https://github.com/resilient-tech/india-compliance)

## 30. HTTP 500 After Deployment

A deployment can complete successfully and all containers can remain running while the site still returns HTTP 500.

First inspect the application logs:

```bash
./scripts/logs.sh --tail 200
```

If the containers are healthy but the site returns HTTP 500, clear the site cache and restart the application services:

```bash
docker compose -f production/production.yaml \
  exec backend \
  bench --site <site> clear-cache

docker compose -f production/production.yaml \
  restart \
  backend \
  queue-short \
  queue-long \
  scheduler \
  websocket \
  frontend
```

Verify the site:

```bash
curl -sk -o /dev/null -w 'HTTP %{http_code}\n' \
  https://<site>/login
```

Expected:

```text
HTTP 200
```

This cache-clear and application-restart sequence was used successfully after the v15 → v16 production rollout when the site returned HTTP 500 despite the containers being up. Treat it as a recovery procedure based on the observed incident, not as proof that every HTTP 500 has the same cause.

If the problem is specifically missing or stale CSS/JS assets rather than an application HTTP 500, use:

[`troubleshooting/css-js-404-after-custom-app.md`](../troubleshooting/css-js-404-after-custom-app.md)

That troubleshooting procedure covers asset rebuild/synchronization and `bench clear-website-cache`.

Do not assume that `docker compose ps` showing all containers as running means the application is healthy. Always verify the HTTP endpoint and, after a migration, test an actual login and critical workflow.

---

**Repository:** `duthink/erp-is`

**Deployment model:** Docker Compose + Traefik + shared MariaDB + isolated staging/production application projects

**Application image model:** immutable layered custom images

**Promotion model:** Local → GitHub staging → Staging/UAT → GitHub main → Production

**Current verified v16 release:** Frappe 16.33.1 / ERPNext 16.34.2 / HRMS 16.18.1 / India Compliance 16.9.0

**Last updated:** September 17, 2026
