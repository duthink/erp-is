# ERPNext Backup

This directory contains the ERPNext backup runner, configuration, and systemd scheduling integration used by the deployment.

The backup design deliberately keeps backups independent of the ERPNext scheduler and application scheduler containers.

---

## 1. Architecture

The backup flow is:

```text
systemd timer
    ↓
docker compose run --rm backup-runner
    ↓
same immutable ERPNext custom image
    ↓
bench backup
    ↓
S3-compatible object storage
```

The backup runner uses the ERPNext installation's existing `sites` volume and the deployment image.

Backups do **not** depend on:

```text
ERPNext scheduler
Ofelia
application cron
```

This keeps backup scheduling independent of application scheduling and reduces the risk that an application-level scheduler failure also disables backups.

---

## 2. Backup Modes

The backup runner supports two modes.

### Database-only backup

```bash
./backup/run-backup.sh 0
```

Creates a database backup without the public/private file archives.

This mode is suitable for a high-frequency database backup schedule.

### Full backup

```bash
./backup/run-backup.sh 1
```

Includes:

```text
database
public files
private files
site configuration
```

This mode is suitable for a lower-frequency full backup schedule and for important maintenance/migration checkpoints.

---

## 3. Where to Run the Script

The script is designed to run from the ERP installation directory rather than from the Git repository root.

Generic example:

```text
<ERP_ROOT>
```

Run:

```bash
cd <ERP_ROOT>
./backup/run-backup.sh 0
```

or:

```bash
./backup/run-backup.sh 1
```

The script assembles the backup-runner Compose configuration from the environment's deployment configuration.

For the exact production path, use the private deployment/environment documentation.

---

## 4. Backup Runner

The backup runner is defined in:

```text
backup/compose.backup-runner.yaml
```

The runner:

- uses the ERPNext custom immutable image
- mounts the site's `sites` volume
- mounts persistent backup tooling where required
- uses the database network required by the deployment
- executes `backup/backup-to-s3.sh`

The backup runner is intentionally ephemeral:

```text
docker compose run --rm
```

It is created for the backup operation and removed after completion.

---

## 5. Backup-to-S3 Script

The main backup logic is:

```text
backup/backup-to-s3.sh
```

The workflow is:

```text
bench backup
    ↓
local backup files
    ↓
validate/upload
    ↓
S3-compatible object storage
    ↓
retention cleanup
```

The script supports:

```text
database-only
```

and:

```text
database + public/private files
```

according to the requested backup mode.

Local retention is bounded and remote retention cleanup is time-bounded so storage cleanup cannot indefinitely block a backup run.

---

## 6. S3-Compatible Storage

The backup design uses S3-compatible object storage for the remote copy.

Examples include:

```text
DigitalOcean Spaces
Amazon S3
other S3-compatible storage
```

Configuration is environment-specific.

Backups use an environment/site/date hierarchy:

```text
s3://<BACKUP_BUCKET>/<ENVIRONMENT>/<SITE>/<YYYY-MM-DD>/
```

Example:

```text
<BACKUP_BUCKET>/
    <ENVIRONMENT>/
        <SITE>/
            YYYY-MM-DD/
```

The exact bucket, endpoint, region, environment, and site names belong in the private deployment configuration.

---

## 7. Private Backup Configuration

Credentials and environment-specific backup settings must never be committed to a public Git repository.

A local installation may use:

```text
backup/backup.env
```

Protect private environment files:

```bash
chmod 600 backup/backup.env
```

Typical configuration includes:

```text
S3_ENDPOINT_URL
S3_BUCKET_NAME
S3_REGION
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
ENV_PREFIX
BACKUP_SITES
```

Never expose credentials in:

```text
Git
Dockerfiles
image layers
shell history
public documentation
```

Keep the actual values in private environment configuration or an appropriate secret-management system.

---

## 8. Server-Side Environment Configuration

Systemd instances use a private host-level environment file:

```text
/etc/erpnext-backup/<instance>.env
```

A typical instance configuration contains the ERP installation root:

```text
ERP_ROOT=<ERP_ROOT>
```

Keep host-specific values outside the public repository.

The private deployment documentation should contain the actual:

```text
ERP_ROOT
SITE
environment name
backup bucket
storage endpoint
```

Do not put credentials into this public README.

---

## 9. Systemd Services and Timers

The repository provides:

```text
erpnext-backup-db@.service
erpnext-backup-db@.timer

erpnext-backup-full@.service
erpnext-backup-full@.timer
```

The intended model is:

```text
DB service
    ↓
high-frequency timer

Full backup service
    ↓
lower-frequency timer
```

A common production schedule is:

```text
database backups: hourly
full backups: daily
```

The exact schedule belongs to the deployment environment and is defined by the installed systemd timer units.

---

## 10. Enable Backup Timers

For a deployment instance named `<INSTANCE>`:

```bash
sudo systemctl enable --now \
  erpnext-backup-db@<INSTANCE>.timer
```

```bash
sudo systemctl enable --now \
  erpnext-backup-full@<INSTANCE>.timer
```

Verify:

```bash
systemctl list-timers --all | grep erpnext-backup
```

Also check:

```bash
systemctl status \
  erpnext-backup-db@<INSTANCE>.timer

systemctl status \
  erpnext-backup-full@<INSTANCE>.timer
```

### Important: systemd is host-wide

Systemd timers are not scoped to the Git checkout or application directory currently open in the shell.

On a host containing multiple environments:

```text
staging
production
```

a production timer remains a production timer regardless of the current working directory.

Do not disable a production backup timer merely because you are working on another environment.

---

## 11. Staging Backup Policy

A deployment may choose to keep staging backups manual rather than running production-style automated timers.

Manual staging backups are useful before:

```text
production-data clone
database restore
migration rehearsal
destructive testing
```

Example:

```bash
./backup/run-backup.sh 1
```

Keep staging backup configuration separate from production configuration.

Never copy production credentials into staging for convenience.

---

## 12. Manual Backup

A manual backup is useful before:

```text
major migration
app installation
app uninstallation
data restoration
destructive maintenance
production troubleshooting that changes data
```

### Database-only

```bash
./backup/run-backup.sh 0
```

### Full backup

```bash
./backup/run-backup.sh 1
```

For a major production migration, prefer the full backup.

For the exact backup taken during a specific release, including date/time, size, and storage location, use the private release/deployment record.

---

## 13. Verify a Backup Completed Successfully

For systemd oneshot services, a successful run normally ends with the service becoming:

```text
inactive (dead)
```

That state alone is not an error.

Inspect the journal:

```bash
sudo journalctl \
  -u erpnext-backup-db@<INSTANCE>.service \
  -n 100 \
  --no-pager
```

and:

```bash
sudo journalctl \
  -u erpnext-backup-full@<INSTANCE>.service \
  -n 100 \
  --no-pager
```

Look for:

```text
Successful backups: 1
Failed backups: 0
```

Also verify that expected remote objects exist in the configured object storage.

---

## 14. Verify Backup Files

Use the validation appropriate to the generated backup type.

### Database archives

For gzip-compressed database backups:

```bash
gzip -t <database-backup-file>.sql.gz
```

No output and exit code `0` indicates gzip integrity passed.

### Public/private file archives

Validate the generated archive:

```bash
tar -tzf <backup-file>.tar
```

or use the appropriate archive format produced by Bench.

### Configuration

Validate JSON where applicable:

```bash
python3 -m json.tool <site-config.json>
```

Do not modify a production configuration file merely to validate it.

---

## 15. Verify Remote Objects

Use the AWS CLI or the backup runner to inspect the configured remote storage.

Generic example:

```bash
aws s3 ls \
  s3://<BACKUP_BUCKET>/<ENVIRONMENT>/<SITE>/ \
  --endpoint-url <S3_ENDPOINT_URL>
```

For an exact date:

```bash
aws s3 ls \
  s3://<BACKUP_BUCKET>/<ENVIRONMENT>/<SITE>/YYYY-MM-DD/ \
  --endpoint-url <S3_ENDPOINT_URL>
```

Do not print credentials while troubleshooting.

---

## 16. AWS CLI

The backup runner uses the AWS CLI-compatible interface to access S3-compatible object storage.

Verify inside the backup tooling environment:

```bash
aws --version
```

The backup tooling may use a persistent volume so the CLI and supporting tools do not need to be bootstrapped for every run.

The exact installed version is an environment/build detail and belongs in the private deployment record when it matters for troubleshooting.

---

## 17. Retention

Two retention controls are used.

### Local retention

```text
BACKUP_RETENTION_DAYS
```

Controls how long local backup files are retained.

### Remote retention

```text
S3_BACKUP_RETENTION_DAYS
```

Controls how long remote backup objects are retained.

Remote cleanup is time-bounded so a storage cleanup operation cannot indefinitely block a backup run.

Retention is a storage-management policy. It is not a substitute for backup verification.

Do not delete a pre-migration backup merely because the normal retention window has elapsed if it is still required for an active release/rollback window.

---

## 18. Why Backups Do Not Use the ERPNext Scheduler

The backup architecture deliberately avoids using the ERPNext scheduler.

Instead of:

```text
ERPNext
   ↓
scheduler
   ↓
backup
```

the dependency chain is:

```text
host systemd
     ↓
backup runner
     ↓
bench backup
     ↓
remote object storage
```

This keeps database protection outside the application scheduling lifecycle.

A scheduler failure therefore does not automatically disable the backup scheduler.

---

## 19. Backup Code Deployment

Backup implementation changes are code changes.

Use:

```text
local development
    ↓
GitHub staging
    ↓
staging verification
    ↓
GitHub main
    ↓
production
```

Do not develop or patch backup scripts directly on production.

Do not manually edit generated deployment files to operate the backup runner.

Change source scripts/configuration and deploy through the normal repository workflow.

---

## 20. Backup Runner Release Safety

The backup runner uses the same immutable custom-image model as the application deployment.

This avoids maintaining a separate ERPNext runtime image solely for backups.

The image used by the backup runner must be compatible with the target site's installed Frappe/ERPNext release.

For each production release, record privately:

```text
image repository
image tag
registry digest
Frappe version
ERPNext version
other installed application versions
```

Do not use mutable release identities such as:

```text
latest
production-latest
```

for backup operations.

---

## 21. Backup Before Major ERPNext Migration

For a major application/database migration:

```text
fresh full backup
        ↓
verify backup
        ↓
migrate staging
        ↓
UAT
        ↓
production migration
```

The pre-migration backup is the primary database rollback point because:

```text
container rollback
    ≠
database rollback
```

A previous application image does not automatically undo migrated database schema/data.

See:

[`../docs/erpnext-v16-upgrade-plan.md`](../docs/erpnext-v16-upgrade-plan.md)

---

## 22. Restore and Recovery

Remote object storage contains the backup artifacts.

Restoration should use the supported Frappe/ERPNext restore procedure appropriate to:

```text
target Frappe version
target ERPNext version
site configuration
backup format
```

A restore should normally be performed into an explicitly chosen target environment/site.

Do not overwrite production with a backup merely as a troubleshooting experiment.

For a major-version rollback:

```text
pre-upgrade backup
      ↓
restore database/files
      ↓
previous compatible application image
```

The database/files restore and application image selection are one coordinated recovery operation.

---

## 23. Production Recovery Checklist

When a production backup needs to be used:

- [ ] Identify the correct backup date/time
- [ ] Identify whether DB-only or full backup is required
- [ ] Confirm remote objects exist
- [ ] Verify archive integrity
- [ ] Confirm target Frappe/ERPNext release compatibility
- [ ] Confirm target site identity
- [ ] Protect the current production state before destructive restore actions
- [ ] Use the documented restore procedure
- [ ] Run required migrations only after confirming the restore state
- [ ] Clear cache where appropriate
- [ ] Verify HTTPS/login/API
- [ ] Verify critical ERP workflows

---

## 24. Troubleshooting

### Backup service exits successfully but timer looks inactive

For a oneshot service, this is normally expected.

Check:

```bash
sudo journalctl \
  -u erpnext-backup-db@<INSTANCE>.service \
  -n 100 \
  --no-pager
```

and the corresponding full-backup service.

Look for the successful/failed backup counters.

### Backup timer does not appear

Run:

```bash
systemctl list-timers --all | grep erpnext-backup
```

Then:

```bash
systemctl status \
  erpnext-backup-db@<INSTANCE>.timer

systemctl status \
  erpnext-backup-full@<INSTANCE>.timer
```

Confirm the unit files are installed and the instance environment file exists:

```text
/etc/erpnext-backup/<INSTANCE>.env
```

### Backup cannot connect to MariaDB

Verify:

```text
MariaDB container
database network
backup-runner Compose configuration
site/database configuration
```

Do not change production database credentials as a first troubleshooting step.

### S3-compatible storage upload fails

Verify:

```text
S3_ENDPOINT_URL
S3_BUCKET_NAME
S3_REGION
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

Do not print secret values.

Test access from the backup tooling environment using the configured endpoint.

### Remote retention cleanup hangs

The implementation should bound the cleanup operation with a timeout.

A cleanup timeout should not become an indefinitely running backup process.

Inspect the backup journal and distinguish:

```text
backup generation succeeded
upload succeeded
cleanup timed out
```

### Backup upload succeeds but local cleanup does not

Check:

```text
disk usage
backup retention settings
file ownership
backup-tools volume
```

Remote backup success should not be confused with local retention success.

---

## 25. Operational Rules

### Rule 1 — Never commit backup credentials

Keep credentials outside Git.

### Rule 2 — Do not depend on the ERPNext scheduler

Backups are host-scheduled through systemd.

### Rule 3 — Keep staging and production credentials separate

Never copy production secrets into staging for convenience.

### Rule 4 — Back up before destructive changes

Especially before:

```text
major migrations
app installation that changes database state
app uninstall
restore operations
destructive maintenance
```

### Rule 5 — Verify backups, not merely backup commands

A command that exits successfully is not the same as a verified remote backup.

Check:

```text
journal
remote object
archive integrity
```

### Rule 6 — Keep pre-migration backups

The backup used before a major release should remain available throughout the rollback window even if normal retention would otherwise remove it.

### Rule 7 — Do not manually edit generated deployment files

Change source configuration and regenerate.

### Rule 8 — Protect environment boundaries

Do not disable another environment's backup timers merely because you are working on a different checkout.

### Rule 9 — Keep backup scheduling independent

Do not reintroduce:

```text
Ofelia
ERPNext scheduler backup jobs
application-level cron dependencies
```

when the systemd/backup-runner architecture is in use.

---

## 26. Standard Backup Checklist

### Manual database backup

- [ ] Run `./backup/run-backup.sh 0`
- [ ] Command completed successfully
- [ ] Remote object exists
- [ ] Database archive passes `gzip -t`

### Manual full backup

- [ ] Run `./backup/run-backup.sh 1`
- [ ] Database backup exists
- [ ] Public backup exists
- [ ] Private backup exists
- [ ] Configuration backup exists
- [ ] Remote objects verified
- [ ] Archives validated

### Automated production backup

- [ ] Database timer enabled
- [ ] Full backup timer enabled
- [ ] Timer schedules visible
- [ ] Last run successful
- [ ] Remote objects present
- [ ] No failed runs
- [ ] Retention cleanup healthy

### Major migration

- [ ] Fresh production full backup
- [ ] Backup integrity verified
- [ ] Remote copy verified
- [ ] Backup retained throughout migration/rollback window

---

## 27. Repository Files

The backup directory contains the backup implementation.

Expected files include:

```text
backup/
├── README.md
├── backup-to-s3.sh
├── run-backup.sh
└── compose.backup-runner.yaml
```

Systemd unit templates are installed separately on the host:

```text
erpnext-backup-db@.service
erpnext-backup-db@.timer
erpnext-backup-full@.service
erpnext-backup-full@.timer
```

Host-private environment files live under:

```text
/etc/erpnext-backup/
```

---

## 28. Generic Production Design

The production backup pattern is:

```text
                    APPLICATION HOST
                         │
              ┌──────────┴──────────┐
              │                     │
       DB backup timer        Full backup timer
              │                     │
              └──────────┬──────────┘
                         ▼
                  backup-runner
                         │
                         ▼
              immutable ERPNext image
                         │
                         ▼
                    bench backup
                         │
              ┌──────────┴──────────┐
              │                     │
        local retention       S3-compatible storage
                                    │
                              <BACKUP_BUCKET> /
                              <ENVIRONMENT> /
                              <SITE> /
                              YYYY-MM-DD/
```

The actual storage provider, bucket, site, paths, schedules, and environment names are deployment-specific and belong in the private deployment documentation.

---

## 29. Related Documentation

- [Production README](../docs/README.md)
- [Operations Runbook](../docs/operations-runbook.md)
- [ERPNext v16 Upgrade Plan](../docs/erpnext-v16-upgrade-plan.md)
- [Custom Image Workflow](../docs/custom-image-workflow.md)
- [Pre-update Safety Checklist](../docs/pre-update-safety-checklist.md)
- [CSS/JS 404 Troubleshooting](../docs/troubleshooting/css-js-404-after-custom-app.md)

---

## 30. Final Operating Principle

The backup system should make recovery boring and predictable.

The intended chain is:

```text
scheduled backup
      ↓
immutable backup runner
      ↓
bench backup
      ↓
verified remote copy
      ↓
known retention policy
      ↓
documented restore path
```

The critical distinction is:

```text
backup created
      ≠
backup verified
      ≠
backup restorable
```

A production backup program should work toward all three.

---

**Repository:** `<GITHUB_ORG>/<GITHUB_REPO>`

**Backup storage:** S3-compatible object storage

**Backup scheduling:** host-level systemd timers

**Backup execution:** ephemeral Docker backup runner using the immutable ERPNext image

**Last updated:** September 17, 2026
