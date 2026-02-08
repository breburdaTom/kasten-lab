"""
Kasten K10 Client Utilities
===========================
Helper class for Kasten K10 CRD operations used in tests.
"""

import logging
from typing import Optional, List, Dict, Any
from kubernetes import client, config
from kubernetes.client.rest import ApiException

logger = logging.getLogger(__name__)


class KastenClient:
    """
    Wrapper class for Kasten K10 Custom Resource operations.
    Provides simplified methods for interacting with K10 CRDs.
    """
    
    # Kasten API groups and versions
    CONFIG_GROUP = "config.kio.kasten.io"
    ACTIONS_GROUP = "actions.kio.kasten.io"
    APPS_GROUP = "apps.kio.kasten.io"
    API_VERSION = "v1alpha1"
    
    def __init__(self, k10_namespace: str = "kasten-io"):
        """
        Initialize Kasten client.
        
        Args:
            k10_namespace: Namespace where K10 is installed
        """
        try:
            config.load_kube_config()
        except config.ConfigException:
            config.load_incluster_config()
        
        self.custom_objects = client.CustomObjectsApi()
        self.k10_namespace = k10_namespace
    
    # =========================================================================
    # Policy Operations
    # =========================================================================
    
    def get_policies(self) -> List[Dict[str, Any]]:
        """Get all backup policies."""
        try:
            result = self.custom_objects.list_namespaced_custom_object(
                group=self.CONFIG_GROUP,
                version=self.API_VERSION,
                namespace=self.k10_namespace,
                plural="policies"
            )
            return result.get("items", [])
        except ApiException as e:
            logger.error(f"Failed to get policies: {e}")
            return []
    
    def get_policy(self, name: str) -> Optional[Dict[str, Any]]:
        """Get a specific policy by name."""
        try:
            return self.custom_objects.get_namespaced_custom_object(
                group=self.CONFIG_GROUP,
                version=self.API_VERSION,
                namespace=self.k10_namespace,
                plural="policies",
                name=name
            )
        except ApiException as e:
            if e.status == 404:
                return None
            raise
    
    def policy_exists(self, name: str) -> bool:
        """Check if a policy exists."""
        return self.get_policy(name) is not None
    
    def get_policy_names(self) -> List[str]:
        """Get names of all policies."""
        policies = self.get_policies()
        return [p["metadata"]["name"] for p in policies]
    
    # =========================================================================
    # BackupAction Operations
    # =========================================================================
    
    def get_backup_actions(
        self, 
        policy_name: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Get backup actions, optionally filtered by policy.
        BackupActions are created in the application namespace, not kasten-io.
        
        Args:
            policy_name: Filter by policy name (optional)
        """
        try:
            label_selector = None
            if policy_name:
                label_selector = f"k10.kasten.io/policyName={policy_name}"
            
            # Search all namespaces since BackupActions are in app namespace
            result = self.custom_objects.list_cluster_custom_object(
                group=self.ACTIONS_GROUP,
                version=self.API_VERSION,
                plural="backupactions",
                label_selector=label_selector
            )
            return result.get("items", [])
        except ApiException as e:
            logger.error(f"Failed to get backup actions: {e}")
            return []
    
    def get_latest_backup_action(
        self, 
        policy_name: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Get the most recent backup action."""
        actions = self.get_backup_actions(policy_name)
        if not actions:
            return None
        
        # Sort by creation timestamp, then by name for deterministic ordering
        actions.sort(
            key=lambda x: (
                x["metadata"].get("creationTimestamp", ""),
                x["metadata"].get("name", "")
            ),
            reverse=True
        )
        return actions[0]
    
    def get_backup_action_state(self, name: str) -> Optional[str]:
        """Get the state of a backup action."""
        try:
            action = self.custom_objects.get_namespaced_custom_object(
                group=self.ACTIONS_GROUP,
                version=self.API_VERSION,
                namespace=self.k10_namespace,
                plural="backupactions",
                name=name
            )
            return action.get("status", {}).get("state")
        except ApiException:
            return None
    
    def is_backup_complete(self, policy_name: Optional[str] = None) -> bool:
        """Check if the latest backup is complete."""
        action = self.get_latest_backup_action(policy_name)
        if not action:
            return False
        state = action.get("status", {}).get("state", "")
        return state == "Complete"
    
    def is_backup_failed(self, policy_name: Optional[str] = None) -> bool:
        """Check if the latest backup failed."""
        action = self.get_latest_backup_action(policy_name)
        if not action:
            return False
        state = action.get("status", {}).get("state", "")
        return state == "Failed"
    
    # =========================================================================
    # RestorePoint Operations
    # =========================================================================
    
    def get_restore_points(self, namespace: str) -> List[Dict[str, Any]]:
        """Get all restore points in a namespace."""
        try:
            result = self.custom_objects.list_namespaced_custom_object(
                group=self.APPS_GROUP,
                version=self.API_VERSION,
                namespace=namespace,
                plural="restorepoints"
            )
            return result.get("items", [])
        except ApiException as e:
            logger.error(f"Failed to get restore points: {e}")
            return []
    
    def get_latest_restore_point(
        self, 
        namespace: str
    ) -> Optional[Dict[str, Any]]:
        """Get the most recent restore point in a namespace."""
        restore_points = self.get_restore_points(namespace)
        if not restore_points:
            return None
        
        # Sort by creation timestamp
        restore_points.sort(
            key=lambda x: x["metadata"].get("creationTimestamp", ""),
            reverse=True
        )
        return restore_points[0]
    
    def get_restore_point(
        self, 
        name: str, 
        namespace: str
    ) -> Optional[Dict[str, Any]]:
        """Get a specific restore point."""
        try:
            return self.custom_objects.get_namespaced_custom_object(
                group=self.APPS_GROUP,
                version=self.API_VERSION,
                namespace=namespace,
                plural="restorepoints",
                name=name
            )
        except ApiException as e:
            if e.status == 404:
                return None
            raise
    
    def is_restore_point_available(self, name: str, namespace: str) -> bool:
        """Check if a restore point is available."""
        rp = self.get_restore_point(name, namespace)
        if not rp:
            return False
        state = rp.get("status", {}).get("state", "")
        return state == "Available"
    
    def restore_point_count(self, namespace: str) -> int:
        """Get count of restore points in a namespace."""
        return len(self.get_restore_points(namespace))
    
    # =========================================================================
    # RestoreAction Operations
    # =========================================================================
    
    def get_restore_actions(self, namespace: str) -> List[Dict[str, Any]]:
        """Get all restore actions in a namespace."""
        try:
            result = self.custom_objects.list_namespaced_custom_object(
                group=self.ACTIONS_GROUP,
                version=self.API_VERSION,
                namespace=namespace,
                plural="restoreactions"
            )
            return result.get("items", [])
        except ApiException as e:
            logger.error(f"Failed to get restore actions: {e}")
            return []
    
    def get_latest_restore_action(
        self, 
        namespace: str
    ) -> Optional[Dict[str, Any]]:
        """Get the most recent restore action."""
        actions = self.get_restore_actions(namespace)
        if not actions:
            return None
        
        actions.sort(
            key=lambda x: x["metadata"].get("creationTimestamp", ""),
            reverse=True
        )
        return actions[0]
    
    def get_restore_action_state(
        self, 
        name: str, 
        namespace: str
    ) -> Optional[str]:
        """Get the state of a restore action."""
        try:
            action = self.custom_objects.get_namespaced_custom_object(
                group=self.ACTIONS_GROUP,
                version=self.API_VERSION,
                namespace=namespace,
                plural="restoreactions",
                name=name
            )
            return action.get("status", {}).get("state")
        except ApiException:
            return None
    
    def is_restore_complete(self, namespace: str) -> bool:
        """Check if the latest restore is complete."""
        action = self.get_latest_restore_action(namespace)
        if not action:
            return False
        state = action.get("status", {}).get("state", "")
        return state == "Complete"
    
    # =========================================================================
    # Profile Operations
    # =========================================================================
    
    def get_profiles(self) -> List[Dict[str, Any]]:
        """Get all location profiles."""
        try:
            result = self.custom_objects.list_namespaced_custom_object(
                group=self.CONFIG_GROUP,
                version=self.API_VERSION,
                namespace=self.k10_namespace,
                plural="profiles"
            )
            return result.get("items", [])
        except ApiException as e:
            logger.error(f"Failed to get profiles: {e}")
            return []
    
    def profile_exists(self, name: str) -> bool:
        """Check if a profile exists."""
        try:
            self.custom_objects.get_namespaced_custom_object(
                group=self.CONFIG_GROUP,
                version=self.API_VERSION,
                namespace=self.k10_namespace,
                plural="profiles",
                name=name
            )
            return True
        except ApiException as e:
            if e.status == 404:
                return False
            raise
