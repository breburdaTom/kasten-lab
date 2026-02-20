"""
Kubernetes Client Utilities
===========================
Helper class for common Kubernetes operations used in tests.
"""

import time
import logging
from typing import Optional, List, Dict, Any, Callable
from kubernetes import client, config
from kubernetes.client.rest import ApiException

logger = logging.getLogger(__name__)


class K8sClient:
    """
    Wrapper class for Kubernetes API operations.
    Provides simplified methods for common test operations.
    """
    
    def __init__(self):
        """Initialize Kubernetes clients."""
        try:
            config.load_kube_config()
        except config.ConfigException:
            # Fallback to in-cluster config
            config.load_incluster_config()
        
        self.core_v1 = client.CoreV1Api()
        self.apps_v1 = client.AppsV1Api()
        self.storage_v1 = client.StorageV1Api()
        self.custom_objects = client.CustomObjectsApi()
        self.api_extensions = client.ApiextensionsV1Api()
    
    # =========================================================================
    # Node Operations
    # =========================================================================
    
    def get_nodes(self) -> List[client.V1Node]:
        """Get all cluster nodes."""
        return self.core_v1.list_node().items
    
    def are_all_nodes_ready(self) -> bool:
        """Check if all nodes are in Ready state."""
        nodes = self.get_nodes()
        for node in nodes:
            conditions = {c.type: c.status for c in node.status.conditions}
            if conditions.get("Ready") != "True":
                return False
        return len(nodes) > 0
    
    # =========================================================================
    # Namespace Operations
    # =========================================================================
    
    def namespace_exists(self, name: str) -> bool:
        """Check if a namespace exists."""
        try:
            self.core_v1.read_namespace(name)
            return True
        except ApiException as e:
            if e.status == 404:
                return False
            raise
    
    def get_namespaces(self) -> List[str]:
        """Get list of all namespace names."""
        namespaces = self.core_v1.list_namespace()
        return [ns.metadata.name for ns in namespaces.items]
    
    # =========================================================================
    # Pod Operations
    # =========================================================================
    
    def get_pods(
        self, 
        namespace: str, 
        label_selector: Optional[str] = None
    ) -> List[client.V1Pod]:
        """Get pods in a namespace, optionally filtered by label."""
        if not namespace or not namespace.strip():
            raise ValueError("namespace parameter cannot be empty")
        
        if label_selector:
            return self.core_v1.list_namespaced_pod(
                namespace, label_selector=label_selector
            ).items
        return self.core_v1.list_namespaced_pod(namespace).items
    
    def get_pods_all_namespaces(
        self, 
        label_selector: Optional[str] = None
    ) -> List[client.V1Pod]:
        """Get pods across all namespaces."""
        if label_selector:
            return self.core_v1.list_pod_for_all_namespaces(
                label_selector=label_selector
            ).items
        return self.core_v1.list_pod_for_all_namespaces().items
    
    def is_pod_running(self, name: str, namespace: str) -> bool:
        """Check if a specific pod is running."""
        try:
            pod = self.core_v1.read_namespaced_pod(name, namespace)
            return pod.status.phase == "Running"
        except ApiException:
            return False
    
    def are_all_pods_ready(
        self, 
        namespace: str, 
        label_selector: Optional[str] = None
    ) -> bool:
        """Check if all relevant pods in namespace are running and ready, with diagnostics.
        
        - Ignores Job pods that are Succeeded/Failed (terminal) as they are not long-running services.
        - Requires phase Running and all containers ready for controller-managed pods.
        - Logs a concise readiness summary and blockers when not yet ready.
        """
        pods = self.get_pods(namespace, label_selector)
        if not pods:
            logger.debug(f"[are_all_pods_ready] No pods found in ns={namespace}")
            return False

        def is_job_pod(p: client.V1Pod) -> bool:
            owners = (p.metadata.owner_references or [])
            return any(getattr(o, "kind", "") == "Job" for o in owners)

        total = 0
        ready_like = 0
        blockers = []

        for pod in pods:
            phase = pod.status.phase or ""
            name = pod.metadata.name

            # Skip terminal Job pods (from hooks or init tasks)
            if is_job_pod(pod) and phase in ("Succeeded", "Failed"):
                continue

            total += 1

            statuses = pod.status.container_statuses or []
            all_ready = bool(statuses) and all(cs.ready for cs in statuses)

            if phase == "Running" and all_ready:
                ready_like += 1
            else:
                # collect blocker info
                ready_cnt = sum(1 for cs in statuses if getattr(cs, "ready", False))
                blockers.append({
                    "name": name,
                    "phase": phase,
                    "ready": f"{ready_cnt}/{len(statuses)}",
                })

        if total == 0:
            logger.debug(f"[are_all_pods_ready] No relevant pods (non-terminal Jobs) in ns={namespace}")
            return False

        if ready_like == total:
            logger.info(f"[are_all_pods_ready] Ready {ready_like}/{total} pods in ns={namespace}")
            return True

        # Not ready yet; log concise blockers
        summary = ", ".join([f"{b['name']}({b['phase']} {b['ready']})" for b in blockers])
        logger.info(f"[are_all_pods_ready] Waiting: ready {ready_like}/{total}; blockers: {summary}")
        return False
    
    # =========================================================================
    # StatefulSet Operations
    # =========================================================================
    
    def get_statefulset(
        self, 
        name: str, 
        namespace: str
    ) -> Optional[client.V1StatefulSet]:
        """Get a StatefulSet by name."""
        try:
            return self.apps_v1.read_namespaced_stateful_set(name, namespace)
        except ApiException as e:
            if e.status == 404:
                return None
            raise
    
    def is_statefulset_ready(self, name: str, namespace: str) -> bool:
        """Check if a StatefulSet has all replicas ready."""
        ss = self.get_statefulset(name, namespace)
        if not ss:
            return False
        return (
            ss.status.ready_replicas is not None and
            ss.status.ready_replicas == ss.spec.replicas
        )
    
    def statefulset_exists(self, name: str, namespace: str) -> bool:
        """Check if a StatefulSet exists."""
        return self.get_statefulset(name, namespace) is not None
    
    # =========================================================================
    # Deployment Operations
    # =========================================================================
    
    def get_deployments(self, namespace: str) -> List[client.V1Deployment]:
        """Get all deployments in a namespace."""
        return self.apps_v1.list_namespaced_deployment(namespace).items
    
    def get_deployment_names(self, namespace: str) -> List[str]:
        """Get names of all deployments in a namespace."""
        deployments = self.get_deployments(namespace)
        return [d.metadata.name for d in deployments]
    
    def is_deployment_available(self, name: str, namespace: str) -> bool:
        """Check if a deployment is available."""
        try:
            deployment = self.apps_v1.read_namespaced_deployment(name, namespace)
            conditions = deployment.status.conditions or []
            for condition in conditions:
                if condition.type == "Available" and condition.status == "True":
                    return True
            return False
        except ApiException:
            return False
    
    # =========================================================================
    # PVC Operations
    # =========================================================================
    
    def get_pvcs(self, namespace: str) -> List[client.V1PersistentVolumeClaim]:
        """Get all PVCs in a namespace."""
        return self.core_v1.list_namespaced_persistent_volume_claim(namespace).items
    
    def is_pvc_bound(self, name: str, namespace: str) -> bool:
        """Check if a PVC is bound."""
        try:
            pvc = self.core_v1.read_namespaced_persistent_volume_claim(name, namespace)
            return pvc.status.phase == "Bound"
        except ApiException:
            return False
    
    def pvc_count(self, namespace: str) -> int:
        """Get count of PVCs in a namespace."""
        return len(self.get_pvcs(namespace))
    
    # =========================================================================
    # StorageClass Operations
    # =========================================================================
    
    def get_storage_classes(self) -> List[client.V1StorageClass]:
        """Get all storage classes."""
        return self.storage_v1.list_storage_class().items
    
    def storage_class_exists(self, name: str) -> bool:
        """Check if a storage class exists."""
        try:
            self.storage_v1.read_storage_class(name)
            return True
        except ApiException as e:
            if e.status == 404:
                return False
            raise
    
    # =========================================================================
    # CRD Operations
    # =========================================================================
    
    def get_crds(self) -> List[str]:
        """Get list of all CRD names."""
        crds = self.api_extensions.list_custom_resource_definition()
        return [crd.metadata.name for crd in crds.items]
    
    def crd_exists(self, name: str) -> bool:
        """Check if a CRD exists."""
        return name in self.get_crds()
    
    # =========================================================================
    # Custom Resource Operations
    # =========================================================================
    
    def get_custom_objects(
        self,
        group: str,
        version: str,
        namespace: str,
        plural: str
    ) -> List[Dict[str, Any]]:
        """Get custom objects of a specific type."""
        try:
            result = self.custom_objects.list_namespaced_custom_object(
                group=group,
                version=version,
                namespace=namespace,
                plural=plural
            )
            return result.get("items", [])
        except ApiException:
            return []
    
    def get_custom_object(
        self,
        group: str,
        version: str,
        namespace: str,
        plural: str,
        name: str
    ) -> Optional[Dict[str, Any]]:
        """Get a specific custom object."""
        try:
            return self.custom_objects.get_namespaced_custom_object(
                group=group,
                version=version,
                namespace=namespace,
                plural=plural,
                name=name
            )
        except ApiException as e:
            if e.status == 404:
                return None
            raise
    
    # =========================================================================
    # Wait Utilities
    # =========================================================================
    
    def wait_for_condition(
        self,
        condition_func: Callable[[], bool],
        timeout: int = 300,
        interval: int = 10,
        description: str = "condition"
    ) -> bool:
        """
        Wait for a condition to be true.
        
        Args:
            condition_func: Function that returns True when condition is met
            timeout: Maximum time to wait in seconds
            interval: Time between checks in seconds
            description: Description for logging
            
        Returns:
            True if condition was met, False if timeout
        """
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                if condition_func():
                    logger.info(f"Condition met: {description}")
                    return True
            except Exception as e:
                logger.debug(f"Condition check failed: {e}")
            
            elapsed = int(time.time() - start_time)
            remaining = timeout - elapsed
            logger.info(f"Waiting for {description}... elapsed={elapsed}s remaining={remaining}s interval={interval}s")
            time.sleep(interval)
        
        logger.error(f"Timeout waiting for {description}")
        return False
