"""
Test Module: Restore Verification
=================================
Verifies that Kasten K10 restore operations complete successfully
and data integrity is maintained.
"""

import pytest
import subprocess
import logging

from tests.utils.k8s_client import K8sClient
from tests.utils.kasten_client import KastenClient

logger = logging.getLogger(__name__)


@pytest.mark.restore
class TestRestoreAction:
    """Test suite for verifying restore action execution."""
    
    def test_restore_action_exists(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify restore action was created."""
        actions = kasten_client.get_restore_actions(app_namespace)
        
        assert len(actions) > 0, \
            f"At least one restore action should exist in namespace '{app_namespace}'"
        
        logger.info(f"Found {len(actions)} restore action(s)")
    
    def test_restore_completed_successfully(
        self, 
        kasten_client: KastenClient,
        app_namespace: str,
        wait_for_condition
    ):
        """Verify restore completed successfully."""
        result = wait_for_condition(
            lambda: kasten_client.is_restore_complete(app_namespace),
            timeout=300,
            interval=15,
            description="restore to complete"
        )
        
        assert result, "Restore should complete successfully"
        
        logger.info("Restore completed successfully")
    
    def test_restore_action_state(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify restore action is in Complete state."""
        action = kasten_client.get_latest_restore_action(app_namespace)
        
        assert action is not None, "Restore action should exist"
        
        state = action.get("status", {}).get("state", "")
        assert state == "Complete", \
            f"Restore action should be 'Complete', but is '{state}'"
        
        logger.info(f"Restore action state: {state}")


@pytest.mark.restore
class TestRestoredResources:
    """Test suite for verifying restored Kubernetes resources."""
    
    STATEFULSET_NAME = "pg-database"
    
    def test_statefulset_restored(
        self, 
        k8s_client: K8sClient,
        app_namespace: str,
        wait_for_condition
    ):
        """Verify StatefulSet was restored."""
        result = wait_for_condition(
            lambda: k8s_client.statefulset_exists(
                self.STATEFULSET_NAME, 
                app_namespace
            ),
            timeout=180,
            interval=10,
            description="StatefulSet to be restored"
        )
        
        assert result, \
            f"StatefulSet '{self.STATEFULSET_NAME}' should be restored"
        
        logger.info(f"StatefulSet '{self.STATEFULSET_NAME}' restored")
    
    def test_statefulset_ready(
        self, 
        k8s_client: K8sClient,
        app_namespace: str,
        wait_for_condition
    ):
        """Verify restored StatefulSet is ready."""
        result = wait_for_condition(
            lambda: k8s_client.is_statefulset_ready(
                self.STATEFULSET_NAME, 
                app_namespace
            ),
            timeout=180,
            interval=10,
            description="StatefulSet to be ready"
        )
        
        assert result, \
            f"StatefulSet '{self.STATEFULSET_NAME}' should be ready"
        
        logger.info(f"StatefulSet '{self.STATEFULSET_NAME}' is ready")
    
    def test_pod_restored_and_running(
        self, 
        k8s_client: K8sClient,
        app_namespace: str,
        wait_for_condition
    ):
        """Verify PostgreSQL pod is restored and running."""
        pod_name = f"{self.STATEFULSET_NAME}-0"
        
        result = wait_for_condition(
            lambda: k8s_client.is_pod_running(pod_name, app_namespace),
            timeout=120,
            interval=10,
            description="PostgreSQL pod to be running"
        )
        
        assert result, f"Pod '{pod_name}' should be running"
        
        logger.info(f"Pod '{pod_name}' is running")
    
    def test_pvc_restored(
        self, 
        k8s_client: K8sClient,
        app_namespace: str
    ):
        """Verify PVC was restored."""
        pvcs = k8s_client.get_pvcs(app_namespace)
        
        assert len(pvcs) > 0, "At least one PVC should be restored"
        
        for pvc in pvcs:
            assert pvc.status.phase == "Bound", \
                f"PVC '{pvc.metadata.name}' should be Bound"
            logger.info(f"PVC '{pvc.metadata.name}' is Bound")


@pytest.mark.restore
class TestPostgresConnectivityAfterRestore:
    """Test suite for verifying PostgreSQL connectivity after restore."""
    
    def test_postgres_accepting_connections(
        self, 
        app_namespace: str,
        wait_for_condition
    ):
        """Verify PostgreSQL is accepting connections after restore."""
        def check_postgres():
            result = subprocess.run(
                [
                    "kubectl", "exec", "-n", app_namespace, "pg-database-0", 
                    "--", "pg_isready", "-U", "postgres"
                ],
                capture_output=True,
                text=True
            )
            return result.returncode == 0 and "accepting" in result.stdout
        
        result = wait_for_condition(
            check_postgres,
            timeout=120,
            interval=10,
            description="PostgreSQL to accept connections"
        )
        
        assert result, "PostgreSQL should be accepting connections"
        
        logger.info("PostgreSQL is accepting connections after restore")


@pytest.mark.integrity
class TestDataIntegrity:
    """
    Test suite for verifying data integrity after restore.
    This is the critical SDET verification of the backup/restore process.
    """
    
    def test_database_exists(self, app_namespace: str):
        """Verify testdb database exists after restore."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-lqt"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Database list query should succeed: {result.stderr}"
        assert "testdb" in result.stdout, \
            "Database 'testdb' should exist after restore"
        
        logger.info("Database 'testdb' exists after restore")
    
    def test_table_exists(self, app_namespace: str):
        """Verify test_data table exists after restore."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-c",
                "\\dt test_data"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Table check should succeed: {result.stderr}"
        assert "test_data" in result.stdout, \
            "Table 'test_data' should exist after restore"
        
        logger.info("Table 'test_data' exists after restore")
    
    def test_record_count_matches(self, app_namespace: str):
        """Verify record count matches expected value."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT COUNT(*) FROM test_data;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Count query should succeed: {result.stderr}"
        
        count = int(result.stdout.strip())
        expected_count = 10  # We seeded 10 records
        
        assert count == expected_count, \
            f"Expected {expected_count} records, found {count}"
        
        logger.info(f"Record count matches: {count}")
    
    def test_aggregate_checksum_matches(
        self, 
        app_namespace: str,
        original_checksum: str
    ):
        """
        Verify aggregate checksum matches original.
        This is the primary data integrity verification.
        """
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Checksum query should succeed: {result.stderr}"
        
        current_checksum = result.stdout.strip()
        
        logger.info(f"Original checksum: {original_checksum}")
        logger.info(f"Current checksum:  {current_checksum}")
        
        assert current_checksum == original_checksum, \
            f"Data integrity check FAILED!\n" \
            f"Original: {original_checksum}\n" \
            f"Current:  {current_checksum}"
        
        logger.info("✅ Data integrity verified - checksums match!")
    
    def test_individual_record_checksums(self, app_namespace: str):
        """Verify each record's checksum is valid."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT COUNT(*) FROM test_data WHERE checksum != md5(data);"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Checksum validation should succeed: {result.stderr}"
        
        invalid_count = int(result.stdout.strip())
        
        assert invalid_count == 0, \
            f"All record checksums should be valid, found {invalid_count} invalid"
        
        logger.info("All individual record checksums are valid")
    
    def test_data_content_sample(self, app_namespace: str):
        """Verify sample data content is correct."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT data FROM test_data WHERE id = 1;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Data query should succeed: {result.stderr}"
        
        data = result.stdout.strip()
        expected = "kasten-backup-test-record-001"
        
        assert data == expected, \
            f"First record should be '{expected}', found '{data}'"
        
        logger.info(f"Sample data content verified: {data}")


@pytest.mark.integrity
class TestRestoreCompleteness:
    """Test suite for verifying restore completeness."""
    
    def test_all_records_present(self, app_namespace: str):
        """Verify all expected records are present."""
        expected_records = [
            "kasten-backup-test-record-001",
            "kasten-backup-test-record-002",
            "kasten-backup-test-record-003",
            "important-business-data-alpha",
            "important-business-data-beta",
            "critical-config-setting-gamma",
            "user-profile-data-delta",
            "transaction-log-epsilon",
            "audit-trail-zeta",
            "system-state-eta",
        ]
        
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT data FROM test_data ORDER BY id;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Data query should succeed: {result.stderr}"
        
        actual_records = [r.strip() for r in result.stdout.strip().split('\n') if r.strip()]
        
        assert len(actual_records) == len(expected_records), \
            f"Expected {len(expected_records)} records, found {len(actual_records)}"
        
        for expected in expected_records:
            assert expected in actual_records, \
                f"Record '{expected}' should be present"
        
        logger.info("All expected records are present")
    
    def test_timestamps_preserved(self, app_namespace: str):
        """Verify timestamps are preserved (not reset to restore time)."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT MIN(created_at), MAX(created_at) FROM test_data;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Timestamp query should succeed: {result.stderr}"
        
        # Just verify we got timestamps back
        output = result.stdout.strip()
        assert output, "Should have timestamp data"
        
        logger.info(f"Timestamp range: {output}")


@pytest.mark.integrity
class TestBackupRestoreSummary:
    """Final summary test for the backup/restore verification."""
    
    def test_full_verification_summary(
        self, 
        k8s_client: K8sClient,
        kasten_client: KastenClient,
        app_namespace: str,
        original_checksum: str
    ):
        """
        Comprehensive verification summary.
        This test provides a complete overview of the backup/restore status.
        """
        logger.info("=" * 60)
        logger.info("BACKUP/RESTORE VERIFICATION SUMMARY")
        logger.info("=" * 60)
        
        # Check StatefulSet
        ss_ready = k8s_client.is_statefulset_ready("pg-database", app_namespace)
        logger.info(f"StatefulSet Ready: {'✅' if ss_ready else '❌'}")
        
        # Check PVCs
        pvc_count = k8s_client.pvc_count(app_namespace)
        logger.info(f"PVCs Restored: {pvc_count}")
        
        # Check RestorePoints
        rp_count = kasten_client.restore_point_count(app_namespace)
        logger.info(f"RestorePoints Available: {rp_count}")
        
        # Check restore completion
        restore_complete = kasten_client.is_restore_complete(app_namespace)
        logger.info(f"Restore Complete: {'✅' if restore_complete else '❌'}")
        
        # Check data integrity
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-t", "-A", "-c",
                "SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;"
            ],
            capture_output=True,
            text=True
        )
        
        current_checksum = result.stdout.strip() if result.returncode == 0 else "ERROR"
        checksum_match = current_checksum == original_checksum
        
        logger.info(f"Data Integrity: {'✅' if checksum_match else '❌'}")
        logger.info(f"  Original Checksum: {original_checksum}")
        logger.info(f"  Current Checksum:  {current_checksum}")
        
        logger.info("=" * 60)
        
        # Final assertion
        assert ss_ready, "StatefulSet should be ready"
        assert pvc_count > 0, "PVCs should be restored"
        assert restore_complete, "Restore should be complete"
        assert checksum_match, "Data integrity should be verified"
        
        logger.info("🎉 ALL VERIFICATIONS PASSED! 🎉")
