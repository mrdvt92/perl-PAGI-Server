# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PAGI (Perl Asynchronous Gateway Interface) is a specification for asynchronous Perl web applications, designed as a spiritual successor to PSGI. It defines a standard interface between async-capable Perl web servers, frameworks, and applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

This repository contains:
- The PAGI specification documents (`docs/`)
- Reference example applications (`examples/`)
- A reference server implementation (`lib/PAGI/Server.pm`) - **in development**

## Implementation Guide

**Read `app_spec.txt` before implementing.** It contains the complete implementation plan including:
- Module structure and architecture
- 12 iterative implementation steps
- Acceptance criteria for each step
- Design principles (fully async, event-driven, no blocking)

### Development Workflow

Implementation follows a strict iterative review process:
1. Implement one step at a time (each step corresponds to an example app)
2. Write tests that verify the target example runs correctly
3. Ensure all acceptance criteria are met
4. **STOP** and wait for review before proceeding
5. Only after approval, proceed to the next step

### Commands

```bash
# Install dependencies
cpanm --installdeps .

# Run tests
prove -l t/

# Run a specific test
prove -lv t/01-hello-http.t

# Build distribution
dzil build

# Run the server (once implemented)
perl -Ilib bin/pagi-server --app examples/01-hello-http/app.pl --port 5000
```

## Architecture

### Core Concepts

PAGI applications are async coderefs with this signature:

```perl
async sub app ($scope, $receive, $send) { ... }
```

- **`$scope`**: Hashref containing connection metadata (type, headers, path, etc.)
- **`$receive`**: Async coderef returning a Future that resolves to the next event
- **`$send`**: Async coderef taking an event hashref, returning a Future

### Protocol Types

Applications dispatch on `$scope->{type}`:
- `http` — HTTP request/response (one scope per request)
- `websocket` — Persistent WebSocket connection
- `sse` — Server-Sent Events stream
- `lifespan` — Process startup/shutdown lifecycle

### Event Flow

Events are hashrefs with a `type` key following `protocol.message_type` convention:
- HTTP: `http.request`, `http.response.start`, `http.response.body`, `http.disconnect`
- WebSocket: `websocket.connect`, `websocket.accept`, `websocket.receive`, `websocket.send`, `websocket.close`
- SSE: `sse.start`, `sse.send`, `sse.disconnect`
- Lifespan: `lifespan.startup`, `lifespan.startup.complete`, `lifespan.shutdown`, `lifespan.shutdown.complete`

### Extensions

Server capabilities are advertised in `$scope->{extensions}`. Check before using:
- `tls` — TLS connection metadata (certs, cipher suite, version)
- `fullflush` — Force immediate flush of buffered data

## Repository Structure

```
PAGI/
├── app_spec.txt           # Implementation specification (READ THIS)
├── cpanfile               # Perl dependencies
├── dist.ini               # Dist::Zilla configuration
├── docs/                  # PAGI specification documents
│   ├── specs/
│   │   ├── main.mkdn      # Core PAGI specification
│   │   ├── www.mkdn       # HTTP, WebSocket, SSE protocol spec
│   │   ├── lifespan.mkdn  # Lifecycle events spec
│   │   └── tls.mkdn       # TLS extension spec
│   └── extensions.mkdn    # Extension registry
├── examples/              # Reference PAGI applications (test targets)
│   ├── 01-hello-http/
│   ├── 02-streaming-response/
│   ├── ...
│   └── 09-psgi-bridge/
├── lib/                   # Server implementation (to be built)
│   └── PAGI/
│       ├── Server.pm
│       └── Server/
│           ├── Connection.pm
│           ├── Protocol/
│           │   └── HTTP1.pm
│           └── ...
├── bin/
│   └── pagi-server        # CLI launcher
└── t/                     # Tests (one per example)
    ├── 01-hello-http.t
    ├── 02-streaming.t
    └── ...
```

## Key Dependencies

- Perl 5.32+ (for signature syntax)
- `IO::Async` — event loop and networking
- `Future::AsyncAwait` — async/await support
- `HTTP::Parser::XS` — HTTP/1.1 parsing (isolated in Protocol::HTTP1)
- `Protocol::WebSocket` — WebSocket frame parsing (low-level, not Net::Async::WebSocket::Server)
- `IO::Async::SSL` — TLS termination

## Writing PAGI Applications

Basic HTTP response pattern:

```perl
async sub app ($scope, $receive, $send) {
    die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({ type => 'http.response.start', status => 200, headers => [...] });
    await $send->({ type => 'http.response.body', body => $content, more => 0 });
}
```

Applications MUST throw an exception for unsupported `$scope->{type}` values.

## Middleware Pattern

Middleware wraps applications, must not mutate original `$scope`:

```perl
sub middleware ($app) {
    return async sub ($scope, $recv, $send) {
        my $modified_scope = { %$scope, custom => 1 };
        await $app->($modified_scope, $recv, $send);
    };
}
```
