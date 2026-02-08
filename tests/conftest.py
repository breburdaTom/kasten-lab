"""
Pytest Configuration and Shared Fixtures
=========================================
This module provides shared fixtures for all test modules.
"""

import os
import time
import logging
import pytest
from typing import Callable

from tests.utils.k8s_client import K8sClient
from tests.utils.kasten_client import KastenClient

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)8s] %(name)s - %(message)s'
)
logger = logging.getLogger(__name__)


# =============================================================================
# Configuration Constants
# =============================================================================

K10_NAMESPACE = os.environ.get("K10_NAMESPACE", "kasten-io")
APP_NAMESPACE = os.environ.get("APP_NAMESPACE", "test-app")
CHECKSUM_FILE = os.environ.get("CHECKSUM_FILE", "/tmp/original_checksum.txt")


# =============================================================================
# Session-Scoped Fixtures (created once per test session)
# =============================================================================

@pytest.fixture(scope="session")
def k8s_client() -> K8sClient:
    """
    Provide a Kubernetes client instance.
    Session-scoped to reuse the same client across all tests.
    """
    logger.info("Initializing Kubernetes client")
    return K8sClient()


@pytest.fixture(scope="session")
def kasten_client() -> KastenClient:
    """
    Provide a Kasten K10 client instance.
    Session-scoped to reuse the same client across all tests.
    """
    logger.info("Initializing Kasten client")
    return KastenClient(k10_namespace=K10_NAMESPACE)


@pytest.fixture(scope="session")
def k10_namespace() -> str:
    """Provide the Kasten K10 namespace."""
    return K10_NAMESPACE


@pytest.fixture(scope="session")
def app_namespace() -> str:
    """Provide the test application namespace."""
    return APP_NAMESPACE


# =============================================================================
# Function-Scoped Fixtures
# =============================================================================

@pytest.fixture
def wait_for_condition(k8s_client: K8sClient):
    """
    Factory fixture for waiting on conditions.
    
    Usage:
        def test_something(wait_for_condition):
            wait_for_condition(
                lambda: some_condition(),
                timeout=300,
                description="something to happen"
            )
    """
    def _wait(
        condition_func: Callable[[], bool],
        timeout: int = 300,
        interval: int = 10,
        description: str = "condition"
    ) -> bool:
        return k8s_client.wait_for_condition(
            condition_func=condition_func,
            timeout=timeout,
            interval=interval,
            description=description
        )
    return _wait


@pytest.fixture
def original_checksum() -> str:
    """
    Load the original data checksum from file.
    This is used to verify data integrity after restore.
    """
    checksum_file = CHECKSUM_FILE
    
    if not os.path.exists(checksum_file):
        pytest.skip(f"Checksum file not found: {checksum_file}")
    
    with open(checksum_file, 'r') as f:
        checksum = f.read().strip()
    
    logger.info(f"Loaded original checksum: {checksum}")
    return checksum


# =============================================================================
# Pytest Hooks
# =============================================================================

def pytest_configure(config):
    """Configure pytest with custom markers."""
    config.addinivalue_line(
        "markers", "cluster: Cluster health and infrastructure tests"
    )
    config.addinivalue_line(
        "markers", "kasten: Kasten K10 installation and health tests"
    )
    config.addinivalue_line(
        "markers", "app: Application deployment tests"
    )
    config.addinivalue_line(
        "markers", "backup: Backup operation tests"
    )
    config.addinivalue_line(
        "markers", "restore: Restore operation tests"
    )
    config.addinivalue_line(
        "markers", "integrity: Data integrity verification tests"
    )
    config.addinivalue_line(
        "markers", "slow: Tests that take longer to execute"
    )


def pytest_collection_modifyitems(config, items):
    """Modify test collection to add markers based on test names."""
    for item in items:
        # Add markers based on test file names
        if "cluster" in item.nodeid:
            item.add_marker(pytest.mark.cluster)
        if "kasten" in item.nodeid:
            item.add_marker(pytest.mark.kasten)
        if "app" in item.nodeid or "deployment" in item.nodeid:
            item.add_marker(pytest.mark.app)
        if "backup" in item.nodeid:
            item.add_marker(pytest.mark.backup)
        if "restore" in item.nodeid:
            item.add_marker(pytest.mark.restore)
        if "integrity" in item.nodeid or "checksum" in item.nodeid:
            item.add_marker(pytest.mark.integrity)


# =============================================================================
# Test Report Helpers
# =============================================================================

@pytest.fixture(autouse=True)
def test_timing(request):
    """Log test execution time."""
    start_time = time.time()
    yield
    elapsed = time.time() - start_time
    logger.info(f"Test '{request.node.name}' completed in {elapsed:.2f}s")


@pytest.fixture
def log_k8s_state(k8s_client: K8sClient, app_namespace: str):
    """
    Helper fixture to log Kubernetes state for debugging.
    
    Usage:
        def test_something(log_k8s_state):
            log_k8s_state()  # Logs current state
    """
    def _log_state():
        logger.info("=== Current Kubernetes State ===")
        
        # Pods in app namespace
        pods = k8s_client.get_pods(app_namespace)
        logger.info(f"Pods in {app_namespace}:")
        for pod in pods:
            logger.info(f"  - {pod.metadata.name}: {pod.status.phase}")
        
        # PVCs in app namespace
        pvcs = k8s_client.get_pvcs(app_namespace)
        logger.info(f"PVCs in {app_namespace}:")
        for pvc in pvcs:
            logger.info(f"  - {pvc.metadata.name}: {pvc.status.phase}")
        
        logger.info("================================")
    
    return _log_state
