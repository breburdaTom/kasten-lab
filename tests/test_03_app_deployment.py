"""
Test Module: Application Deployment
===================================
Verifies that the PostgreSQL test application is properly deployed.
"""

import pytest
import subprocess
import logging

from tests.utils.k8s_client import K8sClient

logger = logging.getLogger(__name__)


@pytest.mark.app
class TestApplicationNamespace:
    """Test suite for verifying application namespace."""
    
    def test_app_namespace_exists(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify application namespace exists."""
        assert k8s_client.namespace_exists(app_namespace), \
            f"Namespace '{app_namespace}' should exist"
        
        logger.info(f"Namespace '{app_namespace}' exists")


@pytest.mark.app
class TestPostgresStatefulSet:
    """Test suite for verifying PostgreSQL StatefulSet."""
    
    STATEFULSET_NAME = "pg-database"
    
    def test_statefulset_exists(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify PostgreSQL StatefulSet exists."""
        assert k8s_client.statefulset_exists(
            self.STATEFULSET_NAME, 
            app_namespace
        ), f"StatefulSet '{self.STATEFULSET_NAME}' should exist"
        
        logger.info(f"StatefulSet '{self.STATEFULSET_NAME}' exists")
    
    def test_statefulset_ready(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str,
        wait_for_condition
    ):
        """Verify PostgreSQL StatefulSet is ready."""
        result = wait_for_condition(
            lambda: k8s_client.is_statefulset_ready(
                self.STATEFULSET_NAME, 
                app_namespace
            ),
            timeout=180,
            interval=10,
            description="PostgreSQL StatefulSet to be ready"
        )
        
        assert result, \
            f"StatefulSet '{self.STATEFULSET_NAME}' should be ready"
        
        logger.info(f"StatefulSet '{self.STATEFULSET_NAME}' is ready")
    
    def test_postgres_pod_running(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify PostgreSQL pod is running."""
        pod_name = f"{self.STATEFULSET_NAME}-0"
        
        assert k8s_client.is_pod_running(pod_name, app_namespace), \
            f"Pod '{pod_name}' should be running"
        
        logger.info(f"Pod '{pod_name}' is running")


@pytest.mark.app
class TestPostgresPVC:
    """Test suite for verifying PostgreSQL PersistentVolumeClaim."""
    
    def test_pvc_exists(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify PVC exists for PostgreSQL."""
        pvcs = k8s_client.get_pvcs(app_namespace)
        
        assert len(pvcs) > 0, \
            f"At least one PVC should exist in namespace '{app_namespace}'"
        
        pvc_names = [pvc.metadata.name for pvc in pvcs]
        logger.info(f"PVCs found: {pvc_names}")
    
    def test_pvc_bound(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify PVC is bound."""
        pvcs = k8s_client.get_pvcs(app_namespace)
        
        for pvc in pvcs:
            assert pvc.status.phase == "Bound", \
                f"PVC '{pvc.metadata.name}' should be Bound, " \
                f"but is {pvc.status.phase}"
            
            logger.info(f"PVC '{pvc.metadata.name}' is Bound")
    
    def test_pvc_uses_correct_storage_class(
        self, 
        k8s_client: K8sClient, 
        app_namespace: str
    ):
        """Verify PVC uses the CSI storage class."""
        pvcs = k8s_client.get_pvcs(app_namespace)
        
        for pvc in pvcs:
            storage_class = pvc.spec.storage_class_name
            assert storage_class == "csi-hostpath-sc", \
                f"PVC should use 'csi-hostpath-sc', but uses '{storage_class}'"
            
            logger.info(
                f"PVC '{pvc.metadata.name}' uses storage class '{storage_class}'"
            )


@pytest.mark.app
class TestPostgresConnectivity:
    """Test suite for verifying PostgreSQL connectivity."""
    
    def test_postgres_accepting_connections(self, app_namespace: str):
        """Verify PostgreSQL is accepting connections."""
        try:
            result = subprocess.run(
                [
                    "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                    "pg_isready", "-U", "postgres"
                ],
                capture_output=True,
                text=True,
                timeout=60
            )
        except subprocess.TimeoutExpired:
            pytest.fail("kubectl command timed out after 60 seconds")
        
        assert result.returncode == 0, \
            f"PostgreSQL should be accepting connections: {result.stderr}"
        assert "accepting connections" in result.stdout, \
            "pg_isready should report 'accepting connections'"
        
        logger.info("PostgreSQL is accepting connections")
    
    def test_postgres_can_execute_query(self, app_namespace: str):
        """Verify PostgreSQL can execute queries."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-c", "SELECT 1 as test;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"PostgreSQL query should succeed: {result.stderr}"
        
        logger.info("PostgreSQL can execute queries")


@pytest.mark.app
class TestSeededData:
    """Test suite for verifying seeded test data."""
    
    def test_testdb_exists(self, app_namespace: str):
        """Verify test database exists."""
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
            "Database 'testdb' should exist"
        
        logger.info("Database 'testdb' exists")
    
    def test_test_data_table_exists(self, app_namespace: str):
        """Verify test_data table exists."""
        result = subprocess.run(
            [
                "kubectl", "exec", "-n", app_namespace, "pg-database-0", "--",
                "psql", "-U", "postgres", "-d", "testdb", "-c",
                "SELECT COUNT(*) FROM test_data;"
            ],
            capture_output=True,
            text=True
        )
        
        assert result.returncode == 0, \
            f"Table query should succeed: {result.stderr}"
        
        logger.info("Table 'test_data' exists")
    
    def test_test_data_has_records(self, app_namespace: str):
        """Verify test_data table has records."""
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
        assert count > 0, "test_data table should have records"
        assert count == 10, f"Expected 10 records, found {count}"
        
        logger.info(f"test_data table has {count} records")
    
    def test_record_checksums_valid(self, app_namespace: str):
        """Verify all record checksums are valid."""
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
            f"Checksum validation query should succeed: {result.stderr}"
        
        invalid_count = int(result.stdout.strip())
        assert invalid_count == 0, \
            f"All checksums should be valid, found {invalid_count} invalid"
        
        logger.info("All record checksums are valid")
