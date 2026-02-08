# Kasten K10 Backup/Restore Demo

Automated demo of Veeam Kasten K10 backup and restore on Kubernetes. Runs as a GitHub Actions pipeline with pytest verification.

## What it does

1. Creates a Kind cluster with CSI driver and snapshot controller
2. Installs Kasten K10
3. Deploys PostgreSQL with test data
4. Creates a backup policy and triggers backup
5. Destroys the application (simulates disaster)
6. Restores from backup
7. Verifies data integrity

## Project structure

```
scripts/
├── lib/common.sh              # Shared functions (logging, wait helpers)
├── setup/                     # Cluster and K10 installation
├── deploy/                    # PostgreSQL deployment and data seeding
├── backup/                    # Policy creation and backup trigger
└── restore/                   # App destruction and restore

tests/
├── test_01_cluster_health.py
├── test_02_kasten_health.py
├── test_03_app_deployment.py
├── test_04_backup_verification.py
└── test_05_restore_verification.py

manifests/
├── kind-config.yaml
├── postgres.yaml
└── k10-clone-snapshotclass.yaml
```

## Running locally

```bash
# Setup
./scripts/setup/install-kind.sh
./scripts/setup/install-snapshot-controller.sh
./scripts/setup/install-csi-driver.sh
./scripts/setup/install-kasten.sh

# Deploy app
./scripts/deploy/deploy-postgres.sh
./scripts/deploy/seed-data.sh

# Backup
./scripts/backup/create-policy.sh
./scripts/backup/trigger-backup.sh

# Destroy and restore
./scripts/restore/destroy-app.sh
./scripts/restore/restore-app.sh

# Run tests
pip install -r requirements.txt
pytest tests/ -v
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `K10_NAMESPACE` | `kasten-io` | Kasten namespace |
| `APP_NAMESPACE` | `test-app` | Application namespace |
| `BACKUP_TIMEOUT` | `600` | Backup timeout (seconds) |
| `RESTORE_TIMEOUT` | `300` | Restore timeout (seconds) |

## Issues and fixes

Problems encountered during development:

**Snapshot data deleted on PVC removal**
- VolumeSnapshotClass had `deletionPolicy: Delete` by default
- Fixed by setting `Retain` policy during CSI driver setup

**RestoreAction stuck in Pending**
- Was creating RestoreAction in `kasten-io` namespace
- Must be created in the same namespace as `targetNamespace` (the app namespace)

**Kasten clone snapshot class**
- Kasten auto-creates `k10-clone-csi-hostpath-snapclass` with `Delete` policy
- Pre-create it with `Retain` policy in `install-csi-driver.sh`

**Log output polluting function return values**
- Functions using `echo` to return values had logs mixed in
- Redirect logs to stderr (`>&2`)

**VolumeSnapshotContents not ready**
- Backup completed but snapshots weren't ready yet
- Added wait loop for `readyToUse: true` status

**Whitespace in kubectl output**
- Record counts had trailing whitespace breaking comparisons
- Clean with `tr -d '[:space:]'`

## Resources

- [Kasten docs](https://docs.kasten.io/)
- [Kind](https://kind.sigs.k8s.io/)
- [CSI Hostpath Driver](https://github.com/kubernetes-csi/csi-driver-host-path)
