---
name: pagi-development
description: Use when writing raw PAGI applications, understanding PAGI spec, or debugging PAGI code. Covers HTTP, WebSocket, SSE, and Lifespan protocols.
---

# PAGI Development Skill

This skill teaches how to write raw PAGI (Perl Asynchronous Gateway Interface) applications. PAGI is an async-native successor to PSGI supporting HTTP, WebSocket, SSE, and lifecycle management.

## When to Use This Skill

- Writing a new raw PAGI application
- Understanding PAGI scope types and events
- Debugging PAGI protocol issues
- Converting PSGI apps to PAGI

## Core Application Interface

Every PAGI application is an async coderef with this signature:

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    # $scope   - HashRef with connection metadata
    # $receive - Async coderef returning event HashRefs
    # $send    - Async coderef accepting event HashRefs
}
```

### The Three Parameters

**$scope** - Connection metadata (read-only):
- `type` - Protocol: `"http"`, `"websocket"`, `"sse"`, `"lifespan"`
- `pagi` - HashRef with `version` and `spec_version`
- Protocol-specific keys (path, method, headers, etc.)

**$receive** - Get events from client/server:
```perl
my $event = await $receive->();
# Returns HashRef with 'type' key
```

**$send** - Send events to client:
```perl
await $send->({ type => 'http.response.start', status => 200, ... });
```

### Required Error Handling

Apps MUST reject unsupported scope types:

```perl
async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}"
        unless $scope->{type} eq 'http';
    # ... handle request
}
```

### File Structure

PAGI apps are typically loaded via `do`:

```perl
# app.pl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

my $app = async sub ($scope, $receive, $send) {
    # ... implementation
};

$app;  # Return coderef when loaded
```

Run with: `pagi-server ./app.pl --port 5000`
