#!/usr/bin/env bash
# ==============================================================================
# Script: seed-data.sh
# Description: Seeds test data into PostgreSQL with checksums for verification
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
CHECKSUM_FILE="${CHECKSUM_FILE:-/tmp/original_checksum.txt}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Create test database and table
create_schema() {
    log_info "Creating test database schema..."
    
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -c "
        -- Create test database if not exists
        SELECT 'CREATE DATABASE testdb' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'testdb')\gexec
    " || true
    
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -c "
        -- Create test table with checksum column
        CREATE TABLE IF NOT EXISTS test_data (
            id SERIAL PRIMARY KEY,
            data TEXT NOT NULL,
            checksum TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        -- Create index for faster queries
        CREATE INDEX IF NOT EXISTS idx_test_data_checksum ON test_data(checksum);
    "
    
    log_info "Schema created"
}

# Insert test data
insert_test_data() {
    log_info "Inserting test data with checksums..."
    
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -c "
        -- Clear existing data for idempotency
        TRUNCATE TABLE test_data RESTART IDENTITY;
        
        -- Insert test records with MD5 checksums
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

# Calculate and save aggregate checksum
save_checksum() {
    log_info "Calculating aggregate checksum..."
    
    # Calculate aggregate checksum of all records
    local checksum
    checksum=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -t -A -c "
        SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;
    ")
    
    # Trim whitespace
    checksum=$(echo "${checksum}" | tr -d '[:space:]')
    
    # Save to file
    echo "${checksum}" > "${CHECKSUM_FILE}"
    
    log_info "Aggregate checksum saved to: ${CHECKSUM_FILE}"
    log_info "Checksum value: ${checksum}"
}

# Verify data integrity
verify_data() {
    log_info "Verifying seeded data..."
    
    # Count records
    local count
    count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -t -A -c "
        SELECT COUNT(*) FROM test_data;
    ")
    log_info "Total records: ${count}"
    
    # Verify individual checksums
    log_info "Verifying individual record checksums..."
    local invalid_count
    invalid_count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -t -A -c "
        SELECT COUNT(*) FROM test_data WHERE checksum != md5(data);
    ")
    
    if [[ "${invalid_count}" -gt 0 ]]; then
        log_error "Found ${invalid_count} records with invalid checksums!"
        exit 1
    fi
    
    log_info "All record checksums are valid"
    
    # Display sample data
    log_info "Sample data:"
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -c "
        SELECT id, substring(data, 1, 30) as data_preview, checksum, created_at 
        FROM test_data 
        ORDER BY id 
        LIMIT 5;
    "
}

# Main execution
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
