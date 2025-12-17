# PAGI::Server Performance Optimization Plan

## Background

Benchmarking revealed that PAGI::Server achieves ~4,000 req/sec in single-worker mode compared to ~11,668 req/sec for raw IO::Async - a ~3x overhead. This plan addresses the identified bottlenecks through 4 optimization phases.

### Current Benchmark Baseline (to be run before starting)

```bash
# Raw IO::Async baseline
LIBEV_FLAGS=8 perl -MIO::Async::Loop::EV /tmp/raw_http.pl &
hey -n 30000 -c 500 http://localhost:5570/

# PAGI::Server baseline
LIBEV_FLAGS=8 perl -Ilib ./bin/pagi-server /tmp/raw_pagi.pl --port 5572 --no-access-log --loop EV &
hey -n 30000 -c 500 http://localhost:5572/

# PAGI::Simple baseline
LIBEV_FLAGS=8 perl -Ilib ./bin/pagi-server ./examples/simple-01-hello/app.pl --port 5560 --no-access-log --loop EV &
hey -n 30000 -c 500 http://localhost:5560/
```

---

## Phase 1: Cache Connection Info

**Risk Level:** Low
**Expected Improvement:** 5-10%
**Files Modified:** `lib/PAGI/Server/Connection.pm`

Currently, `peerhost`, `peerport`, `sockhost`, and `sockport` are extracted from the socket handle on every request in `_create_scope()`. These values never change during a connection's lifetime.

### Step 1.1: Add Connection Info Fields to Constructor

**Sub-steps:**
1. Read `Connection.pm` and identify the `new()` constructor
2. Add new instance fields: `client_host`, `client_port`, `server_host`, `server_port`
3. Initialize fields to default values (`'127.0.0.1'`, `0`, `'127.0.0.1'`, `5000`)
4. Run test suite to verify no regressions: `prove -l t/`

**Verification:**
- [ ] Tests pass before changes
- [ ] Tests pass after changes
- [ ] No new warnings in test output

### Step 1.2: Extract Socket Info in start() Method

**Sub-steps:**
1. Locate the `start()` method in `Connection.pm`
2. After the TCP_NODELAY setup, extract and cache socket info from the handle
3. Add appropriate error handling (eval block) for socket info extraction
4. Run test suite: `prove -l t/`

**Code location:** After line ~146 (TCP_NODELAY block)

**Verification:**
- [ ] Tests pass
- [ ] Socket info is extracted once per connection (add debug logging temporarily)

### Step 1.3: Update _create_scope() to Use Cached Values

**Sub-steps:**
1. Locate `_create_scope()` method (around line 399)
2. Remove the socket info extraction code (lines ~404-412)
3. Replace with references to cached instance fields
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] `_create_scope()` no longer calls `peerhost`/`sockhost` methods

### Step 1.4: Update WebSocket and SSE Scope Creation

**Sub-steps:**
1. Locate `_create_websocket_scope()` method
2. Update to use cached connection info instead of extracting from socket
3. Locate `_create_sse_scope()` method
4. Update to use cached connection info
5. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] WebSocket tests pass: `prove -l t/03-websocket.t`
- [ ] SSE tests pass: `prove -l t/05-sse.t`

### Step 1.5: Benchmark and Report

**Sub-steps:**
1. Run full test suite to confirm no regressions: `prove -l t/`
2. Run PAGI::Server benchmark (raw PAGI app)
3. Run PAGI::Simple benchmark
4. Document results and calculate improvement percentage

**Verification:**
- [ ] All tests pass
- [ ] Benchmark shows improvement (or at minimum, no regression)
- [ ] Report results to user for approval before proceeding to Phase 2

---

## Phase 2: Single Header Pass

**Risk Level:** Low-Medium
**Expected Improvement:** 5-10%
**Files Modified:** `lib/PAGI/Server/Connection.pm`

Currently, headers are scanned multiple times per request:
- `_is_websocket_upgrade()` - scans for upgrade/connection/sec-websocket-key
- `_is_sse_request()` - scans for accept header
- `_should_keep_alive()` - scans for connection header
- `_create_send()` - scans for connection header (HTTP/1.0 keep-alive)

### Step 2.1: Create Header Info Extraction Helper

**Sub-steps:**
1. Design a new method `_extract_header_info($request)` that returns a hash
2. Define the hash structure: `{ upgrade => ..., connection => ..., accept => ..., ws_key => ... }`
3. Implement the single-pass loop through headers
4. Add unit test for the new method
5. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] New method correctly extracts all needed header values

### Step 2.2: Update _try_handle_request() to Use Header Info

**Sub-steps:**
1. Locate `_try_handle_request()` method (around line 224)
2. Call `_extract_header_info()` once after parsing the request
3. Store result in `$self->{current_header_info}` for use by other methods
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] Header info is extracted once per request

### Step 2.3: Refactor _is_websocket_upgrade() to Use Cached Info

**Sub-steps:**
1. Locate `_is_websocket_upgrade()` method (around line 276)
2. Change signature to accept header_info hash (or use instance field)
3. Replace header loop with direct hash access
4. Run WebSocket tests: `prove -l t/03-websocket.t`
5. Run full test suite: `prove -l t/`

**Verification:**
- [ ] WebSocket tests pass
- [ ] All tests pass

### Step 2.4: Refactor _is_sse_request() to Use Cached Info

**Sub-steps:**
1. Locate `_is_sse_request()` method (around line 299)
2. Change to use cached header info
3. Replace header loop with direct hash access
4. Run SSE tests: `prove -l t/05-sse.t`
5. Run full test suite: `prove -l t/`

**Verification:**
- [ ] SSE tests pass
- [ ] All tests pass

### Step 2.5: Refactor _should_keep_alive() to Use Cached Info

**Sub-steps:**
1. Locate `_should_keep_alive()` method (around line 371)
2. Change to use cached header info for connection header
3. Remove the header scanning loop
4. Run HTTP compliance tests: `prove -l t/10-http-compliance.t`
5. Run full test suite: `prove -l t/`

**Verification:**
- [ ] HTTP compliance tests pass
- [ ] Keep-alive behavior unchanged (test with curl -v)

### Step 2.6: Refactor _create_send() Keep-Alive Check

**Sub-steps:**
1. Locate the HTTP/1.0 keep-alive check in `_create_send()` (around line 648-655)
2. Pass the cached `client_wants_keepalive` value instead of scanning headers
3. Remove the header loop from _create_send
4. Run full test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] HTTP/1.0 keep-alive still works

### Step 2.7: Benchmark and Report

**Sub-steps:**
1. Run full test suite: `prove -l t/`
2. Run PAGI::Server benchmark
3. Run PAGI::Simple benchmark
4. Document cumulative improvement (Phase 1 + Phase 2)

**Verification:**
- [ ] All tests pass
- [ ] Benchmark shows improvement
- [ ] Report results to user for approval before proceeding to Phase 3

---

## Phase 3: Reusable Send Closure

**Risk Level:** Medium-High
**Expected Improvement:** 10-20%
**Files Modified:** `lib/PAGI/Server/Connection.pm`

Currently, `_create_send()` creates a new async closure for every request. This closure captures request-specific state. We'll refactor to reuse the closure while carefully managing state.

### Step 3.1: Analyze Current State Management

**Sub-steps:**
1. Document all state captured by `_create_send()` closure:
   - `$chunked`, `$response_started`, `$expects_trailers`, `$body_complete`
   - `$is_head_request`, `$http_version`, `$is_http10`, `$client_wants_keepalive`
2. Identify which state is connection-level vs request-level
3. Design new state management approach using instance fields
4. Write design notes in this document

**Verification:**
- [ ] All closure state documented
- [ ] Clear plan for state isolation between requests

### Step 3.2: Add Request State Fields to Connection

**Sub-steps:**
1. Add new instance fields for request state:
   - `_send_chunked`, `_send_response_started`, `_send_expects_trailers`, `_send_body_complete`
   - `_send_is_head`, `_send_http_version`, `_send_is_http10`, `_send_keepalive`
2. Initialize all fields to safe defaults in constructor
3. Run test suite to verify no impact: `prove -l t/`
4. Verify fields are accessible

**Verification:**
- [ ] Tests pass
- [ ] New fields exist and are initialized

### Step 3.3: Create State Reset Method

**Sub-steps:**
1. Create new method `_reset_send_state($request, $header_info)`
2. Implement state initialization from request data
3. Call this method at the start of request handling (in `_try_handle_request`)
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] State is properly reset between requests

### Step 3.4: Create Connection-Level Send Closure

**Sub-steps:**
1. Create new method `_init_send_handler()` called from `start()`
2. Create the async closure once, storing in `$self->{send_handler}`
3. Closure reads state from instance fields instead of captured lexicals
4. Keep old `_create_send()` temporarily for comparison
5. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] Send handler created once per connection

### Step 3.5: Update _handle_request() to Use Reusable Handler

**Sub-steps:**
1. Modify `_handle_request()` to call `_reset_send_state()` before processing
2. Pass `$self->{send_handler}` instead of calling `_create_send()`
3. Verify state isolation with a test that makes multiple requests on same connection
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] Keep-alive requests work correctly
- [ ] No state leakage between requests

### Step 3.6: Update WebSocket and SSE Send Handlers

**Sub-steps:**
1. Review if WebSocket/SSE need similar treatment
2. Update `_handle_websocket_request()` if applicable
3. Update `_handle_sse_request()` if applicable
4. Run WebSocket and SSE tests: `prove -l t/03-websocket.t t/05-sse.t`

**Verification:**
- [ ] WebSocket tests pass
- [ ] SSE tests pass

### Step 3.7: Remove Old _create_send() and Clean Up

**Sub-steps:**
1. Remove the old `_create_send()` method
2. Update any remaining callers
3. Clean up any dead code
4. Run full test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] No references to old method remain

### Step 3.8: Stress Test for State Leakage

**Sub-steps:**
1. Create a test that sends 1000 requests over a single keep-alive connection
2. Vary request types (GET, POST, HEAD) and verify correct responses
3. Test pipelining (multiple requests before reading responses)
4. Run the stress test multiple times

**Verification:**
- [ ] All responses correct
- [ ] No state leakage detected
- [ ] Memory usage stable

### Step 3.9: Benchmark and Report

**Sub-steps:**
1. Run full test suite: `prove -l t/`
2. Run PAGI::Server benchmark
3. Run PAGI::Simple benchmark
4. Document cumulative improvement (Phases 1-3)

**Verification:**
- [ ] All tests pass
- [ ] Benchmark shows significant improvement
- [ ] Report results to user for approval before proceeding to Phase 4

---

## Phase 4: Fast Path for Simple Responses

**Risk Level:** Medium
**Expected Improvement:** 10-15%
**Files Modified:** `lib/PAGI/Server/Connection.pm`, `lib/PAGI/Server/Protocol/HTTP1.pm`

When an application sends a complete response with Content-Length in a single `http.response.body` event, we can bypass chunked encoding logic and serialize the entire response at once.

### Step 4.1: Define Fast Path Criteria

**Sub-steps:**
1. Document criteria for fast path eligibility:
   - Response has Content-Length header
   - Single `http.response.body` event with `more_body: false`
   - Not a HEAD request (body must be sent)
   - HTTP/1.1 (not HTTP/1.0 with connection close edge cases)
2. Identify where in the code to detect fast path eligibility
3. Design the fast path code flow
4. Document edge cases that must still use normal path

**Verification:**
- [ ] Clear criteria documented
- [ ] Edge cases identified

### Step 4.2: Create Fast Response Serialization Method

**Sub-steps:**
1. Add new method to Protocol/HTTP1.pm: `serialize_complete_response($status, $headers, $body)`
2. Method builds entire HTTP response as single string
3. Include Date header and Server header
4. Add unit test for new method
5. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] New method produces valid HTTP responses

### Step 4.3: Add Fast Path Detection in Send Handler

**Sub-steps:**
1. In the send handler, after receiving `http.response.start`, check if Content-Length present
2. Store the status and headers temporarily instead of writing immediately
3. Add flag `_send_can_fast_path` to track eligibility
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] Fast path detection works correctly

### Step 4.4: Implement Fast Path in Response Body Handler

**Sub-steps:**
1. In `http.response.body` handling, check if fast path eligible
2. If eligible and `more_body: false`, use `serialize_complete_response()`
3. Write entire response in single `$stream->write()` call
4. If not eligible, fall back to normal path
5. Run test suite: `prove -l t/`

**Verification:**
- [ ] Tests pass
- [ ] Fast path used when applicable

### Step 4.5: Add Fast Path Tests

**Sub-steps:**
1. Create test for simple response (fast path should be used)
2. Create test for chunked response (normal path should be used)
3. Create test for HEAD request (fast path should NOT be used for body)
4. Create test for streaming response (normal path should be used)
5. Run new tests and full suite: `prove -l t/`

**Verification:**
- [ ] All new tests pass
- [ ] All existing tests pass

### Step 4.6: Add Metrics/Logging for Fast Path Usage

**Sub-steps:**
1. Add debug-level logging when fast path is used
2. Add debug-level logging when falling back to normal path
3. Verify logging works with `--log-level debug`
4. Run test suite: `prove -l t/`

**Verification:**
- [ ] Logging works correctly
- [ ] Tests pass

### Step 4.7: Verify Both Paths Produce Identical Output

**Sub-steps:**
1. Create a test that captures raw HTTP response from fast path
2. Create equivalent test for normal path (forced by using chunked)
3. Compare response headers and body (excluding Date which may differ)
4. Ensure identical behavior for all status codes (200, 201, 404, 500, etc.)

**Verification:**
- [ ] Both paths produce valid, equivalent responses
- [ ] No behavioral differences

### Step 4.8: Final Benchmark and Report

**Sub-steps:**
1. Run full test suite: `prove -l t/`
2. Run PAGI::Server benchmark (should show most improvement)
3. Run PAGI::Simple benchmark
4. Document final cumulative improvement (all phases)
5. Compare to raw IO::Async baseline

**Verification:**
- [ ] All tests pass
- [ ] Significant performance improvement achieved
- [ ] Report final results to user

---

## Progress Tracking

### Phase 1: Cache Connection Info
- [ ] Step 1.1: Add Connection Info Fields to Constructor
- [ ] Step 1.2: Extract Socket Info in start() Method
- [ ] Step 1.3: Update _create_scope() to Use Cached Values
- [ ] Step 1.4: Update WebSocket and SSE Scope Creation
- [ ] Step 1.5: Benchmark and Report
- **Status:** Not Started
- **Approval:** Pending

### Phase 2: Single Header Pass
- [ ] Step 2.1: Create Header Info Extraction Helper
- [ ] Step 2.2: Update _try_handle_request() to Use Header Info
- [ ] Step 2.3: Refactor _is_websocket_upgrade() to Use Cached Info
- [ ] Step 2.4: Refactor _is_sse_request() to Use Cached Info
- [ ] Step 2.5: Refactor _should_keep_alive() to Use Cached Info
- [ ] Step 2.6: Refactor _create_send() Keep-Alive Check
- [ ] Step 2.7: Benchmark and Report
- **Status:** Not Started
- **Approval:** Pending

### Phase 3: Reusable Send Closure
- [ ] Step 3.1: Analyze Current State Management
- [ ] Step 3.2: Add Request State Fields to Connection
- [ ] Step 3.3: Create State Reset Method
- [ ] Step 3.4: Create Connection-Level Send Closure
- [ ] Step 3.5: Update _handle_request() to Use Reusable Handler
- [ ] Step 3.6: Update WebSocket and SSE Send Handlers
- [ ] Step 3.7: Remove Old _create_send() and Clean Up
- [ ] Step 3.8: Stress Test for State Leakage
- [ ] Step 3.9: Benchmark and Report
- **Status:** Not Started
- **Approval:** Pending

### Phase 4: Fast Path for Simple Responses
- [ ] Step 4.1: Define Fast Path Criteria
- [ ] Step 4.2: Create Fast Response Serialization Method
- [ ] Step 4.3: Add Fast Path Detection in Send Handler
- [ ] Step 4.4: Implement Fast Path in Response Body Handler
- [ ] Step 4.5: Add Fast Path Tests
- [ ] Step 4.6: Add Metrics/Logging for Fast Path Usage
- [ ] Step 4.7: Verify Both Paths Produce Identical Output
- [ ] Step 4.8: Final Benchmark and Report
- **Status:** Not Started
- **Approval:** Pending

---

## Expected Results

| Phase | Expected Improvement | Cumulative |
|-------|---------------------|------------|
| Baseline | ~4,000 req/sec | - |
| Phase 1 | +5-10% | ~4,200-4,400 |
| Phase 2 | +5-10% | ~4,600-4,800 |
| Phase 3 | +10-20% | ~5,500-6,000 |
| Phase 4 | +10-15% | ~6,500-7,500 |

**Target:** Get within 50-65% of raw IO::Async performance (~7,500-8,500 req/sec)

---

## Rollback Plan

If any phase introduces regressions that cannot be quickly resolved:

1. `git stash` or `git checkout` to revert changes
2. Document the issue encountered
3. Discuss with user before attempting alternative approach

Each phase should be committed separately to allow easy rollback.
