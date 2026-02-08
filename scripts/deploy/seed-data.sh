#!/usr/bin/env bash
# ==============================================================================
# Script: seed-data.sh
# Description: Seeds test data into PostgreSQL with checksums for verification
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
CHECKSUM_FILE="${CHECKSUM_FILE:-/tmp/original_checksum.txt}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

create_schema() {
    log_info "Creating test database schema..."
    
    # Create database if it doesn't exist (ignore error if it already exists)
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- \
        psql -U postgres -c "CREATE DATABASE testdb;" 2>/dev/null || true
    
    # Create table and index
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- \
        psql -U postgres -d testdb -c "
            CREATE TABLE IF NOT EXISTS test_data (
                id SERIAL PRIMARY KEY,
                data TEXT NOT NULL,
                checksum TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_test_data_checksum ON test_data(checksum);
        "
    log_info "Schema created"
}

insert_test_data() {
    log_info "Inserting test data with checksums..."
    
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- psql -U postgres -d testdb -c "
        TRUNCATE TABLE test_data RESTART IDENTITY;
        INSERT INTO test_data (data, checksum) VALUES 
            ('kasten-backup-test-record-001', md5('kasten-backup-test-record-001')),
            ('kasten-backup-test-record-002', md5('kasten-backup-test-record-002')),
            ('kasten-backup-test-record-003', md5('kasten-backup-test-record-003')),
            ('important-business-data-alpha', md5('important-business-data-alpha')),
            ('important-business-data-beta', md5('important-business-data-beta')),
            ('critical-config-setting-gamma', md5('critical-config-setting-gamma')),
            ('user-profile-data-delta', md5('user-profile-data-delta')),
            ('transaction-log-epsilon', md5('transaction-log-epsilon')),
            ('audit-trail-zeta', md5('audit-trail-zeta')),
            ('system-state-eta', md5('system-state-eta'));
    "
    log_info "Test data inserted"
}

save_checksum() {
    log_info "Calculating aggregate checksum..."
    
    local checksum
    checksum=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- psql -U postgres -d testdb -t -A -c \
        "SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;" | tr -d '[:space:]')
    
    if [[ -z "${checksum}" ]]; then
        log_error "Failed to calculate checksum - empty result"
        exit 1
    fi
    
    local checksum_dir
    checksum_dir=$(dirname "${CHECKSUM_FILE}")
    mkdir -p "${checksum_dir}" || { log_error "Failed to create directory: ${checksum_dir}"; exit 1; }
    
    echo "${checksum}" > "${CHECKSUM_FILE}" || { log_error "Failed to write checksum file: ${CHECKSUM_FILE}"; exit 1; }
    log_info "Aggregate checksum saved to: ${CHECKSUM_FILE}"
    log_info "Checksum value: ${checksum}"
}

verify_data() {
    log_info "Verifying seeded data..."
    
    local count invalid_count
    count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- psql -U postgres -d testdb -t -A -c "SELECT COUNT(*) FROM test_data;")
    log_info "Total records: ${count}"
    
    log_info "Verifying individual record checksums..."
    invalid_count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- psql -U postgres -d testdb -t -A -c \
        "SELECT COUNT(*) FROM test_data WHERE checksum != md5(data);")
    
    if [[ "${invalid_count}" -gt 0 ]]; then
        log_error "Found ${invalid_count} records with invalid checksums!"
        exit 1
    fi
    log_info "All record checksums are valid"
    
    log_info "Sample data:"
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -c postgres -- psql -U postgres -d testdb -c \
        "SELECT id, substring(data, 1, 30) as data_preview, checksum, created_at FROM test_data ORDER BY id LIMIT 5;"
}

main() {
    log_info "Starting test data seeding..."
    create_schema
    insert_test_data
    save_checksum
    verify_data
    log_info "Test data seeding completed successfully!"
    log_info "Original checksum file: ${CHECKSUM_FILE}"
}

main "$@"
