# Kasten K10 Backup/Restore Demo

[![Kasten K10 Demo](https://github.com/YOUR_USERNAME/kasten-lab/actions/workflows/kasten-demo.yaml/badge.svg)](https://github.com/YOUR_USERNAME/kasten-lab/actions/workflows/kasten-demo.yaml)

A comprehensive demonstration of **Veeam Kasten K10** backup and restore capabilities on Kubernetes, implemented as an automated CI/CD pipeline with SDET-style verification tests.

## 🎯 Overview

This project demonstrates:

1. **Infrastructure Setup**: Automated Kind cluster creation with CSI driver and snapshot controller
2. **Kasten K10 Installation**: Helm-based deployment with proper configuration
3. **Application Deployment**: PostgreSQL StatefulSet with persistent storage
4. **Backup Operations**: Policy-based backup with RestorePoint creation
5. **Disaster Simulation**: Complete application destruction
6. **Restore Operations**: Full application recovery from backup
7. **Data Integrity Verification**: Checksum-based validation of restored data

## 📁 Project Structure

```
kasten-lab/
├── .github/workflows/
│   └── kasten-demo.yaml       # GitHub Actions CI pipeline
├── scripts/
│   ├── setup/                 # Infrastructure setup scripts
│   │   ├── install-kind.sh
│   │   ├── install-snapshot-controller.sh
│   │   ├── install-csi-driver.sh
│   │   └── install-kasten.sh
│   ├── deploy/                # Application deployment scripts
│   │   ├── deploy-postgres.sh
│   │   └── seed-data.sh
│   ├── backup/                # Backup operation scripts
│   │   ├── create-policy.sh
│   │   └── trigger-backup.sh
│   └── restore/               # Restore operation scripts
│       ├── destroy-app.sh
│       └── restore-app.sh
├── tests/                     # Python test suite
│   ├── conftest.py
│   ├── test_01_cluster_health.py
│   ├── test_02_kasten_health.py
│   ├── test_03_app_deployment.py
│   ├── test_04_backup_verification.py
│   ├── test_05_restore_verification.py
│   └── utils/
│       ├── k8s_client.py
│       └── kasten_client.py
├── manifests/                 # Kubernetes manifests
│   ├── kind-config.yaml
│   ├── postgres.yaml
│   └── k10-clone-snapshotclass.yaml
├── csi-driver-host-path/      # CSI driver (submodule/copy)
├── requirements.txt           # Python dependencies
├── pytest.ini                 # Pytest configuration
└── README.md
```

## 🚀 Quick Start

### Prerequisites

- Docker
- kubectl
- Helm 3
- Python 3.9+
- Kind (Kubernetes in Docker)

### Local Execution

1. **Clone the repository**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/kasten-lab.git
   cd kasten-lab
   ```

2. **Setup the cluster**:
   ```bash
   ./scripts/setup/install-kind.sh
   ./scripts/setup/install-snapshot-controller.sh
   ./scripts/setup/install-csi-driver.sh
   ./scripts/setup/install-kasten.sh
   ```

3. **Deploy the application**:
   ```bash
   ./scripts/deploy/deploy-postgres.sh
   ./scripts/deploy/seed-data.sh
   ```

4. **Create and trigger backup**:
   ```bash
   ./scripts/backup/create-policy.sh
   ./scripts/backup/trigger-backup.sh
   ```

5. **Simulate disaster and restore**:
   ```bash
   ./scripts/restore/destroy-app.sh
   ./scripts/restore/restore-app.sh
   ```

6. **Run verification tests**:
   ```bash
   pip install -r requirements.txt
   pytest tests/ -v
   ```

### GitHub Actions

The pipeline runs automatically on:
- Push to `main` branch
- Pull requests to `main`
- Manual trigger via `workflow_dispatch`

## 🧪 Test Suite

The test suite follows SDET best practices with comprehensive verification:

| Test Module | Purpose |
|-------------|---------|
| `test_01_cluster_health.py` | Verify cluster, CSI driver, snapshot controller |
| `test_02_kasten_health.py` | Verify K10 installation, pods, CRDs |
| `test_03_app_deployment.py` | Verify PostgreSQL deployment, data seeding |
| `test_04_backup_verification.py` | Verify backup policy, execution, RestorePoints |
| `test_05_restore_verification.py` | Verify restore, data integrity, checksums |

### Running Tests

```bash
# Run all tests
pytest tests/ -v

# Run specific test module
pytest tests/test_05_restore_verification.py -v

# Run tests with specific marker
pytest tests/ -v -m integrity

# Generate HTML report
pytest tests/ -v --html=reports/test_report.html
```

## 📊 Data Integrity Verification

The project implements multi-layer data integrity verification:

1. **Record-Level Checksums**: Each database record has an MD5 checksum
2. **Aggregate Checksum**: Combined checksum of all records
3. **Record Count Verification**: Ensures no data loss
4. **Content Verification**: Validates actual data values

```sql
-- Checksum calculation
SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `K10_NAMESPACE` | `kasten-io` | Kasten K10 namespace |
| `APP_NAMESPACE` | `test-app` | Application namespace |
| `K10_VERSION` | (latest) | Specific K10 version |
| `KASTEN_READY_TIMEOUT` | `600` | K10 readiness timeout (seconds) |
| `BACKUP_TIMEOUT` | `600` | Backup completion timeout |
| `RESTORE_TIMEOUT` | `300` | Restore completion timeout |

### Customization

- Modify `manifests/kind-config.yaml` for cluster configuration
- Modify `manifests/postgres.yaml` for application configuration
- Adjust timeouts in `.github/workflows/kasten-demo.yaml`

## 📈 Pipeline Stages

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│   Setup     │──▶│   Install   │──▶│   Deploy    │
│   Cluster   │   │   Kasten    │   │   App       │
└─────────────┘   └─────────────┘   └─────────────┘
                                           │
                                           ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│   Verify    │◀──│   Restore   │◀──│   Destroy   │
│   Data      │   │   App       │   │   App       │
└─────────────┘   └─────────────┘   └─────────────┘
       │
       ▼
┌─────────────┐
│   Cleanup   │
└─────────────┘
```

## 🔗 Resources

- [Veeam Kasten Documentation](https://docs.kasten.io/)
- [Kind Documentation](https://kind.sigs.k8s.io/)
- [CSI Hostpath Driver](https://github.com/kubernetes-csi/csi-driver-host-path)
- [Kubernetes Snapshot Controller](https://github.com/kubernetes-csi/external-snapshotter)

## 📝 License

This project is for educational and demonstration purposes.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
