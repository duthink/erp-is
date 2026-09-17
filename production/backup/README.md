# ERPNext Backup

This directory contains the backup runner and systemd scheduling configuration for the ERPNext deployment.

## Architecture

systemd timer -> backup/run-backup.sh -> docker compose run --rm backup-runner -> ERPNext immutable custom image -> bench backup -> DigitalOcean Spaces

Backups do not depend on the ERPNext scheduler container.

## Backup modes

Database-only:
`./backup/run-backup.sh 0`

Full backup including public and private files:
`./backup/run-backup.sh 1`

## Private configuration

Each installation keeps private storage configuration in `backup/backup.env`. Never commit this file. Protect it with `chmod 600 backup/backup.env`.

Required settings include:
- S3_ENDPOINT_URL
- S3_BUCKET_NAME
- S3_REGION
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- ENV_PREFIX
- BACKUP_SITES

Backups are stored as `s3://<bucket>/<environment>/<site>/<YYYY-MM-DD>/`.

## Systemd

Templates:
- erpnext-backup-db@.service
- erpnext-backup-db@.timer
- erpnext-backup-full@.service
- erpnext-backup-full@.timer

Each server has a private `/etc/erpnext-backup/<instance>.env` containing `ERP_ROOT`.

Example production value:
`ERP_ROOT=/srv/erp-clients/indiansolenoids/erp-is/production`

Enable production:
`sudo systemctl enable --now erpnext-backup-db@production.timer`
`sudo systemctl enable --now erpnext-backup-full@production.timer`

Check:
`systemctl list-timers --all | grep erpnext-backup`

## Logs

`sudo journalctl -u erpnext-backup-db@production.service -n 100 --no-pager`
`sudo journalctl -u erpnext-backup-full@production.service -n 100 --no-pager`

A successful oneshot service normally becomes inactive (dead) after completion. Check the journal for `Successful backups: 1` and `Failed backups: 0`.

## Verification

List backup objects with the AWS CLI or from the backup runner.

Validate database backups with `gzip -t`.
Validate public/private file archives with `tar -tzf`.
Validate site configuration with `python3 -m json.tool`.

## Retention

`BACKUP_RETENTION_DAYS` controls local retention.
`S3_BACKUP_RETENTION_DAYS` controls remote retention.

S3 cleanup is time-bounded so storage cleanup cannot indefinitely block a backup run.

## Operational rules

Never commit backup credentials.
Do not depend on the ERPNext scheduler for backups.
Do not manually edit generated `production.yaml`.
Deploy backup-code changes through Git using local -> staging -> UAT -> main -> production.
Keep staging and production private backup configuration separate.

## Recovery

DigitalOcean Spaces contains the remote backup artifacts. Use the appropriate Frappe/ERPNext restore procedure for the target release and site.
