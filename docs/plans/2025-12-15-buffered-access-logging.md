# Buffered Access Logging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce access logging overhead from ~10,000 syscalls/second to ~100/second by buffering log entries and flushing periodically or when buffer fills.

**Architecture:** Move logging control from Connection to Server. Connection formats entries and calls Server.log_access(). Server buffers entries in an array, flushes on timer (1s default) or buffer full (100 entries default). Shutdown flushes remaining entries.

**Tech Stack:** Perl, IO::Async (for timer), existing PAGI::Server infrastructure

---

## Task 1: Add Buffer Configuration Parameters to Server.pm

**Files:**
- Modify: `lib/PAGI/Server.pm:84-122` (POD documentation)
- Modify: `lib/PAGI/Server.pm:306-320` (_init method)
- Modify: `lib/PAGI/Server.pm:365-378` (configure method)

**Step 1: Add POD documentation for new parameters**

Add after the `log_level` documentation (around line 122):

```perl
=item access_log_buffer_size => $count

Number of access log entries to buffer before flushing to disk. When the buffer
reaches this size, all entries are written at once. Default: 100

Set to 0 or 1 to disable buffering (write each entry immediately, legacy behavior).

B<CLI:> C<--access-log-buffer-size 100>

=item access_log_flush_interval => $seconds

Maximum time in seconds to hold buffered log entries before flushing. A timer
flushes the buffer periodically even if not full. Default: 1

Set to 0 to disable timer-based flushing (only flush when buffer is full).

B<CLI:> C<--access-log-flush-interval 1>
```

**Step 2: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 3: Add parameters to _init method**

In `_init`, add after `$self->{_log_level_num}` line:

```perl
    $self->{access_log_buffer_size}     = delete $params->{access_log_buffer_size} // 100;
    $self->{access_log_flush_interval}  = delete $params->{access_log_flush_interval} // 1;
    $self->{_access_log_buffer}         = [];  # Internal buffer for log entries
    $self->{_access_log_timer}          = undef;  # Timer handle for periodic flush
```

**Step 4: Add parameters to configure method**

In `configure`, add after the `log_level` block:

```perl
    if (exists $params{access_log_buffer_size}) {
        $self->{access_log_buffer_size} = delete $params{access_log_buffer_size};
    }
    if (exists $params{access_log_flush_interval}) {
        $self->{access_log_flush_interval} = delete $params{access_log_flush_interval};
    }
```

**Step 5: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 6: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: add access_log_buffer_size and flush_interval parameters"
```

---

## Task 2: Implement Buffer Flush Methods in Server.pm

**Files:**
- Modify: `lib/PAGI/Server.pm` (add new methods after _log)

**Step 1: Add _flush_access_log method**

Add after the `_log` method (around line 415):

```perl
# Flush buffered access log entries to disk
sub _flush_access_log ($self) {
    return unless $self->{access_log};
    return unless @{$self->{_access_log_buffer}};

    my $log = $self->{access_log};
    print $log join('', @{$self->{_access_log_buffer}});
    $self->{_access_log_buffer} = [];
}

# Write a single access log entry (buffered or immediate)
sub log_access ($self, $entry) {
    return unless $self->{access_log};

    # Buffering disabled: write immediately
    if ($self->{access_log_buffer_size} <= 1) {
        my $log = $self->{access_log};
        print $log $entry;
        return;
    }

    # Add to buffer
    push @{$self->{_access_log_buffer}}, $entry;

    # Flush if buffer is full
    if (@{$self->{_access_log_buffer}} >= $self->{access_log_buffer_size}) {
        $self->_flush_access_log;
    }
}
```

**Step 2: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 3: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: add log_access and _flush_access_log methods"
```

---

## Task 3: Start/Stop Flush Timer in Server Lifecycle

**Files:**
- Modify: `lib/PAGI/Server.pm:430-520` (_listen_singleworker)
- Modify: `lib/PAGI/Server.pm:920-945` (shutdown)

**Step 1: Add timer start helper method**

Add after `_flush_access_log` method:

```perl
# Start the periodic access log flush timer
sub _start_access_log_timer ($self) {
    return unless $self->{access_log};
    return unless $self->{access_log_flush_interval} > 0;
    return unless $self->{access_log_buffer_size} > 1;
    return if $self->{_access_log_timer};  # Already running

    my $interval = $self->{access_log_flush_interval};
    weaken(my $weak_self = $self);

    $self->{_access_log_timer} = $self->loop->watch_time(
        after => $interval,
        interval => $interval,
        code => sub {
            return unless $weak_self;
            $weak_self->_flush_access_log;
        },
    );
}

# Stop the periodic access log flush timer
sub _stop_access_log_timer ($self) {
    return unless $self->{_access_log_timer};
    $self->loop->unwatch_time($self->{_access_log_timer});
    $self->{_access_log_timer} = undef;
}
```

**Step 2: Start timer in _listen_singleworker**

In `_listen_singleworker`, add after setting up signal handlers (around line 512):

```perl
    # Start access log flush timer
    $self->_start_access_log_timer;
```

**Step 3: Stop timer and flush in shutdown**

In the `shutdown` method, add at the beginning after the return check:

```perl
    # Stop access log timer and flush any remaining entries
    $self->_stop_access_log_timer;
    $self->_flush_access_log;
```

**Step 4: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 5: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: add access log flush timer lifecycle management"
```

---

## Task 4: Update Connection to Use Server.log_access

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm:99` (constructor)
- Modify: `lib/PAGI/Server/Connection.pm:808-842` (_write_access_log)

**Step 1: Add server reference to Connection constructor**

In the `new` method, the server reference is already passed. Find line ~99:

```perl
        access_log        => $args{access_log},     # Filehandle for access logging
```

Add after it:

```perl
        server            => $args{server},         # Reference to parent server for buffered logging
```

**Step 2: Update _write_access_log to use server**

Replace the `_write_access_log` method:

```perl
sub _write_access_log ($self) {
    return unless $self->{current_request};

    # Check if we have server reference (buffered) or access_log (legacy)
    return unless $self->{server} || $self->{access_log};

    my $request = $self->{current_request};
    my $method = $request->{method} // '-';
    my $path = $request->{raw_path} // '/';
    my $query = $request->{query_string};
    $path .= "?$query" if defined $query && length $query;

    my $status = $self->{response_status} // '-';

    # Calculate request duration
    my $duration = '-';
    if ($self->{request_start}) {
        $duration = sprintf("%.3f", tv_interval($self->{request_start}));
    }

    # Get client IP
    my $client_ip = '-';
    my $handle = $self->{stream} ? $self->{stream}->read_handle : undef;
    if ($handle && $handle->can('peerhost')) {
        $client_ip = $handle->peerhost // '-';
    }

    # Format: client_ip - - [timestamp] "METHOD /path" status duration
    my @gmt = gmtime(time);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my $timestamp = sprintf("%02d/%s/%04d:%02d:%02d:%02d +0000",
        $gmt[3], $months[$gmt[4]], $gmt[5] + 1900,
        $gmt[2], $gmt[1], $gmt[0]);

    my $entry = "$client_ip - - [$timestamp] \"$method $path\" $status ${duration}s\n";

    # Use server's buffered logging if available, otherwise direct write
    if ($self->{server} && $self->{server}->can('log_access')) {
        $self->{server}->log_access($entry);
    }
    elsif ($self->{access_log}) {
        my $log = $self->{access_log};
        print $log $entry;
    }
}
```

**Step 3: Run syntax check**

Run: `perl -c lib/PAGI/Server/Connection.pm`
Expected: `lib/PAGI/Server/Connection.pm syntax OK`

**Step 4: Commit**

```bash
git add lib/PAGI/Server/Connection.pm
git commit -m "feat: update Connection to use server buffered logging"
```

---

## Task 5: Pass Server Reference When Creating Connections

**Files:**
- Modify: `lib/PAGI/Server.pm:680-690` (_on_connection)
- Modify: `lib/PAGI/Server.pm:770-780` (worker connection creation)

**Step 1: Add server reference to single-worker connection creation**

Find the `_on_connection` method where Connection is instantiated (around line 685). Add `server => $self` to the constructor args:

```perl
    my $connection = PAGI::Server::Connection->new(
        stream            => $stream,
        app               => $self->{app},
        protocol          => $self->{protocol},
        extensions        => $self->{extensions},
        tls_enabled       => $self->{tls_enabled},
        state             => $self->{state},
        timeout           => $self->{timeout},
        max_body_size     => $self->{max_body_size},
        access_log        => $self->{access_log},
        server            => $self,  # Add this line
        max_receive_queue => $self->{max_receive_queue},
        max_ws_frame_size => $self->{max_ws_frame_size},
        on_close          => sub { ... },
    );
```

**Step 2: Add server reference to multi-worker connection creation**

Find the similar block in the worker code (around line 772). Add `server => $worker_server`:

```perl
        my $connection = PAGI::Server::Connection->new(
            stream            => $stream,
            app               => $worker_server->{app},
            protocol          => $protocol,
            extensions        => $worker_server->{extensions},
            tls_enabled       => $worker_server->{tls_enabled},
            state             => $worker_server->{state},
            timeout           => $worker_server->{timeout},
            max_body_size     => $worker_server->{max_body_size},
            access_log        => $worker_server->{access_log},
            server            => $worker_server,  # Add this line
            max_receive_queue => $worker_server->{max_receive_queue},
            max_ws_frame_size => $worker_server->{max_ws_frame_size},
            on_close          => sub { ... },
        );
```

**Step 3: Add timer start in worker setup**

In the worker code, after the listener is set up, add timer start (around line 780):

```perl
    # Start access log flush timer for this worker
    $worker_server->_start_access_log_timer;
```

**Step 4: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 5: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: pass server reference to connections for buffered logging"
```

---

## Task 6: Add CLI Options to Runner.pm

**Files:**
- Modify: `lib/PAGI/Runner.pm` (POD, constructor, parse_options, prepare_server)

**Step 1: Add POD documentation**

Add after `log_level` documentation:

```perl
=item access_log_buffer_size => $count

Number of access log entries to buffer before flushing. Default: 100

=item access_log_flush_interval => $seconds

Seconds between automatic buffer flushes. Default: 1
```

**Step 2: Add to constructor**

```perl
        access_log_buffer_size    => $args{access_log_buffer_size}    // undef,
        access_log_flush_interval => $args{access_log_flush_interval} // undef,
```

**Step 3: Add CLI option documentation**

```perl
    --access-log-buffer-size    Entries to buffer before flush (default: 100)
    --access-log-flush-interval Seconds between flushes (default: 1)
```

**Step 4: Add GetOptionsFromArray parsing**

```perl
        'access-log-buffer-size=i'    => \$opts{access_log_buffer_size},
        'access-log-flush-interval=f' => \$opts{access_log_flush_interval},
```

**Step 5: Add option application**

```perl
    $self->{access_log_buffer_size}    = $opts{access_log_buffer_size}    if defined $opts{access_log_buffer_size};
    $self->{access_log_flush_interval} = $opts{access_log_flush_interval} if defined $opts{access_log_flush_interval};
```

**Step 6: Add to prepare_server**

```perl
    if (defined $self->{access_log_buffer_size}) {
        $server_opts{access_log_buffer_size} = $self->{access_log_buffer_size};
    }
    if (defined $self->{access_log_flush_interval}) {
        $server_opts{access_log_flush_interval} = $self->{access_log_flush_interval};
    }
```

**Step 7: Run syntax check**

Run: `perl -c lib/PAGI/Runner.pm`
Expected: `lib/PAGI/Runner.pm syntax OK`

**Step 8: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat: add CLI options for access log buffering"
```

---

## Task 7: Write Tests for Buffered Logging

**Files:**
- Create: `t/25-buffered-access-log.t`

**Step 1: Write test file**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;
use IO::Socket::INET;
use File::Temp qw(tempfile);

use lib 'lib';
use PAGI::Server;

# Test 1: Buffering accumulates entries
subtest 'buffer accumulates entries' => sub {
    my ($fh, $logfile) = tempfile(UNLINK => 1);

    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK' });
        },
        port => 0,
        quiet => 1,
        access_log => $fh,
        access_log_buffer_size => 10,
        access_log_flush_interval => 0,  # Disable timer for deterministic test
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Make 5 requests (less than buffer size)
    for (1..5) {
        my $sock = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
        ) or die "Can't connect: $!";
        print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        my $resp = do { local $/; <$sock> };
        close $sock;
    }

    # Give time for processing
    $loop->loop_once(0.1);

    # Check file - should be empty (buffered)
    seek($fh, 0, 0);
    my $content = do { local $/; <$fh> };
    is($content, '', 'buffer not flushed yet (5 entries < 10 buffer size)');

    # Make 5 more requests (total 10 = buffer size)
    for (1..5) {
        my $sock = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
        ) or die "Can't connect: $!";
        print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        my $resp = do { local $/; <$sock> };
        close $sock;
    }

    $loop->loop_once(0.1);

    # Now buffer should have flushed
    seek($fh, 0, 0);
    $content = do { local $/; <$fh> };
    my @lines = split /\n/, $content;
    is(scalar(@lines), 10, 'buffer flushed when full');

    $server->shutdown->get;
};

# Test 2: Shutdown flushes remaining buffer
subtest 'shutdown flushes buffer' => sub {
    my ($fh, $logfile) = tempfile(UNLINK => 1);

    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK' });
        },
        port => 0,
        quiet => 1,
        access_log => $fh,
        access_log_buffer_size => 100,
        access_log_flush_interval => 0,
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Make 3 requests
    for (1..3) {
        my $sock = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
        ) or die "Can't connect: $!";
        print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        my $resp = do { local $/; <$sock> };
        close $sock;
    }

    $loop->loop_once(0.1);

    # Check file - should be empty
    seek($fh, 0, 0);
    my $content = do { local $/; <$fh> };
    is($content, '', 'buffer not flushed yet');

    # Shutdown
    $server->shutdown->get;

    # Now should be flushed
    seek($fh, 0, 0);
    $content = do { local $/; <$fh> };
    my @lines = split /\n/, $content;
    is(scalar(@lines), 3, 'shutdown flushed remaining entries');
};

# Test 3: Buffering disabled (buffer_size = 1)
subtest 'buffering disabled' => sub {
    my ($fh, $logfile) = tempfile(UNLINK => 1);

    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK' });
        },
        port => 0,
        quiet => 1,
        access_log => $fh,
        access_log_buffer_size => 1,  # Disabled
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Make 1 request
    my $sock = IO::Socket::INET->new(
        PeerHost => '127.0.0.1',
        PeerPort => $port,
    ) or die "Can't connect: $!";
    print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
    my $resp = do { local $/; <$sock> };
    close $sock;

    $loop->loop_once(0.1);

    # Should be immediately written
    seek($fh, 0, 0);
    my $content = do { local $/; <$fh> };
    my @lines = split /\n/, $content;
    is(scalar(@lines), 1, 'immediate write when buffering disabled');

    $server->shutdown->get;
};

done_testing;
```

**Step 2: Run the test**

Run: `prove -l t/25-buffered-access-log.t`
Expected: All tests pass

**Step 3: Commit**

```bash
git add t/25-buffered-access-log.t
git commit -m "test: add buffered access logging tests"
```

---

## Task 8: Update TODO.md

**Files:**
- Modify: `TODO.md`

**Step 1: Mark buffered logging as done**

Update the "Performance: Buffered Access Logging" section:

```markdown
### ~~Performance: Buffered Access Logging~~ **DONE**

Implemented via `access_log_buffer_size` (default 100) and
`access_log_flush_interval` (default 1 second). See `perldoc PAGI::Server`.
```

**Step 2: Commit**

```bash
git add TODO.md
git commit -m "docs: mark buffered access logging as done"
```

---

## Verification

After completing all tasks, verify the full implementation:

```bash
# Run full test suite
prove -l t/

# Test CLI options work
perl -Ilib bin/pagi-server --help 2>&1 | grep -E 'buffer|flush'

# Benchmark comparison (optional)
# Before: PAGI_BENCHMARK_UNBUFFERED=1 hey -n 10000 -c 50 http://localhost:5000/
# After: hey -n 10000 -c 50 http://localhost:5000/
```

---

Plan complete and saved to `docs/plans/2025-12-15-buffered-access-logging.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
