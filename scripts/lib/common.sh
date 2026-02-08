#!/usr/bin/env bash
# ==============================================================================
# Library: common.sh
# Description: Shared utility functions for all scripts
# Usage: source "${SCRIPT_DIR}/../lib/common.sh"
# ==============================================================================

# Prevent multiple sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# ==============================================================================
# wait_for_condition
# Description: Wait for a condition to be true with timeout
# Arguments:
#   $1 - condition: Shell command/expression to evaluate (must return 0 for success)
#   $2 - timeout: Maximum time to wait in seconds (default: 300)
#   $3 - interval: Time between checks in seconds (default: 5)
#   $4 - description: Human-readable description for logging (default: "condition")
# Returns:
#   0 if condition was met, 1 if timeout
# Example:
#   wait_for_condition "kubectl get pod mypod -o jsonpath='{.status.phase}' | grep -q Running" 120 10 "pod to be running"
# ==============================================================================
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-300}"
    local interval="${3:-5}"
    local description="${4:-condition}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}
