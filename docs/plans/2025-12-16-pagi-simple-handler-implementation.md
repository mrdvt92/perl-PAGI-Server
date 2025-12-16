# PAGI::Simple Handler Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable structured, larger PAGI::Simple applications by adding Handler classes that share the root Application's services.

**Architecture:** Handlers are controller-like classes that inherit from `PAGI::Simple::Handler`. When mounted, they receive the root Application and define routes using `#method` syntax. The root Application is always accessible via `$c->app`.

**Tech Stack:** Perl 5.32+, Future::AsyncAwait, existing PAGI::Simple infrastructure

---

## Step 1: Create PAGI::Simple::Handler Base Class

**Files:**
- Create: `lib/PAGI/Simple/Handler.pm`
- Create: `t/30-handler-basic.t`

### Step 1.1: Write the failing test for Handler base class

Create test file to verify Handler can be created and has expected interface.

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

use lib 'lib';

# Test that Handler can be loaded
use_ok('PAGI::Simple::Handler');

# Test basic instantiation
subtest 'Handler instantiation' => sub {
    my $handler = PAGI::Simple::Handler->new;
    ok($handler, 'can create handler');
    isa_ok($handler, 'PAGI::Simple::Handler');
};

# Test that Handler has expected methods
subtest 'Handler interface' => sub {
    my $handler = PAGI::Simple::Handler->new;

    can_ok($handler, 'app');
    can_ok($handler, 'routes');
};

done_testing;
```

### Step 1.2: Run test to verify it fails

Run: `prove -lv t/30-handler-basic.t`
Expected: FAIL with "Can't locate PAGI/Simple/Handler.pm"

### Step 1.3: Write minimal Handler implementation

```perl
package PAGI::Simple::Handler;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::Handler - Base class for controller-like route handlers

=head1 SYNOPSIS

    package MyApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->get('/:id' => '#show');
        $r->post('/' => '#create');
    }

    async sub index ($self, $c) {
        my $todos = $c->app->service('Todo')->all;
        $c->json({ todos => $todos });
    }

    async sub show ($self, $c) {
        my $id = $c->param('id');
        my $todo = $c->app->service('Todo')->find($id);
        $c->json($todo);
    }

    1;

=head1 DESCRIPTION

PAGI::Simple::Handler provides a base class for organizing routes into
controller-like classes. Handlers:

=over 4

=item * Share the root Application's services via C<< $c->app >>

=item * Define routes using the C<routes($class, $app, $r)> class method

=item * Reference handler methods using C<#method> syntax in routes

=item * Are instantiated once per application at mount time

=back

=head1 CLASS METHODS

=head2 routes

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
    }

Override this method to define routes for the handler. Receives:

=over 4

=item * C<$class> - The handler class name

=item * C<$app> - The root Application (access services, config, etc.)

=item * C<$r> - A Router scoped to the handler's mount prefix

=back

The C<#method> syntax resolves to calling that method on the handler instance.

=cut

sub routes ($class, $app, $r) {
    # Override in subclass to define routes
}

=head1 INSTANCE METHODS

=head2 new

    my $handler = MyApp::Todos->new(app => $app);

Create a new handler instance. Called automatically by mount().

=cut

sub new ($class, %args) {
    my $self = bless {
        app => $args{app},
    }, $class;
    return $self;
}

=head2 app

    my $app = $handler->app;

Returns the root Application instance that this handler was mounted on.

=cut

sub app ($self) {
    return $self->{app};
}

=head1 WRITING HANDLER METHODS

Handler methods receive C<$self> (the handler instance) and C<$c> (the request context):

    async sub index ($self, $c) {
        # $self - this handler instance
        # $c    - PAGI::Simple::Context
        # $c->app - root Application (for services)

        my $todos = $c->app->service('Todo')->all;
        $c->json({ todos => $todos });
    }

B<Important:> Don't store per-request state in C<$self>. Handlers are
instantiated once and reused. Use C<< $c->stash >> for request-scoped data.

=head1 MIDDLEWARE CHAINS

Multiple C<#method> references create a middleware chain:

    $r->get('/:id' => '#load' => '#show');

The C<load> method runs first, then C<show>. If C<load> sends a response
(e.g., 404 not found), the chain stops.

    async sub load ($self, $c) {
        my $todo = $c->app->service('Todo')->find($c->param('id'));
        return $c->not_found unless $todo;
        $c->stash->{todo} = $todo;
    }

    async sub show ($self, $c) {
        $c->json($c->stash->{todo});
    }

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>

=cut

1;
```

### Step 1.4: Run test to verify it passes

Run: `prove -lv t/30-handler-basic.t`
Expected: PASS

### Step 1.5: Commit

```bash
git add lib/PAGI/Simple/Handler.pm t/30-handler-basic.t
git commit -m "feat: add PAGI::Simple::Handler base class

Handler is a controller-like base class for organizing routes.
- routes($class, $app, $r) class method for defining routes
- app() method to access root Application
- Handlers are instantiated once per mount

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 1 completion with user**

---

## Step 2: Add #method Syntax Support to Router

**Files:**
- Modify: `lib/PAGI/Simple/Router.pm`
- Modify: `lib/PAGI/Simple/Route.pm`
- Create: `t/31-handler-method-syntax.t`

### Step 2.1: Write the failing test for #method syntax

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple::Router;
use PAGI::Simple::Route;

# Test that #method syntax is parsed correctly
subtest '#method syntax parsing' => sub {
    my $router = PAGI::Simple::Router->new;

    # Create a mock handler
    my $handler = bless {}, 'MockHandler';

    # Add route with #method syntax
    my $route = $router->add('GET', '/', '#index', handler_instance => $handler);

    ok($route, 'route created');
    is($route->handler_methods, ['index'], 'handler_methods parsed correctly');
};

# Test multiple #method references create chain
subtest 'method chain parsing' => sub {
    my $router = PAGI::Simple::Router->new;
    my $handler = bless {}, 'MockHandler';

    # Multiple methods: #load then #show
    my $route = $router->add('GET', '/:id', '#load', '#show', handler_instance => $handler);

    ok($route, 'route created');
    is($route->handler_methods, ['load', 'show'], 'multiple methods parsed');
};

# Mock handler class
package MockHandler;
use experimental 'signatures';

sub index ($self, $c) { $c->{called} = 'index' }
sub load ($self, $c) { $c->{called} = 'load' }
sub show ($self, $c) { $c->{called} = 'show' }

package main;

done_testing;
```

### Step 2.2: Run test to verify it fails

Run: `prove -lv t/31-handler-method-syntax.t`
Expected: FAIL with "handler_methods" not found

### Step 2.3: Update Router to parse #method syntax

Modify `lib/PAGI/Simple/Router.pm` - update `add` method:

```perl
sub add ($self, $method, $path, @args) {
    my %options;
    my @handlers;

    # Parse args: can be mix of #method strings, coderefs, and %options
    while (@args) {
        my $arg = shift @args;

        if (ref($arg) eq 'CODE') {
            push @handlers, $arg;
        }
        elsif (ref($arg) eq 'HASH') {
            # Remaining hash is options
            %options = (%options, %$arg);
        }
        elsif (ref($arg) eq 'ARRAY') {
            # Middleware array
            $options{middleware} = $arg;
        }
        elsif (!ref($arg) && $arg =~ /^#(\w+)$/) {
            # #method syntax - store method name
            push @{$options{handler_methods}}, $1;
        }
        elsif (!ref($arg)) {
            # Named option key - next arg is value
            $options{$arg} = shift @args;
        }
    }

    # If we have handler_methods, we need handler_instance to resolve them
    my $handler;
    if (@handlers) {
        $handler = $handlers[0];  # Use first coderef as handler
    }

    my $route = PAGI::Simple::Route->new(
        method          => $method,
        path            => $path,
        handler         => $handler,
        name            => $options{name},
        middleware      => $options{middleware} // [],
        handler_methods => $options{handler_methods} // [],
        handler_instance => $options{handler_instance},
    );

    push @{$self->{routes}}, $route;

    if (my $name = $options{name}) {
        $self->{named_routes}{$name} = $route;
    }

    return $route;
}
```

### Step 2.4: Update Route to store handler_methods

Modify `lib/PAGI/Simple/Route.pm` - add handler_methods attribute:

```perl
# In new():
handler_methods  => $args{handler_methods} // [],
handler_instance => $args{handler_instance},

# Add accessor:
sub handler_methods ($self) {
    return $self->{handler_methods};
}

sub handler_instance ($self) {
    return $self->{handler_instance};
}
```

### Step 2.5: Run test to verify it passes

Run: `prove -lv t/31-handler-method-syntax.t`
Expected: PASS

### Step 2.6: Run regression tests

Run: `prove -l t/01-hello-http.t t/27-mount-string.t`
Expected: PASS (no regressions)

### Step 2.7: Commit

```bash
git add lib/PAGI/Simple/Router.pm lib/PAGI/Simple/Route.pm t/31-handler-method-syntax.t
git commit -m "feat: add #method syntax support to Router

Routes can now use #method syntax to reference handler methods:
  \$r->get('/' => '#index')
  \$r->get('/:id' => '#load' => '#show')

- Router.add() parses #method strings into handler_methods array
- Route stores handler_methods and handler_instance
- Multiple methods create middleware chain

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 2 completion with user**

---

## Step 3: Update mount() to Detect and Handle Handlers

**Files:**
- Modify: `lib/PAGI/Simple.pm`
- Create: `t/32-handler-mount.t`

### Step 3.1: Write the failing test for Handler mounting

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Handler;

# Create a test handler
{
    package TestApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    our $routes_called = 0;
    our $received_app;

    sub routes ($class, $app, $r) {
        $routes_called = 1;
        $received_app = $app;
        $r->get('/' => '#index');
    }

    async sub index ($self, $c) {
        $c->text('todos index');
    }

    $INC{'TestApp/Todos.pm'} = 1;
}

subtest 'mount detects Handler and calls routes()' => sub {
    $TestApp::Todos::routes_called = 0;
    $TestApp::Todos::received_app = undef;

    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    # Mount the handler
    $app->mount('/todos' => 'TestApp::Todos');

    # routes() should have been called
    ok($TestApp::Todos::routes_called, 'routes() was called');

    # routes() should receive the root app
    is($TestApp::Todos::received_app, $app, 'routes() received root app');
};

subtest '$c->app returns root Application' => sub {
    # This will be tested via integration test
    pass('deferred to integration test');
};

done_testing;
```

### Step 3.2: Run test to verify it fails

Run: `prove -lv t/32-handler-mount.t`
Expected: FAIL - routes() not called

### Step 3.3: Update mount() to handle Handlers

Modify `lib/PAGI/Simple.pm` - update `mount` method:

```perl
sub mount ($self, $prefix, $sub_app, @args) {
    my $middleware = [];
    my $constructor_args = {};

    # Parse args: can be \@middleware or \%constructor_args or both
    for my $arg (@args) {
        if (ref($arg) eq 'ARRAY') {
            $middleware = $arg;
        }
        elsif (ref($arg) eq 'HASH') {
            $constructor_args = $arg;
        }
    }

    # Normalize prefix
    $prefix =~ s{/$}{};
    $prefix = "/$prefix" unless $prefix =~ m{^/};

    # Prepend current group prefix if inside a group
    if ($self->{_prefix}) {
        $prefix = $self->{_prefix} . $prefix;
    }

    # Handle string class names
    if (!ref($sub_app) && $sub_app =~ /^[A-Za-z_:]/) {
        my $class = $sub_app;

        # Relative namespace - prepend caller's package
        if ($class =~ /^::/) {
            $class = ref($self) . $class;
        }

        # Require and instantiate the class
        eval "require $class" or die "mount(): Can't load $class: $@";

        if (!$class->can('new')) {
            die "mount(): $class has no new() method";
        }

        # Check if this is a Handler
        if ($class->isa('PAGI::Simple::Handler')) {
            return $self->_mount_handler($prefix, $class, $middleware, $constructor_args);
        }

        $sub_app = $class->new(%$constructor_args);
    }

    # Check if already-instantiated object is a Handler
    if (blessed($sub_app) && $sub_app->isa('PAGI::Simple::Handler')) {
        return $self->_mount_handler($prefix, ref($sub_app), $middleware, $constructor_args, $sub_app);
    }

    # Normal mount (existing behavior)
    my $app;
    if (blessed($sub_app) && $sub_app->can('to_app')) {
        $app = $sub_app;
    }
    elsif (ref($sub_app) eq 'CODE') {
        $app = $sub_app;
    }
    else {
        die 'mount() requires a PAGI::Simple app, Handler, class name, or PAGI app coderef';
    }

    push @{$self->{_mounted_apps}}, {
        prefix     => $prefix,
        app        => $app,
        middleware => $middleware,
    };

    return $self;
}

# Internal: Mount a Handler class
sub _mount_handler ($self, $prefix, $class, $middleware, $constructor_args, $instance = undef) {
    require PAGI::Simple::Handler;

    # Instantiate handler with reference to root app
    $instance //= $class->new(
        %$constructor_args,
        app => $self,
    );

    # Create a scoped router for this handler
    # Routes added here will be prefixed and have handler_instance set
    my $scoped_router = PAGI::Simple::Router::Scoped->new(
        parent          => $self->{router},
        prefix          => $prefix,
        handler_instance => $instance,
        middleware      => [@{$self->{_group_middleware}}, @$middleware],
    );

    # Call the handler's routes() class method
    $class->routes($self, $scoped_router);

    return $self;
}
```

### Step 3.4: Create Scoped Router

Add to `lib/PAGI/Simple/Router.pm`:

```perl
#---------------------------------------------------------------------------
# PAGI::Simple::Router::Scoped - Prefixed router for handlers
#---------------------------------------------------------------------------
package PAGI::Simple::Router::Scoped;

use strict;
use warnings;
use experimental 'signatures';

sub new ($class, %args) {
    return bless {
        parent           => $args{parent},
        prefix           => $args{prefix},
        handler_instance => $args{handler_instance},
        middleware       => $args{middleware} // [],
    }, $class;
}

sub get ($self, $path, @args) { $self->_add_route('GET', $path, @args) }
sub post ($self, $path, @args) { $self->_add_route('POST', $path, @args) }
sub put ($self, $path, @args) { $self->_add_route('PUT', $path, @args) }
sub patch ($self, $path, @args) { $self->_add_route('PATCH', $path, @args) }
sub delete ($self, $path, @args) { $self->_add_route('DELETE', $path, @args) }
sub del ($self, $path, @args) { $self->_add_route('DELETE', $path, @args) }
sub any ($self, $path, @args) { $self->_add_route('*', $path, @args) }

sub _add_route ($self, $method, $path, @args) {
    my $full_path = $self->{prefix} . $path;

    # Add handler_instance and middleware to args
    push @args, (
        handler_instance => $self->{handler_instance},
        middleware => $self->{middleware},
    );

    return $self->{parent}->add($method, $full_path, @args);
}

package PAGI::Simple::Router;
```

### Step 3.5: Run test to verify it passes

Run: `prove -lv t/32-handler-mount.t`
Expected: PASS

### Step 3.6: Run regression tests

Run: `prove -l t/01-hello-http.t t/27-mount-string.t`
Expected: PASS

### Step 3.7: Commit

```bash
git add lib/PAGI/Simple.pm lib/PAGI/Simple/Router.pm t/32-handler-mount.t
git commit -m "feat: mount() detects Handlers and calls routes()

When mounting a class that ISA PAGI::Simple::Handler:
- Instantiates with app => root Application
- Creates scoped router with prefix and handler_instance
- Calls routes(\$class, \$app, \$r) class method
- Handler's routes are registered in main router

Adds Router::Scoped for prefixed route registration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 3 completion with user**

---

## Step 4: Execute #method Routes in Middleware Chain

**Files:**
- Modify: `lib/PAGI/Simple.pm` (specifically `_run_middleware_chain`)
- Create: `t/33-handler-execution.t`

### Step 4.1: Write the failing test for handler method execution

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Handler;

# Create a test handler with actual route handlers
{
    package TestApp::API;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    our @calls;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->get('/:id' => '#load' => '#show');
    }

    async sub index ($self, $c) {
        push @calls, 'index';
        $c->text('api index');
    }

    async sub load ($self, $c) {
        push @calls, 'load:' . $c->param('id');
        $c->stash->{item} = { id => $c->param('id') };
    }

    async sub show ($self, $c) {
        push @calls, 'show';
        $c->json($c->stash->{item});
    }

    $INC{'TestApp/API.pm'} = 1;
}

# Helper to simulate request
sub make_request ($app, $method, $path) {
    my $response_body;
    my $response_status;

    my $scope = {
        type => 'http',
        method => $method,
        path => $path,
        headers => [],
        query_string => '',
    };

    my $receive = async sub { { type => 'http.request', body => '' } };
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            $response_status = $event->{status};
        }
        elsif ($event->{type} eq 'http.response.body') {
            $response_body = $event->{body};
        }
    };

    $app->to_app->($scope, $receive, $send)->get;

    return ($response_status, $response_body);
}

subtest 'single #method handler executes' => sub {
    @TestApp::API::calls = ();

    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);
    $app->mount('/api' => 'TestApp::API');

    my ($status, $body) = make_request($app, 'GET', '/api/');

    is($status, 200, 'status is 200');
    is($body, 'api index', 'body is correct');
    is(\@TestApp::API::calls, ['index'], 'index handler called');
};

subtest 'chained #method handlers execute in order' => sub {
    @TestApp::API::calls = ();

    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);
    $app->mount('/api' => 'TestApp::API');

    my ($status, $body) = make_request($app, 'GET', '/api/42');

    is($status, 200, 'status is 200');
    like($body, qr/"id".*"42"/, 'body contains id');
    is(\@TestApp::API::calls, ['load:42', 'show'], 'handlers called in order');
};

done_testing;
```

### Step 4.2: Run test to verify it fails

Run: `prove -lv t/33-handler-execution.t`
Expected: FAIL - handlers not being called

### Step 4.3: Update _run_middleware_chain to execute handler methods

Modify `lib/PAGI/Simple.pm`:

```perl
async sub _run_middleware_chain ($self, $c, $route) {
    my @middleware_names = @{$route->middleware};
    my $handler = $route->handler;
    my $handler_methods = $route->handler_methods // [];
    my $handler_instance = $route->handler_instance;

    # Build the innermost handler
    my $final_handler;

    if (@$handler_methods && $handler_instance) {
        # #method syntax - chain handler methods
        $final_handler = async sub {
            for my $method_name (@$handler_methods) {
                my $method = $handler_instance->can($method_name);
                unless ($method) {
                    die "Handler " . ref($handler_instance) . " has no method '$method_name'";
                }

                my $result = $method->($handler_instance, $c);
                if (blessed($result) && $result->can('get')) {
                    await $result;
                }

                # Stop if response was sent
                last if $c->response_started;
            }
        };
    }
    elsif ($handler) {
        # Traditional coderef handler
        $final_handler = sub {
            return $handler->($c);
        };
    }
    else {
        die "Route has no handler or handler_methods";
    }

    # If no middleware, just run the handler directly
    if (!@middleware_names) {
        my $result = $final_handler->();
        if (blessed($result) && $result->can('get')) {
            await $result;
        }
        return;
    }

    # Build the chain from inside out (handler is innermost)
    my $chain = $final_handler;

    # Wrap each middleware around the chain, in reverse order
    for my $name (reverse @middleware_names) {
        my $mw = $self->get_middleware($name);
        unless ($mw) {
            die "Unknown middleware: $name";
        }

        my $next = $chain;
        $chain = sub {
            return $mw->($c, $next);
        };
    }

    # Execute the chain
    my $result = $chain->();
    if (blessed($result) && $result->can('get')) {
        await $result;
    }
}
```

### Step 4.4: Run test to verify it passes

Run: `prove -lv t/33-handler-execution.t`
Expected: PASS

### Step 4.5: Run regression tests

Run: `prove -l t/01-hello-http.t t/27-mount-string.t`
Expected: PASS

### Step 4.6: Commit

```bash
git add lib/PAGI/Simple.pm t/33-handler-execution.t
git commit -m "feat: execute #method handler chains

_run_middleware_chain now handles:
- #method syntax: calls handler methods in sequence
- Stops chain if response_started (for middleware-style handlers)
- Validates method exists on handler instance

Enables routes like: \$r->get('/:id' => '#load' => '#show')

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 4 completion with user**

---

## Step 5: Add init() and routes() Support to PAGI::Simple

**Files:**
- Modify: `lib/PAGI/Simple.pm`
- Create: `t/34-handler-init-routes.t`

### Step 5.1: Write the failing test for init() and routes()

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';

# Test subclassing PAGI::Simple with init() and routes()
{
    package MyTestApp;
    use parent 'PAGI::Simple';
    use experimental 'signatures';
    use Future::AsyncAwait;

    our $init_called = 0;
    our $routes_called = 0;

    sub init ($class) {
        $init_called = 1;
        return (
            name  => 'MyTestApp',
            quiet => 1,
        );
    }

    sub routes ($class, $app, $r) {
        $routes_called = 1;
        $r->get('/' => '#home');
    }

    async sub home ($self, $c) {
        $c->text('home');
    }
}

subtest 'init() provides defaults' => sub {
    $MyTestApp::init_called = 0;

    my $app = MyTestApp->new;

    ok($MyTestApp::init_called, 'init() was called');
    is($app->name, 'MyTestApp', 'name from init()');
};

subtest 'constructor args override init()' => sub {
    my $app = MyTestApp->new(name => 'Override');

    is($app->name, 'Override', 'constructor arg wins');
};

subtest 'routes() called after construction' => sub {
    $MyTestApp::routes_called = 0;

    my $app = MyTestApp->new;

    ok($MyTestApp::routes_called, 'routes() was called');
};

done_testing;
```

### Step 5.2: Run test to verify it fails

Run: `prove -lv t/34-handler-init-routes.t`
Expected: FAIL - init() not called

### Step 5.3: Update PAGI::Simple new() to support init() and routes()

Modify `lib/PAGI/Simple.pm`:

```perl
sub new ($class, %args) {
    # If subclassed and has init(), call it for defaults
    if ($class ne __PACKAGE__ && $class->can('init')) {
        my %defaults = $class->init();
        # Merge: defaults < constructor args
        %args = (%defaults, %args);
    }

    # ... existing new() logic ...

    # At end of new(), before return:

    # If subclassed and has routes(), call it
    if ($class ne __PACKAGE__ && $class->can('routes') && $class->can('routes') ne __PACKAGE__->can('routes')) {
        # Create a scoped router (or use self as router since PAGI::Simple has routing methods)
        # For PAGI::Simple subclasses, the app IS the router
        $class->routes($self, $self);
    }

    return $self;
}
```

### Step 5.4: Run test to verify it passes

Run: `prove -lv t/34-handler-init-routes.t`
Expected: PASS

### Step 5.5: Run regression tests

Run: `prove -l t/`
Expected: All tests pass

### Step 5.6: Commit

```bash
git add lib/PAGI/Simple.pm t/34-handler-init-routes.t
git commit -m "feat: support init() and routes() in PAGI::Simple subclasses

When subclassing PAGI::Simple:
- init(\$class) provides default constructor args
- Constructor args override init() values
- routes(\$class, \$app, \$r) called after construction

Enables class-based app organization:

    package MyApp;
    use parent 'PAGI::Simple';

    sub init (\$class) { (name => 'MyApp') }
    sub routes (\$class, \$app, \$r) { ... }

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 5 completion with user**

---

## Step 6: Integration Test with Full Handler Stack

**Files:**
- Create: `t/35-handler-integration.t`

### Step 6.1: Write comprehensive integration test

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Handler;

# =============================================================================
# Test app structure:
#   MainApp (PAGI::Simple subclass)
#     /api/todos -> TodosHandler
#     /api/users -> UsersHandler (with middleware)
# =============================================================================

# Service class (in-memory storage)
{
    package TestService;
    use experimental 'signatures';

    my @todos = (
        { id => 1, title => 'First' },
        { id => 2, title => 'Second' },
    );

    sub new ($class) { bless {}, $class }
    sub all ($self) { return @todos }
    sub find ($self, $id) { return (grep { $_->{id} == $id } @todos)[0] }
}

# Todos Handler
{
    package TestApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->get('/:id' => '#load' => '#show');
    }

    async sub index ($self, $c) {
        # Access service via $c->app
        my @todos = $c->app->stash->{service}->all;
        $c->json({ todos => \@todos });
    }

    async sub load ($self, $c) {
        my $todo = $c->app->stash->{service}->find($c->param('id'));
        return $c->status(404)->json({ error => 'Not found' }) unless $todo;
        $c->stash->{todo} = $todo;
    }

    async sub show ($self, $c) {
        $c->json($c->stash->{todo});
    }

    $INC{'TestApp/Todos.pm'} = 1;
}

# Users Handler with auth middleware
{
    package TestApp::Users;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
    }

    async sub index ($self, $c) {
        $c->json({ users => [] });
    }

    $INC{'TestApp/Users.pm'} = 1;
}

# Main App
{
    package MainApp;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub init ($class) {
        return (
            name  => 'MainApp',
            quiet => 1,
        );
    }

    sub routes ($class, $app, $r) {
        # Set up service
        $app->stash->{service} = TestService->new;

        # Define middleware
        $app->middleware(auth => sub ($c, $next) {
            my $token = $c->req->header('Authorization');
            return $c->status(401)->json({ error => 'Unauthorized' }) unless $token;
            $next->();
        });

        # Mount handlers
        $r->group('/api' => sub ($r) {
            $r->mount('/todos' => 'TestApp::Todos');
            $r->mount('/users' => 'TestApp::Users', ['auth']);
        });

        # Root route
        $r->get('/' => sub ($c) { $c->text('ok') });
    }
}

# Helper to make requests
sub request ($app, $method, $path, %opts) {
    my $response_body;
    my $response_status;

    my $scope = {
        type => 'http',
        method => $method,
        path => $path,
        headers => $opts{headers} // [],
        query_string => '',
    };

    my $receive = async sub { { type => 'http.request', body => '' } };
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            $response_status = $event->{status};
        }
        elsif ($event->{type} eq 'http.response.body') {
            $response_body .= $event->{body} // '';
        }
    };

    $app->to_app->($scope, $receive, $send)->get;

    return ($response_status, $response_body);
}

my $app = MainApp->new;

subtest 'root route works' => sub {
    my ($status, $body) = request($app, 'GET', '/');
    is($status, 200, 'status ok');
    is($body, 'ok', 'body correct');
};

subtest 'handler index via $c->app->stash' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/');
    is($status, 200, 'status ok');
    like($body, qr/First/, 'has first todo');
    like($body, qr/Second/, 'has second todo');
};

subtest 'handler chain with params' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/1');
    is($status, 200, 'status ok');
    like($body, qr/"id".*1/, 'has correct id');
    like($body, qr/First/, 'has correct title');
};

subtest 'handler chain 404' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/999');
    is($status, 404, 'status 404');
    like($body, qr/Not found/, 'error message');
};

subtest 'mounted handler with middleware - no auth' => sub {
    my ($status, $body) = request($app, 'GET', '/api/users/');
    is($status, 401, 'status 401 without auth');
};

subtest 'mounted handler with middleware - with auth' => sub {
    my ($status, $body) = request($app, 'GET', '/api/users/',
        headers => [['authorization', 'Bearer token']]);
    is($status, 200, 'status 200 with auth');
};

done_testing;
```

### Step 6.2: Run integration test

Run: `prove -lv t/35-handler-integration.t`
Expected: PASS (or fix issues found)

### Step 6.3: Fix any issues discovered

If tests fail, fix implementation and re-run.

### Step 6.4: Run full regression test

Run: `prove -l t/`
Expected: All tests pass

### Step 6.5: Commit

```bash
git add t/35-handler-integration.t
git commit -m "test: add comprehensive Handler integration test

Tests full handler stack:
- MainApp subclass with init() and routes()
- Handlers accessing root app services via \$c->app
- Handler method chains (#load => #show)
- 404 handling in chains
- Middleware on mounted handlers
- Nested groups with handlers

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 6 completion with user**

---

## Step 7: Update view-todo Example to Use Handlers

**Files:**
- Create: `examples/view-todo/lib/TodoApp.pm`
- Create: `examples/view-todo/lib/TodoApp/Todos.pm`
- Modify: `examples/view-todo/app.pl`

### Step 7.1: Create TodoApp main class

```perl
# examples/view-todo/lib/TodoApp.pm
package TodoApp;

use strict;
use warnings;
use parent 'PAGI::Simple';
use experimental 'signatures';

sub init ($class) {
    return (
        name  => 'Todo App',
        share => 'htmx',
        views => {
            directory => './templates',
            roles     => ['PAGI::Simple::View::Role::Valiant'],
            preamble  => 'use experimental "signatures";',
        },
    );
}

sub routes ($class, $app, $r) {
    # Mount handlers
    $r->mount('/' => '::Todos');

    # SSE for live updates
    $app->sse('/todos/live' => sub ($sse) {
        $sse->send_event(event => 'connected', data => 'ok');
        $sse->subscribe('todos:changes' => sub ($msg) {
            $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
        });
    });
}

1;
```

### Step 7.2: Create Todos handler

```perl
# examples/view-todo/lib/TodoApp/Todos.pm
package TodoApp::Todos;

use strict;
use warnings;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';
use Future::AsyncAwait;

sub routes ($class, $app, $r) {
    # Home and filters
    $r->get('/'          => '#index')->name('home');
    $r->get('/active'    => '#active')->name('active');
    $r->get('/completed' => '#completed')->name('completed');

    # CRUD with #load chain for :id routes
    $r->post('/todos'              => '#create')->name('todos_create');
    $r->patch('/todos/:id/toggle'  => '#load' => '#toggle')->name('todo_toggle');
    $r->get('/todos/:id/edit'      => '#load' => '#edit_form')->name('todo_edit');
    $r->patch('/todos/:id'         => '#load' => '#update')->name('todo_update');
    $r->delete('/todos/:id'        => '#load' => '#destroy')->name('todo_delete');

    # Bulk operations
    $r->post('/todos/clear-completed' => '#clear_completed')->name('todos_clear');
    $r->post('/todos/toggle-all'      => '#toggle_all')->name('todos_toggle_all');

    # Validation
    $r->post('/validate/:field' => '#validate_field')->name('validate_field');
}

# Middleware: load todo by :id
async sub load ($self, $c) {
    my $id = $c->param('id');
    my $todo = $c->app->service('Todo')->find($id);

    return $c->status(404)->html('<span class="error">Todo not found</span>')
        unless $todo;

    $c->stash->{todo} = $todo;
}

# Index views
async sub index ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->all],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'home',
    );
}

async sub active ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->active],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'active',
    );
}

async sub completed ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->completed],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'completed',
    );
}

# CRUD operations
async sub create ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $new_todo = $todos->new_todo;

    my $data = (await $c->structured_body)
        ->namespace_for($new_todo)
        ->permitted('title')
        ->to_hash;

    my $todo = $todos->build($data);

    if ($todos->save($todo)) {
        if ($c->req->is_htmx) {
            $c->hx_trigger('todoAdded');
            $c->render('todos/_form', todo => $todos->new_todo);
        } else {
            $c->redirect('/');
        }
    } else {
        if ($c->req->is_htmx) {
            $c->render('todos/_form', todo => $todo);
        } else {
            $c->render('index',
                todos    => [$todos->all],
                new_todo => $todo,
                active   => $todos->active_count,
                filter   => 'home',
            );
        }
    }
}

async sub toggle ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $todo = $todos->toggle($c->stash->{todo}{id} // $c->param('id'));

    $c->hx_trigger('todoToggled');
    await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
}

async sub edit_form ($self, $c) {
    $c->render('todos/_edit_form', todo => $c->stash->{todo});
}

async sub update ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $todo = $c->stash->{todo};

    my $data = (await $c->structured_body)
        ->namespace_for($todo)
        ->permitted('title')
        ->to_hash;

    $todo->title($data->{title} // $todo->title);

    if ($todo->validate->valid) {
        $todos->save($todo);
        $c->hx_trigger('todoUpdated');
        await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
    } else {
        await $c->render_or_redirect('/', 'todos/_edit_form', todo => $todo);
    }
}

async sub destroy ($self, $c) {
    $c->app->service('Todo')->delete($c->stash->{todo}{id} // $c->param('id'));
    $c->hx_trigger('todoDeleted');
    await $c->empty_or_redirect('/');
}

# Bulk operations
async sub clear_completed ($self, $c) {
    my $todos = $c->app->service('Todo');
    $todos->clear_completed;

    $c->hx_trigger('todosCleared');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

async sub toggle_all ($self, $c) {
    my $todos = $c->app->service('Todo');
    $todos->toggle_all;

    $c->hx_trigger('todosToggled');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

# Field validation
async sub validate_field ($self, $c) {
    my $field = $c->param('field');

    my $data = (await $c->structured_body)
        ->namespace_for('TodoApp::Entity::Todo')
        ->permitted($field)
        ->to_hash;

    my $value = $data->{$field} // '';
    my @errors = $c->app->service('Todo')->validate_field($field, $value);

    if (@errors) {
        $c->html(qq{<span class="error">@{[join(', ', @errors)]}</span>});
    } else {
        $c->html(qq{<span class="valid">Looks good!</span>});
    }
}

1;
```

### Step 7.3: Update app.pl to use new structure

```perl
#!/usr/bin/env perl

# =============================================================================
# Todo App Example - Handler-based version
#
# Demonstrates:
# - PAGI::Simple subclass with init() and routes()
# - Handler classes for organizing routes
# - #method syntax for route handlers
# - Middleware chains (#load => #show)
# =============================================================================

use strict;
use warnings;

use lib 'lib';
use TodoApp;

TodoApp->new->to_app;
```

### Step 7.4: Test the updated example

Run: `pagi-server ./examples/view-todo/app.pl --port 5000`
Test manually in browser at http://localhost:5000

### Step 7.5: Verify tests still pass

Run: `prove -l t/`
Expected: All tests pass

### Step 7.6: Commit

```bash
git add examples/view-todo/
git commit -m "refactor: view-todo example to use Handler pattern

Demonstrates Handler-based app organization:
- TodoApp: PAGI::Simple subclass with init() and routes()
- TodoApp::Todos: Handler with all route logic
- #method syntax: #load => #show chains
- Cleaner app.pl (3 lines)

Before: 244 lines in app.pl
After: ~150 lines total (3 in app.pl + handler logic)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Review Step 7 completion with user**

---

## Step 8: Documentation and POD Updates

**Files:**
- Modify: `lib/PAGI/Simple.pm` (POD)
- Modify: `lib/PAGI/Simple/Handler.pm` (POD)

### Step 8.1: Update PAGI::Simple POD with Handler section

Add new section to PAGI::Simple POD:

```pod
=head1 ORGANIZING LARGER APPLICATIONS

For applications beyond a single file, PAGI::Simple supports class-based
organization with Handlers.

=head2 Class-Based App Structure

    # lib/MyApp.pm
    package MyApp;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub init ($class) {
        return (
            name  => 'MyApp',
            views => 'templates',
            share => 'htmx',
        );
    }

    sub routes ($class, $app, $r) {
        $r->mount('/todos' => '::Todos');
        $r->mount('/users' => '::Users', ['auth']);
    }

    1;

    # app.pl
    use lib 'lib';
    use MyApp;
    MyApp->new->to_app;

=head2 Handlers

Handlers are controller-like classes that share the root Application:

    # lib/MyApp/Todos.pm
    package MyApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->get('/:id' => '#load' => '#show');
        $r->post('/' => '#create');
    }

    async sub load ($self, $c) {
        my $todo = $c->app->service('Todo')->find($c->param('id'));
        return $c->not_found unless $todo;
        $c->stash->{todo} = $todo;
    }

    async sub index ($self, $c) {
        $c->json({ todos => [$c->app->service('Todo')->all] });
    }

    async sub show ($self, $c) {
        $c->json($c->stash->{todo});
    }

    1;

Key points:

=over 4

=item * C<< $c->app >> always returns the root Application

=item * C<#method> syntax references handler methods

=item * Multiple C<#method>s create a middleware chain

=item * Use C<< $c->stash >> for request-scoped data

=back

See L<PAGI::Simple::Handler> for full documentation.

=cut
```

### Step 8.2: Add Handler documentation

Already included in Step 1. Verify POD is complete.

### Step 8.3: Run POD tests

Run: `podchecker lib/PAGI/Simple.pm lib/PAGI/Simple/Handler.pm`
Expected: No errors

### Step 8.4: Commit

```bash
git add lib/PAGI/Simple.pm lib/PAGI/Simple/Handler.pm
git commit -m "docs: add Handler documentation to PAGI::Simple POD

- New section: ORGANIZING LARGER APPLICATIONS
- Handler pattern explanation with examples
- Links to PAGI::Simple::Handler for details

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**PAUSE: Final review with user**

---

## Summary

This plan implements the Handler pattern in 8 steps:

1. **Handler base class** - Create `PAGI::Simple::Handler`
2. **#method syntax** - Parse `#method` in Router
3. **mount() for Handlers** - Detect ISA Handler, call routes()
4. **Method execution** - Run #method chains in middleware
5. **init() and routes()** - Support in PAGI::Simple subclasses
6. **Integration tests** - Full stack testing
7. **view-todo update** - Demonstrate real-world usage
8. **Documentation** - POD updates

Each step:
- Runs tests before/after
- Pauses for user review
- Commits with clear message
- Checks for regressions

Total estimated tasks: ~40 individual steps across 8 major steps.
