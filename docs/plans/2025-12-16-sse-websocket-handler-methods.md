# SSE/WebSocket Handler Methods and Named Routes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable `#method` syntax and named routes for SSE and WebSocket routes in handlers, matching HTTP route capabilities.

**Architecture:** Extend Router::Scoped's `sse()` and `websocket()` methods to detect `#method` strings and resolve them against the handler instance. Modify PAGI::Simple's `sse()` and `websocket()` methods to accept optional name parameter and register with a named route registry.

**Tech Stack:** Perl, PAGI::Simple, Test2::V0

---

## Background

Currently HTTP routes support:
```perl
$r->get('/' => '#index')->name('home');
$r->post('/todos' => '#create')->name('todos_create');
```

But SSE/WebSocket require coderefs:
```perl
$r->sse('/live' => sub ($sse) { ... });
$r->websocket('/chat' => sub ($ws) { ... });
```

After this implementation:
```perl
$r->sse('/live' => '#live')->name('live_updates');
$r->websocket('/chat' => '#chat')->name('chat_room');
```

---

### Task 1: Add SSE #method Support in Router::Scoped

**Files:**
- Modify: `lib/PAGI/Simple/Router.pm:388-392`
- Test: `t/simple/51-handler-sse-ws.t` (new)

**Step 1: Write the failing test**

Create `t/simple/51-handler-sse-ws.t`:

```perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

use PAGI::Simple;
use PAGI::Simple::Handler;

# Helper to simulate SSE connection
sub simulate_sse ($app, %opts) {
    my $path = $opts{path} // '/events';
    my @sent;
    my $scope = { type => 'sse', path => $path };

    my @events = ({ type => 'sse.disconnect' });
    my $event_index = 0;

    my $receive = sub {
        return Future->done($events[$event_index++] // { type => 'sse.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return { sent => \@sent };
}

# Test handler class
{
    package TestApp::Events;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    our $live_called = 0;
    our $live_sse_ref;

    sub routes ($class, $app, $r) {
        $r->sse('/live' => '#live');
    }

    sub live ($self, $sse) {
        $live_called = 1;
        $live_sse_ref = $sse;
        $sse->send_event(data => 'connected');
    }
}

# Test 1: SSE #method syntax works
subtest 'sse #method syntax resolves handler method' => sub {
    $TestApp::Events::live_called = 0;
    $TestApp::Events::live_sse_ref = undef;

    my $app = PAGI::Simple->new;
    $app->mount('/' => 'TestApp::Events');

    my $result = simulate_sse($app, path => '/live');

    ok($TestApp::Events::live_called, 'handler method was called');
    ok($TestApp::Events::live_sse_ref, 'received SSE context');
    ok($TestApp::Events::live_sse_ref->isa('PAGI::Simple::SSE'), 'context is SSE object');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: FAIL - handler method not called (coderef not resolved)

**Step 3: Implement SSE #method resolution in Router::Scoped**

Modify `lib/PAGI/Simple/Router.pm` - replace the `sse` method:

```perl
sub sse ($self, $path, @args) {
    my $full_path = $self->{prefix} . $path;
    $full_path =~ s{^//+}{/};

    # Resolve #method syntax
    my @resolved_args;
    for my $arg (@args) {
        if (!ref($arg) && $arg =~ /^#(\w+)$/) {
            my $method = $1;
            my $instance = $self->{handler_instance};
            push @resolved_args, sub ($sse) {
                $instance->$method($sse);
            };
        } else {
            push @resolved_args, $arg;
        }
    }

    $self->{app}->sse($full_path, @resolved_args);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple/Router.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: add #method syntax support for SSE routes in handlers"
```

---

### Task 2: Add WebSocket #method Support in Router::Scoped

**Files:**
- Modify: `lib/PAGI/Simple/Router.pm:394-398`
- Test: `t/simple/51-handler-sse-ws.t`

**Step 1: Write the failing test**

Add to `t/simple/51-handler-sse-ws.t`:

```perl
# Helper to simulate WebSocket connection
sub simulate_websocket ($app, %opts) {
    my $path = $opts{path} // '/ws';
    my $messages = $opts{messages} // [];
    my @sent;

    my $scope = { type => 'websocket', path => $path };

    my @events = ({ type => 'websocket.connect' });
    push @events, { type => 'websocket.receive', text => $_ } for @$messages;
    push @events, { type => 'websocket.disconnect' };

    my $event_index = 0;

    my $receive = sub {
        return Future->done($events[$event_index++] // { type => 'websocket.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return { sent => \@sent };
}

# WebSocket test handler
{
    package TestApp::Chat;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    our $chat_called = 0;
    our $chat_ws_ref;

    sub routes ($class, $app, $r) {
        $r->websocket('/room' => '#room');
    }

    sub room ($self, $ws) {
        $chat_called = 1;
        $chat_ws_ref = $ws;
    }
}

# Test 2: WebSocket #method syntax works
subtest 'websocket #method syntax resolves handler method' => sub {
    $TestApp::Chat::chat_called = 0;
    $TestApp::Chat::chat_ws_ref = undef;

    my $app = PAGI::Simple->new;
    $app->mount('/chat' => 'TestApp::Chat');

    my $result = simulate_websocket($app, path => '/chat/room');

    ok($TestApp::Chat::chat_called, 'handler method was called');
    ok($TestApp::Chat::chat_ws_ref, 'received WebSocket context');
    ok($TestApp::Chat::chat_ws_ref->isa('PAGI::Simple::WebSocket'), 'context is WebSocket object');
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: FAIL - websocket handler method not called

**Step 3: Implement WebSocket #method resolution in Router::Scoped**

Modify `lib/PAGI/Simple/Router.pm` - replace the `websocket` method:

```perl
sub websocket ($self, $path, @args) {
    my $full_path = $self->{prefix} . $path;
    $full_path =~ s{^//+}{/};

    # Resolve #method syntax
    my @resolved_args;
    for my $arg (@args) {
        if (!ref($arg) && $arg =~ /^#(\w+)$/) {
            my $method = $1;
            my $instance = $self->{handler_instance};
            push @resolved_args, sub ($ws) {
                $instance->$method($ws);
            };
        } else {
            push @resolved_args, $arg;
        }
    }

    $self->{app}->websocket($full_path, @resolved_args);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple/Router.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: add #method syntax support for WebSocket routes in handlers"
```

---

### Task 3: Add Named Route Support for SSE Routes

**Files:**
- Modify: `lib/PAGI/Simple.pm:2454-2460` (sse method)
- Test: `t/simple/51-handler-sse-ws.t`

**Step 1: Write the failing test**

Add to `t/simple/51-handler-sse-ws.t`:

```perl
# Test 3: SSE named routes
subtest 'sse routes can be named' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->sse('/events' => sub ($sse) { });

    # Should return something chainable with ->name()
    ok($result->can('name'), 'sse returns object with name method');

    $result->name('live_events');

    my $url = $app->url_for('live_events');
    is($url, '/events', 'url_for resolves named SSE route');
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: FAIL - sse returns $app (no name method that registers routes)

**Step 3: Implement named SSE routes**

Modify `lib/PAGI/Simple.pm` - update the `sse` method:

```perl
sub sse ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    my $route = $self->{sse_router}->add('GET', $full_path, $handler);
    return $route;  # Return route for chaining ->name()
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: add named route support for SSE routes"
```

---

### Task 4: Add Named Route Support for WebSocket Routes

**Files:**
- Modify: `lib/PAGI/Simple.pm:2420-2426` (websocket method)
- Test: `t/simple/51-handler-sse-ws.t`

**Step 1: Write the failing test**

Add to `t/simple/51-handler-sse-ws.t`:

```perl
# Test 4: WebSocket named routes
subtest 'websocket routes can be named' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->websocket('/chat' => sub ($ws) { });

    ok($result->can('name'), 'websocket returns object with name method');

    $result->name('chat_room');

    my $url = $app->url_for('chat_room');
    is($url, '/chat', 'url_for resolves named WebSocket route');
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: FAIL - websocket returns $app

**Step 3: Implement named WebSocket routes**

Modify `lib/PAGI/Simple.pm` - update the `websocket` method:

```perl
sub websocket ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    my $route = $self->{ws_router}->add('GET', $full_path, $handler);
    return $route;  # Return route for chaining ->name()
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: add named route support for WebSocket routes"
```

---

### Task 5: Ensure Named SSE/WebSocket Routes Work with url_for

**Files:**
- Modify: `lib/PAGI/Simple.pm` (url_for method if needed)
- Test: `t/simple/51-handler-sse-ws.t`

**Step 1: Write the failing test**

Add to `t/simple/51-handler-sse-ws.t`:

```perl
# Test 5: url_for works across all router types
subtest 'url_for finds routes in all routers' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/home' => sub ($c) { $c->text('ok') })->name('home');
    $app->sse('/events' => sub ($sse) { })->name('events');
    $app->websocket('/ws' => sub ($ws) { })->name('websocket');

    is($app->url_for('home'), '/home', 'finds HTTP route');
    is($app->url_for('events'), '/events', 'finds SSE route');
    is($app->url_for('websocket'), '/ws', 'finds WebSocket route');
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: May FAIL if url_for only checks main router

**Step 3: Update url_for to check all routers**

Check if `url_for` in `lib/PAGI/Simple.pm` needs to search `sse_router` and `ws_router`:

```perl
sub url_for ($self, $name, %params) {
    # Check main router first
    my $url = $self->{router}->url_for($name, %params);
    return $url if defined $url;

    # Check SSE router
    $url = $self->{sse_router}->url_for($name, %params);
    return $url if defined $url;

    # Check WebSocket router
    $url = $self->{ws_router}->url_for($name, %params);
    return $url if defined $url;

    return undef;
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: url_for searches SSE and WebSocket routers"
```

---

### Task 6: Test Named Routes in Handler Context with Router::Scoped

**Files:**
- Modify: `lib/PAGI/Simple/Router.pm` (Scoped sse/websocket return value)
- Test: `t/simple/51-handler-sse-ws.t`

**Step 1: Write the failing test**

Add to `t/simple/51-handler-sse-ws.t`:

```perl
# Handler that uses named SSE/WebSocket routes
{
    package TestApp::NamedRoutes;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index')->name('home');
        $r->sse('/live' => '#live')->name('live_feed');
        $r->websocket('/chat' => '#chat')->name('chat_room');
    }

    sub index ($self, $c) { $c->text('ok') }
    sub live ($self, $sse) { }
    sub chat ($self, $ws) { }
}

# Test 6: Named routes work via Router::Scoped
subtest 'named SSE/WebSocket routes via handler' => sub {
    my $app = PAGI::Simple->new;
    $app->mount('/api' => 'TestApp::NamedRoutes');

    is($app->url_for('home'), '/api/', 'HTTP named route has prefix');
    is($app->url_for('live_feed'), '/api/live', 'SSE named route has prefix');
    is($app->url_for('chat_room'), '/api/chat', 'WebSocket named route has prefix');
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: FAIL - Router::Scoped sse/websocket don't return route objects

**Step 3: Update Router::Scoped to return route objects**

Modify `lib/PAGI/Simple/Router.pm` - update `sse` and `websocket` in Scoped:

```perl
sub sse ($self, $path, @args) {
    my $full_path = $self->{prefix} . $path;
    $full_path =~ s{^//+}{/};

    # Resolve #method syntax
    my @resolved_args;
    for my $arg (@args) {
        if (!ref($arg) && $arg =~ /^#(\w+)$/) {
            my $method = $1;
            my $instance = $self->{handler_instance};
            push @resolved_args, sub ($sse) {
                $instance->$method($sse);
            };
        } else {
            push @resolved_args, $arg;
        }
    }

    return $self->{app}->sse($full_path, @resolved_args);
}

sub websocket ($self, $path, @args) {
    my $full_path = $self->{prefix} . $path;
    $full_path =~ s{^//+}{/};

    # Resolve #method syntax
    my @resolved_args;
    for my $arg (@args) {
        if (!ref($arg) && $arg =~ /^#(\w+)$/) {
            my $method = $1;
            my $instance = $self->{handler_instance};
            push @resolved_args, sub ($ws) {
                $instance->$method($ws);
            };
        } else {
            push @resolved_args, $arg;
        }
    }

    return $self->{app}->websocket($full_path, @resolved_args);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/simple/51-handler-sse-ws.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Simple/Router.pm t/simple/51-handler-sse-ws.t
git commit -m "feat: Router::Scoped sse/websocket return route for chaining"
```

---

### Task 7: Update TodoApp Example to Use New Syntax

**Files:**
- Modify: `examples/view-todo/lib/TodoApp.pm`

**Step 1: Update the example**

Change:
```perl
$r->sse('/todos/live' => sub ($sse) {
    $sse->send_event(event => 'connected', data => 'ok');
    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });
});
```

To:
```perl
$r->sse('/todos/live' => '#live')->name('todos_live');
```

And add to `TodoApp::Todos` or create a method in `TodoApp`:

```perl
sub live ($self, $sse) {
    $sse->send_event(event => 'connected', data => 'ok');
    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });
}
```

**Step 2: Test the example**

Run: `perl -I lib bin/pagi-server -I examples/view-todo/lib TodoApp --port 5066`
Verify: App starts and SSE endpoint works

**Step 3: Commit**

```bash
git add examples/view-todo/lib/TodoApp.pm examples/view-todo/lib/TodoApp/Todos.pm
git commit -m "refactor: TodoApp uses #method syntax for SSE route"
```

---

### Task 8: Update Documentation

**Files:**
- Modify: `lib/PAGI/Simple.pm` (POD for sse and websocket methods)
- Modify: `lib/PAGI/Simple/Handler.pm` (POD for #method syntax)

**Step 1: Update PAGI::Simple POD**

In `lib/PAGI/Simple.pm`, update the `sse` and `websocket` documentation:

```perl
=head2 sse

    # Basic usage
    $app->sse('/events' => sub ($sse) {
        $sse->send_event(data => { message => "Hello" });
    });

    # Named route
    $app->sse('/events' => sub ($sse) { ... })->name('live_events');

    # In handlers with #method syntax
    $r->sse('/live' => '#live')->name('live_feed');

Register a Server-Sent Events endpoint. Returns a route object that
can be named with C<< ->name() >> for URL generation.

=head2 websocket

    # Basic usage
    $app->websocket('/chat' => sub ($ws) {
        $ws->on(message => sub ($msg) { ... });
    });

    # Named route
    $app->websocket('/chat' => sub ($ws) { ... })->name('chat');

    # In handlers with #method syntax
    $r->websocket('/room' => '#room')->name('chat_room');

Register a WebSocket endpoint. Returns a route object that can be
named with C<< ->name() >> for URL generation.
```

**Step 2: Update Handler documentation**

In `lib/PAGI/Simple/Handler.pm`, add examples:

```perl
=head2 SSE and WebSocket Routes

Handlers can define SSE and WebSocket routes using the same C<#method>
syntax as HTTP routes:

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->sse('/live' => '#live')->name('live_feed');
        $r->websocket('/chat' => '#chat')->name('chat_room');
    }

    sub live ($self, $sse) {
        $sse->send_event(data => 'connected');
        $sse->subscribe('updates' => sub ($msg) {
            $sse->send_event(data => $msg);
        });
    }

    sub chat ($self, $ws) {
        $ws->on(message => sub ($msg) {
            $ws->send("Echo: $msg");
        });
    }

Note that SSE handlers receive a L<PAGI::Simple::SSE> object and
WebSocket handlers receive a L<PAGI::Simple::WebSocket> object,
not a Context object.
```

**Step 3: Commit**

```bash
git add lib/PAGI/Simple.pm lib/PAGI/Simple/Handler.pm
git commit -m "docs: document #method and named routes for SSE/WebSocket"
```

---

### Task 9: Run Full Test Suite and Verify No Regressions

**Step 1: Run all Simple tests**

Run: `prove -l t/simple/`
Expected: All tests pass

**Step 2: Run SSE and WebSocket specific tests**

Run: `prove -l t/simple/14-websocket-basic.t t/simple/17-sse-basic.t t/simple/51-handler-sse-ws.t`
Expected: All pass

**Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address test regressions from SSE/WebSocket changes"
```

---

## Summary

After completing all tasks:

1. **SSE routes** support `#method` syntax in handlers
2. **WebSocket routes** support `#method` syntax in handlers
3. **Both** support named routes via `->name()`
4. **url_for** finds routes across HTTP, SSE, and WebSocket routers
5. **Documentation** updated with examples
6. **TodoApp example** refactored to use new syntax
