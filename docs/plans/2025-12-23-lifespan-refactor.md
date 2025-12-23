# Lifespan Separation Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Separate lifespan management from routing so routers are composable without lifecycle footguns.

**Architecture:** Create `PAGI::Lifespan` wrapper that handles startup/shutdown and injects app state into `$scope->{'pagi.state'}`. Remove lifecycle methods from `PAGI::Endpoint::Router`. Add `state` accessor to Request/WebSocket/SSE that reads from scope. This gives clean separation: routers define routes (composable), lifespan wrapper manages lifecycle (explicit), state flows via scope (accessible everywhere).

**Tech Stack:** Perl 5.16+, Future::AsyncAwait, Test2::V0

---

## Task 1: Create PAGI::Lifespan Module

**Files:**
- Create: `lib/PAGI/Lifespan.pm`
- Test: `t/lifespan.t`

**Step 1: Write the failing test**

Create `t/lifespan.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

my $loaded = eval { require PAGI::Lifespan; 1 };
ok($loaded, 'PAGI::Lifespan loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Lifespan->can('new'), 'has new');
    ok(PAGI::Lifespan->can('wrap'), 'has wrap');
    ok(PAGI::Lifespan->can('to_app'), 'has to_app');
    ok(PAGI::Lifespan->can('state'), 'has state');
};

subtest 'wrap returns coderef' => sub {
    my $inner_app = async sub { };
    my $app = PAGI::Lifespan->wrap($inner_app);
    is(ref($app), 'CODE', 'wrap returns coderef');
};

subtest 'startup and shutdown callbacks' => sub {
    my $startup_called = 0;
    my $shutdown_called = 0;
    my $state_in_startup;

    my $inner_app = async sub { };

    my $lifespan = PAGI::Lifespan->new(
        app      => $inner_app,
        startup  => async sub {
            my ($state) = @_;
            $startup_called = 1;
            $state->{db} = 'connected';
            $state_in_startup = $state;
        },
        shutdown => async sub {
            my ($state) = @_;
            $shutdown_called = 1;
        },
    );

    my $app = $lifespan->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };

        my $msg_index = 0;
        my @messages = (
            { type => 'lifespan.startup' },
            { type => 'lifespan.shutdown' },
        );
        my $receive = sub { Future->done($messages[$msg_index++]) };

        await $app->({ type => 'lifespan' }, $receive, $send);

        ok($startup_called, 'startup callback was called');
        ok($shutdown_called, 'shutdown callback was called');
        is($sent[0]{type}, 'lifespan.startup.complete', 'startup complete sent');
        is($sent[1]{type}, 'lifespan.shutdown.complete', 'shutdown complete sent');
        is($state_in_startup->{db}, 'connected', 'state was passed to startup');
    })->()->get;
};

subtest 'state injected into scope for requests' => sub {
    my $scope_state;

    my $inner_app = async sub {
        my ($scope, $receive, $send) = @_;
        $scope_state = $scope->{'pagi.state'};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok' });
    };

    my $lifespan = PAGI::Lifespan->new(
        app     => $inner_app,
        startup => async sub {
            my ($state) = @_;
            $state->{db} = 'test-connection';
        },
    );

    my $app = $lifespan->to_app;

    (async sub {
        # First run lifespan startup
        my $msg_index = 0;
        my @lifespan_messages = (
            { type => 'lifespan.startup' },
            { type => 'lifespan.shutdown' },
        );

        await $app->(
            { type => 'lifespan' },
            sub { Future->done($lifespan_messages[$msg_index++]) },
            sub { Future->done }
        );

        # Now make an HTTP request
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done }
        );

        is($scope_state->{db}, 'test-connection', 'state injected into scope');
    })->()->get;
};

subtest 'startup failure sends failed message' => sub {
    my $inner_app = async sub { };

    my $lifespan = PAGI::Lifespan->new(
        app     => $inner_app,
        startup => async sub { die "Connection failed"; },
    );

    my $app = $lifespan->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'lifespan' },
            sub { Future->done({ type => 'lifespan.startup' }) },
            sub { push @sent, $_[0]; Future->done }
        );

        is($sent[0]{type}, 'lifespan.startup.failed', 'startup failed sent');
        like($sent[0]{message}, qr/Connection failed/, 'error message included');
    })->()->get;
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/lifespan.t`
Expected: FAIL with "Can't locate PAGI/Lifespan.pm"

**Step 3: Write minimal implementation**

Create `lib/PAGI/Lifespan.pm`:

```perl
package PAGI::Lifespan;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    my $app = delete $args{app}
        or croak "PAGI::Lifespan requires 'app' parameter";

    return bless {
        app      => $app,
        startup  => $args{startup},
        shutdown => $args{shutdown},
        _state   => {},
    }, $class;
}

sub state { shift->{_state} }

sub wrap {
    my ($class, $app, %args) = @_;

    my $self = $class->new(app => $app, %args);
    return $self->to_app;
}

sub to_app {
    my ($self) = @_;

    my $app      = $self->{app};
    my $startup  = $self->{startup};
    my $shutdown = $self->{shutdown};
    my $state    = $self->{_state};

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';

        if ($type eq 'lifespan') {
            await _handle_lifespan($state, $startup, $shutdown, $receive, $send);
            return;
        }

        # Inject state into scope for all other request types
        $scope->{'pagi.state'} = $state;

        await $app->($scope, $receive, $send);
    };
}

async sub _handle_lifespan {
    my ($state, $startup, $shutdown, $receive, $send) = @_;

    while (1) {
        my $msg = await $receive->();
        my $type = $msg->{type} // '';

        if ($type eq 'lifespan.startup') {
            if ($startup) {
                eval { await $startup->($state) };
                if ($@) {
                    await $send->({
                        type    => 'lifespan.startup.failed',
                        message => "$@",
                    });
                    return;
                }
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            if ($shutdown) {
                eval { await $shutdown->($state) };
            }
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

1;

__END__

=head1 NAME

PAGI::Lifespan - Wrap a PAGI app with lifecycle management

=head1 SYNOPSIS

    use PAGI::Lifespan;
    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;
    $router->get('/' => sub { ... });

    my $app = PAGI::Lifespan->wrap(
        $router->to_app,
        startup => async sub {
            my ($state) = @_;
            $state->{db} = DBI->connect(...);
        },
        shutdown => async sub {
            my ($state) = @_;
            $state->{db}->disconnect;
        },
    );

    # Or using OO interface for access to state
    my $lifespan = PAGI::Lifespan->new(
        app     => $router->to_app,
        startup => async sub { ... },
    );
    my $app = $lifespan->to_app;

=head1 DESCRIPTION

PAGI::Lifespan wraps any PAGI application with lifecycle management.
It handles C<lifespan.startup> and C<lifespan.shutdown> events and
injects application state into the scope for all requests.

=head2 State Flow

During startup, the C<startup> callback receives a state hashref.
Populate it with database connections, caches, configuration, etc.

For every request, this state is injected into the scope as
C<$scope-E<gt>{'pagi.state'}>. This makes it accessible via:

    $req->state->{db}    # In HTTP handlers
    $ws->state->{db}     # In WebSocket handlers
    $sse->state->{db}    # In SSE handlers

=head2 Separation of Concerns

This design separates:

=over 4

=item * B<Routing> - Define routes with PAGI::App::Router or PAGI::Endpoint::Router

=item * B<Lifecycle> - Manage startup/shutdown with PAGI::Lifespan

=item * B<State> - Flows via scope, accessible everywhere

=back

Routers are composable (mount subrouters freely). Lifecycle is explicit
and visible at the app entry point.

=head1 METHODS

=head2 new

    my $lifespan = PAGI::Lifespan->new(
        app      => $pagi_app,      # Required
        startup  => async sub { },  # Optional
        shutdown => async sub { },  # Optional
    );

Create a new Lifespan wrapper.

=head2 wrap

    my $app = PAGI::Lifespan->wrap($inner_app, startup => ..., shutdown => ...);

Class method shortcut that creates a wrapper and returns the app coderef.

=head2 to_app

    my $app = $lifespan->to_app;

Returns the wrapped PAGI application coderef.

=head2 state

    my $state = $lifespan->state;

Returns the state hashref. Useful for accessing state from outside
the callbacks (e.g., for testing).

=head1 SEE ALSO

L<PAGI::App::Router>, L<PAGI::Endpoint::Router>

=cut
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/lifespan.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Lifespan.pm t/lifespan.t
git commit -m "feat(lifespan): add PAGI::Lifespan for lifecycle management

Separates lifecycle from routing:
- startup/shutdown callbacks receive state hashref
- State injected into scope as pagi.state for all requests
- Routers become composable without lifecycle footguns"
```

---

## Task 2: Add state Accessor to PAGI::Request

**Files:**
- Modify: `lib/PAGI/Request.pm`
- Test: `t/request-state.t`

**Step 1: Write the failing test**

Create `t/request-state.t`:

```perl
use strict;
use warnings;
use Test2::V0;

require PAGI::Request;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        'pagi.state' => { db => 'test-connection', config => { env => 'test' } },
    };

    my $req = PAGI::Request->new($scope, sub { });

    is(ref($req->state), 'HASH', 'state returns hashref');
    is($req->state->{db}, 'test-connection', 'state contains db');
    is($req->state->{config}{env}, 'test', 'state contains nested config');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $req = PAGI::Request->new($scope, sub { });

    is(ref($req->state), 'HASH', 'state returns hashref');
    is_deeply($req->state, {}, 'state is empty hash when not injected');
};

subtest 'state is separate from stash' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        'pagi.state' => { db => 'connection' },
    };

    my $req = PAGI::Request->new($scope, sub { });

    # Set something in stash
    $req->stash->{user} = 'alice';

    # Verify they are separate
    is($req->state->{db}, 'connection', 'state has app data');
    is($req->stash->{user}, 'alice', 'stash has request data');
    ok(!exists $req->state->{user}, 'state does not have stash data');
    ok(!exists $req->stash->{db}, 'stash does not have state data');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/request-state.t`
Expected: FAIL with "Can't locate object method 'state'"

**Step 3: Write minimal implementation**

Add to `lib/PAGI/Request.pm` after the `stash` method (around line 310):

```perl
# Application state (injected by PAGI::Lifespan, read-only)
sub state {
    my $self = shift;
    return $self->{scope}{'pagi.state'} // {};
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/request-state.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Request.pm t/request-state.t
git commit -m "feat(request): add state accessor for app state

Reads from scope->{'pagi.state'}, injected by PAGI::Lifespan.
Separate from stash (per-request data)."
```

---

## Task 3: Add state Accessor to PAGI::WebSocket

**Files:**
- Modify: `lib/PAGI/WebSocket.pm`
- Test: `t/websocket-state.t`

**Step 1: Write the failing test**

Create `t/websocket-state.t`:

```perl
use strict;
use warnings;
use Test2::V0;

require PAGI::WebSocket;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
        'pagi.state' => { db => 'test-connection' },
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is(ref($ws->state), 'HASH', 'state returns hashref');
    is($ws->state->{db}, 'test-connection', 'state contains db');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is(ref($ws->state), 'HASH', 'state returns hashref');
    is_deeply($ws->state, {}, 'state is empty when not injected');
};

subtest 'state is separate from stash' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
        'pagi.state' => { db => 'connection' },
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    $ws->stash->{room} = 'lobby';

    is($ws->state->{db}, 'connection', 'state has app data');
    is($ws->stash->{room}, 'lobby', 'stash has connection data');
    ok(!exists $ws->state->{room}, 'state does not have stash data');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/websocket-state.t`
Expected: FAIL with "Can't locate object method 'state'" (conflicts with internal _state)

Note: PAGI::WebSocket already has a `state` method that returns internal `_state`. We need to rename the app state accessor or the internal state.

**Step 3: Rename internal state and add app state accessor**

In `lib/PAGI/WebSocket.pm`:

1. The existing `sub state { shift->{_state} }` (line ~64) returns connection state ('connecting', 'connected', 'closed'). Rename to `connection_state`.

2. Add new `state` accessor for app state.

Find and replace in `lib/PAGI/WebSocket.pm`:
- Change `sub state { shift->{_state} }` to `sub connection_state { shift->{_state} }`
- Add after stash method:

```perl
# Application state (injected by PAGI::Lifespan, read-only)
sub state {
    my $self = shift;
    return $self->{scope}{'pagi.state'} // {};
}
```

- Update any internal references from `->state` to `->connection_state` (check for `$self->state` usage)

**Step 4: Run test to verify it passes**

Run: `prove -l t/websocket-state.t`
Expected: PASS

Also run: `prove -l t/websocket*.t` to ensure no regressions.

**Step 5: Commit**

```bash
git add lib/PAGI/WebSocket.pm t/websocket-state.t
git commit -m "feat(websocket): add state accessor for app state

- Rename internal state to connection_state
- Add state accessor reading from scope->{'pagi.state'}
- Separate from stash (per-connection data)"
```

---

## Task 4: Add state Accessor to PAGI::SSE

**Files:**
- Modify: `lib/PAGI/SSE.pm`
- Test: `t/sse-state.t`

**Step 1: Write the failing test**

Create `t/sse-state.t`:

```perl
use strict;
use warnings;
use Test2::V0;

require PAGI::SSE;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
        'pagi.state' => { db => 'test-connection' },
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    # Note: SSE has 'state' for internal state, need to handle naming
    is(ref($sse->app_state), 'HASH', 'app_state returns hashref');
    is($sse->app_state->{db}, 'test-connection', 'app_state contains db');
};

subtest 'app_state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is_deeply($sse->app_state, {}, 'app_state is empty when not injected');
};

done_testing;
```

Wait - SSE already has `sub state { shift->{_state} }` for internal connection state. Let me reconsider.

**Revised approach:** For consistency across Request/WebSocket/SSE, we should:
- Use `state` for app state (from scope)
- Use `connection_state` for internal connection state (SSE/WebSocket only)

Update the test:

```perl
use strict;
use warnings;
use Test2::V0;

require PAGI::SSE;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
        'pagi.state' => { db => 'test-connection' },
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is(ref($sse->state), 'HASH', 'state returns hashref');
    is($sse->state->{db}, 'test-connection', 'state contains db');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is_deeply($sse->state, {}, 'state is empty when not injected');
};

subtest 'connection_state for internal state' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is($sse->connection_state, 'pending', 'connection_state returns internal state');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/sse-state.t`
Expected: FAIL

**Step 3: Write minimal implementation**

In `lib/PAGI/SSE.pm`:

1. Rename `sub state { shift->{_state} }` to `sub connection_state { shift->{_state} }`

2. Add new `state` accessor:

```perl
# Application state (injected by PAGI::Lifespan, read-only)
sub state {
    my $self = shift;
    return $self->{scope}{'pagi.state'} // {};
}
```

3. Update internal references from `$self->state` to `$self->connection_state` or `$self->{_state}`

**Step 4: Run test to verify it passes**

Run: `prove -l t/sse-state.t t/sse*.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/SSE.pm t/sse-state.t
git commit -m "feat(sse): add state accessor for app state

- Rename internal state to connection_state
- Add state accessor reading from scope->{'pagi.state'}"
```

---

## Task 5: Remove Lifecycle from PAGI::Endpoint::Router

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `t/endpoint-router.t`

**Step 1: Update the Router module**

In `lib/PAGI/Endpoint/Router.pm`:

1. Remove `on_startup` method (lines 32-36)
2. Remove `on_shutdown` method (lines 38-42)
3. Remove `_handle_lifespan` method (lines 75-99)
4. Remove lifespan handling from `to_app` (lines 64-68)
5. Add state injection into scope in `to_app`
6. Update POD documentation

The new `to_app` should be:

```perl
sub to_app {
    my ($class) = @_;

    # Create instance that lives for app lifetime
    my $instance = blessed($class) ? $class : $class->new;

    # Store instance reference for state access
    $instance->{router} = do {
        load('PAGI::App::Router');
        PAGI::App::Router->new;
    };

    # Let subclass define routes
    $instance->_build_routes($instance->{router});

    my $app = $instance->{router}->to_app;
    my $state = $instance->{_state};

    return async sub {
        my ($scope, $receive, $send) = @_;

        # Inject instance state into scope (allows $req->state to work)
        $scope->{'pagi.state'} //= $state;

        # Dispatch to internal router
        await $app->($scope, $receive, $send);
    };
}
```

**Step 2: Update the test file**

In `t/endpoint-router.t`:

1. Remove `ok(PAGI::Endpoint::Router->can('on_startup'), 'has on_startup');`
2. Remove `ok(PAGI::Endpoint::Router->can('on_shutdown'), 'has on_shutdown');`
3. Update the "lifespan startup and shutdown with state" subtest to test state injection instead

Replace the lifespan subtest with:

```perl
subtest 'state accessible in handlers' => sub {
    {
        package TestApp::State;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $state_value;

        sub routes {
            my ($self, $r) = @_;
            # Pre-populate state (normally done via PAGI::Lifespan)
            $self->state->{db} = 'connected';
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $req, $res) = @_;
            # Access state via $self->state
            $state_value = $self->state->{db};
            # Also accessible via $req->state
            my $req_state = $req->state->{db};
            await $res->json({ self_state => $state_value, req_state => $req_state });
        }
    }

    my $app = TestApp::State->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({ type => 'http', method => 'GET', path => '/test', headers => [] },
                     $receive, $send);

        is($TestApp::State::state_value, 'connected', 'state accessible via $self->state');
        like($sent[1]{body}, qr/"req_state":"connected"/, 'state accessible via $req->state');
    })->()->get;
};
```

**Step 3: Run tests**

Run: `prove -l t/endpoint-router.t`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t
git commit -m "refactor(router): remove lifecycle from Endpoint::Router

BREAKING CHANGE: on_startup and on_shutdown removed from Router.
Use PAGI::Lifespan wrapper for lifecycle management instead.

- Router now injects its state into scope
- State accessible via \$self->state and \$req->state
- Routers are now freely composable without lifecycle footguns"
```

---

## Task 6: Update Example Application

**Files:**
- Modify: `examples/endpoint-router-demo/app.pl`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`

**Step 1: Update app.pl to use PAGI::Lifespan**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Future::AsyncAwait;

use MyApp::Main;
use PAGI::Lifespan;

my $router = MyApp::Main->new;

# Wrap with lifecycle management
PAGI::Lifespan->wrap(
    $router->to_app,
    startup => async sub {
        my ($state) = @_;
        warn "MyApp starting up...\n";

        $state->{config} = {
            app_name => 'Endpoint Router Demo',
            version  => '1.0.0',
        };

        $state->{metrics} = {
            requests  => 0,
            ws_active => 0,
        };

        # Copy to router instance state for $self->state access
        %{$router->state} = %$state;

        warn "MyApp ready!\n";
    },
    shutdown => async sub {
        my ($state) = @_;
        warn "MyApp shutting down...\n";
    },
);
```

**Step 2: Update MyApp::Main - remove lifecycle methods**

Remove `on_startup` and `on_shutdown` from `lib/MyApp/Main.pm`. The state is now managed by PAGI::Lifespan in app.pl.

Keep the handlers accessing `$self->state` - this still works because:
1. PAGI::Lifespan injects state into scope
2. Router also injects its instance state into scope
3. Both reference the same data (copied in app.pl)

Simplified `MyApp/Main.pm`:

```perl
package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API;
use PAGI::App::File;
use File::Spec;
use File::Basename qw(dirname);

sub routes {
    my ($self, $r) = @_;

    $r->get('/' => 'home');
    $r->mount('/api' => MyApp::API->to_app);
    $r->websocket('/ws/echo' => 'ws_echo');
    $r->sse('/events/metrics' => 'sse_metrics');

    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');
    $r->mount('/' => PAGI::App::File->new(root => $root)->to_app);
}

async sub home {
    my ($self, $req, $res) = @_;
    my $config = $self->state->{config};
    # ... rest of handler
}

# ... other handlers unchanged, they access $self->state
```

**Step 3: Update MyApp::API - remove lazy init hack**

The subrouter can now access state via `$req->state` since it flows through scope:

```perl
package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

my @USERS = (
    { id => 1, name => 'Alice', email => 'alice@example.com' },
    { id => 2, name => 'Bob', email => 'bob@example.com' },
);

sub routes {
    my ($self, $r) = @_;
    $r->get('/info' => 'get_info');
    $r->get('/users' => 'list_users');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');
}

async sub get_info {
    my ($self, $req, $res) = @_;

    # Access app state via $req->state (injected by PAGI::Lifespan)
    my $config = $req->state->{config};

    await $res->json({
        app     => $config->{app_name},
        version => $config->{version},
        api     => 'v1',
    });
}

# ... other handlers
```

**Step 4: Run the example to verify it works**

```bash
cd examples/endpoint-router-demo
perl -Ilib ../../bin/pagi-server --app app.pl --port 5000
# Test in another terminal:
curl http://localhost:5000/
curl http://localhost:5000/api/info
```

**Step 5: Commit**

```bash
git add examples/endpoint-router-demo/
git commit -m "refactor(example): use PAGI::Lifespan for lifecycle

- Move startup/shutdown to app.pl using PAGI::Lifespan
- Remove on_startup/on_shutdown from MyApp::Main
- Subrouter accesses state via \$req->state
- Removes lazy init hack from MyApp::API"
```

---

## Task 7: Update Integration Tests

**Files:**
- Modify: `t/integration-endpoint-router-demo.t`

**Step 1: Update test to use PAGI::Lifespan**

The test currently relies on lifespan being handled by the Router. Update to use PAGI::Lifespan wrapper:

```perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/endpoint-router-demo/lib";
use lib "$Bin/../lib";
use Future::AsyncAwait;

use PAGI::Test::Client;
use PAGI::Lifespan;

# Load example app modules
subtest 'example app modules load' => sub {
    my $main_loaded = eval { require MyApp::Main; 1 };
    ok($main_loaded, 'MyApp::Main loads') or diag $@;

    my $api_loaded = eval { require MyApp::API; 1 };
    ok($api_loaded, 'MyApp::API loads') or diag $@;
};

subtest 'MyApp::Main class structure' => sub {
    ok(MyApp::Main->can('new'), 'has new');
    ok(MyApp::Main->can('to_app'), 'has to_app');
    ok(MyApp::Main->can('routes'), 'has routes');
    ok(MyApp::Main->can('state'), 'has state');
    ok(MyApp::Main->can('home'), 'has home handler');
    ok(MyApp::Main->can('ws_echo'), 'has ws_echo handler');
    ok(MyApp::Main->can('sse_metrics'), 'has sse_metrics handler');
    # No longer has on_startup/on_shutdown
};

subtest 'app routes work with lifespan' => sub {
    my $router = MyApp::Main->new;

    my $app = PAGI::Lifespan->wrap(
        $router->to_app,
        startup => async sub {
            my ($state) = @_;
            $state->{config} = {
                app_name => 'Endpoint Router Demo',
                version  => '1.0.0',
            };
            $state->{metrics} = {
                requests  => 0,
                ws_active => 0,
            };
            %{$router->state} = %$state;
        },
    );

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        subtest 'home page' => sub {
            my $res = $client->get('/');
            is($res->status, 200, '/ returns 200');
            like($res->text, qr/Endpoint Router Demo/, 'body contains app name from state');
        };

        subtest 'API info' => sub {
            my $res = $client->get('/api/info');
            is($res->status, 200, '/api/info returns 200');
            like($res->text, qr/version/, 'body contains version');
        };

        subtest 'API users list' => sub {
            my $res = $client->get('/api/users');
            is($res->status, 200, '/api/users returns 200');
            like($res->text, qr/Alice|Bob/, 'body contains user names');
        };

        subtest 'WebSocket echo' => sub {
            $client->websocket('/ws/echo', sub {
                my ($ws) = @_;
                my $msg = $ws->receive_json;
                is($msg->{type}, 'connected', 'received connected message');
            });
        };

        subtest 'SSE metrics' => sub {
            $client->sse('/events/metrics', sub {
                my ($sse) = @_;
                my $event = $sse->receive_event;
                is($event->{event}, 'connected', 'received connected event');
            });
        };
    });
};

done_testing;
```

**Step 2: Run test**

Run: `prove -l t/integration-endpoint-router-demo.t`
Expected: PASS

**Step 3: Commit**

```bash
git add t/integration-endpoint-router-demo.t
git commit -m "test: update integration test for lifespan refactor

Use PAGI::Lifespan wrapper instead of relying on Router lifecycle"
```

---

## Task 8: Update Documentation

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm` (POD)
- Modify: `Changes`

**Step 1: Update Router POD**

Update the POD in `lib/PAGI/Endpoint/Router.pm`:

1. Remove on_startup/on_shutdown from SYNOPSIS
2. Update description to explain new pattern
3. Add migration guide
4. Reference PAGI::Lifespan

New SYNOPSIS:

```perl
=head1 SYNOPSIS

    package MyApp;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    sub routes {
        my ($self, $r) = @_;

        $r->get('/users' => ['require_auth'] => 'list_users');
        $r->get('/users/:id' => 'get_user');
        $r->websocket('/ws/chat/:room' => 'chat_handler');
        $r->sse('/events' => 'events_handler');
        $r->mount('/api' => MyApp::API->to_app);
    }

    async sub require_auth {
        my ($self, $req, $res, $next) = @_;
        my $user = verify_token($req->bearer_token);
        $req->stash->{user} = $user;
        await $next->();
    }

    async sub list_users {
        my ($self, $req, $res) = @_;
        my $db = $req->state->{db};  # App state from PAGI::Lifespan
        await $res->json($db->get_users);
    }

    # In app.pl - wrap with lifecycle
    use MyApp;
    use PAGI::Lifespan;

    my $router = MyApp->new;

    PAGI::Lifespan->wrap(
        $router->to_app,
        startup => async sub {
            my ($state) = @_;
            $state->{db} = DBI->connect(...);
            %{$router->state} = %$state;
        },
        shutdown => async sub {
            my ($state) = @_;
            $state->{db}->disconnect;
        },
    );
```

**Step 2: Update Changes file**

Add to the [Unreleased] section in `Changes`:

```markdown
### Changed

- **BREAKING**: Removed `on_startup` and `on_shutdown` from PAGI::Endpoint::Router
  - Use PAGI::Lifespan wrapper for lifecycle management instead
  - Routers are now freely composable without lifecycle concerns

### Added

- New `PAGI::Lifespan` module for explicit lifecycle management
- `state` accessor on Request, WebSocket, SSE for app state access
- `connection_state` accessor on WebSocket, SSE (renamed from `state`)

### Migration Guide

**Before (lifecycle in router):**
```perl
package MyApp;
use parent 'PAGI::Endpoint::Router';

async sub on_startup {
    my ($self) = @_;
    $self->state->{db} = DBI->connect(...);
}

# app.pl
MyApp->to_app;
```

**After (lifecycle via wrapper):**
```perl
package MyApp;
use parent 'PAGI::Endpoint::Router';
# No on_startup/on_shutdown

# app.pl
use PAGI::Lifespan;
my $router = MyApp->new;

PAGI::Lifespan->wrap(
    $router->to_app,
    startup => async sub {
        my ($state) = @_;
        $state->{db} = DBI->connect(...);
        %{$router->state} = %$state;  # Sync with router
    },
);
```

**Accessing state:**
```perl
# In handlers - both work
my $db = $self->state->{db};   # Via router instance
my $db = $req->state->{db};    # Via request (from scope)

# In subrouters - use request
my $db = $req->state->{db};    # Always works
```
```

**Step 3: Commit**

```bash
git add lib/PAGI/Endpoint/Router.pm Changes
git commit -m "docs: update documentation for lifespan refactor

- Update Router POD with new usage pattern
- Add migration guide to Changes
- Document PAGI::Lifespan integration"
```

---

## Task 9: Run Full Test Suite and Fix Any Issues

**Step 1: Run full test suite**

```bash
prove -l t/
```

**Step 2: Fix any failing tests**

Common issues to watch for:
- Tests that expect `on_startup`/`on_shutdown` methods
- Tests using `$ws->state` or `$sse->state` for connection state (now `connection_state`)
- Tests that don't inject `pagi.state` into scope

**Step 3: Commit fixes**

```bash
git add -A
git commit -m "fix: address test failures from lifespan refactor"
```

---

## Task 10: Final Verification and Cleanup

**Step 1: Run full test suite again**

```bash
prove -l t/
```
Expected: All tests pass

**Step 2: Test example app manually**

```bash
cd examples/endpoint-router-demo
perl -I../../lib -Ilib ../../bin/pagi-server --app app.pl --port 5000
```

Test in browser:
- http://localhost:5000/ - Home page with demo UI
- http://localhost:5000/api/info - Should return app info
- http://localhost:5000/api/users - Should return user list
- WebSocket echo should work
- SSE metrics should stream

**Step 3: Final commit**

```bash
git add -A
git commit -m "chore: final cleanup for lifespan refactor"
```

---

## Summary

This refactor achieves:

1. **Separation of concerns**: Routers define routes, Lifespan manages lifecycle
2. **Composable routers**: Mount subrouters freely without lifecycle footguns
3. **Clear state flow**: App state via `$req->state`, request data via `$req->stash`
4. **Explicit lifecycle**: Visible at app entry point, not hidden in router classes
5. **Starlette-like design**: Follows proven patterns from Python ecosystem
