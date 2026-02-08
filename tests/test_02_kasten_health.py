"""
Test Module: Kasten K10 Health
==============================
Verifies that Kasten K10 is properly installed and healthy.
"""

import pytest
import logging

from tests.utils.k8s_client import K8sClient
from tests.utils.kasten_client import KastenClient

logger = logging.getLogger(__name__)


@pytest.mark.kasten
class TestKastenNamespace:
    """Test suite for verifying Kasten namespace setup."""
    
    def test_kasten_namespace_exists(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify Kasten namespace exists."""
        assert k8s_client.namespace_exists(k10_namespace), \
            f"Namespace '{k10_namespace}' should exist"
        
        logger.info(f"Namespace '{k10_namespace}' exists")


@pytest.mark.kasten
class TestKastenPods:
    """Test suite for verifying Kasten K10 pods."""
    
    def test_kasten_pods_exist(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify Kasten pods exist in the namespace."""
        pods = k8s_client.get_pods(k10_namespace)
        
        assert len(pods) > 0, \
            f"Kasten pods should exist in namespace '{k10_namespace}'"
        
        logger.info(f"Found {len(pods)} Kasten pod(s)")
    
    def test_kasten_pods_running(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str,
        wait_for_condition
    ):
        """Verify all Kasten pods are running and ready."""
        # Wait for pods to be ready (K10 can take a while to start)
        result = wait_for_condition(
            lambda: k8s_client.are_all_pods_ready(k10_namespace),
            timeout=600,
            interval=15,
            description="all Kasten pods to be ready"
        )
        
        assert result, "All Kasten pods should be running and ready"
        
        # Log pod status
        pods = k8s_client.get_pods(k10_namespace)
        for pod in pods:
            logger.info(f"Pod {pod.metadata.name}: {pod.status.phase}")
    
    def test_gateway_pod_ready(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify the gateway pod is ready (critical for dashboard access)."""
        # K10 gateway deployment uses component=gateway label
        pods = k8s_client.get_pods(k10_namespace, label_selector="component=gateway")
        
        assert len(pods) > 0, "Gateway pod should exist"
        
        gateway_pod = pods[0]
        assert gateway_pod.status.phase == "Running", \
            f"Gateway pod should be Running, but is {gateway_pod.status.phase}"
        
        # Check container readiness
        if gateway_pod.status.container_statuses:
            for cs in gateway_pod.status.container_statuses:
                assert cs.ready, f"Gateway container {cs.name} should be ready"
        
        logger.info("Gateway pod is ready")


@pytest.mark.kasten
class TestKastenDeployments:
    """Test suite for verifying Kasten K10 deployments."""
    
    # Core K10 deployments that should always exist
    REQUIRED_DEPLOYMENTS = [
        "aggregatedapis-svc",
        "auth-svc",
        "catalog-svc",
        "controllermanager-svc",
        "crypto-svc",
        "dashboardbff-svc",
        "executor-svc",
        "frontend-svc",
        "gateway",
        "jobs-svc",
        "kanister-svc",
        "logging-svc",
        "metering-svc",
        "state-svc",
    ]
    
    def test_core_deployments_exist(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify core K10 deployments exist."""
        deployment_names = k8s_client.get_deployment_names(k10_namespace)
        
        logger.info(f"Found deployments: {deployment_names}")
        
        missing = []
        for required in self.REQUIRED_DEPLOYMENTS:
            if required not in deployment_names:
                missing.append(required)
        
        assert len(missing) == 0, \
            f"Missing required deployments: {missing}"
        
        logger.info("All required deployments exist")
    
    def test_deployments_available(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify K10 deployments are available."""
        unavailable = []
        
        for deployment_name in self.REQUIRED_DEPLOYMENTS:
            if not k8s_client.is_deployment_available(
                deployment_name, 
                k10_namespace
            ):
                unavailable.append(deployment_name)
        
        if unavailable:
            logger.warning(f"Unavailable deployments: {unavailable}")
        
        # Allow some deployments to be unavailable during startup
        assert len(unavailable) <= 2, \
            f"Too many unavailable deployments: {unavailable}"


@pytest.mark.kasten
class TestKastenCRDs:
    """Test suite for verifying Kasten K10 CRDs."""
    
    # Core CRD patterns that are always installed with K10
    REQUIRED_CRD_PATTERNS = [
        "policies.config.kio.kasten.io",
        "profiles.config.kio.kasten.io",
    ]
    
    def test_kasten_crds_installed(self, k8s_client: K8sClient):
        """Verify core Kasten CRDs are installed."""
        existing_crds = k8s_client.get_crds()
        kasten_crds = [crd for crd in existing_crds if "kasten.io" in crd]
        
        logger.info(f"Found {len(kasten_crds)} Kasten CRDs: {kasten_crds}")
        
        missing = []
        for required_crd in self.REQUIRED_CRD_PATTERNS:
            if required_crd not in kasten_crds:
                missing.append(required_crd)
        
        assert len(missing) == 0, \
            f"Missing required Kasten CRDs: {missing}"
        
        logger.info("All required Kasten CRDs are installed")
    
    def test_kasten_crds_count(self, k8s_client: K8sClient):
        """Verify expected number of Kasten CRDs."""
        existing_crds = k8s_client.get_crds()
        kasten_crds = [crd for crd in existing_crds if "kasten.io" in crd]
        
        logger.info(f"Found {len(kasten_crds)} Kasten CRDs")
        
        # K10 typically installs 15+ CRDs
        assert len(kasten_crds) >= 10, \
            f"Expected at least 10 Kasten CRDs, found {len(kasten_crds)}"


@pytest.mark.kasten
class TestKastenServices:
    """Test suite for verifying Kasten K10 services."""
    
    def test_gateway_service_exists(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify gateway service exists for dashboard access."""
        from kubernetes import client
        
        core_v1 = client.CoreV1Api()
        
        try:
            service = core_v1.read_namespaced_service("gateway", k10_namespace)
            assert service is not None, "Gateway service should exist"
            
            logger.info(f"Gateway service type: {service.spec.type}")
            logger.info(f"Gateway service ports: {service.spec.ports}")
            
        except Exception as e:
            pytest.fail(f"Gateway service not found: {e}")
    
    def test_k10_services_count(
        self, 
        k8s_client: K8sClient, 
        k10_namespace: str
    ):
        """Verify expected number of K10 services."""
        from kubernetes import client
        
        core_v1 = client.CoreV1Api()
        services = core_v1.list_namespaced_service(k10_namespace)
        
        logger.info(f"Found {len(services.items)} services in {k10_namespace}")
        
        # K10 typically has 15+ services
        assert len(services.items) >= 10, \
            f"Expected at least 10 services, found {len(services.items)}"


@pytest.mark.kasten
class TestKastenVolumeSnapshotIntegration:
    """Test suite for verifying K10 VolumeSnapshot integration."""
    
    def test_snapshot_class_annotated_for_kasten(self, k8s_client: K8sClient):
        """Verify VolumeSnapshotClass is annotated for Kasten."""
        from kubernetes import client
        
        custom_objects = client.CustomObjectsApi()
        
        result = custom_objects.list_cluster_custom_object(
            group="snapshot.storage.k8s.io",
            version="v1",
            plural="volumesnapshotclasses"
        )
        
        snapshot_classes = result.get("items", [])
        
        # Find classes annotated for Kasten
        kasten_annotated = []
        for sc in snapshot_classes:
            annotations = sc.get("metadata", {}).get("annotations", {})
            if annotations.get("k10.kasten.io/is-snapshot-class") == "true":
                kasten_annotated.append(sc["metadata"]["name"])
        
        assert len(kasten_annotated) > 0, \
            "At least one VolumeSnapshotClass should be annotated for Kasten"
        
        logger.info(f"Kasten-annotated VolumeSnapshotClasses: {kasten_annotated}")
