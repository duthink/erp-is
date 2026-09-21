# Building Custom ERPNext Images

**Production workflow for ERPNext, HRMS, India Compliance, and other Frappe apps**

This document defines the repository's standard workflow for building, testing, publishing, and promoting custom ERPNext Docker images.

The image is built from:

```text
images/layered/Containerfile
```

and contains the Frappe Framework plus the applications declared in the **approved build-time application manifest**.

Application assets are built into the image so application containers use the same immutable artifact.

> **Public repository rule:** This guide documents the reusable image-build and promotion method. Live site names, server paths, environment names, release digests, and deployment-specific infrastructure values belong in private deployment documentation.

> **Important:** an application being present in the image does not mean it is installed in every site's database. Image contents and site-installed applications are separate concerns.

---

## 1. Architecture

The repository uses the **layered custom-image pattern**:

```text
approved application manifest
        │
        │ BuildKit secret
        ▼
images/layered/Containerfile
        │
        ├── frappe/build:version-16
        │
        ├── Frappe Framework
        ├── ERPNext
        ├── HRMS
        └── other approved Frappe apps
        │
        ▼
<IMAGE_REGISTRY>/<IMAGE_NAME>:<immutable-tag>
        │
        ├── Staging / UAT
        │
        └── Production
```

The layered `Containerfile` consumes the application manifest through a BuildKit secret:

```dockerfile
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json ...
```

The secret is passed as:

```text
id=apps_json
```

The current build system intentionally uses this mechanism.

**Do not use the older `APPS_JSON_BASE64` build-argument workflow.**

---

## 2. Repository and promotion rules

### Build locally

Image builds and Git operations are performed from the local development checkout.

```text
LOCAL VS CODE
     │
     ├── edit code/manifests
     ├── validate manifests
     ├── build image
     ├── test image
     ├── commit changes
     └── push to GitHub
             │
             ▼
       GitHub / staging
```

The staging and production servers are deployment targets.

Do not perform the following on staging or production as part of the normal release workflow:

```text
Git merge
Git rebase
conflict resolution
application development
custom image building
```

### Build once, promote the same artifact

The release flow is:

```text
local build
    ↓
immutable registry tag
    ↓
staging deployment
    ↓
database migration if required
    ↓
UAT
    ↓
same image digest
    ↓
production
```

Do **not** rebuild the application image from `main` after staging passes.

Production must receive the same tested image artifact that passed staging/UAT.

---

## 3. What belongs in the application manifest

Frappe Framework is **not** listed in the application manifest.

The Framework line is selected through:

```text
FRAPPE_BRANCH
```

passed to:

```text
images/layered/Containerfile
```

The application manifest contains ERPNext, HRMS, India Compliance, and any other applications that should be baked into the image.

### Current verified v16 application set

The application versions used for the completed v16 production image were:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "v16.34.2"
  },
  {
    "url": "https://github.com/frappe/hrms",
    "branch": "v16.18.1"
  },
  {
    "url": "https://github.com/resilient-tech/india-compliance",
    "branch": "v16.9.0"
  }
]
```

Frappe Framework:

```text
FRAPPE_BRANCH=version-16
```

### Important manifest rule

The application manifest used to build a release is a **build input**.

Do not assume that today's checked-in `production/apps.json` is automatically the exact manifest that produced an already-deployed historical image.

For the completed v16 rollout, the v16 build used an approved temporary manifest during image creation. That temporary file was later retired from the repository.

For future releases:

```text
approved release manifest
        ↓
immutable image
        ↓
record tag + digest
        ↓
staging/UAT
        ↓
same artifact → production
```

Never reconstruct a production image from memory when the exact release artifact already exists in GHCR.

### Validate JSON

Before building:

```bash
python3 -m json.tool <approved-apps-manifest>
```

For production-grade releases, prefer release tags or exact commits over moving application branches.

---

## 4. Current verified v16 stack

The current verified production image contains:

| Component        | Version |
| ---------------- | ------: |
| Frappe Framework | 16.33.1 |
| ERPNext          | 16.34.2 |
| HRMS             | 16.18.1 |
| India Compliance |  16.9.0 |
| Python           |  3.14.7 |

The custom image uses:

```text
FRAPPE_BRANCH=version-16
```

The base/build image family is:

```text
frappe/build:version-16
frappe/base:version-16
```

For release identity, use the custom image tag plus registry digest.

### Current deployed image

```text
<IMAGE_REGISTRY>/<IMAGE_NAME>:<IMMUTABLE_TAG>
```

Registry digest:

```text
sha256:<REGISTRY_DIGEST>
```

This exact image was promoted to production.

Do not treat a historical local Docker image ID as the release identity. The registry digest is the authoritative immutable artifact identity.

---

## 5. Prerequisites

Verify Docker:

```bash
docker --version
```

Verify Compose:

```bash
docker compose version
```

Verify Buildx:

```bash
docker buildx version
```

The layered build requires BuildKit secret support, so use:

```bash
docker buildx build
```

Pull the required Frappe base images:

```bash
docker pull frappe/build:version-16
docker pull frappe/base:version-16
```

Verify the runtime if required:

```bash
docker run --rm \
  frappe/base:version-16 \
  python --version
```

Expected current runtime:

```text
Python 3.14.7
```

---

## 6. Build a local test image

For experimental local testing, create a temporary application manifest separately from the release manifest whenever the test needs different application pins.

Example temporary file:

```text
/tmp/apps.v16-test.json
```

Do not overwrite the production release manifest merely to perform an experiment.

Example:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "v16.34.2"
  },
  {
    "url": "https://github.com/frappe/hrms",
    "branch": "v16.18.1"
  },
  {
    "url": "https://github.com/resilient-tech/india-compliance",
    "branch": "v16.9.0"
  }
]
```

Validate:

```bash
python3 -m json.tool /tmp/apps.v16-test.json
```

Build:

```bash
docker buildx build \
  --load \
  --secret id=apps_json,src=/tmp/apps.v16-test.json \
  --build-arg=FRAPPE_IMAGE_PREFIX=frappe \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --tag=<IMAGE_REGISTRY>/<IMAGE_NAME>:v16-local-test \
  --file=images/layered/Containerfile \
  .
```

### Why `--load`?

`--load` imports the resulting image into the local Docker image store so it can immediately be used with:

```text
docker run
```

or a local Compose test project.

---

## 7. Verify the image before publishing or deploying

Check application versions:

```bash
docker run --rm \
  <IMAGE_REGISTRY>/<IMAGE_NAME>:v16-local-test \
  bench version
```

Expected current v16 stack:

```text
erpnext          16.34.2
frappe           16.33.1
hrms             16.18.1
india_compliance 16.9.0
```

Check Python:

```bash
docker run --rm \
  <IMAGE_REGISTRY>/<IMAGE_NAME>:v16-local-test \
  python --version
```

Check the local image identity:

```bash
docker image inspect \
  <IMAGE_REGISTRY>/<IMAGE_NAME>:v16-local-test \
  --format '{{.Id}}'
```

The local image ID can be useful for debugging.

For the production release record, however, retain:

```text
Git commit
image tag
registry digest
bench version
Python/runtime version
application manifest
```

### Important distinction

This command:

```bash
bench version
```

verifies the applications contained in the image.

It does **not** verify the applications installed in a site's database.

For an existing site, separately run:

```bash
docker compose \
  -f production.yaml \
  exec backend \
  bench --site <site> list-apps
```

---

## 8. Create an immutable release tag

For a release candidate, use a traceable immutable tag.

One useful pattern is:

```bash
BUILD_DATE=$(date +%Y%m%d)
GIT_SHA=$(git rev-parse --short HEAD)

IMAGE="ghcr.io/your-org/erpnext-custom"
IMAGE_TAG="${IMAGE}:${BUILD_DATE}-${GIT_SHA}"

echo "Image: $IMAGE_TAG"
```

For a version-specific ERPNext release, a semantic tag may also be appropriate:

```text
<IMMUTABLE_TAG>
```

The important properties are:

```text
unique
traceable
immutable for deployment
```

Record the Git commit used for the build.

Do not use:

```text
latest
production-latest
staging-latest
```

as the production release identity.

The **registry digest** is the authoritative immutable identity after publishing.

---

## 9. Build the staging release image

From the local repository checkout:

```bash
docker buildx build \
  --load \
  --secret id=apps_json,src=<approved-apps-manifest> \
  --build-arg=FRAPPE_IMAGE_PREFIX=frappe \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --tag="$IMAGE_TAG" \
  --file=images/layered/Containerfile \
  .
```

Verify:

```bash
docker run --rm \
  "$IMAGE_TAG" \
  bench version
```

Do not publish an image that has not passed local verification.

For a major-version release, also perform the required local migration testing before staging.

See:

[`erpnext-v16-upgrade-plan.md`](erpnext-v16-upgrade-plan.md)

---

## 10. Publish the image to GHCR

Authenticate to GHCR using an appropriate token:

```bash
echo "$GITHUB_TOKEN" | \
  docker login ghcr.io \
  -u <GHCR_USERNAME> \
  --password-stdin
```

Push:

```bash
docker push "$IMAGE_TAG"
```

Verify the remote artifact:

```bash
docker buildx imagetools inspect "$IMAGE_TAG"
```

Record the resulting digest.

A release record should look like:

```text
Git commit:
Image:
Registry digest:
ERPNext:
Frappe:
HRMS:
India Compliance:
Python:
```

Do not treat a successful `docker push` as sufficient verification. Confirm the remote digest.

---

## 11. GHCR credential-helper fallback

The host may have Docker configured with the `pass` credential store:

```json
{
  "credsStore": "pass"
}
```

If Docker reports an OpenPGP/GPG credential decryption error while `pass show` can still read the stored entry, treat this as a:

```text
Docker
  ↓
docker-credential-pass
  ↓
GPG/OpenPGP
```

credential-helper problem.

Do not replace or disable the system-wide GPG/pass configuration merely to work around a single GHCR publishing operation.

Use a short-lived isolated Docker configuration:

```bash
mkdir -p ~/.docker/ghcr-push

cat > ~/.docker/ghcr-push/config.json <<'EOF'
{
  "auths": {
    "ghcr.io": {}
  }
}
EOF

export DOCKER_CONFIG="$HOME/.docker/ghcr-push"

docker login ghcr.io -u <GHCR_USERNAME>
docker push "$IMAGE_TAG"
docker buildx imagetools inspect "$IMAGE_TAG"
```

Docker may warn that credentials are stored in the temporary configuration without a credential helper.

For a short-lived publishing configuration, clean it up immediately:

```bash
rm -rf ~/.docker/ghcr-push
unset DOCKER_CONFIG
```

See the separate incident record:

[`GHCR Docker Authentication – OpenPGP Issue and Resolution.md`](GHCR%20Docker%20Authentication%20%E2%80%93%20OpenPGP%20Issue%20and%20Resolution.md)

---

## 12. Staging deployment

The image tag is selected in the staging environment configuration.

The staging release process is:

```text
1. Select immutable candidate image
2. Regenerate complete Compose configuration
3. Deploy staging application project
4. Run database migration if required
5. Verify image versions
6. Verify site-installed applications
7. Run technical smoke tests
8. Run authenticated UAT
```

### Current staging architecture

Staging Git root:

```text
<STAGING_GIT_ROOT>
```

Staging ERP installation:

```text
<STAGING_ERP_ROOT>
```

Staging runs as its own application project.

The current server also contains production and shared infrastructure on the same physical host.

Shared infrastructure:

```text
MariaDB: <MARIADB_IMAGE>
Traefik: <TRAEFIK_IMAGE>
```

Do not copy staging environment files, site volumes, generated Compose files, or database credentials into production.

### Deploy staging with existing shared infrastructure

When shared MariaDB/Traefik infrastructure is already running and the deployment must touch only the application project:

```bash
./scripts/deploy.sh --regenerate
```

Inspect the generated Compose file first.

Then:

```bash
./scripts/deploy.sh --skip-infra
```

Do not assume `--skip-infra` is the correct mode for every host. It is appropriate for this shared-infrastructure architecture.

---

## 13. Activate applications on a site

Putting an application into the image does not automatically install it into a site's database.

Always compare:

```bash
bench --site <site> list-apps
```

with the intended site application set before installing anything.

Example:

```bash
docker compose \
  -f production.yaml \
  exec backend \
  bench --site <site> list-apps
```

If HRMS is intentionally required:

```bash
docker compose \
  -f production.yaml \
  exec backend \
  bench --site <site> install-app hrms
```

Then migrate:

```bash
docker compose \
  -f production.yaml \
  exec backend \
  bench --site <site> migrate
```

For a major-version upgrade, take and verify the required backup before migration.

### Current production application set

The current verified production site has:

```text
frappe
erpnext
hrms
india_compliance
```

This is a site-level fact, not merely an image-content fact.

---

## 14. Production promotion

Production uses the **same immutable image that passed staging/UAT**.

Do not rebuild the image from `main` after staging approval.

Promotion:

```text
GitHub staging
      │
      │ approved
      ▼
GitHub main
      │
      ▼
production deploy
      │
      ▼
same image tag / same registry digest
```

### Production paths

Production Git root:

```text
<PRODUCTION_GIT_ROOT>
```

Production ERP installation:

```text
<PRODUCTION_ERP_ROOT>
```

From the production Git root:

```bash
cd <PRODUCTION_GIT_ROOT>
```

Set/select the approved immutable image:

```env
CUSTOM_IMAGE=<IMAGE_REGISTRY>/<IMAGE_NAME>
CUSTOM_TAG=<approved-immutable-tag>
PULL_POLICY=always
```

Regenerate:

```bash
./production/scripts/deploy.sh --regenerate
```

Inspect the complete generated configuration before deployment:

```bash
grep -nE \
  'image:|traefik.http.routers|REDIS_|SITES|SITES_RULE' \
  production/production.yaml
```

Then deploy:

```bash
./production/scripts/deploy.sh
```

For the current production architecture, use the normal production deployment command. Do not use the staging `--skip-infra` behavior unless the deployment procedure for that environment explicitly requires it.

---

## 15. Generate, inspect, then deploy

Do not manually edit the generated:

```text
production/production.yaml
```

Change the intended environment/configuration inputs and regenerate:

```bash
./production/scripts/deploy.sh --regenerate
```

Then inspect:

```bash
grep -n 'image:' production/production.yaml
```

Also verify the generated file contains the intended:

```text
image
site/router rule
Redis configuration
networks
shared-infrastructure references
```

The generated Compose file is an output.

It should not be treated as the primary configuration source.

---

## 16. Verify production after deployment

Check containers:

```bash
docker compose \
  -f production/production.yaml \
  ps
```

Check image references:

```bash
docker compose \
  -f production/production.yaml \
  images
```

Verify the application image versions:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench version
```

Verify site-installed applications:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <PRODUCTION_SITE> list-apps
```

For the current production release, expected applications are:

```text
frappe
erpnext
hrms
india_compliance
```

Verify HTTPS:

```bash
curl -sk -o /dev/null \
  -w 'HTTP %{http_code}\n' \
  https://<PRODUCTION_SITE>/login
```

Expected:

```text
HTTP 200
```

Verify API:

```bash
curl -sk \
  https://<PRODUCTION_SITE>/api/method/ping
```

Expected:

```json
{ "message": "pong" }
```

Then test browser login and representative business workflows.

---

## 17. Cache and frontend considerations

The layered image contains the built application assets.

Do not manually copy assets between containers to make one deployment match another.

When an application release requires cache invalidation, use the Bench command:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <PRODUCTION_SITE> clear-cache
```

Restart the relevant application services when required.

For an HTTP 500 or frontend asset problem, inspect logs and current container/image state before changing files manually.

See:

[`troubleshooting/css-js-404-after-custom-app.md`](troubleshooting/css-js-404-after-custom-app.md)

---

## 18. Rollback

The application-image rollback mechanism is:

```text
current approved image
        ↓
previous approved immutable image
```

Set:

```env
CUSTOM_TAG=<previous-approved-tag>
```

Regenerate:

```bash
./scripts/deploy.sh --regenerate
```

Then redeploy using the environment's normal deployment command.

### Critical database warning

An image rollback is **not** automatically a database rollback.

If a site migration has changed the database schema/data, reverting the container image alone may leave the previous application incompatible with the current database.

For major-version upgrades:

```text
pre-upgrade backup
        ↓
database/files restore
        ↓
previous compatible application release
```

The documented backup/restore procedure is therefore the authoritative database rollback mechanism.

See:

[`../backup/README.md`](../backup/README.md)

---

## 19. Updating an application

To update a pinned application:

```text
1. Change the application version in the approved build manifest
2. Commit the change locally
3. Build a new immutable image
4. Verify bench version
5. Push the new image
6. Record the registry digest
7. Deploy to staging
8. Perform UAT
9. Promote the same artifact to production
```

Example:

```json
{
  "url": "https://github.com/resilient-tech/india-compliance",
  "branch": "v16.10.0"
}
```

Rebuild using the same BuildKit-secret pattern:

```bash
docker buildx build \
  --load \
  --secret id=apps_json,src=<approved-apps-manifest> \
  --build-arg=FRAPPE_IMAGE_PREFIX=frappe \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --tag="$IMAGE_TAG" \
  --file=images/layered/Containerfile \
  .
```

Do not mix application pin changes with unrelated production host changes unless the combined change has been tested together.

---

## 20. Adding a custom app

Add the application to the approved build manifest.

Example:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "v16.34.2"
  },
  {
    "url": "https://github.com/frappe/hrms",
    "branch": "v16.18.1"
  },
  {
    "url": "https://github.com/resilient-tech/india-compliance",
    "branch": "v16.9.0"
  },
  {
    "url": "https://github.com/YOUR_ORG/your-app",
    "branch": "v1.0.0"
  }
]
```

Validate:

```bash
python3 -m json.tool <approved-apps-manifest>
```

Build a new immutable image.

Then:

```text
local verification
      ↓
staging
      ↓
UAT
      ↓
production
```

The custom app being present in the image does not by itself change an existing site's database.

Use:

```bash
bench --site <site> install-app your_app
```

and then:

```bash
bench --site <site> migrate
```

when the site actually requires installation/migration.

---

## 21. Private application repositories

Do not commit access tokens inside application manifests.

For private repositories, use an authentication mechanism appropriate for the build environment.

Credentials should be supplied as secrets, not embedded in:

```text
Dockerfile ARG
Docker image layer
Git commit
public application manifest
```

The BuildKit secret pattern is part of the repository's intended approach for keeping build-time manifest data out of ordinary build arguments.

---

## 22. CI/CD

GitHub Actions may be used to build and publish images.

The important requirement is that CI must use the same:

```text
images/layered/Containerfile
```

and the same BuildKit secret mechanism as local builds.

Conceptually:

```yaml
secrets: |
  id=apps_json,src=<approved-apps-manifest>
```

The release workflow should be:

```text
checkout
   ↓
prepare approved manifest
   ↓
build with BuildKit secret
   ↓
smoke-test image
   ↓
push immutable image
   ↓
record digest
```

Do not maintain a second production build process based on:

```text
APPS_JSON_BASE64
```

Different build mechanisms create different artifacts and weaken reproducibility.

---

## 23. Troubleshooting

### Build fails with "app not found"

Validate the manifest:

```bash
python3 -m json.tool <approved-apps-manifest>
```

Verify repository visibility/access:

```bash
git ls-remote https://github.com/frappe/erpnext.git
git ls-remote https://github.com/resilient-tech/india-compliance.git
```

Verify the requested application tag:

```bash
git ls-remote --tags \
  https://github.com/frappe/erpnext.git \
  v16.34.2
```

For private applications, check authentication separately.

---

### Build fails before `bench init`

Verify base images:

```bash
docker pull frappe/build:version-16
docker pull frappe/base:version-16
```

Verify Buildx:

```bash
docker buildx version
```

Verify Docker has BuildKit/buildx secret support.

---

### Build does not see the application manifest

Use:

```bash
--secret id=apps_json,src=<approved-apps-manifest>
```

and not:

```bash
--build-arg=APPS_JSON_BASE64=...
```

The secret name must be exactly:

```text
apps_json
```

and the current layered Containerfile must consume that secret.

---

### Application versions are unexpected

Check:

```bash
docker run --rm \
  "$IMAGE_TAG" \
  bench version
```

Confirm:

```text
FRAPPE_BRANCH=version-16
```

and confirm the application versions in the approved build manifest.

Remember:

```text
Frappe Framework
    ↓
FRAPPE_BRANCH / base-build images

ERPNext / HRMS / India Compliance / custom apps
    ↓
application manifest
```

Because `version-16` is a moving reference, record the final custom image digest for important production releases.

---

### Site-installed applications are unexpected

Check:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <site> list-apps
```

Do not infer site installation from:

```bash
bench version
```

The image may contain an application that the site's database does not have installed.

---

### Assets return 404

First verify that application containers are running the intended image:

```bash
docker compose \
  -f production/production.yaml \
  images
```

Then inspect:

```text
application assets inside the image/container
mounted sites/assets
frontend logs
backend logs
```

The current layered architecture builds assets into the image and links them into the mounted sites volume during container startup.

Do not manually copy application assets between containers as a permanent fix.

After an application update, redeploy the intended image and clear the site cache where appropriate:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <site> clear-cache
```

For the known custom-app CSS/JS failure mode, see:

[`troubleshooting/css-js-404-after-custom-app.md`](troubleshooting/css-js-404-after-custom-app.md)

---

### Production returns HTTP 500 after deployment

First inspect logs and container state:

```bash
docker compose \
  -f production/production.yaml \
  ps
```

```bash
./scripts/logs.sh --tail
```

Then, where the failure matches the observed v16 recovery path, clear cache:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site <PRODUCTION_SITE> clear-cache
```

Restart application services as required and test again.

Do not assume that cache clearing is the universal cause/fix for HTTP 500. Use logs to identify the actual failure.

---

### Cannot push to GHCR

Check authentication:

```bash
docker login ghcr.io
```

Then:

```bash
docker push "$IMAGE_TAG"
```

If authentication succeeds but push is denied, verify that the account/token has permission to publish the package.

For the Docker credential-helper/GPG failure observed previously, use the isolated `DOCKER_CONFIG` procedure in section 11.

---

## 24. Operational rules

### Rule 1 — Never build production on the server

Build from the local development checkout.

### Rule 2 — Never deploy an untested image

At minimum verify:

```bash
bench version
```

and perform the required local/staging smoke tests.

### Rule 3 — Use immutable image tags

Prefer:

```text
YYYYMMDD-GITSHA
```

or another uniquely traceable release tag.

Avoid:

```text
latest
production-latest
staging-latest
```

as deployment identities.

### Rule 4 — Promote the same artifact

Record the registry digest and ensure staging and production reference the same immutable image digest.

### Rule 5 — Keep previous images

Retain previous production images long enough to support a practical rollback window.

### Rule 6 — Back up before migrations

For major application/database changes:

```bash
./scripts/backup-site.sh \
  <site> \
  --with-files \
  --auto-copy
```

Verify that the backup completed successfully before migrating.

### Rule 7 — Do not manually edit generated Compose

Change the underlying environment/configuration inputs and regenerate:

```bash
./scripts/deploy.sh --regenerate
```

### Rule 8 — Do not use raw SQL as a migration shortcut

Database maintenance scripts that rely on internal Frappe table structures must be reviewed against the target Frappe version before use.

### Rule 9 — Record the exact artifact

For every promoted image retain:

```text
repository commit
image tag
registry digest
bench version
Python/runtime version
application manifest
```

The tag is convenient for deployment; the registry digest is the authoritative immutable identity.

### Rule 10 — Keep image and database state separate

An image can contain a newer application without changing a site's database.

A site migration can change the database without changing the image contents.

Track both.

---

## 25. Standard release checklist

### Local

- [ ] Working tree reviewed
- [ ] Correct application versions pinned in the approved manifest
- [ ] Test/release manifest choice is intentional
- [ ] Manifest validates as JSON
- [ ] Build uses `docker buildx`
- [ ] Build uses `--secret id=apps_json`
- [ ] Image builds successfully
- [ ] `bench version` verified
- [ ] Python/runtime verified
- [ ] Local application smoke test passed
- [ ] Changes committed

### Staging

- [ ] Immutable image pushed
- [ ] Registry digest recorded
- [ ] Staging uses the intended image tag
- [ ] Image digest verified
- [ ] Backup taken before migration where required
- [ ] `bench migrate` completed where required
- [ ] Site-installed applications verified
- [ ] Login verified
- [ ] Critical ERP workflows tested
- [ ] HRMS tested where applicable
- [ ] India Compliance tested where applicable
- [ ] UAT approved
- [ ] Burn-in completed where required

### Production

- [ ] Staging/UAT approved
- [ ] GitHub `main` contains the approved state
- [ ] Same immutable image tag selected
- [ ] Same registry digest verified
- [ ] Pre-change production backup completed for migrations
- [ ] `production.yaml` regenerated
- [ ] Generated Compose file inspected
- [ ] Containers updated
- [ ] `bench version` verified
- [ ] Site-installed applications verified
- [ ] Site migrations completed where required
- [ ] HTTPS `/login` returns 200
- [ ] API ping returns `pong`
- [ ] Browser login verified
- [ ] Critical workflows verified
- [ ] Logs checked
- [ ] Previous image retained for rollback

---

## 26. Related repository documentation

### Production

- [Production README](README.md)
- [Operations Runbook](operations-runbook.md)

### Major upgrades

- [ERPNext v16 Upgrade Plan](erpnext-v16-upgrade-plan.md)
- [Pre-update Safety Checklist](pre-update-safety-checklist.md)

### Backups

- [Automated Backup README](../backup/README.md)

### Troubleshooting

- [CSS/JS 404 after Custom App](troubleshooting/css-js-404-after-custom-app.md)
- [GHCR Docker Authentication – OpenPGP Issue and Resolution](GHCR%20Docker%20Authentication%20%E2%80%93%20OpenPGP%20Issue%20and%20Resolution.md)

### Build source

```text
images/layered/Containerfile
```

The application manifest is a build-time input and may be represented by a dedicated release/test manifest depending on the release workflow. The exact manifest used for a deployed immutable image must be recorded with the release.

---

## 27. Current verified production release

Current image:

```text
<IMAGE_REGISTRY>/<IMAGE_NAME>:<IMMUTABLE_TAG>
```

Registry digest:

```text
sha256:<REGISTRY_DIGEST>
```

Verified application versions:

```text
Frappe           16.33.1
ERPNext          16.34.2
HRMS             16.18.1
India Compliance 16.9.0
Python            3.14.7
```

The same immutable image artifact passed staging/UAT and was promoted to production.

---

## 28. Deployment model

The repository's standard promotion model is:

```text
LOCAL VS CODE
     ↓
Git commit + push
     ↓
GitHub / staging
     ↓
Staging deployment + migration + UAT
     ↓
GitHub / main
     ↓
Production deployment
```

The application image model is:

```text
Build locally
     ↓
Publish to GHCR
     ↓
Record digest
     ↓
Promote exact same artifact
```

Servers are deployment targets, not build environments.

---

## 29. Final operating principles

The custom-image workflow exists to make the ERPNext deployment:

```text
reproducible
traceable
immutable
testable
rollback-aware
```

The most important rule is simple:

> **Build once. Verify it. Record the digest. Promote the exact artifact.**

---

**Repository:** `<GITHUB_ORG>/<GITHUB_REPO>`

**Image pattern:** Layered custom image with immutable promotion

**Build mechanism:** Docker BuildKit secret for the application manifest

**Current release:** Frappe 16.33.1 / ERPNext 16.34.2 / HRMS 16.18.1 / India Compliance 16.9.0

**Current image:** `<IMAGE_REGISTRY>/<IMAGE_NAME>:<IMMUTABLE_TAG>`

**Current registry digest:** `sha256:<REGISTRY_DIGEST>`

**Last updated:** September 17, 2026
