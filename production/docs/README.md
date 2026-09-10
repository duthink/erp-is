# Production ERPNext Deployment

Production deployment for ERPNext/Frappe using Docker Compose, Traefik, MariaDB, Redis, and immutable custom application images.

This directory contains the deployment configuration and operational scripts for the ERPNext environments.

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

| Branch | Purpose |
|---|---|
| `main` | Production-approved state |
| `staging` | UAT/release-candidate state |
| `dev` | Local feature and development work |

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
ghcr.io/duthink/erpnext-custom:<immutable-tag>
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

## 4. Current Verified v16 Stack

The current locally verified v16 application stack is:

| Component | Version |
|---|---:|
| Frappe Framework | 16.33.1 |
| ERPNext | 16.34.2 |
| HRMS | 16.18.1 |
| India Compliance | 16.9.0 |
| Python | 3.14.7 |

The current verified v16 test image is:

```text
ghcr.io/duthink/erpnext-custom:v16-test-v3.2.2
```

Local image ID:

```text
sha256:25506deba681e66f9356b927a8a0450baa88725d2b2e41fab3614f5a3deab559
```

This image was successfully built after integrating `frappe_docker` v3.2.2 and verified with:

```text
erpnext 16.34.2
frappe 16.33.1
hrms 16.18.1
india_compliance 16.9.0
```

The v15 → v16 migration is a major application/database upgrade. See:

[`erpnext-v16-upgrade-plan.md`](erpnext-v16-upgrade-plan.md)

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
    ├── apps.v16-test.json
    ├── *.env.example
    ├── scripts/
    │   ├── deploy.sh
    │   ├── create-site.sh
    │   ├── backup-site.sh
    │   ├── validate-env.sh
    │   ├── logs.sh
    │   └── stop.sh
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
SITES=erp.example.com
ROUTER=erpnext-production
BENCH_NETWORK=erpnext-production

DB_HOST=mariadb-database
DB_PORT=3306

CUSTOM_IMAGE=ghcr.io/duthink/erpnext-custom
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

The standard deployment command is:

```bash
./scripts/deploy.sh
```

This:

1. validates the environment
2. starts Traefik
3. starts MariaDB
4. generates `production.yaml`
5. starts the ERPNext application project

### Staging on the same host

When staging uses the host's already-running Traefik and MariaDB:

```bash
./scripts/deploy.sh --skip-infra
```

This deploys only the ERPNext application project.

Do not stop the shared infrastructure merely to restart staging.

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

Inspect generated image references before a release:

```bash
grep -n 'image:' production/production.yaml
```

Do not edit `production.yaml` manually.

## 10. Creating a Site

Create a site using:

```bash
./scripts/create-site.sh erp.example.com
```

The script creates the site and installs ERPNext.

Applications such as HRMS and India Compliance are installed separately at the site level when required.

Example:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com install-app hrms
```

and:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com install-app india_compliance
```

Then:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com migrate
```

An application being present in the Docker image does not automatically activate it in an existing site's database.

## 11. Backups

Backups are performed with:

```bash
./scripts/backup-site.sh erp.example.com --with-files --auto-copy
```

For a migration, use a fresh backup immediately before the migration.

The backup script supports:

- database backups
- public/private files
- host copying
- retention policies
- optional encryption
- verification

See:

```bash
./scripts/backup-site.sh --help
```

Never commit database backups to Git.

For major upgrades, the backup is the primary database rollback mechanism.

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

Run it before deployments and after configuration changes.

## 15. Application Updates

For an application release:

```text
local change
   ↓
update apps.json
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
ghcr.io/duthink/erpnext-custom:<immutable-tag>
```

After staging UAT, production must use the same image artifact.

Prefer recording the registry digest in the release record.

Example:

```text
image:
ghcr.io/duthink/erpnext-custom:20260910-abc1234

digest:
sha256:...
```

Do not rebuild from `main` after staging UAT and call the resulting image equivalent.

## 19. Applying a Release to an Existing Site

For a normal application release:

```bash
./scripts/backup-site.sh erp.example.com --with-files --auto-copy
```

Then deploy the new immutable image.

After containers are healthy:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com migrate
```

Then:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com clear-cache
```

Verify:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com list-apps
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
  bench --site erp.example.com list-apps
```

### Clear cache

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com clear-cache
```

### Migrate site

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com migrate
```

### Regenerate Compose

```bash
./scripts/deploy.sh --regenerate
```

### Validate environment

```bash
./scripts/validate-env.sh
```

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
- [ ] Generated `production.yaml` reviewed
- [ ] Production migration completed
- [ ] Critical workflows verified
- [ ] Logs reviewed
- [ ] Previous image and backup retained

## 25. Files and Responsibilities

| File | Responsibility |
|---|---|
| `production.env` | ERPNext environment configuration |
| `mariadb.env` | Shared MariaDB configuration |
| `traefik.env` | Traefik configuration |
| `apps.json` | Production application manifest |
| `apps.v16-test.json` | Temporary/reproducible v16 test manifest |
| `scripts/deploy.sh` | Deployment and Compose generation |
| `scripts/create-site.sh` | Site creation |
| `scripts/backup-site.sh` | Site backups |
| `scripts/validate-env.sh` | Configuration validation |
| `scripts/logs.sh` | Application log viewing |
| `scripts/stop.sh` | Application/infrastructure shutdown |
| `scripts/check-docker-compat.sh` | Docker/Traefik compatibility check |
| `docs/custom-image-workflow.md` | Custom image build/release procedure |
| `docs/erpnext-v16-upgrade-plan.md` | v15 → v16 migration procedure |
| `docs/operations-runbook.md` | Environment-specific operational runbook |
| `docs/pre-update-safety-checklist.md` | OS/Docker update safety |

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

Database maintenance scripts that directly manipulate internal Frappe tables should not be considered part of the standard v16 maintenance procedure unless they have been explicitly validated for the target Frappe release.

## 28. Documentation Map

Use the document appropriate to the task:

### Building application images

[`custom-image-workflow.md`](custom-image-workflow.md)

### v15 → v16 upgrade

[`erpnext-v16-upgrade-plan.md`](erpnext-v16-upgrade-plan.md)

### Day-to-day staging/production operations

[`operations-runbook.md`](operations-runbook.md)

### OS/Docker updates

[`pre-update-safety-checklist.md`](pre-update-safety-checklist.md)

## 29. Support and Upstream References

- [Frappe Docker](https://github.com/frappe/frappe_docker)
- [Frappe Framework](https://github.com/frappe/frappe)
- [ERPNext](https://github.com/frappe/erpnext)
- [HRMS](https://github.com/frappe/hrms)
- [India Compliance](https://github.com/resilient-tech/india-compliance)

---

**Repository:** `duthinker/erp-is`

**Deployment model:** Docker Compose + Traefik + shared MariaDB + isolated staging/production application projects

**Application image model:** immutable layered custom images

**Promotion model:** Local → GitHub staging → Staging/UAT → GitHub main → Production

**Current verified v16 candidate:** Frappe 16.33.1 / ERPNext 16.34.2 / HRMS 16.18.1 / India Compliance 16.9.0

**Last updated:** September 2026