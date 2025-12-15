# Max Requests Per Worker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow workers to restart after handling N requests, preventing unbounded memory growth in long-running deployments. Common in production servers like Starman, Gunicorn, uWSGI.

**Architecture:** Add `max_requests` parameter to Server. Worker tracks request count. After reaching max, worker initiates graceful shutdown (finishes current request, then exits). Parent automatically respawns. Only applies to multi-worker mode.

**Tech Stack:** Perl, existing PAGI::Server multi-worker infrastructure

---

## Task 1: Add max_requests Parameter to Server.pm

**Files:**
- Modify: `lib/PAGI/Server.pm:124-140` (POD documentation)
- Modify: `lib/PAGI/Server.pm:310-330` (_init method)
- Modify: `lib/PAGI/Server.pm:376-395` (configure method)

**Step 1: Add POD documentation**

Add after the `workers` documentation section:

```perl
=item max_requests => $count

Maximum number of requests a worker process will handle before restarting.
After serving this many requests, the worker gracefully shuts down and the
parent spawns a replacement.

B<Default:> 0 (disabled - workers run indefinitely)

B<When to use:>

=over 4

=item * Long-running deployments where gradual memory growth is a concern

=item * Applications with known memory leaks that can't be easily fixed

=item * Defense against slow memory growth (~6.5 bytes/request observed in PAGI)

=back

B<Note:> Only applies in multi-worker mode (C<workers> > 0). In single-worker
mode, this setting is ignored.

B<CLI:> C<--max-requests 10000>

Example: With 4 workers and max_requests=10000, total capacity before any
restart is 40,000 requests. Workers restart individually without downtime.
```

**Step 2: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 3: Add parameter to _init method**

Add after `$self->{workers}` line:

```perl
    $self->{max_requests}     = delete $params->{max_requests} // 0;  # 0 = unlimited
```

**Step 4: Add parameter to configure method**

Add in the configure method:

```perl
    if (exists $params{max_requests}) {
        $self->{max_requests} = delete $params{max_requests};
    }
```

**Step 5: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 6: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: add max_requests parameter documentation and storage"
```

---

## Task 2: Pass max_requests to Worker Server

**Files:**
- Modify: `lib/PAGI/Server.pm:678-692` (worker_server creation)

**Step 1: Pass max_requests to worker server**

In `_run_as_worker`, add `max_requests` to the worker_server constructor:

```perl
    my $worker_server = PAGI::Server->new(
        app             => $self->{app},
        host            => $self->{host},
        port            => $self->{port},
        ssl             => $self->{ssl},
        extensions      => $self->{extensions},
        on_error        => $self->{on_error},
        access_log      => $self->{access_log},
        log_level       => $self->{log_level},
        quiet           => 1,
        timeout         => $self->{timeout},
        max_header_size  => $self->{max_header_size},
        max_header_count => $self->{max_header_count},
        max_body_size    => $self->{max_body_size},
        max_requests     => $self->{max_requests},  # Add this line
        workers          => 0,
    );
```

**Step 2: Initialize request counter in worker**

Add after `$worker_server->{is_worker} = 1;`:

```perl
    $worker_server->{_request_count} = 0;  # Track requests handled
```

**Step 3: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 4: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: pass max_requests to worker and initialize counter"
```

---

## Task 3: Implement Request Counting and Worker Restart

**Files:**
- Modify: `lib/PAGI/Server.pm:759-785` (_on_connection and Connection close handling)

**Step 1: Add request counting callback**

The Connection's on_close callback already exists for tracking. We need to add request counting there. Find the existing `on_close` callback in `_on_connection` and wrap it:

First, add a new method after `_on_connection`:

```perl
# Called when a request completes (for max_requests tracking)
sub _on_request_complete ($self) {
    return unless $self->{is_worker};
    return unless $self->{max_requests} && $self->{max_requests} > 0;

    $self->{_request_count}++;

    if ($self->{_request_count} >= $self->{max_requests}) {
        $self->_log(info => "Worker $$: reached max_requests ($self->{max_requests}), shutting down");
        # Initiate graceful shutdown (finish current connections, then exit)
        $self->shutdown->on_done(sub {
            $self->loop->stop;
        })->retain;
    }
}
```

**Step 2: Run syntax check**

Run: `perl -c lib/PAGI/Server.pm`
Expected: `lib/PAGI/Server.pm syntax OK`

**Step 3: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat: add _on_request_complete method for max_requests"
```

---

## Task 4: Call Request Complete from Connection

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm:99` (constructor - add server ref)
- Modify: `lib/PAGI/Server/Connection.pm:336-345` (_finish_request)

**Step 1: Verify server reference in Connection**

Check that Connection has the `server` reference (from Task 5 of buffered logging plan, or add it if not done):

```perl
        server            => $args{server},         # Reference to parent server
```

**Step 2: Call _on_request_complete after request finishes**

Find the `_finish_request` method or where response completes. Add at the end of request processing (after writing access log):

In the section where `$self->_write_access_log` is called (around line 336-345), add after:

```perl
    # Notify server that request completed (for max_requests tracking)
    if ($self->{server} && $self->{server}->can('_on_request_complete')) {
        $self->{server}->_on_request_complete;
    }
```

**Step 3: Run syntax check**

Run: `perl -c lib/PAGI/Server/Connection.pm`
Expected: `lib/PAGI/Server/Connection.pm syntax OK`

**Step 4: Commit**

```bash
git add lib/PAGI/Server/Connection.pm
git commit -m "feat: notify server on request complete for max_requests"
```

---

## Task 5: Add CLI Option to Runner.pm

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add POD documentation**

```perl
=item max_requests => $count

Maximum requests per worker before restart. Default: 0 (unlimited)
```

**Step 2: Add to constructor**

```perl
        max_requests      => $args{max_requests}      // undef,
```

**Step 3: Add CLI option documentation**

```perl
    --max-requests      Requests per worker before restart (default: unlimited)
```

**Step 4: Add GetOptionsFromArray parsing**

```perl
        'max-requests=i'       => \$opts{max_requests},
```

**Step 5: Add option application**

```perl
    $self->{max_requests}      = $opts{max_requests}      if defined $opts{max_requests};
```

**Step 6: Add to prepare_server**

```perl
    if (defined $self->{max_requests}) {
        $server_opts{max_requests} = $self->{max_requests};
    }
```

**Step 7: Run syntax check**

Run: `perl -c lib/PAGI/Runner.pm`
Expected: `lib/PAGI/Runner.pm syntax OK`

**Step 8: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat: add --max-requests CLI option"
```

---

## Task 6: Write Tests

**Files:**
- Create: `t/26-max-requests.t`

**Step 1: Write test file**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;
use IO::Socket::INET;

use lib 'lib';
use PAGI::Server;

# Test: Worker restarts after max_requests
subtest 'worker restarts after max_requests' => sub {
    plan skip_all => 'Multi-worker tests require fork' unless $^O ne 'MSWin32';

    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => "PID: $$" });
        },
        port => 0,
        quiet => 1,
        workers => 1,
        max_requests => 3,  # Restart after 3 requests
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Make requests and track PIDs
    my @pids;
    for my $i (1..6) {
        my $sock = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
            Timeout  => 5,
        );
        skip "Can't connect on request $i" unless $sock;

        print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        my $resp = do { local $/; <$sock> };
        close $sock;

        if ($resp =~ /PID: (\d+)/) {
            push @pids, $1;
        }

        # Give time for potential worker restart
        $loop->loop_once(0.1) if $i == 3;
    }

    # First 3 requests should be same PID, next 3 should be different
    is(scalar(@pids), 6, 'Got 6 responses');

    if (@pids >= 6) {
        my $first_pid = $pids[0];
        ok($pids[1] == $first_pid && $pids[2] == $first_pid,
           'First 3 requests served by same worker');

        # After restart, PID should change
        my $second_pid = $pids[5];
        ok($second_pid != $first_pid,
           'Worker restarted after max_requests (different PID)');
    }

    $server->shutdown->get;
};

# Test: max_requests=0 means unlimited
subtest 'max_requests 0 means unlimited' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK' });
        },
        port => 0,
        quiet => 1,
        max_requests => 0,  # Unlimited
    );

    is($server->{max_requests}, 0, 'max_requests stored as 0');
    is($server->{_request_count}, undef, 'no request counter initialized (single-worker)');
};

# Test: max_requests ignored in single-worker mode
subtest 'max_requests ignored in single worker mode' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK' });
        },
        port => 0,
        quiet => 1,
        workers => 0,  # Single-worker
        max_requests => 5,
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Make 10 requests - server should not restart
    for (1..10) {
        my $sock = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
        ) or die "Can't connect: $!";
        print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        my $resp = do { local $/; <$sock> };
        close $sock;
        like($resp, qr/200/, "Request $_ succeeded");
    }

    ok($server->is_running, 'Server still running after 10 requests');

    $server->shutdown->get;
};

done_testing;
```

**Step 2: Run the test**

Run: `prove -l t/26-max-requests.t`
Expected: All tests pass (or skip on Windows)

**Step 3: Commit**

```bash
git add t/26-max-requests.t
git commit -m "test: add max_requests per worker tests"
```

---

## Task 7: Update TODO.md

**Files:**
- Modify: `TODO.md`

**Step 1: Mark max_requests as done**

Update the "Max requests per worker" item:

```markdown
- ~~Max requests per worker (--max-requests) for long-running deployments~~ **DONE**
  - Workers restart after N requests via `max_requests` parameter
  - CLI: `pagi-server --workers 4 --max-requests 10000 app.pl`
  - Defense against slow memory growth (~6.5 bytes/request observed)
```

**Step 2: Commit**

```bash
git add TODO.md
git commit -m "docs: mark max_requests per worker as done"
```

---

## Verification

After completing all tasks:

```bash
# Run tests
prove -l t/26-max-requests.t

# Test CLI
perl -Ilib bin/pagi-server --help 2>&1 | grep max-requests

# Manual verification (in separate terminal)
# Terminal 1: Start server with max_requests
perl -Ilib bin/pagi-server --workers 2 --max-requests 5 \
    'PAGI::App::Echo' --quiet 2>&1 | grep 'max_requests'

# Terminal 2: Make requests and observe worker restarts
for i in {1..12}; do
    curl -s http://localhost:5000/ > /dev/null
    echo "Request $i done"
done
```

---

Plan complete and saved to `docs/plans/2025-12-15-max-requests-per-worker.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
