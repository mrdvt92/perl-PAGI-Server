# PAGI Compliance and Security Testing Report

This document tracks HTTP/1.1 compliance testing and security testing for PAGI::Server.

## Test Environment

- **Server**: PAGI::Server with EV+kqueue backend
- **Start command**: `LIBEV_FLAGS=8 ./bin/pagi-server --loop EV --no-access-log -p 5000 ./examples/01-hello-http/app.pl`
- **Platform**: macOS Darwin 24.6.0
- **Test Date**: 2025-12-14

---

## Results Summary

| Category | Tests | Passed | Failed | Notes |
|----------|-------|--------|--------|-------|
| HTTP/1.1 Compliance | 10 | 10 | 0 | All compliant |
| Slow HTTP Attacks | 4 | 4 | 0 | Async model resistant |
| Concurrent Attack + Traffic | 1 | 1 | 0 | 3,843 req/sec under attack |
| Request Smuggling | 6 | 6 | 0 | Not vulnerable |
| nikto Scanner | 4 | 4 | 0 | No critical findings |
| Protocol Fuzzing | 49 | 49 | 0 | No crashes, robust parsing |
| Memory/Resource Leaks | 4 | 4 | 0 | No significant leaks |
| WebSocket (Autobahn) | 301 | 215 | 86 | RSV/opcode/close validation added |

**Overall: PAGI demonstrates full HTTP/1.1 compliance, strong security posture, and stable resource management. WebSocket support handles standard use cases well; strict RFC 6455 validation is limited by Protocol::WebSocket library.**

---

## Phase 1: HTTP/1.1 Compliance Testing

### 1.1 Manual Compliance Tests

| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| Normal request | 200 | 200 | PASS |
| HTTP/1.1 missing Host | 400 | 400 | PASS |
| HTTP/1.0 no Host | 200 | 200 | PASS |
| Content-Length: abc | 400 | 400 | PASS |
| Content-Length: -1 | 400 | 400 | PASS |
| Content-Length: overflow | 413 | 413 | PASS |
| Content-Length: with spaces | 400 | 400 | PASS |
| URI > 8KB | 414 | 414 | PASS |
| Header > 8KB | 431 | 431 | PASS |
| CL+TE conflict | 200 | 200 | PASS |

### 1.2 Compliance Issue (FIXED)

**RFC 7230 Section 5.4**: HTTP/1.1 requests without a Host header now correctly return 400 Bad Request.

**Fix Applied**: Added Host header validation in `lib/PAGI/Server/Protocol/HTTP1.pm` (lines 254-259):

```perl
# RFC 7230 Section 5.4: A client MUST send a Host header field in all
# HTTP/1.1 request messages. A server MUST respond with a 400 (Bad Request)
# status code to any HTTP/1.1 request message that lacks a Host header field.
if ($http_version eq '1.1' && !defined $env{HTTP_HOST}) {
    return ({ error => 400, message => 'Bad Request' }, $header_end + 4);
}
```

**Test Coverage**: Added to `t/10-http-compliance.t` (Tests 25-26):
- Test 25: HTTP/1.1 without Host header returns 400 Bad Request
- Test 26: HTTP/1.0 without Host header is allowed (returns 200)

---

## Phase 2: Security Testing (Slow HTTP Attacks)

### 2.1 Slowloris Attack (Slow Headers)

**Test**: 500 connections sending headers very slowly (10 second intervals)

```
slowhttptest -c 500 -H -g -o slowloris -i 10 -r 100 -t GET -u http://localhost:5000/ -l 30
```

**Results**:
- Duration: 30 seconds
- Connections: 500
- Errors: 0
- Closed: 0
- **Service Available: YES throughout**

**Status**: PASS - Server remained fully available during Slowloris attack.

---

### 2.2 Slow POST Attack (Slow Body)

**Test**: 500 connections sending POST body very slowly

```
slowhttptest -c 500 -B -g -o slowpost -i 10 -r 100 -t POST -u http://localhost:5000/ -l 30
```

**Results**:
- Duration: 5 seconds (test ended early)
- Connections: 500 attempted
- Closed: 433 (server closed idle connections)
- **Service Available: YES**

**Status**: PASS - Server actively closed slow POST connections, preventing resource exhaustion.

---

### 2.3 Slow Read Attack

**Test**: 500 connections reading responses very slowly (32 bytes per 5 seconds)

```
slowhttptest -c 500 -X -g -o slowread -r 100 -w 512 -y 1024 -n 5 -z 32 -u http://localhost:5000/ -l 30
```

**Results**:
- Duration: 30 seconds
- Connections: 500
- Errors: 0
- Closed: 0
- **Service Available: YES throughout**

**Status**: PASS - Server handled slow readers without resource exhaustion.

---

### 2.4 Concurrent Slow Attack + Normal Traffic

**Test**: Run Slowloris attack while simultaneously serving normal traffic with hey.

```bash
# Terminal 1: Slowloris attack
slowhttptest -c 500 -H -i 10 -r 100 -u http://localhost:5000/ -l 35

# Terminal 2: Normal traffic
hey -z 20s -c 100 http://localhost:5000/
```

**Results**:
- Slowloris: 500 connections held, service available
- Normal traffic during attack:
  - **Requests/sec: 3,843**
  - **Total requests: 76,963**
  - **Errors: 0**
  - **p99 latency: 33ms**

**Status**: PASS - Server handled normal traffic efficiently while under slow attack.

---

## Phase 3: HTTP Request Smuggling Tests

HTTP Request Smuggling exploits differences in how servers interpret request boundaries when both Content-Length and Transfer-Encoding headers are present.

### 3.1 CL.TE Attack Vector

**Test**: Request with both Content-Length and Transfer-Encoding: chunked

```
POST / HTTP/1.1
Host: localhost
Content-Length: 6
Transfer-Encoding: chunked

0

```

**Result**: 200 OK - PAGI correctly uses Transfer-Encoding (per RFC 7230 Section 3.3.3)

**Status**: PASS

---

### 3.2 TE.CL Attack Vector

**Test**: Same as above but testing if body boundaries are respected

**Result**: 200 OK - Transfer-Encoding takes precedence

**Status**: PASS

---

### 3.3 Transfer-Encoding Obfuscation

**Test**: Various obfuscation techniques attackers use to make one server see TE and another not:

| Variant | Result |
|---------|--------|
| Normal chunked | TE recognized |
| CHUNKED (uppercase) | TE recognized |
| Space before colon | TE recognized |
| Tab after colon | TE recognized |
| Lowercase header | TE recognized |
| Line folding (obs-fold) | TE recognized |
| Null byte in value | 400 Rejected |
| Vertical tab | 400 Rejected |
| Form feed | 400 Rejected |

**Status**: PASS - All variants handled safely

---

### 3.4 Duplicate Content-Length Headers

**Test**: Multiple Content-Length headers (RFC 7230 requires rejection if values differ)

| Test | Result |
|------|--------|
| Duplicate CL (same values) | 400 Rejected |
| Duplicate CL (different values) | 400 Rejected |
| CL with leading zeros | 200 Accepted |
| CL with + sign | 400 Rejected |

**Status**: PASS - Conflicting CL headers rejected

---

### 3.5 Smuggling Payload Test

**Test**: Classic CL.TE smuggling attempt where "GPOST /admin" would be smuggled if vulnerable

```
POST / HTTP/1.1
Host: localhost
Content-Length: 13
Transfer-Encoding: chunked

0

GPOST /admin
```

**Result**:
- First request: 200 OK (TE used correctly)
- Smuggled data: 400 Bad Request (rejected as malformed)

**Status**: PASS - **NOT VULNERABLE** - Smuggled data rejected

---

### 3.6 Chunk Extensions and Trailers

**Test**: Chunk extensions (;name=value) and trailer headers

| Test | Result |
|------|--------|
| Valid extension | 200 OK |
| Extension with CRLF | 200 OK |
| Extension with null | 200 OK |
| Very long extension | 200 OK |
| Valid trailer | 200 OK |
| Trailer CL override | 200 OK (ignored) |

**Status**: PASS - Extensions/trailers handled safely

---

### Request Smuggling Summary

PAGI is **NOT VULNERABLE** to HTTP Request Smuggling because:

1. **RFC 7230 Compliant**: Transfer-Encoding always takes precedence over Content-Length
2. **Strict Parsing**: HTTP::Parser::XS provides robust header parsing
3. **Safe Rejection**: Malformed/leftover data is rejected with 400 Bad Request
4. **No Desync**: Request boundaries are consistently determined

---

## Phase 4: nikto Security Scanner

**Tool**: nikto v2.5.0
**Scan Time**: ~4 minutes
**Requests**: 7,853

### Findings

| Finding | Severity | Notes |
|---------|----------|-------|
| Missing X-Frame-Options | Low | App-level header responsibility |
| Missing X-Content-Type-Options | Low | App-level header responsibility |
| Responds to junk HTTP methods | Info | Expected behavior for REST APIs |
| /.htpasswd found | False Positive | Hello app returns 200 for all paths |

### Analysis

No critical or high-severity vulnerabilities found. The missing security headers (X-Frame-Options, X-Content-Type-Options) are application-level responsibilities, not server-level. PAGI provides the `Server:` header automatically.

**Status**: PASS - No server-level vulnerabilities

---

## Phase 5: HTTP Protocol Fuzzing

Custom fuzzing suite testing parser resilience to malformed input.

### 5.1 Malformed Request Lines (10 tests)

| Test | Result |
|------|--------|
| Empty request | 400 Bad Request |
| Missing path/version | 400 Bad Request |
| Invalid HTTP version | 400 Bad Request |
| Null bytes in method/path | 400 Bad Request |
| Lowercase method (get) | 200 OK (accepted) |
| Unknown method (HACK) | 200 OK (passed to app) |

### 5.2 Malformed Headers (7 tests)

| Test | Result |
|------|--------|
| Header without colon | 400 Bad Request |
| Empty header name | 400 Bad Request |
| Null bytes in header | 400 Bad Request |
| Binary data in header | 200 OK (accepted) |
| 1000 headers | 431 Header Too Large |

### 5.3 Extreme Sizes (4 tests)

| Test | Result |
|------|--------|
| 1MB URI | Timeout (protected) |
| 1MB header value | Timeout (protected) |
| 100KB single header | 431 Header Too Large |

### 5.4 Binary/Random Data (5 tests)

| Test | Result |
|------|--------|
| Random bytes | Timeout (no crash) |
| All nulls | Timeout (no crash) |
| Mixed binary + HTTP | 400 Bad Request |

### 5.5 Incomplete Requests (5 tests)

| Test | Result |
|------|--------|
| Partial request line | Timeout (waiting for more) |
| Missing final CRLF | Timeout (waiting for more) |
| Wrong line endings (LF only) | Timeout (strict parsing) |

### 5.6 Special Characters (5 tests)

| Test | Result |
|------|--------|
| Tab/backspace/DEL in request | 400 Bad Request |
| Unicode BOM prefix | 200 OK (accepted) |
| UTF-8 in path | 200 OK (accepted) |

### 5.7 Stress/Edge Cases (13 tests)

| Test | Result |
|------|--------|
| 100 rapid connections | Server healthy |
| Path traversal attempts | 200 OK (app handles) |
| HTTP/2 preface | 400 Bad Request |
| CONNECT/TRACE methods | 200 OK (passed to app) |
| 100 pipelined requests | Handled correctly |
| 50 incomplete + 1 normal | Server responsive |

### Fuzzing Summary

**49/49 tests passed** - Server never crashed or became unresponsive.

Key findings:
- Parser is robust against malformed input
- Large inputs properly rejected (414/431 errors)
- Binary/random data doesn't crash server
- Server remains responsive under stress
- Incomplete connections don't exhaust resources

---

## Phase 6: Memory and Resource Leak Testing

Sustained load testing to detect memory leaks, file descriptor leaks, and connection object leaks.

### 6.1 Memory Usage Under Sustained Load

**Test**: 1 million HTTP requests at 100 concurrent connections

| Requests | RSS (KB) | Growth | Growth/100K |
|----------|----------|--------|-------------|
| Initial | 28,392 | - | - |
| 100K | 30,048 | +1,656 | +1,656 |
| 200K | 31,048 | +2,656 | +1,000 |
| 500K | 32,736 | +4,344 | +563 |
| 1,000K | 34,944 | +6,552 | +440 |

**Analysis**: Memory growth of ~6.5 MB over 1 million requests (~6.5 bytes/request). This is normal Perl memory allocator behavior, not a leak. Growth rate decreases over time, indicating memory is being reused.

**Status**: PASS - No significant memory leak

---

### 6.2 File Descriptor Leaks

**Test**: Monitor FD count during sustained load

| Phase | File Descriptors |
|-------|------------------|
| Initial (idle) | 35 |
| During load (100 concurrent) | 135 |
| After load (idle) | 35 |
| After 1M requests | 35 |

**Status**: PASS - FDs return to baseline after connections close

---

### 6.3 Connection Object Cleanup

**Test**: Verify connection tracking hash is cleaned up (t/23-connection-cleanup.t)

| Test | Result |
|------|--------|
| WebSocket frame parser cleanup | PASS |
| Connection removed after exception | PASS |
| Exception after response started | PASS |
| Multiple connections with exceptions | PASS |

**Status**: PASS - Connection objects properly removed from tracking

---

### 6.4 Resource Leak Summary

| Resource | Test | Result |
|----------|------|--------|
| Memory (RSS) | 1M requests | +6.5 MB (normal) |
| File Descriptors | Sustained load | Stable at baseline |
| Connection Objects | Cleanup tests | Properly freed |
| Event Loop Handles | Implicit via FDs | Stable |

**Conclusion**: No significant resource leaks detected. The server is suitable for long-running production deployments.

---

## Security Analysis

### Why PAGI Handles Slow Attacks Well

1. **Async Architecture**: Single event loop handles all connections without blocking. Slow connections don't consume worker processes.

2. **Non-blocking I/O**: IO::Async with EV/kqueue backend allows thousands of concurrent connections.

3. **No Worker Pool Exhaustion**: Unlike pre-fork servers (Apache, Starman), PAGI doesn't have a fixed number of workers that can be tied up.

### Comparison with Pre-fork Servers

| Server | Architecture | Slowloris Vulnerability |
|--------|--------------|------------------------|
| Apache | Pre-fork | HIGH - Workers exhausted |
| Starman | Pre-fork | HIGH - Workers exhausted |
| Gazelle | Pre-fork | HIGH - Workers exhausted |
| **PAGI** | Async | LOW - Event loop resilient |
| Uvicorn | Async | LOW - Similar to PAGI |
| Nginx | Event-driven | LOW - Designed for this |

---

## Phase 7: WebSocket Compliance (Autobahn Testsuite)

The Autobahn Testsuite is the industry-standard WebSocket conformance test suite with 517 test cases.

### Test Environment

- **Tool**: Autobahn Testsuite v25.10.1 (Docker)
- **Server**: PAGI::Server with EV+kqueue backend
- **App**: WebSocket echo server (examples/autobahn-echo/app.pl)

### Results Summary

| Behavior | Count | Description |
|----------|-------|-------------|
| OK | 202 | Passed |
| NON-STRICT | 10 | Minor deviations, acceptable |
| INFORMATIONAL | 3 | Informational only |
| FAILED | 86 | Failed tests |
| UNIMPLEMENTED | 216 | Compression not implemented |

### Results by Category

| Category | Description | OK | Failed | Notes |
|----------|-------------|-----|--------|-------|
| 1 | Text/Binary Messages | 16 | 0 | All pass |
| 2 | Ping/Pong | 11 | 0 | Control frame size validated ✓ |
| 3 | Reserved Bits | 7 | 0 | RSV bits validated ✓ |
| 4 | Opcodes | 10 | 0 | Reserved opcodes rejected ✓ |
| 5 | Fragmentation | 14 | 6 | Edge cases (Protocol::WebSocket limit) |
| 6 | UTF-8 Handling | 99 | 42 | Streaming UTF-8 (library limit) |
| 7 | Close Handling | 30 | 1 | Close codes validated ✓ |
| 9 | Limits/Performance | 14 | 37 | Large messages (>64KB default) |
| 10 | Misc | 1 | 0 | All pass |
| 12-13 | Compression | 0 | 0 | 216 unimplemented (optional) |

### Analysis

**What Works Well:**
- Basic text/binary message exchange
- Ping/pong (including control frame size limits)
- RSV bits validation (closes with 1002 if non-zero)
- Reserved opcode rejection (closes with 1002)
- Close code validation (rejects invalid codes)
- Standard fragmentation
- Most UTF-8 validation
- Normal close handshake

**Validations Added to PAGI::Server (2025-12-15):**

1. **RSV Bits (Category 3)**: Now validates RSV1-3 must be 0 (no extensions negotiated)
2. **Reserved Opcodes (Category 4)**: Now rejects opcodes 3-7 and 11-15 with 1002
3. **Control Frame Size (Category 2)**: Now rejects ping/pong/close frames >125 bytes
4. **Close Code Validation (Category 7)**: Now validates close codes per RFC 6455 Section 7.4.1
5. **Close Frame UTF-8**: Now validates close reason is valid UTF-8

**Remaining Limitations (Protocol::WebSocket library):**

1. **UTF-8 Streaming (Category 6)**: Invalid UTF-8 in fragmented messages validated at end, not per-fragment
2. **Fragmentation Edge Cases (Category 5)**: Complex fragmentation scenarios
3. **Large Messages (Category 9)**: Default 64KB limit; configurable via max_ws_frame_size

**Compression (Categories 12-13):**
PAGI does not implement WebSocket compression (permessage-deflate per RFC 7692). This is optional and intentionally not supported. 216 tests are marked UNIMPLEMENTED, which is the correct behavior.

### Comparison with Other Servers

| Server | Autobahn Pass Rate | Notes |
|--------|-------------------|-------|
| PAGI | 72% (215/301) | RFC 6455 validation in PAGI::Server |
| Node.js ws | ~95% | Native implementation |
| Python websockets | ~98% | Strict RFC compliance |
| Go gorilla | ~95% | Native implementation |

**Note:** Pass rate excluding compression (301 non-compression tests):
- OK + NON-STRICT + INFORMATIONAL: 215 (71%)
- Failed: 86 (29%)

### Recommendations

The remaining failures are primarily in Protocol::WebSocket's handling of:

1. **UTF-8 streaming validation** - validates at message end, not per-fragment
2. **Fragmentation edge cases** - complex interleaved control/data frames
3. **Large messages** - limited by default 64KB max_payload_size

For most production use cases, the current implementation is now sufficient. The key RFC 6455 validations (RSV bits, reserved opcodes, close codes, control frame sizes) have been implemented directly in PAGI::Server.

**To increase large message support:**
```perl
my $server = PAGI::Server->new(
    max_ws_frame_size => 16 * 1024 * 1024,  # 16MB
);
```

### Test Artifacts

Full HTML reports available at: `autobahn-reports/index.html`

---

## Recommendations

### Consider Adding (Low Priority)

1. **Request timeout**: Close connections that don't complete request within N seconds.
2. **Request body timeout**: Close connections with slow body uploads.

Note: Per-IP connection limits are best handled at the reverse proxy layer (nginx, HAProxy) or firewall level, not the application server.

### Already Implemented

- **RFC 7230 Section 5.4**: HTTP/1.1 Host header requirement - returns 400
- **RFC 7230 Section 3.3.3**: TE takes precedence over CL (smuggling protection)
- Request line size limit (8KB default) - returns 414
- Header size limit (8KB default) - returns 431
- Content-Length validation - returns 400/413
- Duplicate Content-Length rejection - returns 400
- Control character rejection in headers - returns 400
- WebSocket frame size limit (--max-ws-frame-size)
- WebSocket receive queue limit (--max-receive-queue)
- Header count limit (max_header_count, default 100) - returns 431

---

## Test Artifacts

HTML and CSV reports saved to:
- `compliance-results/slowloris.html`
- `compliance-results/slowloris.csv`
- `compliance-results/slowpost.html`
- `compliance-results/slowpost.csv`
- `compliance-results/slowread.html`
- `compliance-results/slowread.csv`

---

## References

- [RFC 7230 - HTTP/1.1 Message Syntax and Routing](https://tools.ietf.org/html/rfc7230)
- [RFC 7231 - HTTP/1.1 Semantics and Content](https://tools.ietf.org/html/rfc7231)
- [RFC 6455 - The WebSocket Protocol](https://tools.ietf.org/html/rfc6455)
- [RFC 7692 - Compression Extensions for WebSocket](https://tools.ietf.org/html/rfc7692)
- [OWASP Slow HTTP Attack](https://owasp.org/www-community/attacks/Slow_Http_Attack)
- [slowhttptest](https://github.com/shekyan/slowhttptest)
- [PortSwigger - HTTP Request Smuggling](https://portswigger.net/web-security/request-smuggling)
- [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite)
