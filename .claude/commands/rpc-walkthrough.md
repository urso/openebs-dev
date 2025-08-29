---
description: "Analyze RPC call definitions and trace their complete implementation through the codebase"
argument-hint: "RPC method name or pattern (e.g., 'CreateVolume', 'ListVolumes')"
---

# RPC Walkthrough

This command analyzes RPC call definitions and traces their complete implementation through the codebase. It finds where an RPC is defined, follows the implementation chain, and identifies edge cases and error handling for both gRPC and JSON-RPC protocols.

## User Input:
```
$ARGUMENTS
```

## Instructions:

You will perform a comprehensive analysis of the specified RPC call by:

### 1. Discovery Phase
- Search for RPC method definitions using the provided RPC name/pattern
- Look in common RPC definition locations:
  - **gRPC**: protobuf files, service definitions, generated code
  - **JSON-RPC**: method registrations, handler mappings, schema definitions
- Report the exact location where the RPC is defined with file path and line numbers
- Identify the RPC protocol type (gRPC vs JSON-RPC)

### 2. Implementation Tracing
- Find the actual implementation of the RPC method
- Follow the call chain through all layers (API handlers, business logic, data access, etc.)
- Document each significant function/method in the implementation path
- Report file locations and relevant code snippets for each step

### 3. Cross-Service RPC Analysis
- Identify any outbound RPC calls to other services within the implementation
- Trace these downstream RPC calls and their implementations (both gRPC and JSON-RPC)
- Document the complete chain of service-to-service communication
- Map the dependency flow between different services/components
- Note protocol transitions (e.g., gRPC to JSON-RPC or vice versa)

### 4. Edge Case Analysis
- Identify error handling paths and conditions
- Look for validation logic and input sanitization
- Find timeout handling, retry logic, and failure scenarios
- Document any special cases or conditional behavior
- Analyze failure propagation across service boundaries
- Consider protocol-specific error handling differences

### 5. Complete Report
For each step in the implementation (including cross-service calls), provide:
- **File location**: `path/to/file.ext:line_number`
- **Code snippet**: The relevant function/method signature and key logic
- **Purpose**: What this step accomplishes in the RPC flow
- **Protocol**: gRPC, JSON-RPC, or other
- **Dependencies**: Other functions or services it calls
- **Service boundaries**: When calls cross to different services
- **Error conditions**: How it handles failures

### 6. Summary
- Provide a high-level flow diagram in text format showing service interactions
- List all identified edge cases and error scenarios
- Note any potential issues or areas of concern
- Document the complete service dependency chain
- Highlight any protocol mixing or transitions

Focus on providing actionable insights that help understand the complete RPC implementation across all services and protocols, including both the happy path and all error/edge case scenarios.