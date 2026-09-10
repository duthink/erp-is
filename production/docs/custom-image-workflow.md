# Building Custom ERPNext Images

**Production workflow for ERPNext, HRMS, India Compliance, and other Frappe apps**

This document defines the repository's standard workflow for building and promoting custom ERPNext Docker images.

The image is built from `images/layered/Containerfile` and contains the Frappe Framework plus the applications declared in an `apps.json` manifest. Application assets are built into the image so application containers use the same immutable artifact.

## 1. Architecture

The repository uses the **layered custom-image pattern**:

```text
production/apps.json
        │
        │ BuildKit secret
        ▼
images/layered/Containerfile
        │
        ├── frappe/build:version-16
        │
        ├── Frappe Framework
        │
        ├── ERPNext
        ├── HRMS
        └── other apps in apps.json
        │
        ▼
ghcr.io/duthink/erpnext-custom:<immutable-tag>
        │
        ├── Staging / UAT
        │
        └── Production
```

The layered Containerfile consumes the `apps.json` file through a BuildKit secret:

```dockerfile
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json ...
```

**Do not use `APPS_JSON_BASE64`.** The current build system intentionally uses a BuildKit secret instead.

## 2. Important repository rules

### Build locally

Image builds and Git operations are performed from the local development checkout.

```text
LOCAL VS CODE
     │
     ├── edit code/manifests
     ├── build image
     ├── test image
     └── commit changes
             │
             ▼
       GitHub / staging
```

The staging and production servers are deployment targets. Do not perform merges, rebases, application development, or image-building changes there as part of the normal promotion workflow.

### Build once, promote the same artifact

For a release candidate:

```text
local build
    ↓
immutable registry tag
    ↓
staging
    ↓
UAT
    ↓
same image digest
    ↓
production
```

Do not rebuild the application image from `main` after staging passes. Production should receive the same tested image artifact.

## 3. What belongs in `apps.json`

Frappe Framework is **not** listed in `apps.json`.

The Framework is selected through:

```text
FRAPPE_BRANCH
```

passed to `images/layered/Containerfile`.

`apps.json` contains ERPNext, HRMS, India Compliance, and other applications that should be baked into the image.

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

For production images, prefer release tags or exact commits over moving branches.

Validate the manifest before building:

```bash
python3 -m json.tool production/apps.json
```

## 4. Current verified v16 stack

The current locally verified v16 application set is:

| Component | Version |
|---|---:|
| Frappe Framework | 16.33.1 |
| ERPNext | 16.34.2 |
| HRMS | 16.18.1 |
| India Compliance | 16.9.0 |
| Python | 3.14.7 |

The custom image is built with:

```text
FRAPPE_BRANCH=version-16
```

which currently resolves through:

```text
frappe/build:version-16
frappe/base:version-16
```

For the current verified build, the local image was:

```text
ghcr.io/duthink/erpnext-custom:v16-test-v3.2.2
```

with local image ID:

```text
sha256:25506deba681e66f9356b927a8a0450baa88725d2b2e41fab3614f5a3deab559
```

The local image build and `bench version` check completed successfully.

## 5. Prerequisites

Verify Docker and Compose:

```bash
docker --version
docker compose version
docker buildx version
```

The layered build requires BuildKit secret support, so use `docker buildx build`.

The required Frappe base images are:

```bash
docker pull frappe/build:version-16
docker pull frappe/base:version-16
```

Verify the runtime if required:

```bash
docker run --rm frappe/base:version-16 python --version
```

## 6. Build a local test image

For a temporary test manifest, use a separate file such as:

```text
production/apps.v16-test.json
```

Do not overwrite the production manifest merely to perform a test.

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

Build:

```bash
docker buildx build \
  --load \
  --secret id=apps_json,src=production/apps.v16-test.json \
  --build-arg=FRAPPE_IMAGE_PREFIX=frappe \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --tag=ghcr.io/duthink/erpnext-custom:v16-test \
  --file=images/layered/Containerfile \
  .
```

### Why `--load`?

`--load` imports the resulting image into the local Docker image store so it can immediately be used with `docker run` or a local Compose test project.

## 7. Verify the image before deploying it

Check the application versions:

```bash
docker run --rm \
  ghcr.io/duthink/erpnext-custom:v16-test \
  bench version
```

Expected structure:

```text
erpnext 16.34.2
frappe 16.33.1
hrms 16.18.1
india_compliance 16.9.0
```

Check Python:

```bash
docker run --rm \
  ghcr.io/duthink/erpnext-custom:v16-test \
  python --version
```

Check the image itself:

```bash
docker image inspect \
  ghcr.io/duthink/erpnext-custom:v16-test \
  --format '{{.Id}}'
```

Record the resulting image identity for the local test.

## 8. Create an immutable release tag

For a candidate that is ready for staging, use a traceable immutable tag.

Example:

```bash
BUILD_DATE=$(date +%Y%m%d)
GIT_SHA=$(git rev-parse --short HEAD)

IMAGE="ghcr.io/duthink/erpnext-custom"
IMAGE_TAG="${IMAGE}:${BUILD_DATE}-${GIT_SHA}"

echo "Image: $IMAGE_TAG"
```

The Git commit should represent the exact repository state used to build the image.

Do not use `production-latest` as the production version identifier.

## 9. Build the staging candidate

From the local checkout:

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

Verify:

```bash
docker run --rm "$IMAGE_TAG" bench version
```

Do not push an image that has not passed the local verification.

## 10. Push the candidate image

Log in to GHCR using credentials appropriate for your environment:

```bash
echo "$GITHUB_TOKEN" | \
  docker login ghcr.io \
  -u duthink \
  --password-stdin
```

Push the immutable tag:

```bash
docker push "$IMAGE_TAG"
```

Then retrieve the registry digest:

```bash
docker inspect "$IMAGE_TAG" \
  --format '{{json .RepoDigests}}'
```

The registry digest is the preferred identity for verifying that staging and production use the same image artifact.

## 11. Staging deployment

The image tag is selected in the staging environment configuration.

The staging deployment should:

```text
1. Pull the immutable candidate image
2. Start the staging Compose project
3. Run database migration if required
4. Verify application versions
5. Perform UAT
```

Staging and production are separate Compose projects and separate site/data volumes.

Do not copy staging environment files, site volumes, generated Compose files, or database credentials into production.

## 12. Activate applications on a site

Putting an application into the image does not automatically install it into every site's database.

For an existing site:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com list-apps
```

Install an application when required:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com install-app hrms
```

Then migrate:

```bash
docker compose \
  -f production/production.yaml \
  exec backend \
  bench --site erp.example.com migrate
```

For a major-version upgrade, take a verified backup before running migrations.

## 13. Production promotion

Production should use the **same immutable image that passed staging/UAT**.

Do not rebuild it from `main`.

After staging approval:

```text
GitHub staging
      │
      ▼
GitHub main
      │
      ▼
Production deploy
      │
      ▼
same image tag / digest
```

Set production:

```env
CUSTOM_IMAGE=ghcr.io/duthink/erpnext-custom
CUSTOM_TAG=<approved-immutable-tag>
PULL_POLICY=always
```

Then regenerate the generated Compose file:

```bash
./scripts/deploy.sh --regenerate
```

Inspect the generated image references before deploying:

```bash
grep -n 'image:' production/production.yaml
```

Then deploy:

```bash
./scripts/deploy.sh
```

## 14. Verify production

Check the running containers:

```bash
docker compose -f production/production.yaml ps
```

Check the image references:

```bash
docker compose -f production/production.yaml images
```

Check application versions:

```bash
docker compose -f production/production.yaml \
  exec backend \
  bench version
```

Check site applications:

```bash
docker compose -f production/production.yaml \
  exec backend \
  bench --site erp.example.com list-apps
```

Clear cache after a major application update when appropriate:

```bash
docker compose -f production/production.yaml \
  exec backend \
  bench --site erp.example.com clear-cache
```

Run the application smoke tests and critical business workflows before closing the deployment window.

## 15. Rollback

The image rollback mechanism is:

```text
current image
     ↓
previous approved immutable image
```

Change `CUSTOM_TAG` back to the previously known-good image tag:

```env
CUSTOM_TAG=<previous-approved-tag>
```

Regenerate:

```bash
./scripts/deploy.sh --regenerate
```

Then redeploy:

```bash
./scripts/deploy.sh
```

**Important:** an application-image rollback is not automatically a database rollback.

If a migration has changed the database schema, reverting the container image alone may not restore the previous database state. For major-version migrations, the database backup/restore procedure is the authoritative rollback mechanism.

## 16. Updating an application

To update an application:

```text
1. Change the pinned version in apps.json
2. Commit the change locally
3. Build a new immutable image
4. Verify bench version
5. Push the new image
6. Deploy to staging
7. Perform UAT
8. Promote the same artifact to production
```

Example:

```json
{
  "url": "https://github.com/resilient-tech/india-compliance",
  "branch": "v16.10.0"
}
```

Rebuild using the same BuildKit-secret workflow:

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

## 17. Adding a custom app

Add the application to `production/apps.json`:

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

Build and test a new immutable image.

The application being present in the image does not by itself modify an existing site's database. Use `bench install-app` and `bench migrate` where required.

## 18. Private application repositories

Do not commit access tokens inside `apps.json`.

For private repositories, use an authentication mechanism appropriate for the build environment and ensure credentials are supplied as secrets rather than committed files or build arguments.

Never expose a token through:

```text
Dockerfile ARG
Docker image layer
Git commit
public apps.json
```

The BuildKit secret mechanism used by the current Containerfile is intended to avoid leaking the application manifest through normal image build arguments.

## 19. CI/CD

The repository may use GitHub Actions to build and publish images.

The important requirement is that CI uses the same layered Containerfile and the same BuildKit secret mechanism as local builds:

```yaml
secrets: |
  id=apps_json,src=production/apps.json
```

The workflow should:

```text
checkout
  ↓
prepare apps.json
  ↓
build with BuildKit secret
  ↓
smoke-test image
  ↓
push immutable image
```

Do not maintain a separate CI implementation based on `APPS_JSON_BASE64`.

The upstream reusable image workflow in this repository already demonstrates the BuildKit secret pattern.

## 20. Troubleshooting

### Build fails with "app not found"

Validate the manifest:

```bash
python3 -m json.tool production/apps.json
```

Verify the repository:

```bash
git ls-remote https://github.com/frappe/erpnext.git
git ls-remote https://github.com/resilient-tech/india-compliance.git
```

Verify the requested tag:

```bash
git ls-remote --tags \
  https://github.com/frappe/erpnext.git \
  v16.34.2
```

Check private repository authentication separately.

### Build fails before `bench init`

Verify the base images:

```bash
docker pull frappe/build:version-16
docker pull frappe/base:version-16
```

Verify BuildKit:

```bash
docker buildx version
```

### Build does not see `apps.json`

Use:

```bash
--secret id=apps_json,src=production/apps.json
```

and do not replace it with:

```bash
--build-arg=APPS_JSON_BASE64=...
```

The current layered Containerfile expects the secret named exactly:

```text
apps_json
```

### Application versions are unexpected

Check the image:

```bash
docker run --rm "$IMAGE_TAG" bench version
```

Remember that:

```text
FRAPPE_BRANCH=version-16
```

selects the Frappe framework line through the Frappe base images, while individual applications are pinned in `apps.json`.

Because `version-16` is a moving reference, record the base-image digest used for important production builds.

### Assets return 404

First verify every application container is running the same image:

```bash
docker compose -f production/production.yaml images
```

Then inspect assets inside the image/container.

The current layered image architecture moves built assets into the image and links them into the mounted sites volume during container startup.

Restart/redeploy the affected application containers rather than manually copying application assets between containers.

### Cannot push to GHCR

Check authentication:

```bash
docker login ghcr.io
```

Then:

```bash
docker push "$IMAGE_TAG"
```

If authentication succeeds but push is denied, verify the account/token has permission to publish the package.

## 21. Operational rules

### Rule 1 — Never build production on the server

Build from the local development checkout.

### Rule 2 — Never deploy an untested image

At minimum verify:

```bash
bench version
```

and perform the local/staging smoke tests.

### Rule 3 — Use immutable image tags

Prefer:

```text
YYYYMMDD-GITSHA
```

or another uniquely traceable tag.

Avoid relying on:

```text
latest
production-latest
```

as the production identity.

### Rule 4 — Promote the same artifact

Record the registry digest and ensure staging and production point to the same image digest.

### Rule 5 — Keep old images

Retain previous production images long enough to support a practical rollback window.

### Rule 6 — Back up before migrations

For major application/database changes:

```bash
./scripts/backup-site.sh <site> --with-files --auto-copy
```

Verify that the backup completed successfully before proceeding.

### Rule 7 — Do not manually edit generated `production.yaml`

Change the environment/configuration inputs and regenerate it:

```bash
./scripts/deploy.sh --regenerate
```

### Rule 8 — Do not run raw SQL cleanup scripts during a major-version migration

Database maintenance scripts that depend on internal Frappe table names must be reviewed for the target Frappe version before use.

## 22. Standard release checklist

### Local

- [ ] Working tree clean or intentionally modified
- [ ] Correct application versions pinned in `apps.json`
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
- [ ] Staging uses the candidate image
- [ ] Backup taken before migration
- [ ] `bench migrate` completed
- [ ] Login verified
- [ ] Critical ERP workflows tested
- [ ] HRMS tested where applicable
- [ ] India Compliance tested where applicable
- [ ] UAT approved

### Production

- [ ] Staging/UAT approved
- [ ] Same immutable image tag selected
- [ ] Same registry digest verified
- [ ] Production backup completed
- [ ] Maintenance window confirmed
- [ ] `production.yaml` regenerated
- [ ] Containers updated
- [ ] `bench version` verified
- [ ] Site migrations completed
- [ ] Critical workflows verified
- [ ] Logs checked
- [ ] Previous image retained for rollback

## 23. Repository references

Related repository documentation:

- [Production README](README.md)
- [Operations Runbook](operations-runbook.md)
- [ERPNext v16 Upgrade Plan](erpnext-v16-upgrade-plan.md)
- [Pre-update Safety Checklist](pre-update-safety-checklist.md)

The image build source is:

```text
images/layered/Containerfile
```

The application manifest is:

```text
production/apps.json
```

For temporary version testing, use a separate manifest such as:

```text
production/apps.v16-test.json
```

---

**Pattern:** Layered custom image with immutable promotion

**Build mechanism:** Docker BuildKit secret for `apps.json`

**Promotion model:** Build locally → staging/UAT → same artifact → production