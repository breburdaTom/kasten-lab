"""
Test Module: Cluster Health
===========================
Verifies that the Kind cluster and infrastructure components are healthy.
"""

import pytest
import logging

from tests.utils.k8s_client import K8sClient

logger = logging.getLogger(__name__)


@pytest.mark.cluster
class TestClusterHealth:
    """
    Test suite for verifying cluster health and infrastructure readiness.
    These tests should pass before any Kasten K10 operations.
    """
    
    def test_cluster_has_nodes(self, k8s_client: K8sClient):
        """Verify the cluster has at least one node."""
        nodes = k8s_client.get_nodes()
        
        assert len(nodes) >= 1, "Cluster should have at least one node"
        logger.info(f"Cluster has {len(nodes)} node(s)")
        
        for node in nodes:
            logger.info(f"  Node: {node.metadata.name}")
    
    def test_all_nodes_ready(self, k8s_client: K8sClient):
        """Verify all cluster nodes are in Ready state."""
        nodes = k8s_client.get_nodes()
        
        for node in nodes:
            conditions = {c.type: c.status for c in node.status.conditions}
            ready_status = conditions.get("Ready")
            
            assert ready_status == "True", \
                f"Node {node.metadata.name} is not ready (status: {ready_status})"
            
            logger.info(f"Node {node.metadata.name} is Ready")
    
    def test_kube_system_pods_running(self, k8s_client: K8sClient):
        """Verify essential kube-system pods are running."""
        pods = k8s_client.get_pods("kube-system")
        
        assert len(pods) > 0, "kube-system should have pods"
        
        running_count = 0
        for pod in pods:
            if pod.status.phase == "Running":
                running_count += 1
            else:
                logger.warning(
                    f"Pod {pod.metadata.name} is {pod.status.phase}"
                )
        
        logger.info(f"kube-system has {running_count}/{len(pods)} running pods")
        
        # At least core components should be running
        assert running_count >= 3, \
            "At least 3 kube-system pods should be running"


@pytest.mark.cluster
class TestCSIDriver:
    """Test suite for verifying CSI driver installation."""
    
    def test_csi_driver_pods_exist(self, k8s_client: K8sClient):
        """Verify CSI hostpath driver pods exist."""
        pods = k8s_client.get_pods_all_namespaces(
            label_selector="app.kubernetes.io/instance=hostpath.csi.k8s.io"
        )
        
        assert len(pods) > 0, "CSI driver pods should exist"
        logger.info(f"Found {len(pods)} CSI driver pod(s)")
    
    def test_csi_driver_pods_running(self, k8s_client: K8sClient):
        """Verify CSI hostpath driver pods are running."""
        pods = k8s_client.get_pods_all_namespaces(
            label_selector="app.kubernetes.io/instance=hostpath.csi.k8s.io"
        )
        
        for pod in pods:
            assert pod.status.phase == "Running", \
                f"CSI pod {pod.metadata.name} should be Running, " \
                f"but is {pod.status.phase}"
            logger.info(f"CSI pod {pod.metadata.name} is Running")
    
    def test_storage_class_exists(self, k8s_client: K8sClient):
        """Verify CSI storage class exists."""
        storage_class_name = "csi-hostpath-sc"
        
        assert k8s_client.storage_class_exists(storage_class_name), \
            f"StorageClass '{storage_class_name}' should exist"
        
        logger.info(f"StorageClass '{storage_class_name}' exists")
    
    def test_csi_driver_registered(self, k8s_client: K8sClient):
        """Verify CSI driver is registered with Kubernetes."""
        from kubernetes import client
        
        storage_v1 = client.StorageV1Api()
        csi_drivers = storage_v1.list_csi_driver()
        driver_names = [d.metadata.name for d in csi_drivers.items]
        
        assert "hostpath.csi.k8s.io" in driver_names, \
            "CSI hostpath driver should be registered"
        
        logger.info("CSI hostpath driver is registered")


@pytest.mark.cluster
class TestSnapshotController:
    """Test suite for verifying snapshot controller installation."""
    
    def test_snapshot_crds_exist(self, k8s_client: K8sClient):
        """Verify VolumeSnapshot CRDs are installed."""
        required_crds = [
            "volumesnapshotclasses.snapshot.storage.k8s.io",
            "volumesnapshotcontents.snapshot.storage.k8s.io",
            "volumesnapshots.snapshot.storage.k8s.io",
        ]
        
        existing_crds = k8s_client.get_crds()
        
        for crd in required_crds:
            assert crd in existing_crds, f"CRD '{crd}' should exist"
            logger.info(f"CRD '{crd}' exists")
    
    def test_snapshot_controller_running(self, k8s_client: K8sClient):
        """Verify snapshot controller is running."""
        pods = k8s_client.get_pods(
            "kube-system",
            label_selector="app=snapshot-controller"
        )
        
        assert len(pods) > 0, "Snapshot controller pods should exist"
        
        for pod in pods:
            assert pod.status.phase == "Running", \
                f"Snapshot controller pod {pod.metadata.name} should be Running"
            logger.info(f"Snapshot controller pod {pod.metadata.name} is Running")
    
    def test_volume_snapshot_class_exists(self, k8s_client: K8sClient):
        """Verify VolumeSnapshotClass exists for CSI driver."""
        from kubernetes import client
        
        custom_objects = client.CustomObjectsApi()
        
        try:
            result = custom_objects.list_cluster_custom_object(
                group="snapshot.storage.k8s.io",
                version="v1",
                plural="volumesnapshotclasses"
            )
            
            snapshot_classes = result.get("items", [])
            assert len(snapshot_classes) > 0, \
                "At least one VolumeSnapshotClass should exist"
            
            # Check for CSI hostpath snapshot class
            class_names = [sc["metadata"]["name"] for sc in snapshot_classes]
            logger.info(f"VolumeSnapshotClasses: {class_names}")
            
            # Verify at least one is for hostpath driver
            hostpath_classes = [
                sc for sc in snapshot_classes 
                if sc.get("driver") == "hostpath.csi.k8s.io"
            ]
            assert len(hostpath_classes) > 0, \
                "VolumeSnapshotClass for hostpath.csi.k8s.io should exist"
            
        except Exception as e:
            pytest.fail(f"Failed to list VolumeSnapshotClasses: {e}")
