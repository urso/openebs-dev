---
title: SPDK RPC Testing Examples
type: note
permalink: spdk/rpc/testing/spdk-rpc-testing-examples
---

# SPDK RPC Testing Examples

## Overview

This document provides comprehensive testing approaches for SPDK RPC functionality, including built-in methods, custom methods, and integration testing. The examples demonstrate validation techniques, error testing, and automation patterns used throughout the SPDK project.

## Core RPC Testing Framework

### Basic Integrity Testing
**Source**: `test/rpc/rpc.sh:8`

```bash
#!/usr/bin/env bash
testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../..)
source $rootdir/test/common/autotest_common.sh

# Test basic RPC functionality with bdev operations
function rpc_integrity() {
    time {
        # Verify no bdevs initially  
        bdevs=$($rpc bdev_get_bdevs)
        [ "$(jq length <<< "$bdevs")" == "0" ]

        # Create malloc bdev and verify
        malloc=$($rpc bdev_malloc_create 8 512)
        bdevs=$($rpc bdev_get_bdevs)
        [ "$(jq length <<< "$bdevs")" == "1" ]

        # Create passthru bdev on top of malloc
        $rpc bdev_passthru_create -b "$malloc" -p Passthru0
        bdevs=$($rpc bdev_get_bdevs)
        [ "$(jq length <<< "$bdevs")" == "2" ]

        # Clean up in reverse order
        $rpc bdev_passthru_delete Passthru0
        $rpc bdev_malloc_delete $malloc
        bdevs=$($rpc bdev_get_bdevs)
        [ "$(jq length <<< "$bdevs")" == "0" ]
    }
}
```

### Plugin Testing
```bash
function rpc_plugins() {
    time {
        # Test custom plugin loading
        malloc=$($rpc --plugin rpc_plugin create_malloc)
        [ "$malloc" != "" ]

        # Verify created bdev exists
        bdevs=$($rpc bdev_get_bdevs)
        found=$(jq -r ".[] | select(.name==\"$malloc\") | .name" <<< "$bdevs")
        [ "$found" == "$malloc" ]

        # Clean up via plugin
        $rpc --plugin rpc_plugin delete_malloc $malloc

        # Verify cleanup
        bdevs=$($rpc bdev_get_bdevs)
        [ "$(jq length <<< "$bdevs")" == "0" ]
    }
}
```

## Parameter Validation Testing

### JSON Parameter Testing
```bash
#!/bin/bash
RPC_CMD="./scripts/rpc.py"

test_parameter_validation() {
    local method="$1"
    local valid_params="$2"
    local invalid_params="$3"
    local expected_error="$4"

    echo "Testing $method parameter validation"
    
    # Test valid parameters
    if ! $RPC_CMD $method -p "$valid_params" >/dev/null 2>&1; then
        echo "ERROR: Valid parameters rejected for $method"
        return 1
    fi

    # Test invalid parameters  
    local output
    output=$($RPC_CMD $method -p "$invalid_params" 2>&1)
    if echo "$output" | grep -q "$expected_error"; then
        echo "PASS: Invalid parameters properly rejected"
    else
        echo "ERROR: Expected error '$expected_error' not found"
        echo "Actual output: $output"
        return 1
    fi
}

# Test specific method parameter validation
test_parameter_validation "bdev_malloc_create" \
    '{"num_blocks": 1024, "block_size": 4096, "name": "TestDisk"}' \
    '{"num_blocks": -1, "block_size": 4096}' \
    "Invalid parameters"

test_parameter_validation "nvmf_create_subsystem" \
    '{"nqn": "nqn.2016-06.io.spdk:cnode1", "allow_any_host": true}' \
    '{"nqn": "invalid-nqn-format"}' \
    "Invalid parameters"
```

### State Mask Testing
```bash
test_state_restrictions() {
    local startup_method="$1"
    local runtime_method="$2"
    
    # Start SPDK in wait-for-RPC mode (STARTUP state)
    timeout 30 $SPDK_BIN_DIR/spdk_tgt --wait-for-rpc &
    spdk_tgt_pid=$!
    
    # Wait for RPC socket
    while [ ! -S /var/tmp/spdk.sock ]; do
        sleep 0.1
    done
    
    # Test startup-only method (should work)
    if $RPC_CMD $startup_method 2>&1 | grep -q "Invalid state"; then
        echo "ERROR: Startup method rejected in STARTUP state"
        kill $spdk_tgt_pid
        return 1
    fi
    
    # Test runtime-only method (should fail)  
    if ! $RPC_CMD $runtime_method 2>&1 | grep -q "Invalid state"; then
        echo "ERROR: Runtime method allowed in STARTUP state"
        kill $spdk_tgt_pid
        return 1
    fi
    
    # Transition to RUNTIME state
    $RPC_CMD framework_start_init
    
    # Now runtime method should work
    if $RPC_CMD $runtime_method 2>&1 | grep -q "Invalid state"; then
        echo "ERROR: Runtime method rejected in RUNTIME state"
        kill $spdk_tgt_pid  
        return 1
    fi
    
    kill $spdk_tgt_pid
    echo "PASS: State restrictions working correctly"
}

test_state_restrictions "bdev_set_options" "bdev_get_bdevs"
```

## Error Condition Testing

### Connection Error Testing
```bash
test_connection_errors() {
    echo "Testing RPC connection error handling"
    
    # Test invalid socket path
    if $RPC_CMD -s /nonexistent/socket bdev_get_bdevs 2>/dev/null; then
        echo "ERROR: Invalid socket path should fail"
        return 1
    fi
    
    # Test connection timeout
    timeout 5 $RPC_CMD -s /dev/null -t 1.0 bdev_get_bdevs 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "ERROR: Connection timeout should fail"
        return 1
    fi
    
    # Test invalid IP address
    if $RPC_CMD -s 999.999.999.999 -p 5260 bdev_get_bdevs 2>/dev/null; then
        echo "ERROR: Invalid IP should fail"  
        return 1
    fi
    
    echo "PASS: Connection errors handled correctly"
}
```

### Method Error Testing
```bash
test_method_errors() {
    echo "Testing RPC method error conditions"
    
    # Start SPDK normally
    $RPC_CMD framework_start_init
    
    # Test nonexistent method
    local output
    output=$($RPC_CMD nonexistent_method 2>&1)
    if ! echo "$output" | grep -q "Method not found"; then
        echo "ERROR: Nonexistent method should return 'Method not found'"
        return 1
    fi
    
    # Test malformed JSON parameters
    output=$($RPC_CMD bdev_malloc_create -p '{"invalid": json}' 2>&1)
    if ! echo "$output" | grep -q "Parse error"; then
        echo "ERROR: Malformed JSON should return parse error"
        return 1
    fi
    
    # Test method with missing required parameters
    output=$($RPC_CMD bdev_malloc_create -p '{"block_size": 4096}' 2>&1)
    if ! echo "$output" | grep -q "Invalid parameters"; then
        echo "ERROR: Missing required parameters should fail"
        return 1
    fi
    
    # Test duplicate resource creation
    $RPC_CMD bdev_malloc_create 1024 4096 TestDisk
    output=$($RPC_CMD bdev_malloc_create 1024 4096 TestDisk 2>&1)
    if ! echo "$output" | grep -q "already exists\|duplicate"; then
        echo "ERROR: Duplicate creation should fail"
        return 1
    fi
    
    # Clean up
    $RPC_CMD bdev_malloc_delete TestDisk
    
    echo "PASS: Method errors handled correctly"
}
```

## Performance Testing

### RPC Throughput Testing
```bash
test_rpc_performance() {
    local num_requests=1000
    local start_time
    local end_time
    
    echo "Testing RPC performance with $num_requests requests"
    
    $RPC_CMD framework_start_init
    
    # Measure simple method calls
    start_time=$(date +%s.%N)
    for ((i=0; i<num_requests; i++)); do
        $RPC_CMD spdk_get_version >/dev/null
    done
    end_time=$(date +%s.%N)
    
    local duration=$(echo "$end_time - $start_time" | bc)
    local rps=$(echo "scale=2; $num_requests / $duration" | bc)
    
    echo "Simple method calls: $rps requests/second"
    
    # Measure bdev operations
    start_time=$(date +%s.%N)
    for ((i=0; i<100; i++)); do
        local name="PerfTest$i"
        $RPC_CMD bdev_malloc_create 64 4096 $name >/dev/null
        $RPC_CMD bdev_malloc_delete $name >/dev/null
    done
    end_time=$(date +%s.%N)
    
    duration=$(echo "$end_time - $start_time" | bc)
    local ops_per_sec=$(echo "scale=2; 200 / $duration" | bc) # 2 ops per iteration
    
    echo "Bdev create/delete: $ops_per_sec operations/second"
}
```

### Concurrent RPC Testing
```bash
test_concurrent_rpcs() {
    local num_clients=10
    local requests_per_client=100
    
    echo "Testing concurrent RPC clients: $num_clients clients, $requests_per_client requests each"
    
    $RPC_CMD framework_start_init
    
    # Create test function for background clients
    concurrent_client() {
        local client_id="$1"
        local requests="$2"
        
        for ((i=0; i<requests; i++)); do
            if ! $RPC_CMD spdk_get_version >/dev/null 2>&1; then
                echo "Client $client_id request $i failed"
                return 1
            fi
        done
        echo "Client $client_id completed $requests requests"
    }
    
    # Start background clients
    local pids=()
    for ((i=0; i<num_clients; i++)); do
        concurrent_client $i $requests_per_client &
        pids+=($!)
    done
    
    # Wait for all clients and check results
    local failures=0
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            ((failures++))
        fi
    done
    
    if [ $failures -eq 0 ]; then
        echo "PASS: All concurrent clients completed successfully"
    else
        echo "ERROR: $failures clients failed"
        return 1
    fi
}
```

## Custom Method Testing

### Custom RPC Method Unit Tests
```c
// test_custom_rpc.c - Unit tests for custom RPC methods
#include "spdk/stdinc.h"
#include "CUnit/Basic.h"
#include "spdk/rpc.h"
#include "spdk/json.h"

// Mock request for testing
struct mock_jsonrpc_request {
    bool response_sent;
    struct spdk_json_write_ctx *response;
    int error_code;
    char error_message[256];
};

// Test parameter validation
static void
test_custom_method_params(void)
{
    // Test valid parameters
    const char *valid_json = "{\"name\":\"test\",\"value\":42,\"enabled\":true}";
    struct spdk_json_val *params = parse_json_string(valid_json);
    
    CU_ASSERT_PTR_NOT_NULL(params);
    
    // Test parameter decoding
    struct my_rpc_params decoded = {};
    int rc = decode_custom_params(params, &decoded);
    
    CU_ASSERT_EQUAL(rc, 0);
    CU_ASSERT_STRING_EQUAL(decoded.name, "test");
    CU_ASSERT_EQUAL(decoded.value, 42);
    CU_ASSERT_TRUE(decoded.enabled);
    
    free_custom_params(&decoded);
    free(params);
}

// Test error conditions
static void
test_custom_method_errors(void)
{
    // Test missing required parameter
    const char *invalid_json = "{\"value\":42}"; // missing "name"
    struct spdk_json_val *params = parse_json_string(invalid_json);
    
    struct my_rpc_params decoded = {};
    int rc = decode_custom_params(params, &decoded);
    
    CU_ASSERT_NOT_EQUAL(rc, 0); // Should fail
    
    free(params);
}

// Test response generation
static void
test_response_generation(void)
{
    struct mock_jsonrpc_request mock_req = {};
    
    // Test success response
    generate_custom_success_response(&mock_req, "test_result");
    CU_ASSERT_TRUE(mock_req.response_sent);
    
    // Test error response  
    mock_req.response_sent = false;
    generate_custom_error_response(&mock_req, -EINVAL, "Test error");
    CU_ASSERT_TRUE(mock_req.response_sent);
    CU_ASSERT_EQUAL(mock_req.error_code, -EINVAL);
}

static int
init_suite(void)
{
    // Initialize any required test infrastructure
    return 0;
}

static int
clean_suite(void)
{
    // Clean up test infrastructure
    return 0;
}

int main(void)
{
    CU_pSuite suite = NULL;
    
    if (CU_initialize_registry() != CUE_SUCCESS) {
        return CU_get_error();
    }
    
    suite = CU_add_suite("Custom RPC Tests", init_suite, clean_suite);
    if (suite == NULL) {
        CU_cleanup_registry();
        return CU_get_error();
    }
    
    // Add tests to suite
    if (CU_add_test(suite, "test_parameter_validation", test_custom_method_params) == NULL ||
        CU_add_test(suite, "test_error_conditions", test_custom_method_errors) == NULL ||
        CU_add_test(suite, "test_response_generation", test_response_generation) == NULL) {
        CU_cleanup_registry();
        return CU_get_error();
    }
    
    CU_basic_set_mode(CU_BRM_VERBOSE);
    CU_basic_run_tests();
    CU_cleanup_registry();
    
    return CU_get_error();
}
```

### Integration Testing with External Methods
```bash
#!/bin/bash
# test_external_rpc.sh - Test external RPC methods

test_external_passthru_rpc() {
    echo "Testing external passthru RPC methods"
    
    # Build external module
    cd test/external_code/passthru
    make clean && make
    
    # Start SPDK with external module
    timeout 60 ./passthru_external --wait-for-rpc &
    local spdk_pid=$!
    
    # Wait for RPC socket
    while [ ! -S /var/tmp/spdk.sock ]; do
        sleep 0.1
    done
    
    # Initialize framework
    $RPC_CMD framework_start_init
    
    # Create base bdev
    local base_bdev
    base_bdev=$($RPC_CMD bdev_malloc_create 1024 4096)
    
    # Test external method - create passthru
    local passthru_bdev
    passthru_bdev=$($RPC_CMD construct_ext_passthru_bdev -p "{
        \"base_bdev_name\": \"$base_bdev\",
        \"name\": \"ExtPassthru0\"
    }")
    
    [ "$passthru_bdev" == "ExtPassthru0" ] || {
        echo "ERROR: External passthru creation failed"
        kill $spdk_pid
        return 1
    }
    
    # Verify bdev exists in system
    local bdevs
    bdevs=$($RPC_CMD bdev_get_bdevs)
    if ! echo "$bdevs" | jq -e '.[] | select(.name=="ExtPassthru0")' >/dev/null; then
        echo "ERROR: External passthru bdev not found in system"
        kill $spdk_pid
        return 1
    fi
    
    # Test external method - delete passthru
    local delete_result
    delete_result=$($RPC_CMD delete_ext_passthru_bdev -p "{\"name\": \"ExtPassthru0\"}")
    
    [ "$delete_result" == "true" ] || {
        echo "ERROR: External passthru deletion failed"
        kill $spdk_pid
        return 1
    }
    
    # Clean up
    $RPC_CMD bdev_malloc_delete "$base_bdev"
    kill $spdk_pid
    wait $spdk_pid 2>/dev/null
    
    echo "PASS: External passthru RPC methods working correctly"
}
```

## Automated Test Suites

### Python Test Framework
```python
#!/usr/bin/env python3
# test_rpc_framework.py - Comprehensive RPC testing framework

import subprocess
import json
import time
import tempfile
import os
from contextlib import contextmanager

class SPDKRPCTester:
    def __init__(self, spdk_binary, rpc_script):
        self.spdk_binary = spdk_binary
        self.rpc_script = rpc_script
        self.spdk_process = None
        
    @contextmanager
    def spdk_instance(self, wait_for_rpc=True):
        """Context manager for SPDK instance"""
        args = [self.spdk_binary]
        if wait_for_rpc:
            args.append('--wait-for-rpc')
            
        self.spdk_process = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL)
        
        # Wait for RPC socket
        socket_path = '/var/tmp/spdk.sock'
        timeout = 30
        start_time = time.time()
        
        while not os.path.exists(socket_path):
            if time.time() - start_time > timeout:
                raise TimeoutError("SPDK RPC socket not created")
            time.sleep(0.1)
            
        try:
            if wait_for_rpc:
                self.call_rpc('framework_start_init')
            yield self
        finally:
            if self.spdk_process:
                self.spdk_process.terminate()
                self.spdk_process.wait()
    
    def call_rpc(self, method, params=None, expect_error=False):
        """Call RPC method and return result"""
        cmd = [self.rpc_script, method]
        if params:
            cmd.extend(['-p', json.dumps(params)])
            
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            
            if expect_error:
                if result.returncode == 0:
                    raise AssertionError(f"Expected {method} to fail but it succeeded")
                return result.stderr
            else:
                if result.returncode != 0:
                    raise RuntimeError(f"RPC {method} failed: {result.stderr}")
                return json.loads(result.stdout) if result.stdout else None
                
        except subprocess.TimeoutExpired:
            raise TimeoutError(f"RPC {method} timed out")
    
    def test_basic_functionality(self):
        """Test basic RPC functionality"""
        with self.spdk_instance():
            # Test version info
            version = self.call_rpc('spdk_get_version')
            assert 'version' in version
            assert 'fields' in version
            
            # Test method listing
            methods = self.call_rpc('rpc_get_methods')
            assert isinstance(methods, list)
            assert len(methods) > 0
            
            # Test bdev operations
            bdevs = self.call_rpc('bdev_get_bdevs')
            initial_count = len(bdevs)
            
            # Create malloc bdev
            malloc_name = self.call_rpc('bdev_malloc_create', {
                'num_blocks': 1024,
                'block_size': 4096,
                'name': 'TestMalloc'
            })
            assert malloc_name == 'TestMalloc'
            
            # Verify bdev exists
            bdevs = self.call_rpc('bdev_get_bdevs')
            assert len(bdevs) == initial_count + 1
            
            test_bdev = next(b for b in bdevs if b['name'] == 'TestMalloc')
            assert test_bdev['num_blocks'] == 1024
            assert test_bdev['block_size'] == 4096
            
            # Delete bdev
            result = self.call_rpc('bdev_malloc_delete', {'name': 'TestMalloc'})
            assert result is True
            
            # Verify deletion
            bdevs = self.call_rpc('bdev_get_bdevs')
            assert len(bdevs) == initial_count
    
    def test_error_conditions(self):
        """Test error condition handling"""
        with self.spdk_instance():
            # Test nonexistent method
            self.call_rpc('nonexistent_method', expect_error=True)
            
            # Test invalid parameters
            self.call_rpc('bdev_malloc_create', {
                'num_blocks': -1,  # Invalid value
                'block_size': 4096
            }, expect_error=True)
            
            # Test missing required parameters
            self.call_rpc('bdev_malloc_create', {
                'block_size': 4096  # Missing num_blocks
            }, expect_error=True)
    
    def test_state_management(self):
        """Test RPC state management"""
        with self.spdk_instance(wait_for_rpc=False):
            # In startup state, runtime methods should fail
            self.call_rpc('bdev_get_bdevs', expect_error=True)
            
            # Startup methods should work
            self.call_rpc('rpc_get_methods')
            
            # Transition to runtime
            self.call_rpc('framework_start_init')
            
            # Now runtime methods should work
            self.call_rpc('bdev_get_bdevs')
    
    def run_all_tests(self):
        """Run complete test suite"""
        tests = [
            self.test_basic_functionality,
            self.test_error_conditions,
            self.test_state_management
        ]
        
        passed = 0
        failed = 0
        
        for test in tests:
            try:
                print(f"Running {test.__name__}...")
                test()
                print(f"✓ {test.__name__} passed")
                passed += 1
            except Exception as e:
                print(f"✗ {test.__name__} failed: {e}")
                failed += 1
        
        print(f"\nTest Results: {passed} passed, {failed} failed")
        return failed == 0

if __name__ == '__main__':
    tester = SPDKRPCTester('./build/bin/spdk_tgt', './scripts/rpc.py')
    success = tester.run_all_tests()
    exit(0 if success else 1)
```

## Continuous Integration Testing

### GitHub Actions RPC Testing
```yaml
# .github/workflows/rpc-tests.yml
name: SPDK RPC Tests

on: [push, pull_request]

jobs:
  rpc-tests:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v2
      with:
        submodules: recursive
    
    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y build-essential pkg-config libnuma-dev
        
    - name: Build SPDK
      run: |
        ./configure --enable-debug
        make -j$(nproc)
    
    - name: Run RPC integrity tests
      run: |
        cd test/rpc
        timeout 300 ./rpc.sh
    
    - name: Run custom RPC tests
      run: |
        cd test/external_code
        timeout 300 ./test_make.sh $(pwd)/../..
    
    - name: Run Python RPC framework tests
      run: |
        python3 test/rpc_framework/test_rpc_framework.py
```

## Test Utilities and Helpers

### Common Test Functions
```bash
# test/common/rpc_helpers.sh - Reusable RPC test functions

setup_spdk_test_environment() {
    local wait_for_rpc=${1:-true}
    
    # Kill any existing SPDK processes
    pkill -f spdk_tgt || true
    sleep 1
    
    # Clean up socket
    rm -f /var/tmp/spdk.sock
    
    # Start SPDK
    local args=()
    if [ "$wait_for_rpc" == "true" ]; then
        args+=("--wait-for-rpc")
    fi
    
    timeout 60 $SPDK_BIN_DIR/spdk_tgt "${args[@]}" &
    export SPDK_TEST_PID=$!
    
    # Wait for socket
    local timeout=30
    local count=0
    while [ ! -S /var/tmp/spdk.sock ]; do
        sleep 0.1
        count=$((count + 1))
        if [ $count -gt $((timeout * 10)) ]; then
            echo "ERROR: SPDK socket not created within $timeout seconds"
            return 1
        fi
    done
    
    if [ "$wait_for_rpc" == "true" ]; then
        $RPC_CMD framework_start_init
    fi
}

cleanup_spdk_test_environment() {
    if [ -n "$SPDK_TEST_PID" ]; then
        kill $SPDK_TEST_PID 2>/dev/null || true
        wait $SPDK_TEST_PID 2>/dev/null || true
    fi
    rm -f /var/tmp/spdk.sock
}

verify_bdev_count() {
    local expected_count="$1"
    local bdevs
    bdevs=$($RPC_CMD bdev_get_bdevs)
    local actual_count
    actual_count=$(echo "$bdevs" | jq length)
    
    if [ "$actual_count" != "$expected_count" ]; then
        echo "ERROR: Expected $expected_count bdevs, found $actual_count"
        echo "Bdevs: $bdevs"
        return 1
    fi
}

create_test_bdev() {
    local name="$1"
    local blocks="${2:-1024}"
    local block_size="${3:-4096}"
    
    local result
    result=$($RPC_CMD bdev_malloc_create "$blocks" "$block_size" "$name")
    if [ "$result" != "$name" ]; then
        echo "ERROR: Failed to create bdev $name"
        return 1
    fi
}
```

---

**Related Documentation:**
- **[[SPDK RPC Client Usage]]** - Client-side testing techniques
- **[[SPDK RPC External Examples]]** - Testing custom implementations  
- **[[Custom RPC Development Guide]]** - Development testing patterns
- **[[SPDK RPC Architecture]]** - Understanding test requirements

**Key Test Files:**
- `test/rpc/rpc.sh` - Core RPC functionality tests
- `test/external_code/test_make.sh` - External module testing
- `test/common/autotest_common.sh` - Test infrastructure
- Unit tests in `test/unit/lib/` directories