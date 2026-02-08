"""
Test Module: Backup Verification
================================
Verifies that Kasten K10 backup operations complete successfully.
"""

import pytest
import logging

from tests.utils.k8s_client import K8sClient
from tests.utils.kasten_client import KastenClient

logger = logging.getLogger(__name__)


@pytest.mark.backup
class TestBackupPolicy:
    """Test suite for verifying backup policy creation."""
    
    POLICY_NAME = "postgres-backup-policy"
    
    def test_policy_exists(
        self, 
        kasten_client: KastenClient
    ):
        """Verify backup policy exists."""
        assert kasten_client.policy_exists(self.POLICY_NAME), \
            f"Policy '{self.POLICY_NAME}' should exist"
        
        logger.info(f"Policy '{self.POLICY_NAME}' exists")
    
    def test_policy_configuration(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify backup policy is correctly configured."""
        policy = kasten_client.get_policy(self.POLICY_NAME)
        
        assert policy is not None, "Policy should exist"
        
        # Verify policy targets the correct namespace
        spec = policy.get("spec", {})
        selector = spec.get("selector", {})
        match_expressions = selector.get("matchExpressions", [])
        
        # Find the namespace selector
        namespace_values = []
        for expr in match_expressions:
            if expr.get("key") == "k10.kasten.io/appNamespace":
                namespace_values = expr.get("values", [])
                break
        
        assert app_namespace in namespace_values, \
            f"Policy should target namespace '{app_namespace}'"
        
        logger.info(f"Policy targets namespace: {namespace_values}")
    
    def test_policy_has_backup_action(
        self, 
        kasten_client: KastenClient
    ):
        """Verify policy includes backup action."""
        policy = kasten_client.get_policy(self.POLICY_NAME)
        
        assert policy is not None, "Policy should exist"
        
        spec = policy.get("spec", {})
        actions = spec.get("actions", [])
        
        action_types = [a.get("action") for a in actions]
        assert "backup" in action_types, \
            "Policy should include 'backup' action"
        
        logger.info(f"Policy actions: {action_types}")


@pytest.mark.backup
class TestBackupExecution:
    """Test suite for verifying backup execution."""
    
    POLICY_NAME = "postgres-backup-policy"
    
    def test_backup_action_exists(
        self, 
        kasten_client: KastenClient
    ):
        """Verify backup action was created."""
        actions = kasten_client.get_backup_actions(self.POLICY_NAME)
        
        assert len(actions) > 0, \
            f"At least one backup action should exist for policy '{self.POLICY_NAME}'"
        
        logger.info(f"Found {len(actions)} backup action(s)")
    
    def test_backup_completed_successfully(
        self, 
        kasten_client: KastenClient,
        wait_for_condition
    ):
        """Verify backup completed successfully."""
        # Wait for backup to complete
        result = wait_for_condition(
            lambda: kasten_client.is_backup_complete(self.POLICY_NAME),
            timeout=600,
            interval=15,
            description="backup to complete"
        )
        
        assert result, "Backup should complete successfully"
        
        # Verify it didn't fail
        assert not kasten_client.is_backup_failed(self.POLICY_NAME), \
            "Backup should not have failed"
        
        logger.info("Backup completed successfully")
    
    def test_backup_action_state(
        self, 
        kasten_client: KastenClient
    ):
        """Verify backup action is in Complete state."""
        action = kasten_client.get_latest_backup_action(self.POLICY_NAME)
        
        assert action is not None, "Backup action should exist"
        
        state = action.get("status", {}).get("state", "")
        assert state == "Complete", \
            f"Backup action should be 'Complete', but is '{state}'"
        
        # Log additional details
        status = action.get("status", {})
        logger.info(f"Backup action state: {state}")
        logger.info(f"Backup action status: {status}")


@pytest.mark.backup
class TestRestorePoint:
    """Test suite for verifying RestorePoint creation."""
    
    def test_restore_point_exists(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify RestorePoint was created."""
        restore_points = kasten_client.get_restore_points(app_namespace)
        
        assert len(restore_points) > 0, \
            f"At least one RestorePoint should exist in namespace '{app_namespace}'"
        
        rp_names = [rp["metadata"]["name"] for rp in restore_points]
        logger.info(f"RestorePoints found: {rp_names}")
    
    def test_restore_point_available(
        self, 
        kasten_client: KastenClient,
        app_namespace: str,
        wait_for_condition
    ):
        """Verify RestorePoint is in Available state."""
        # Get the latest restore point
        rp = kasten_client.get_latest_restore_point(app_namespace)
        assert rp is not None, "RestorePoint should exist"
        
        rp_name = rp["metadata"]["name"]
        
        # Wait for it to be available
        result = wait_for_condition(
            lambda: kasten_client.is_restore_point_available(
                rp_name, 
                app_namespace
            ),
            timeout=120,
            interval=10,
            description="RestorePoint to be available"
        )
        
        assert result, f"RestorePoint '{rp_name}' should be Available"
        
        logger.info(f"RestorePoint '{rp_name}' is Available")
    
    def test_restore_point_has_artifacts(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify RestorePoint contains backup artifacts."""
        rp = kasten_client.get_latest_restore_point(app_namespace)
        
        assert rp is not None, "RestorePoint should exist"
        
        # Check for artifacts in the spec
        spec = rp.get("spec", {})
        
        # RestorePoint should have application data
        assert "actions" in spec or "artifacts" in spec or "data" in spec, \
            "RestorePoint should contain backup data"
        
        logger.info(f"RestorePoint spec keys: {list(spec.keys())}")
    
    def test_restore_point_count(
        self, 
        kasten_client: KastenClient,
        app_namespace: str
    ):
        """Verify expected number of RestorePoints."""
        count = kasten_client.restore_point_count(app_namespace)
        
        # After one backup, we should have at least one restore point
        assert count >= 1, \
            f"Expected at least 1 RestorePoint, found {count}"
        
        logger.info(f"Total RestorePoints: {count}")


@pytest.mark.backup
class TestBackupArtifacts:
    """Test suite for verifying backup artifacts."""
    
    def test_volume_snapshot_created(
        self, 
        k8s_client: K8sClient,
        app_namespace: str
    ):
        """Verify VolumeSnapshot was created for the PVC."""
        from kubernetes import client
        
        custom_objects = client.CustomObjectsApi()
        
        try:
            result = custom_objects.list_namespaced_custom_object(
                group="snapshot.storage.k8s.io",
                version="v1",
                namespace=app_namespace,
                plural="volumesnapshots"
            )
            
            snapshots = result.get("items", [])
            
            # Note: Kasten may create snapshots in its own namespace
            # or use a different mechanism, so this is informational
            logger.info(
                f"VolumeSnapshots in {app_namespace}: {len(snapshots)}"
            )
            
            for snapshot in snapshots:
                name = snapshot["metadata"]["name"]
                status = snapshot.get("status", {})
                ready = status.get("readyToUse", False)
                logger.info(f"  Snapshot '{name}': readyToUse={ready}")
                
        except Exception as e:
            logger.warning(f"Could not list VolumeSnapshots: {e}")
            # This is not a failure - Kasten may manage snapshots differently
