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

# Type alias for wait_for_condition fixture
WaitFunc = Callable[[Callable[[], bool], int, int, str], bool]


# =============================================================================
# Session-Scoped Fixtures (created once per test session)
# =============================================================================

@pytest.fixture(scope="session")
def k8s_client() -> K8sClient:
    """Provide a Kubernetes client instance."""
    logger.info("Initializing Kubernetes client")
    return K8sClient()


@pytest.fixture(scope="session")
def kasten_client() -> KastenClient:
    """Provide a Kasten K10 client instance."""
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
def wait_for_condition(k8s_client: K8sClient) -> WaitFunc:
    """Factory fixture for waiting on conditions."""
    return lambda cond, timeout=300, interval=10, desc="condition": \
        k8s_client.wait_for_condition(cond, timeout, interval, desc)


@pytest.fixture
def original_checksum() -> str:
    """Load the original data checksum from file for integrity verification."""
    if not os.path.exists(CHECKSUM_FILE):
        pytest.skip(f"Checksum file not found: {CHECKSUM_FILE}")
    
    with open(CHECKSUM_FILE, 'r') as f:
        checksum = f.read().strip()
    
    logger.info(f"Loaded original checksum: {checksum}")
    return checksum


# =============================================================================
# Pytest Hooks
# =============================================================================

def pytest_configure(config):
    """Configure pytest with custom markers."""
    markers = [
        "cluster: Cluster health and infrastructure tests",
        "kasten: Kasten K10 installation and health tests",
        "app: Application deployment tests",
        "backup: Backup operation tests",
        "restore: Restore operation tests",
        "integrity: Data integrity verification tests",
        "slow: Tests that take longer to execute",
    ]
    for marker in markers:
        config.addinivalue_line("markers", marker)


def pytest_collection_modifyitems(config, items):
    """Modify test collection to add markers based on test names."""
    marker_patterns = {
        "cluster": pytest.mark.cluster,
        "kasten": pytest.mark.kasten,
        "app": pytest.mark.app,
        "deployment": pytest.mark.app,
        "backup": pytest.mark.backup,
        "restore": pytest.mark.restore,
        "integrity": pytest.mark.integrity,
        "checksum": pytest.mark.integrity,
    }
    for item in items:
        for pattern, marker in marker_patterns.items():
            if pattern in item.nodeid:
                item.add_marker(marker)


# =============================================================================
# Test Report Helpers
# =============================================================================

@pytest.fixture(autouse=True)
def test_timing(request):
    """Log test execution time."""
    start_time = time.time()
    yield
    logger.info(f"Test '{request.node.name}' completed in {time.time() - start_time:.2f}s")


@pytest.fixture
def log_k8s_state(k8s_client: K8sClient, app_namespace: str) -> Callable[[], None]:
    """Helper fixture to log Kubernetes state for debugging."""
    def _log_state():
        logger.info("=== Current Kubernetes State ===")
        for pod in k8s_client.get_pods(app_namespace):
            logger.info(f"  Pod: {pod.metadata.name}: {pod.status.phase}")
        for pvc in k8s_client.get_pvcs(app_namespace):
            logger.info(f"  PVC: {pvc.metadata.name}: {pvc.status.phase}")
        logger.info("================================")
    return _log_state
