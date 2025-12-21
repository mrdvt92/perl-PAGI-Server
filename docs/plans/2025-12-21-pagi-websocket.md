# PAGI::WebSocket Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a `PAGI::WebSocket` convenience wrapper that provides a clean, Starlette-inspired API for WebSocket handling, eliminating raw protocol boilerplate.

**Architecture:** Thin wrapper around PAGI's `($scope, $receive, $send)` interface. Provides state tracking, typed send/receive methods, iteration helpers, and cleanup registration. No external dependencies beyond what PAGI already uses.

**Tech Stack:** Perl 5.16+, Future::AsyncAwait, JSON::PP, Test2::V0

---

## Task 1: Core Module Structure and Constructor

**Files:**
- Create: `lib/PAGI/WebSocket.pm`
- Create: `t/websocket/01-constructor.t`

**Step 1.1: Create test file with constructor tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::WebSocket;

subtest 'constructor accepts scope, receive, send' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/ws',
        query_string => 'token=abc',
        headers      => [
            ['host', 'example.com'],
            ['sec-websocket-protocol', 'chat, echo'],
        ],
        subprotocols => ['chat', 'echo'],
        client       => ['127.0.0.1', 54321],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    ok($ws, 'constructor returns object');
    isa_ok($ws, 'PAGI::WebSocket');
};

subtest 'dies on non-websocket scope type' => sub {
    my $scope = { type => 'http', headers => [] };
    my $receive = sub { };
    my $send = sub { };

    like(
        dies { PAGI::WebSocket->new($scope, $receive, $send) },
        qr/websocket/i,
        'dies with message about websocket'
    );
};

subtest 'dies without required parameters' => sub {
    like(
        dies { PAGI::WebSocket->new() },
        qr/scope/i,
        'dies without scope'
    );

    my $scope = { type => 'websocket', headers => [] };
    like(
        dies { PAGI::WebSocket->new($scope) },
        qr/receive/i,
        'dies without receive'
    );

    my $receive = sub { };
    like(
        dies { PAGI::WebSocket->new($scope, $receive) },
        qr/send/i,
        'dies without send'
    );
};

done_testing;
```

**Step 1.2: Run test to verify it fails**

```bash
prove -l t/websocket/01-constructor.t
```
Expected: FAIL - Can't locate PAGI/WebSocket.pm

**Step 1.3: Create minimal PAGI::WebSocket module**

```perl
package PAGI::WebSocket;
use strict;
use warnings;
use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::WebSocket requires scope hashref" unless $scope;
    croak "PAGI::WebSocket requires receive coderef" unless $receive;
    croak "PAGI::WebSocket requires send coderef" unless $send;
    croak "PAGI::WebSocket requires scope type 'websocket', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'websocket';

    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
        _state  => 'connecting',  # connecting -> connected -> closed
        _close_code   => undef,
        _close_reason => undef,
        _on_close     => [],
    }, $class;
}

1;

__END__

=head1 NAME

PAGI::WebSocket - Convenience wrapper for PAGI WebSocket connections

=head1 SYNOPSIS

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        while (my $msg = await $ws->receive_text) {
            await $ws->send_text("Echo: $msg");
        }
    }

=head1 DESCRIPTION

PAGI::WebSocket provides a clean, high-level API for WebSocket handling,
inspired by Starlette's WebSocket class. It wraps the raw PAGI protocol
and provides:

=over 4

=item * Typed send/receive methods (text, bytes, JSON)

=item * Connection state tracking

=item * Cleanup callback registration

=item * Safe send methods for broadcast scenarios

=item * Message iteration helpers

=back

=cut
```

**Step 1.4: Run test to verify it passes**

```bash
prove -l t/websocket/01-constructor.t
```
Expected: PASS - all tests pass

**Step 1.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/01-constructor.t
git commit -m "$(cat <<'EOF'
feat(websocket): add PAGI::WebSocket module skeleton

Initial module with constructor that validates scope type
and stores receive/send coderefs.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Scope Property Accessors

**Files:**
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `t/websocket/01-constructor.t`

**Step 2.1: Add property accessor tests**

Add to `t/websocket/01-constructor.t`:

```perl
subtest 'scope property accessors' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/chat/room1',
        raw_path     => '/chat/room1',
        query_string => 'token=abc&user=bob',
        scheme       => 'wss',
        http_version => '1.1',
        headers      => [
            ['host', 'example.com'],
            ['origin', 'https://example.com'],
        ],
        subprotocols => ['chat', 'json'],
        client       => ['192.168.1.1', 54321],
        server       => ['example.com', 443],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->path, '/chat/room1', 'path accessor');
    is($ws->raw_path, '/chat/room1', 'raw_path accessor');
    is($ws->query_string, 'token=abc&user=bob', 'query_string accessor');
    is($ws->scheme, 'wss', 'scheme accessor');
    is($ws->http_version, '1.1', 'http_version accessor');
    is($ws->subprotocols, ['chat', 'json'], 'subprotocols accessor');
    is($ws->client, ['192.168.1.1', 54321], 'client accessor');
    is($ws->server, ['example.com', 443], 'server accessor');
    is($ws->scope, $scope, 'scope returns raw scope');
};

subtest 'header accessors' => sub {
    my $scope = {
        type    => 'websocket',
        headers => [
            ['host', 'example.com'],
            ['origin', 'https://example.com'],
            ['cookie', 'session=abc123'],
            ['x-custom', 'value1'],
            ['x-custom', 'value2'],
        ],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->header('host'), 'example.com', 'single header');
    is($ws->header('Host'), 'example.com', 'case-insensitive');
    is($ws->header('x-custom'), 'value2', 'returns last value for duplicates');
    is($ws->header('nonexistent'), undef, 'returns undef for missing');

    my @customs = $ws->header_all('x-custom');
    is(\@customs, ['value1', 'value2'], 'header_all returns all values');

    isa_ok($ws->headers, 'Hash::MultiValue', 'headers returns Hash::MultiValue');
};

subtest 'defaults for optional scope keys' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->raw_path, '/ws', 'raw_path defaults to path');
    is($ws->query_string, '', 'query_string defaults to empty');
    is($ws->scheme, 'ws', 'scheme defaults to ws');
    is($ws->http_version, '1.1', 'http_version defaults to 1.1');
    is($ws->subprotocols, [], 'subprotocols defaults to empty array');
};
```

**Step 2.2: Run test to verify it fails**

```bash
prove -l t/websocket/01-constructor.t
```
Expected: FAIL - Can't locate method "path"

**Step 2.3: Implement property accessors**

Add to `lib/PAGI/WebSocket.pm` after constructor:

```perl
use Hash::MultiValue;

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'ws' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub subprotocols { shift->{scope}{subprotocols} // [] }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}
```

**Step 2.4: Run test to verify it passes**

```bash
prove -l t/websocket/01-constructor.t
```
Expected: PASS

**Step 2.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/01-constructor.t
git commit -m "$(cat <<'EOF'
feat(websocket): add scope property accessors

Adds path, query_string, scheme, headers, subprotocols, client,
server accessors with sensible defaults. Header lookup is
case-insensitive and supports Hash::MultiValue for multi-headers.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Connection State Tracking

**Files:**
- Create: `t/websocket/02-state.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 3.1: Create state tracking tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::WebSocket;

subtest 'initial state is connecting' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    ok(!$ws->is_connected, 'not connected initially');
    ok(!$ws->is_closed, 'not closed initially');
    is($ws->state, 'connecting', 'state is connecting');
    is($ws->close_code, undef, 'close_code is undef');
    is($ws->close_reason, undef, 'close_reason is undef');
};

subtest 'state transitions' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    # Simulate internal state change (normally done by accept)
    $ws->_set_state('connected');
    ok($ws->is_connected, 'is_connected after transition');
    ok(!$ws->is_closed, 'not closed after connect');
    is($ws->state, 'connected', 'state is connected');

    # Simulate close
    $ws->_set_closed(1000, 'Normal closure');
    ok(!$ws->is_connected, 'not connected after close');
    ok($ws->is_closed, 'is_closed after close');
    is($ws->state, 'closed', 'state is closed');
    is($ws->close_code, 1000, 'close_code is set');
    is($ws->close_reason, 'Normal closure', 'close_reason is set');
};

subtest 'close_code defaults' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    $ws->_set_closed();  # No args
    is($ws->close_code, 1005, 'close_code defaults to 1005 (no status)');
    is($ws->close_reason, '', 'close_reason defaults to empty string');
};

done_testing;
```

**Step 3.2: Run test to verify it fails**

```bash
prove -l t/websocket/02-state.t
```
Expected: FAIL - Can't locate method "is_connected"

**Step 3.3: Implement state tracking methods**

Add to `lib/PAGI/WebSocket.pm`:

```perl
# State accessors
sub state { shift->{_state} }

sub is_connected {
    my $self = shift;
    return $self->{_state} eq 'connected';
}

sub is_closed {
    my $self = shift;
    return $self->{_state} eq 'closed';
}

sub close_code   { shift->{_close_code} }
sub close_reason { shift->{_close_reason} }

# Internal state setters
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

sub _set_closed {
    my ($self, $code, $reason) = @_;
    $self->{_state} = 'closed';
    $self->{_close_code} = $code // 1005;
    $self->{_close_reason} = $reason // '';
}
```

**Step 3.4: Run test to verify it passes**

```bash
prove -l t/websocket/02-state.t
```
Expected: PASS

**Step 3.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/02-state.t
git commit -m "$(cat <<'EOF'
feat(websocket): add connection state tracking

Tracks connection state (connecting/connected/closed) and
provides is_connected, is_closed, close_code, close_reason
accessors. State defaults: code=1005, reason=''.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Accept and Close Methods

**Files:**
- Create: `t/websocket/03-lifecycle.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 4.1: Create lifecycle tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

subtest 'accept sends websocket.accept event' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    my $result = $ws->accept->get;

    is(scalar @sent, 1, 'one event sent');
    is($sent[0]{type}, 'websocket.accept', 'sent websocket.accept');
    ok($ws->is_connected, 'state is connected after accept');
};

subtest 'accept with subprotocol' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [], subprotocols => ['chat', 'json'] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    $ws->accept(subprotocol => 'chat')->get;

    is($sent[0]{subprotocol}, 'chat', 'subprotocol included in accept');
};

subtest 'accept with headers' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    $ws->accept(headers => [['x-custom', 'value']])->get;

    is($sent[0]{headers}, [['x-custom', 'value']], 'headers included in accept');
};

subtest 'close sends websocket.close event' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->close->get;

    is(scalar @sent, 1, 'one event sent');
    is($sent[0]{type}, 'websocket.close', 'sent websocket.close');
    is($sent[0]{code}, 1000, 'default close code is 1000');
    ok($ws->is_closed, 'state is closed after close');
};

subtest 'close with code and reason' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->close(4000, 'Custom reason')->get;

    is($sent[0]{code}, 4000, 'custom close code');
    is($sent[0]{reason}, 'Custom reason', 'custom close reason');
    is($ws->close_code, 4000, 'close_code accessor updated');
    is($ws->close_reason, 'Custom reason', 'close_reason accessor updated');
};

subtest 'close is idempotent' => sub {
    my $send_count = 0;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { $send_count++; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    $send_count = 0;

    $ws->close->get;
    $ws->close->get;
    $ws->close->get;

    is($send_count, 1, 'close only sends once');
};

done_testing;
```

**Step 4.2: Run test to verify it fails**

```bash
prove -l t/websocket/03-lifecycle.t
```
Expected: FAIL - Can't locate method "accept"

**Step 4.3: Implement accept and close methods**

Add to `lib/PAGI/WebSocket.pm`:

```perl
use Future::AsyncAwait;
use Future;

async sub accept {
    my ($self, %opts) = @_;

    my $event = {
        type => 'websocket.accept',
    };
    $event->{subprotocol} = $opts{subprotocol} if exists $opts{subprotocol};
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await $self->{send}->($event);
    $self->_set_state('connected');

    return $self;
}

async sub close {
    my ($self, $code, $reason) = @_;

    # Idempotent - don't send close twice
    return if $self->is_closed;

    $code //= 1000;
    $reason //= '';

    await $self->{send}->({
        type   => 'websocket.close',
        code   => $code,
        reason => $reason,
    });

    $self->_set_closed($code, $reason);

    return $self;
}
```

**Step 4.4: Run test to verify it passes**

```bash
prove -l t/websocket/03-lifecycle.t
```
Expected: PASS

**Step 4.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/03-lifecycle.t
git commit -m "$(cat <<'EOF'
feat(websocket): add accept and close methods

accept() sends websocket.accept with optional subprotocol/headers.
close() sends websocket.close with code (default 1000) and reason.
close() is idempotent - only sends once.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Send Methods (text, bytes, JSON)

**Files:**
- Create: `t/websocket/04-send.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 5.1: Create send method tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::WebSocket;

# Helper to create connected WebSocket
sub create_ws {
    my ($send_cb) = @_;
    my @sent;
    $send_cb //= sub { push @sent, $_[0]; Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send_cb);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'send_text sends text frame' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_text('Hello, World!')->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');
    is($sent->[0]{text}, 'Hello, World!', 'text content');
    ok(!exists $sent->[0]{bytes}, 'no bytes key');
};

subtest 'send_bytes sends binary frame' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $binary = "\x00\x01\x02\xFF";
    $ws->send_bytes($binary)->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');
    is($sent->[0]{bytes}, $binary, 'bytes content');
    ok(!exists $sent->[0]{text}, 'no text key');
};

subtest 'send_json encodes and sends as text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = { action => 'greet', name => 'Alice', count => 42 };
    $ws->send_json($data)->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'JSON decoded correctly');
};

subtest 'send_json handles arrays' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = [1, 2, 3, 'four'];
    $ws->send_json($data)->get;

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'array encoded correctly');
};

subtest 'send_json handles nested structures' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = {
        users => [
            { id => 1, name => 'Alice' },
            { id => 2, name => 'Bob' },
        ],
        meta => { total => 2 },
    };
    $ws->send_json($data)->get;

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'nested structure encoded correctly');
};

subtest 'send methods fail when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;

    like(
        dies { $ws->send_text('test')->get },
        qr/closed/i,
        'send_text dies when closed'
    );

    like(
        dies { $ws->send_bytes('test')->get },
        qr/closed/i,
        'send_bytes dies when closed'
    );

    like(
        dies { $ws->send_json({ test => 1 })->get },
        qr/closed/i,
        'send_json dies when closed'
    );
};

done_testing;
```

**Step 5.2: Run test to verify it fails**

```bash
prove -l t/websocket/04-send.t
```
Expected: FAIL - Can't locate method "send_text"

**Step 5.3: Implement send methods**

Add to `lib/PAGI/WebSocket.pm`:

```perl
use JSON::PP ();

async sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    await $self->{send}->({
        type => 'websocket.send',
        text => $text,
    });

    return $self;
}

async sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    await $self->{send}->({
        type  => 'websocket.send',
        bytes => $bytes,
    });

    return $self;
}

async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    my $json = JSON::PP::encode_json($data);

    await $self->{send}->({
        type => 'websocket.send',
        text => $json,
    });

    return $self;
}
```

**Step 5.4: Run test to verify it passes**

```bash
prove -l t/websocket/04-send.t
```
Expected: PASS

**Step 5.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/04-send.t
git commit -m "$(cat <<'EOF'
feat(websocket): add send_text, send_bytes, send_json methods

All methods send websocket.send events with appropriate keys.
send_json encodes data with JSON::PP. All methods die if
called on a closed connection.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Safe Send Methods (try_send, send_if_connected)

**Files:**
- Create: `t/websocket/05-safe-send.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 6.1: Create safe send tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

# Helper to create connected WebSocket
sub create_ws {
    my (%opts) = @_;
    my @sent;
    my $should_fail = $opts{fail};

    my $send = sub {
        push @sent, $_[0];
        return $should_fail ? Future->fail('Connection lost') : Future->done;
    };

    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'try_send_text returns true on success' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok($result, 'returns true on success');
    is($sent->[0]{text}, 'Hello', 'message sent');
};

subtest 'try_send_text returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false on failure');
    ok($ws->is_closed, 'marks connection as closed');
};

subtest 'try_send_text returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_bytes works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00\x01")->get;

    ok($result, 'returns true on success');
    is($sent->[0]{bytes}, "\x00\x01", 'bytes sent');
};

subtest 'try_send_json works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok($result, 'returns true on success');
    like($sent->[0]{text}, qr/"msg"/, 'JSON sent');
};

subtest 'send_text_if_connected is silent when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    # Should not die, should not send
    $ws->send_text_if_connected('Hello')->get;

    is(scalar @$sent, 0, 'no message sent');
};

subtest 'send_json_if_connected sends when connected' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_json_if_connected({ test => 1 })->get;

    is(scalar @$sent, 1, 'message sent');
};

done_testing;
```

**Step 6.2: Run test to verify it fails**

```bash
prove -l t/websocket/05-safe-send.t
```
Expected: FAIL - Can't locate method "try_send_text"

**Step 6.3: Implement safe send methods**

Add to `lib/PAGI/WebSocket.pm`:

```perl
# Safe send methods - return bool instead of throwing

async sub try_send_text {
    my ($self, $text) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->{send}->({
            type => 'websocket.send',
            text => $text,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

async sub try_send_bytes {
    my ($self, $bytes) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->{send}->({
            type  => 'websocket.send',
            bytes => $bytes,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

async sub try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    my $json = JSON::PP::encode_json($data);
    eval {
        await $self->{send}->({
            type => 'websocket.send',
            text => $json,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

# Silent send methods - no-op when closed

async sub send_text_if_connected {
    my ($self, $text) = @_;
    return unless $self->is_connected;
    await $self->try_send_text($text);
    return;
}

async sub send_bytes_if_connected {
    my ($self, $bytes) = @_;
    return unless $self->is_connected;
    await $self->try_send_bytes($bytes);
    return;
}

async sub send_json_if_connected {
    my ($self, $data) = @_;
    return unless $self->is_connected;
    await $self->try_send_json($data);
    return;
}
```

**Step 6.4: Run test to verify it passes**

```bash
prove -l t/websocket/05-safe-send.t
```
Expected: PASS

**Step 6.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/05-safe-send.t
git commit -m "$(cat <<'EOF'
feat(websocket): add safe send methods for broadcast scenarios

try_send_* returns bool (true=sent, false=failed/closed).
send_*_if_connected is silent no-op when closed.
Both patterns useful for broadcasting to multiple clients.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Receive Methods

**Files:**
- Create: `t/websocket/06-receive.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 7.1: Create receive method tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::WebSocket;

subtest 'receive returns raw event' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'Hello' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $event = $ws->receive->get;
    is($event->{type}, 'websocket.receive', 'got receive event');
    is($event->{text}, 'Hello', 'has text');
};

subtest 'receive returns undef on disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Bye' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $event = $ws->receive->get;
    is($event, undef, 'returns undef on disconnect');
    ok($ws->is_closed, 'marked as closed');
    is($ws->close_code, 1000, 'close code captured');
    is($ws->close_reason, 'Bye', 'close reason captured');
};

subtest 'receive_text returns text content' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'Hello, World!' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $text = $ws->receive_text->get;
    is($text, 'Hello, World!', 'received text');
};

subtest 'receive_text skips binary frames' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\x00\x01" },
        { type => 'websocket.receive', text => 'Text message' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $text = $ws->receive_text->get;
    is($text, 'Text message', 'skipped binary, got text');
};

subtest 'receive_bytes returns binary content' => sub {
    my $binary = "\x00\x01\x02\xFF";
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => $binary },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $bytes = $ws->receive_bytes->get;
    is($bytes, $binary, 'received bytes');
};

subtest 'receive_json decodes JSON text' => sub {
    my $data = { action => 'greet', name => 'Alice' };
    my $json = encode_json($data);
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => $json },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $received = $ws->receive_json->get;
    is($received, $data, 'JSON decoded correctly');
};

subtest 'receive_json dies on invalid JSON' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'not valid json{' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    like(
        dies { $ws->receive_json->get },
        qr/JSON|malformed/i,
        'dies on invalid JSON'
    );
};

subtest 'receive methods return undef when closed' => sub {
    my @events = (
        { type => 'websocket.connect' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    $ws->close->get;

    is($ws->receive->get, undef, 'receive returns undef when closed');
    is($ws->receive_text->get, undef, 'receive_text returns undef when closed');
    is($ws->receive_bytes->get, undef, 'receive_bytes returns undef when closed');
    is($ws->receive_json->get, undef, 'receive_json returns undef when closed');
};

done_testing;
```

**Step 7.2: Run test to verify it fails**

```bash
prove -l t/websocket/06-receive.t
```
Expected: FAIL - Can't locate method "receive"

**Step 7.3: Implement receive methods**

Add to `lib/PAGI/WebSocket.pm`:

```perl
async sub receive {
    my ($self) = @_;

    return undef if $self->is_closed;

    my $event = await $self->{receive}->();

    if (!$event || $event->{type} eq 'websocket.disconnect') {
        my $code = $event->{code} // 1005;
        my $reason = $event->{reason} // '';
        $self->_set_closed($code, $reason);
        return undef;
    }

    return $event;
}

async sub receive_text {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and binary frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{text};

        return $event->{text};
    }
}

async sub receive_bytes {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and text frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{bytes};

        return $event->{bytes};
    }
}

async sub receive_json {
    my ($self) = @_;

    my $text = await $self->receive_text;
    return undef unless defined $text;

    return JSON::PP::decode_json($text);
}
```

**Step 7.4: Run test to verify it passes**

```bash
prove -l t/websocket/06-receive.t
```
Expected: PASS

**Step 7.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/06-receive.t
git commit -m "$(cat <<'EOF'
feat(websocket): add receive, receive_text, receive_bytes, receive_json

receive() returns raw events, undef on disconnect.
receive_text/bytes skip unwanted frame types.
receive_json decodes JSON, dies on invalid.
All return undef when connection is closed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Iteration Helpers

**Files:**
- Create: `t/websocket/07-iteration.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 8.1: Create iteration tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::WebSocket;

subtest 'each_message iterates until disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'msg1' },
        { type => 'websocket.receive', text => 'msg2' },
        { type => 'websocket.receive', text => 'msg3' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_message(async sub {
        my ($event) = @_;
        push @received, $event->{text};
    })->get;

    is(\@received, ['msg1', 'msg2', 'msg3'], 'received all messages');
    ok($ws->is_closed, 'connection closed after iteration');
};

subtest 'each_text iterates text frames' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\x00" },  # skipped
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.receive', text => 'world' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_text(async sub {
        my ($text) = @_;
        push @received, $text;
    })->get;

    is(\@received, ['hello', 'world'], 'received text messages only');
};

subtest 'each_json iterates and decodes' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"n":1}' },
        { type => 'websocket.receive', text => '{"n":2}' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_json(async sub {
        my ($data) = @_;
        push @received, $data->{n};
    })->get;

    is(\@received, [1, 2], 'received and decoded JSON');
};

subtest 'callback can send responses' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'ping' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my @sent;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("pong: $text");
    })->get;

    is($sent[0]{text}, 'pong: ping', 'callback sent response');
};

subtest 'exception in callback propagates' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'trigger' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    like(
        dies {
            $ws->each_text(async sub {
                die "Intentional error";
            })->get;
        },
        qr/Intentional error/,
        'exception propagates'
    );
};

done_testing;
```

**Step 8.2: Run test to verify it fails**

```bash
prove -l t/websocket/07-iteration.t
```
Expected: FAIL - Can't locate method "each_message"

**Step 8.3: Implement iteration helpers**

Add to `lib/PAGI/WebSocket.pm`:

```perl
async sub each_message {
    my ($self, $callback) = @_;

    while (my $event = await $self->receive) {
        next unless $event->{type} eq 'websocket.receive';
        await $callback->($event);
    }

    return;
}

async sub each_text {
    my ($self, $callback) = @_;

    while (my $text = await $self->receive_text) {
        await $callback->($text);
    }

    return;
}

async sub each_bytes {
    my ($self, $callback) = @_;

    while (my $bytes = await $self->receive_bytes) {
        await $callback->($bytes);
    }

    return;
}

async sub each_json {
    my ($self, $callback) = @_;

    while (1) {
        my $text = await $self->receive_text;
        last unless defined $text;

        my $data = JSON::PP::decode_json($text);
        await $callback->($data);
    }

    return;
}
```

**Step 8.4: Run test to verify it passes**

```bash
prove -l t/websocket/07-iteration.t
```
Expected: PASS

**Step 8.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/07-iteration.t
git commit -m "$(cat <<'EOF'
feat(websocket): add iteration helpers each_message/text/bytes/json

Callback-based iteration that runs until disconnect.
each_text/bytes filter frame types.
each_json decodes automatically.
Exceptions in callbacks propagate to caller.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Cleanup Registration (on_close)

**Files:**
- Create: `t/websocket/08-cleanup.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 9.1: Create cleanup tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

subtest 'on_close callback runs on disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Bye' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my ($called_code, $called_reason);
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        $called_code = $code;
        $called_reason = $reason;
    });

    # Trigger disconnect
    $ws->receive->get;

    is($called_code, 1000, 'on_close received code');
    is($called_reason, 'Bye', 'on_close received reason');
};

subtest 'on_close runs after each_* loops' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'msg' },
        { type => 'websocket.disconnect', code => 1001 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    $ws->each_text(async sub {})->get;

    ok($cleanup_ran, 'on_close ran after each_text');
};

subtest 'multiple on_close callbacks run in order' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @order;
    $ws->on_close(async sub { push @order, 1 });
    $ws->on_close(async sub { push @order, 2 });
    $ws->on_close(async sub { push @order, 3 });

    $ws->receive->get;

    is(\@order, [1, 2, 3], 'callbacks run in registration order');
};

subtest 'on_close runs on explicit close()' => sub {
    my @events = (
        { type => 'websocket.connect' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    $ws->close(1000, 'Goodbye')->get;

    ok($cleanup_ran, 'on_close ran on explicit close');
};

subtest 'on_close only runs once' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $call_count = 0;
    $ws->on_close(async sub { $call_count++ });

    $ws->receive->get;    # triggers disconnect
    $ws->receive->get;    # already closed
    $ws->close->get;      # already closed

    is($call_count, 1, 'on_close only called once');
};

subtest 'on_close exception does not prevent other callbacks' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $second_ran = 0;
    $ws->on_close(async sub { die "First callback error" });
    $ws->on_close(async sub { $second_ran = 1 });

    # Should not die, should run second callback
    $ws->receive->get;

    ok($second_ran, 'second callback ran despite first dying');
};

done_testing;
```

**Step 9.2: Run test to verify it fails**

```bash
prove -l t/websocket/08-cleanup.t
```
Expected: FAIL - Can't locate method "on_close"

**Step 9.3: Implement on_close and cleanup logic**

Add to `lib/PAGI/WebSocket.pm`:

```perl
sub on_close {
    my ($self, $callback) = @_;
    push @{$self->{_on_close}}, $callback;
    return $self;
}

async sub _run_close_callbacks {
    my ($self) = @_;

    # Only run once
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;

    my $code = $self->close_code;
    my $reason = $self->close_reason;

    for my $cb (@{$self->{_on_close}}) {
        eval { await $cb->($code, $reason) };
        if ($@) {
            warn "PAGI::WebSocket on_close callback error: $@";
        }
    }
}
```

Modify `_set_closed`:

```perl
sub _set_closed {
    my ($self, $code, $reason) = @_;

    return if $self->{_state} eq 'closed';  # Prevent double-close

    $self->{_state} = 'closed';
    $self->{_close_code} = $code // 1005;
    $self->{_close_reason} = $reason // '';

    # Run cleanup callbacks (fire and forget - don't await in sync context)
    $self->_run_close_callbacks;
}
```

Wait, this is tricky because `_set_closed` is called from sync context but `_run_close_callbacks` is async. Let me refactor.

Update `_set_closed` and modify `receive` and `close`:

```perl
sub _set_closed {
    my ($self, $code, $reason) = @_;

    return if $self->{_state} eq 'closed';

    $self->{_state} = 'closed';
    $self->{_close_code} = $code // 1005;
    $self->{_close_reason} = $reason // '';
}

async sub receive {
    my ($self) = @_;

    return undef if $self->is_closed;

    my $event = await $self->{receive}->();

    if (!$event || $event->{type} eq 'websocket.disconnect') {
        my $code = $event->{code} // 1005;
        my $reason = $event->{reason} // '';
        $self->_set_closed($code, $reason);
        await $self->_run_close_callbacks;
        return undef;
    }

    return $event;
}

async sub close {
    my ($self, $code, $reason) = @_;

    return if $self->is_closed;

    $code //= 1000;
    $reason //= '';

    await $self->{send}->({
        type   => 'websocket.close',
        code   => $code,
        reason => $reason,
    });

    $self->_set_closed($code, $reason);
    await $self->_run_close_callbacks;

    return $self;
}
```

**Step 9.4: Run test to verify it passes**

```bash
prove -l t/websocket/08-cleanup.t
```
Expected: PASS

**Step 9.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/08-cleanup.t
git commit -m "$(cat <<'EOF'
feat(websocket): add on_close cleanup registration

on_close() registers callbacks that run on disconnect or close().
Multiple callbacks run in order. Exceptions are caught and warned
but don't prevent other callbacks. Callbacks only run once.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Timeout Support

**Files:**
- Create: `t/websocket/09-timeout.t`
- Modify: `lib/PAGI/WebSocket.pm`

**Step 10.1: Create timeout tests**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use IO::Async::Loop;

use lib 'lib';
use PAGI::WebSocket;

my $loop = IO::Async::Loop->new;

subtest 'receive_with_timeout returns message before timeout' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'quick' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->set_loop($loop);
    $ws->accept->get;

    my $event = $ws->receive_with_timeout(5)->get;

    ok($event, 'got event');
    is($event->{text}, 'quick', 'correct message');
};

subtest 'receive_with_timeout returns undef on timeout' => sub {
    my @events = (
        { type => 'websocket.connect' },
    );
    my $idx = 0;

    # receive that never resolves
    my $pending = Future->new;
    my $receive = sub { $idx == 0 ? Future->done($events[$idx++]) : $pending };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->set_loop($loop);
    $ws->accept->get;

    my $event = $ws->receive_with_timeout(0.1)->get;

    is($event, undef, 'returns undef on timeout');
    ok(!$ws->is_closed, 'connection still open after timeout');
};

subtest 'receive_text_with_timeout works' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'hello' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->set_loop($loop);
    $ws->accept->get;

    my $text = $ws->receive_text_with_timeout(5)->get;

    is($text, 'hello', 'got text');
};

subtest 'receive_json_with_timeout works' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"key":"value"}' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->set_loop($loop);
    $ws->accept->get;

    my $data = $ws->receive_json_with_timeout(5)->get;

    is($data, { key => 'value' }, 'got decoded JSON');
};

done_testing;
```

**Step 10.2: Run test to verify it fails**

```bash
prove -l t/websocket/09-timeout.t
```
Expected: FAIL - Can't locate method "set_loop"

**Step 10.3: Implement timeout support**

Add to `lib/PAGI/WebSocket.pm`:

```perl
sub set_loop {
    my ($self, $loop) = @_;
    $self->{_loop} = $loop;
    return $self;
}

sub loop {
    my ($self) = @_;
    return $self->{_loop} if $self->{_loop};

    # Try to get default loop
    require IO::Async::Loop;
    $self->{_loop} = IO::Async::Loop->new;
    return $self->{_loop};
}

async sub receive_with_timeout {
    my ($self, $timeout) = @_;

    return undef if $self->is_closed;

    my $loop = $self->loop;
    my $receive_f = $self->{receive}->();
    my $timeout_f = $loop->delay_future(after => $timeout);

    my $winner = await Future->wait_any($receive_f, $timeout_f);

    if ($timeout_f->is_ready && !$receive_f->is_ready) {
        # Timeout won - cancel receive and return undef
        $receive_f->cancel;
        return undef;
    }

    # Message received
    my $event = $receive_f->get;

    if (!$event || $event->{type} eq 'websocket.disconnect') {
        my $code = $event->{code} // 1005;
        my $reason = $event->{reason} // '';
        $self->_set_closed($code, $reason);
        await $self->_run_close_callbacks;
        return undef;
    }

    return $event;
}

async sub receive_text_with_timeout {
    my ($self, $timeout) = @_;

    my $event = await $self->receive_with_timeout($timeout);
    return undef unless $event;
    return undef unless $event->{type} eq 'websocket.receive';
    return undef unless exists $event->{text};

    return $event->{text};
}

async sub receive_bytes_with_timeout {
    my ($self, $timeout) = @_;

    my $event = await $self->receive_with_timeout($timeout);
    return undef unless $event;
    return undef unless $event->{type} eq 'websocket.receive';
    return undef unless exists $event->{bytes};

    return $event->{bytes};
}

async sub receive_json_with_timeout {
    my ($self, $timeout) = @_;

    my $text = await $self->receive_text_with_timeout($timeout);
    return undef unless defined $text;

    return JSON::PP::decode_json($text);
}
```

**Step 10.4: Run test to verify it passes**

```bash
prove -l t/websocket/09-timeout.t
```
Expected: PASS

**Step 10.5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket/09-timeout.t
git commit -m "$(cat <<'EOF'
feat(websocket): add receive_with_timeout methods

Uses IO::Async::Loop for timeout. Returns undef on timeout
without closing the connection. Includes text, bytes, and
JSON variants with timeout support.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Integration Tests with Real Server

**Files:**
- Create: `t/websocket/10-integration.t`

**Step 11.1: Create comprehensive integration test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::WebSocket::Client;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use PAGI::Server;
use PAGI::WebSocket;

my $loop = IO::Async::Loop->new;

sub create_server {
    my ($app) = @_;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    return $server;
}

subtest 'PAGI::WebSocket echo app' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("echo: $text");
        });
    };

    my $server = create_server($app);
    my $port = $server->port;

    my @received;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            push @received, $text;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame("Hello");
        $client->send_text_frame("World");

        my $deadline = time + 5;
        while (@received < 2 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    is(\@received, ['echo: Hello', 'echo: World'], 'echo app works');

    $server->shutdown->get;
};

subtest 'PAGI::WebSocket JSON echo app' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_json(async sub {
            my ($data) = @_;
            $data->{echoed} = 1;
            await $ws->send_json($data);
        });
    };

    my $server = create_server($app);
    my $port = $server->port;

    my @received;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            push @received, $text;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame('{"msg":"test"}');

        my $deadline = time + 5;
        while (@received < 1 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    use JSON::PP;
    my $response = decode_json($received[0]);
    is($response->{msg}, 'test', 'original data preserved');
    is($response->{echoed}, 1, 'echoed flag added');

    $server->shutdown->get;
};

subtest 'on_close runs on client disconnect' => sub {
    my $cleanup_ran = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        $ws->on_close(async sub {
            $cleanup_ran = 1;
        });

        await $ws->each_text(async sub {});
    };

    my $server = create_server($app);
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new;
    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame("test");
        $loop->loop_once(0.1);
        $client->close;

        # Wait for cleanup
        my $deadline = time + 3;
        while (!$cleanup_ran && time < $deadline) {
            $loop->loop_once(0.1);
        }
    };

    ok($cleanup_ran, 'on_close ran on client disconnect');

    $server->shutdown->get;
};

done_testing;
```

**Step 11.2: Run test to verify it works**

```bash
prove -l t/websocket/10-integration.t
```
Expected: PASS (assuming previous tasks complete correctly)

**Step 11.3: Commit**

```bash
git add t/websocket/10-integration.t
git commit -m "$(cat <<'EOF'
test(websocket): add integration tests with real server

Tests PAGI::WebSocket with actual PAGI::Server using
Net::Async::WebSocket::Client. Covers text echo, JSON echo,
and on_close cleanup on client disconnect.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Complete Documentation

**Files:**
- Modify: `lib/PAGI/WebSocket.pm` (add full POD)

**Step 12.1: Write comprehensive POD documentation**

Add at the end of `lib/PAGI/WebSocket.pm` before the final `1;`:

```perl
__END__

=head1 NAME

PAGI::WebSocket - Convenience wrapper for PAGI WebSocket connections

=head1 SYNOPSIS

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    # Simple echo server
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("Echo: $text");
        });
    }

    # JSON API with cleanup
    async sub json_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept(subprotocol => 'json');

        my $user_id = generate_id();

        # Cleanup runs on any disconnect
        $ws->on_close(async sub {
            my ($code, $reason) = @_;
            await remove_user($user_id);
            log_disconnect($user_id, $code);
        });

        await $ws->each_json(async sub {
            my ($data) = @_;

            if ($data->{type} eq 'ping') {
                await $ws->send_json({ type => 'pong' });
            }
        });
    }

=head1 DESCRIPTION

PAGI::WebSocket wraps the raw PAGI WebSocket protocol to provide a clean,
high-level API inspired by Starlette's WebSocket class. It eliminates
protocol boilerplate and provides:

=over 4

=item * Typed send/receive methods (text, bytes, JSON)

=item * Connection state tracking (is_connected, is_closed, close_code)

=item * Cleanup callback registration (on_close)

=item * Safe send methods for broadcast scenarios (try_send_*, send_*_if_connected)

=item * Message iteration helpers (each_text, each_json)

=item * Timeout support for receives

=back

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

Creates a new WebSocket wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<type => 'websocket'>

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'websocket'.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $ws->path;              # /chat/room1
    my $qs = $ws->query_string;        # token=abc
    my $scheme = $ws->scheme;          # ws or wss

Standard PAGI scope properties with sensible defaults.

=head2 subprotocols

    my $protos = $ws->subprotocols;    # ['chat', 'json']

Returns arrayref of requested subprotocols.

=head2 client, server

    my $client = $ws->client;          # ['192.168.1.1', 54321]

Client and server address info.

=head2 header, headers, header_all

    my $origin = $ws->header('origin');
    my $all_cookies = $ws->header_all('cookie');
    my $hmv = $ws->headers;            # Hash::MultiValue

Case-insensitive header access.

=head1 LIFECYCLE METHODS

=head2 accept

    await $ws->accept;
    await $ws->accept(subprotocol => 'chat');
    await $ws->accept(headers => [['x-custom', 'value']]);

Accepts the WebSocket connection. Optionally specify a subprotocol
to use and additional response headers.

=head2 close

    await $ws->close;
    await $ws->close(1000, 'Normal closure');
    await $ws->close(4000, 'Custom reason');

Closes the connection. Default code is 1000 (normal closure).
Idempotent - calling multiple times only sends close once.

=head1 STATE ACCESSORS

=head2 is_connected, is_closed, state

    if ($ws->is_connected) { ... }
    if ($ws->is_closed) { ... }
    my $state = $ws->state;            # 'connecting', 'connected', 'closed'

=head2 close_code, close_reason

    my $code = $ws->close_code;        # 1000, 1001, etc.
    my $reason = $ws->close_reason;    # 'Normal closure'

Available after connection closes. Defaults: code=1005, reason=''.

=head1 SEND METHODS

=head2 send_text, send_bytes, send_json

    await $ws->send_text("Hello!");
    await $ws->send_bytes("\x00\x01\x02");
    await $ws->send_json({ action => 'greet', name => 'Alice' });

Send a message. Dies if connection is closed.

=head2 try_send_text, try_send_bytes, try_send_json

    my $sent = await $ws->try_send_json($data);
    if (!$sent) {
        # Client disconnected
        cleanup_user($id);
    }

Returns true if sent, false if failed or closed. Does not throw.
Useful for broadcasting to multiple clients.

=head2 send_text_if_connected, send_bytes_if_connected, send_json_if_connected

    await $ws->send_json_if_connected($data);

Silent no-op if connection is closed. Useful for fire-and-forget.

=head1 RECEIVE METHODS

=head2 receive

    my $event = await $ws->receive;

Returns raw PAGI event hashref, or undef on disconnect.

=head2 receive_text, receive_bytes

    my $text = await $ws->receive_text;
    my $bytes = await $ws->receive_bytes;

Waits for specific frame type, skipping others. Returns undef on disconnect.

=head2 receive_json

    my $data = await $ws->receive_json;

Receives text frame and decodes as JSON. Dies on invalid JSON.

=head2 receive_with_timeout, receive_text_with_timeout, etc.

    my $event = await $ws->receive_with_timeout(30);  # 30 seconds

Returns undef on timeout (connection remains open).

=head1 ITERATION HELPERS

=head2 each_message, each_text, each_bytes, each_json

    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("Got: $text");
    });

    await $ws->each_json(async sub {
        my ($data) = @_;
        if ($data->{type} eq 'ping') {
            await $ws->send_json({ type => 'pong' });
        }
    });

Loops until disconnect, calling callback for each message.
Exceptions in callback propagate to caller.

=head1 CLEANUP

=head2 on_close

    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        await cleanup_resources();
    });

Registers cleanup callback that runs on disconnect or close().
Multiple callbacks run in registration order. Exceptions are
caught and warned but don't prevent other callbacks.

=head1 COMPLETE EXAMPLE

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    my %connections;

    async sub chat_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        my $user_id = generate_id();
        $connections{$user_id} = $ws;

        $ws->on_close(async sub {
            delete $connections{$user_id};
            await broadcast({ type => 'leave', user => $user_id });
        });

        await broadcast({ type => 'join', user => $user_id });

        await $ws->each_json(async sub {
            my ($data) = @_;
            $data->{from} = $user_id;
            await broadcast($data);
        });
    }

    async sub broadcast {
        my ($data) = @_;
        for my $ws (values %connections) {
            await $ws->try_send_json($data);
        }
    }

=head1 SEE ALSO

L<PAGI::Request> - Similar convenience wrapper for HTTP requests

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
```

**Step 12.2: Verify documentation renders correctly**

```bash
perldoc lib/PAGI/WebSocket.pm
```

**Step 12.3: Run all WebSocket tests**

```bash
prove -l t/websocket/
```
Expected: All tests pass

**Step 12.4: Commit**

```bash
git add lib/PAGI/WebSocket.pm
git commit -m "$(cat <<'EOF'
docs(websocket): add comprehensive POD documentation

Full documentation with synopsis, method descriptions,
parameters, return values, and complete examples.
Covers all public methods and common usage patterns.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Example App - Simple Echo (v2)

**Files:**
- Create: `examples/websocket-echo-v2/app.pl`

**Step 13.1: Create the v2 echo example**

```perl
#!/usr/bin/env perl
#
# WebSocket Echo Server using PAGI::WebSocket
#
# This example demonstrates the clean PAGI::WebSocket API compared
# to the raw protocol. Compare with examples/04-websocket-echo/app.pl.
#
# Run: pagi-server --app examples/websocket-echo-v2/app.pl --port 5000
# Test: websocat ws://localhost:5000/
#
use strict;
use warnings;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::WebSocket;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan events (server startup/shutdown)
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                print "Echo server starting...\n";
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                print "Echo server shutting down...\n";
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    # Reject non-websocket connections
    die "Expected websocket, got $scope->{type}" if $scope->{type} ne 'websocket';

    #
    # This is the magic - compare to the raw protocol version!
    #
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    # Accept the connection
    await $ws->accept;
    print "Client connected from ", ($ws->client->[0] // 'unknown'), "\n";

    # Optional: register cleanup
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        print "Client disconnected: $code",
              ($reason ? " ($reason)" : ""), "\n";
    });

    # Echo loop - just 4 lines!
    await $ws->each_text(async sub {
        my ($text) = @_;
        print "Received: $text\n";
        await $ws->send_text("echo: $text");
    });
};

$app;
```

**Step 13.2: Test the example**

```bash
pagi-server --app examples/websocket-echo-v2/app.pl --port 5000 &
sleep 1
echo "Hello" | websocat ws://localhost:5000/
kill %1
```

**Step 13.3: Commit**

```bash
git add examples/websocket-echo-v2/app.pl
git commit -m "$(cat <<'EOF'
example(websocket): add v2 echo example using PAGI::WebSocket

Clean 4-line echo loop compared to ~20 lines of raw protocol.
Demonstrates accept, on_close, each_text, and send_text.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Example App - Chat (v2)

**Files:**
- Create: `examples/websocket-chat-v2/app.pl`

**Step 14.1: Create the v2 chat example**

```perl
#!/usr/bin/env perl
#
# Multi-room WebSocket Chat using PAGI::WebSocket
#
# This example shows a complete chat application with:
# - Room join/leave
# - Nicknames
# - Broadcast messaging
# - Proper cleanup on disconnect
#
# Compare with lib/PAGI/App/WebSocket/Chat.pm for the raw protocol version.
#
# Run: pagi-server --app examples/websocket-chat-v2/app.pl --port 5000
#
use strict;
use warnings;
use Future::AsyncAwait;
use JSON::PP qw(encode_json decode_json);
use lib 'lib';
use PAGI::WebSocket;

# Shared state
my %rooms;      # room => { users => { id => { ws => $ws, name => $name } } }
my $next_id = 1;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                print "Chat server starting...\n";
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                print "Chat server shutting down...\n";
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    die "Expected websocket" if $scope->{type} ne 'websocket';

    # Create WebSocket wrapper
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    await $ws->accept;

    # User setup
    my $user_id = $next_id++;
    my $username = "user_$user_id";
    my @my_rooms;

    # Register cleanup - runs on ANY disconnect
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        print "User $username disconnected ($code)\n";

        for my $room (@my_rooms) {
            leave_room($user_id, $room);
            await broadcast_to_room($room, {
                type     => 'user_left',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            });
        }
    });

    # Join default room
    join_room($user_id, $ws, $username, 'lobby');
    push @my_rooms, 'lobby';

    # Send welcome
    await $ws->send_json({
        type     => 'welcome',
        user_id  => $user_id,
        username => $username,
        room     => 'lobby',
    });

    print "User $username joined lobby\n";

    # Message loop
    await $ws->each_json(async sub {
        my ($data) = @_;
        my $cmd = $data->{type} // 'message';

        if ($cmd eq 'message') {
            my $msg = $data->{message} // '';
            my $target = $data->{room};
            my @targets = $target ? ($target) : @my_rooms;

            for my $room (@targets) {
                next unless grep { $_ eq $room } @my_rooms;
                await broadcast_to_room($room, {
                    type      => 'message',
                    room      => $room,
                    user_id   => $user_id,
                    username  => $username,
                    message   => $msg,
                    timestamp => time(),
                }, $user_id);
            }
        }
        elsif ($cmd eq 'join') {
            my $room = $data->{room} // 'lobby';

            join_room($user_id, $ws, $username, $room);
            push @my_rooms, $room unless grep { $_ eq $room } @my_rooms;

            await $ws->send_json({ type => 'joined', room => $room });

            await broadcast_to_room($room, {
                type     => 'user_joined',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            }, $user_id);
        }
        elsif ($cmd eq 'leave') {
            my $room = $data->{room};
            return unless $room && grep { $_ eq $room } @my_rooms;

            leave_room($user_id, $room);
            @my_rooms = grep { $_ ne $room } @my_rooms;

            await $ws->send_json({ type => 'left', room => $room });

            await broadcast_to_room($room, {
                type     => 'user_left',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            });
        }
        elsif ($cmd eq 'nick') {
            my $new_name = $data->{username} // $username;
            $new_name =~ s/[^\w\-]//g;
            $new_name = substr($new_name, 0, 20);

            for my $room (@my_rooms) {
                $rooms{$room}{users}{$user_id}{name} = $new_name
                    if $rooms{$room}{users}{$user_id};
            }
            $username = $new_name;

            await $ws->send_json({ type => 'nick', username => $username });
        }
        elsif ($cmd eq 'list') {
            my $room = $data->{room};
            return unless $room && $rooms{$room};

            my @users = map { $_->{name} } values %{$rooms{$room}{users}};
            await $ws->send_json({ type => 'users', room => $room, users => \@users });
        }
        elsif ($cmd eq 'rooms') {
            my @room_list = map {
                { name => $_, count => scalar keys %{$rooms{$_}{users}} }
            } keys %rooms;
            await $ws->send_json({ type => 'rooms', rooms => \@room_list });
        }
    });
};

#
# Helper functions
#

sub join_room {
    my ($user_id, $ws, $username, $room) = @_;

    $rooms{$room} //= { users => {} };
    $rooms{$room}{users}{$user_id} = {
        ws   => $ws,
        name => $username,
    };
}

sub leave_room {
    my ($user_id, $room) = @_;

    return unless $rooms{$room};
    delete $rooms{$room}{users}{$user_id};
    delete $rooms{$room} if !keys %{$rooms{$room}{users}};
}

async sub broadcast_to_room {
    my ($room, $data, $exclude_id) = @_;

    return unless $rooms{$room};
    my $users = $rooms{$room}{users};

    for my $id (keys %$users) {
        next if defined $exclude_id && $id eq $exclude_id;

        my $ws = $users->{$id}{ws};

        # Safe send - returns false if client disconnected
        my $sent = await $ws->try_send_json($data);

        if (!$sent) {
            # Client gone, clean up
            delete $users->{$id};
        }
    }

    # Clean empty room
    delete $rooms{$room} if !keys %{$rooms{$room}{users}};
}

$app;
```

**Step 14.2: Verify it runs**

```bash
pagi-server --app examples/websocket-chat-v2/app.pl --port 5000
```

**Step 14.3: Commit**

```bash
git add examples/websocket-chat-v2/app.pl
git commit -m "$(cat <<'EOF'
example(websocket): add v2 chat example using PAGI::WebSocket

Complete multi-room chat with:
- Room join/leave
- Nicknames
- Broadcast with safe send
- Automatic cleanup via on_close

Compare with lib/PAGI/App/WebSocket/Chat.pm for raw protocol version.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Final Review and Test Suite

**Step 15.1: Run complete test suite**

```bash
prove -l t/websocket/
```

**Step 15.2: Run full PAGI test suite to ensure no regressions**

```bash
prove -l t/
```

**Step 15.3: Update cpanfile if needed**

Check if any new dependencies (should be none - using existing modules).

**Step 15.4: Create summary commit**

```bash
git log --oneline HEAD~14..HEAD
```

Review all commits are clean and well-documented.

**Step 15.5: Final commit with feature flag (if using)**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(websocket): complete PAGI::WebSocket implementation

PAGI::WebSocket provides a Starlette-inspired convenience wrapper
for WebSocket handling with:

- Typed send/receive methods (text, bytes, JSON)
- Connection state tracking
- Cleanup registration (on_close)
- Safe broadcast methods (try_send_*, send_*_if_connected)
- Message iteration helpers (each_text, each_json)
- Timeout support

Includes comprehensive tests and two example apps (echo, chat).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Summary

This plan creates `PAGI::WebSocket` in 15 tasks with ~75 steps total:

| Task | Description | Tests |
|------|-------------|-------|
| 1 | Core module structure | 01-constructor.t |
| 2 | Scope property accessors | 01-constructor.t |
| 3 | Connection state tracking | 02-state.t |
| 4 | Accept and close methods | 03-lifecycle.t |
| 5 | Send methods | 04-send.t |
| 6 | Safe send methods | 05-safe-send.t |
| 7 | Receive methods | 06-receive.t |
| 8 | Iteration helpers | 07-iteration.t |
| 9 | Cleanup registration | 08-cleanup.t |
| 10 | Timeout support | 09-timeout.t |
| 11 | Integration tests | 10-integration.t |
| 12 | Documentation | POD in module |
| 13 | Echo example v2 | examples/ |
| 14 | Chat example v2 | examples/ |
| 15 | Final review | Full test suite |

Each task follows TDD: write failing test, implement, verify pass, commit.
