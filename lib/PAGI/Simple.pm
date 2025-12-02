package PAGI::Simple;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Simple::Router;
use PAGI::Simple::Context;
use PAGI::Simple::WebSocket;
use PAGI::Simple::SSE;
use PAGI::App::Directory;

=head1 NAME

PAGI::Simple - A micro web framework built on PAGI

=head1 SYNOPSIS

    use PAGI::Simple;

    my $app = PAGI::Simple->new;

    $app->get('/' => sub ($c) {
        $c->text("Hello, World!");
    });

    $app->get('/users/:id' => sub ($c) {
        my $id = $c->param('id');
        $c->json({ user_id => $id });
    });

    $app->post('/users' => sub ($c) {
        my $data = $c->req->json_body;
        $c->json({ created => $data }, 201);
    });

    # Run with pagi-server
    $app->to_app;

=head1 DESCRIPTION

PAGI::Simple is a lightweight micro web framework built on top of PAGI
(Perl Asynchronous Gateway Interface). It provides a simple, expressive
API for building web applications with support for:

=over 4

=item * HTTP routing with path parameters

=item * WebSocket connections with pub/sub

=item * Server-Sent Events (SSE)

=item * Middleware (global and per-route)

=item * Request/Response helpers

=back

=head1 METHODS

=cut

=head2 new

    my $app = PAGI::Simple->new(%options);

Create a new PAGI::Simple application.

Options:

=over 4

=item * C<name> - Application name (default: 'PAGI::Simple')

=back

=cut

sub new ($class, %args) {
    my $self = bless {
        name       => $args{name} // 'PAGI::Simple',
        router     => PAGI::Simple::Router->new,
        ws_router  => PAGI::Simple::Router->new,  # WebSocket routes
        sse_router => PAGI::Simple::Router->new,  # SSE routes
        middleware => {},
        hooks      => { before => [], after => [] },
        error_handlers => {},
        stash      => {},
        _startup_hooks   => [],
        _shutdown_hooks  => [],
        _static_handlers => [],           # Static file handlers [(prefix, app), ...]
        _prefix          => '',           # Current route group prefix
        _group_middleware => [],          # Current group middleware stack
    }, $class;

    return $self;
}

=head2 router

    my $router = $app->router;

Returns the application's Router instance.

=cut

sub router ($self) {
    return $self->{router};
}

=head2 name

    my $name = $app->name;

Returns the application name.

=cut

sub name ($self) {
    return $self->{name};
}

=head2 stash

    my $stash = $app->stash;
    $app->stash->{db} = $dbh;

Application-level storage hashref. Useful for storing shared resources
like database connections that are initialized at startup.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 to_app

    my $pagi_app = $app->to_app;

Returns a PAGI-compatible coderef that can be used with PAGI::Server
or pagi-server CLI.

=cut

sub to_app ($self) {
    return async sub ($scope, $receive, $send) {
        await $self->_handle_request($scope, $receive, $send);
    };
}

# Internal: Main request dispatcher
async sub _handle_request ($self, $scope, $receive, $send) {
    my $type = $scope->{type} // '';

    if ($type eq 'lifespan') {
        await $self->_handle_lifespan($scope, $receive, $send);
    }
    elsif ($type eq 'http') {
        await $self->_handle_http($scope, $receive, $send);
    }
    elsif ($type eq 'websocket') {
        await $self->_handle_websocket($scope, $receive, $send);
    }
    elsif ($type eq 'sse') {
        await $self->_handle_sse($scope, $receive, $send);
    }
    else {
        die "Unsupported scope type: $type";
    }
}

# Internal: Handle lifespan events
async sub _handle_lifespan ($self, $scope, $receive, $send) {
    while (1) {
        my $event = await $receive->();
        my $type = $event->{type} // '';

        if ($type eq 'lifespan.startup') {
            eval {
                for my $hook (@{$self->{_startup_hooks}}) {
                    $hook->($self);
                }
            };
            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "$@",
                });
                return;
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            eval {
                for my $hook (@{$self->{_shutdown_hooks}}) {
                    $hook->($self);
                }
            };
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

# Internal: Handle HTTP requests
async sub _handle_http ($self, $scope, $receive, $send) {
    my $method = $scope->{method} // 'GET';
    my $path   = $scope->{path} // '/';

    # Try to match a route first
    my $match = $self->{router}->match($method, $path);

    if ($match) {
        # Route found - create context with path params
        my $route = $match->{route};
        my $params = $match->{params};

        my $c = PAGI::Simple::Context->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        my $error_to_handle;
        eval {
            # Run before hooks
            for my $hook (@{$self->{hooks}{before}}) {
                my $result = $hook->($c);
                # If hook returns a Future, await it
                if (blessed($result) && $result->can('get')) {
                    await $result;
                }
                # If hook sent a response, stop processing
                last if $c->response_started;
            }

            # Run route middleware + handler chain (only if response not started)
            unless ($c->response_started) {
                await $self->_run_middleware_chain($c, $route);
            }
        };
        if (my $err = $@) {
            # Check if this is an abort exception (expected, don't log)
            if (blessed($err) && $err->isa('PAGI::Simple::Abort')) {
                # Send the error response for abort
                unless ($c->response_started) {
                    await $self->_send_error($c, $err->code, $err->message);
                }
            }
            else {
                # Handler threw a real error
                unless ($c->response_started) {
                    await $self->_send_error($c, 500, $err);
                }
            }
        }

        # Run after hooks (always run, even after abort or error)
        for my $hook (@{$self->{hooks}{after}}) {
            eval {
                my $result = $hook->($c);
                # If hook returns a Future, await it
                if (blessed($result) && $result->can('get')) {
                    await $result;
                }
            };
            # Ignore errors in after hooks
        }
    }
    else {
        # No route matched - check static handlers first
        for my $static (@{$self->{_static_handlers}}) {
            my $prefix = $static->{prefix};

            # Check if path starts with this prefix
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E/}) {
                # Strip the prefix from the path
                my $sub_path = $path;
                $sub_path =~ s{^\Q$prefix\E}{};
                $sub_path = '/' unless $sub_path;

                # Create a modified scope with the adjusted path
                my $static_scope = { %$scope, path => $sub_path };

                # Call the static file handler
                eval {
                    await $static->{app}->($static_scope, $receive, $send);
                };
                if (my $err = $@) {
                    warn "Static file error: $err";
                }
                return;
            }
        }

        # No static match either - create context for error response
        my $c = PAGI::Simple::Context->new(
            app     => $self,
            scope   => $scope,
            receive => $receive,
            send    => $send,
        );

        # Check if path exists with different method
        my ($path_route, $allowed_methods) = $self->{router}->find_path_match($path);

        if ($path_route && @$allowed_methods) {
            # Path exists but method not allowed
            $c->res_header('Allow', join(', ', sort @$allowed_methods));
            await $self->_send_error($c, 405);
        }
        else {
            # Path not found at all
            await $self->_send_error($c, 404);
        }
    }
}

# Internal: Send error response using custom handler if available
async sub _send_error ($self, $c, $code, $error = undef) {
    my $handler = $self->get_error_handler($code);

    if ($handler) {
        my $result = $handler->($c, $error);
        if (blessed($result) && $result->isa('Future')) {
            await $result;
        }
    }
    else {
        # Default response with standard HTTP status text
        my %text = (
            400 => 'Bad Request',
            401 => 'Unauthorized',
            403 => 'Forbidden',
            404 => 'Not Found',
            405 => 'Method Not Allowed',
            409 => 'Conflict',
            410 => 'Gone',
            422 => 'Unprocessable Entity',
            429 => 'Too Many Requests',
            500 => 'Internal Server Error',
            501 => 'Not Implemented',
            502 => 'Bad Gateway',
            503 => 'Service Unavailable',
            504 => 'Gateway Timeout',
        );
        my $status_text = $text{$code} // "Error $code";
        my $message = defined $error ? "$status_text: $error" : $status_text;
        await $c->status($code)->text($message);
    }
}

# Internal: Handle WebSocket connections
async sub _handle_websocket ($self, $scope, $receive, $send) {
    my $path = $scope->{path} // '/';

    # Try to match a WebSocket route
    my $match = $self->{ws_router}->match('GET', $path);

    if ($match) {
        my $route = $match->{route};
        my $params = $match->{params};

        # Create WebSocket context
        my $ws = PAGI::Simple::WebSocket->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        eval {
            await $ws->_run($route->handler);
        };
        if (my $err = $@) {
            # Error in WebSocket handler - close connection if not already closed
            unless ($ws->is_closed) {
                await $ws->close(1011, "Internal error");
            }
        }
    }
    else {
        # No WebSocket route matched - close with error
        my $event = await $receive->();  # websocket.connect
        await $send->({ type => 'websocket.close', code => 4004, reason => 'Not Found' });
    }
}

# Internal: Handle SSE connections
async sub _handle_sse ($self, $scope, $receive, $send) {
    my $path = $scope->{path} // '/';

    # Try to match an SSE route
    my $match = $self->{sse_router}->match('GET', $path);

    if ($match) {
        my $route = $match->{route};
        my $params = $match->{params};

        # Create SSE context
        my $sse = PAGI::Simple::SSE->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        eval {
            await $sse->_run($route->handler);
        };
        if (my $err = $@) {
            # Error in SSE handler - already started, just log
            warn "SSE handler error: $err";
        }
    }
    else {
        # No SSE route matched - return 404
        await $send->({
            type    => 'sse.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        # For SSE, just return (stream ends)
    }
}

# Internal: Run route middleware chain and handler
async sub _run_middleware_chain ($self, $c, $route) {
    my @middleware_names = @{$route->middleware};
    my $handler = $route->handler;

    # If no middleware, just run the handler directly
    if (!@middleware_names) {
        my $result = $handler->($c);
        if (blessed($result) && $result->can('get')) {
            await $result;
        }
        return;
    }

    # Build the chain from inside out (handler is innermost)
    # Start with the handler as the final $next
    my $chain = sub {
        return $handler->($c);
    };

    # Wrap each middleware around the chain, in reverse order
    for my $name (reverse @middleware_names) {
        my $mw = $self->get_middleware($name);
        unless ($mw) {
            die "Unknown middleware: $name";
        }

        my $next = $chain;  # Capture current chain for closure
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

=head2 on

    $app->on(startup => sub ($app) {
        # Initialize resources
    });

    $app->on(shutdown => sub ($app) {
        # Cleanup
    });

Register lifecycle hooks.

=cut

sub on ($self, $event, $callback) {
    if ($event eq 'startup') {
        push @{$self->{_startup_hooks}}, $callback;
    }
    elsif ($event eq 'shutdown') {
        push @{$self->{_shutdown_hooks}}, $callback;
    }
    else {
        die "Unknown lifecycle event: $event";
    }
    return $self;
}

=head2 error

    $app->error(404 => sub ($c) {
        $c->json({ error => 'Not found', path => $c->req->path });
    });

    $app->error(500 => sub ($c, $error) {
        warn "Error: $error";
        $c->json({ error => 'Internal error' });
    });

Register custom error handlers for specific HTTP status codes.
The handler receives the context and optionally the error message (for 500 errors).

Returns $app for chaining.

=cut

sub error ($self, $code, $handler) {
    $self->{error_handlers}{$code} = $handler;
    return $self;
}

=head2 get_error_handler

    my $handler = $app->get_error_handler(404);

Returns the error handler for the given status code, or undef if not defined.

=cut

sub get_error_handler ($self, $code) {
    return $self->{error_handlers}{$code};
}

=head1 MIDDLEWARE METHODS

=head2 hook

    $app->hook(before => sub ($c) {
        $c->stash->{start} = time();
    });

    $app->hook(after => sub ($c) {
        my $elapsed = time() - $c->stash->{start};
        warn "Request took ${elapsed}s";
    });

Register global middleware hooks. C<before> hooks run before the route
handler, C<after> hooks run after. Multiple hooks of the same type execute
in the order they were registered.

A C<before> hook can short-circuit request processing by sending a response.
If the response has been started, the route handler will not be called.

=cut

sub hook ($self, $type, $callback) {
    if ($type eq 'before') {
        push @{$self->{hooks}{before}}, $callback;
    }
    elsif ($type eq 'after') {
        push @{$self->{hooks}{after}}, $callback;
    }
    else {
        die "Unknown hook type: $type (expected 'before' or 'after')";
    }
    return $self;
}

=head2 middleware

    $app->middleware(auth => sub ($c, $next) {
        return $c->status(401)->text("Unauthorized")
            unless $c->req->header('Authorization');
        $next->();  # Continue to route handler
    });

    $app->middleware(json_only => sub ($c, $next) {
        return $c->status(415)->json({ error => 'JSON required' })
            unless $c->req->content_type =~ /json/;
        $next->();
    });

Define a named middleware that can be applied to specific routes.
The callback receives the context C<$c> and a continuation function C<$next>.

Call C<< $next->() >> to continue to the next middleware or route handler.
If you don't call C<$next>, the chain stops (useful for auth failures, etc.).

Returns $app for chaining.

=cut

sub middleware ($self, $name, $callback) {
    $self->{middleware}{$name} = $callback;
    return $self;
}

=head2 get_middleware

    my $mw = $app->get_middleware('auth');

Returns the middleware callback for the given name, or undef if not found.

=cut

sub get_middleware ($self, $name) {
    return $self->{middleware}{$name};
}

=head2 has_middleware

    if ($app->has_middleware('auth')) { ... }

Returns true if a middleware with the given name is defined.

=cut

sub has_middleware ($self, $name) {
    return exists $self->{middleware}{$name};
}

=head1 ROUTING METHODS

=head2 get

    $app->get('/' => sub ($c) { $c->text("Hello") });
    $app->get('/protected' => [qw(auth)] => sub ($c) { ... });

Register a GET route. Optionally specify middleware as an arrayref
before the handler. Returns $app for chaining.

=cut

sub get ($self, $path, @args) {
    $self->_add_route('GET', $path, @args);
    return $self;
}

=head2 post

    $app->post('/users' => sub ($c) { ... });
    $app->post('/api/users' => [qw(auth json_only)] => sub ($c) { ... });

Register a POST route. Returns $app for chaining.

=cut

sub post ($self, $path, @args) {
    $self->_add_route('POST', $path, @args);
    return $self;
}

=head2 put

    $app->put('/users/:id' => sub ($c) { ... });
    $app->put('/users/:id' => [qw(auth)] => sub ($c) { ... });

Register a PUT route. Returns $app for chaining.

=cut

sub put ($self, $path, @args) {
    $self->_add_route('PUT', $path, @args);
    return $self;
}

=head2 del

    $app->del('/users/:id' => sub ($c) { ... });
    $app->del('/users/:id' => [qw(auth admin)] => sub ($c) { ... });

Register a DELETE route. Named 'del' to avoid conflict with Perl's
built-in delete. Returns $app for chaining.

=cut

sub del ($self, $path, @args) {
    $self->_add_route('DELETE', $path, @args);
    return $self;
}

=head2 patch

    $app->patch('/users/:id' => sub ($c) { ... });
    $app->patch('/users/:id' => [qw(auth)] => sub ($c) { ... });

Register a PATCH route. Returns $app for chaining.

=cut

sub patch ($self, $path, @args) {
    $self->_add_route('PATCH', $path, @args);
    return $self;
}

=head2 delete

    $app->delete('/items/:id' => sub ($c) { ... });
    $app->delete('/items/:id' => [qw(auth)] => sub ($c) { ... });

Register a DELETE route. Returns $app for chaining.

=cut

sub delete ($self, $path, @args) {
    $self->_add_route('DELETE', $path, @args);
    return $self;
}

=head2 any

    $app->any('/ping' => sub ($c) { $c->text("pong") });
    $app->any('/protected' => [qw(auth)] => sub ($c) { ... });

Register a route that matches any HTTP method.
Returns $app for chaining.

=cut

sub any ($self, $path, @args) {
    $self->_add_route('*', $path, @args);
    return $self;
}

=head2 route

    $app->route('OPTIONS', '/resource' => sub ($c) { ... });
    $app->route('OPTIONS', '/resource' => [qw(cors)] => sub ($c) { ... });

Register a route with an explicit HTTP method.
Returns $app for chaining.

=cut

sub route ($self, $method, $path, @args) {
    $self->_add_route($method, $path, @args);
    return $self;
}

=head2 websocket

    $app->websocket('/ws' => sub ($ws) {
        $ws->send("Welcome!");

        $ws->on(message => sub ($data) {
            $ws->send("Echo: $data");
        });

        $ws->on(close => sub {
            # Cleanup
        });
    });

    $app->websocket('/chat/:room' => sub ($ws) {
        my $room = $ws->param('room');
        # ...
    });

Register a WebSocket route. The callback receives a PAGI::Simple::WebSocket
context object instead of the regular HTTP context.

Returns $app for chaining.

=cut

sub websocket ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    $self->{ws_router}->add('GET', $full_path, $handler);
    return $self;
}

=head2 sse

    $app->sse('/events' => sub ($sse) {
        $sse->send_event(
            data  => { message => "Hello" },
            event => 'greeting',
            id    => 1,
        );

        $sse->on(close => sub {
            # Client disconnected
        });
    });

    $app->sse('/notifications/:user' => sub ($sse) {
        my $user = $sse->param('user');
        # ...
    });

Register a Server-Sent Events route. The callback receives a PAGI::Simple::SSE
context object instead of the regular HTTP context.

Returns $app for chaining.

=cut

sub sse ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    $self->{sse_router}->add('GET', $full_path, $handler);
    return $self;
}

=head2 static

    # Simple form: prefix => directory
    $app->static('/public' => './static');

    # With options
    $app->static('/assets' => {
        root         => './public',
        index        => ['index.html'],
        show_hidden  => 0,
    });

Mount a static file handler under the given URL prefix. Files are served
from the specified directory using PAGI::App::Directory.

Returns $app for chaining.

=cut

sub static ($self, $prefix, $target) {
    # Normalize prefix - ensure it starts with / and doesn't end with /
    $prefix =~ s{/+$}{};
    $prefix = "/$prefix" unless $prefix =~ m{^/};

    my %opts;
    if (ref($target) eq 'HASH') {
        %opts = %$target;
    }
    else {
        # Simple form: target is the root directory
        $opts{root} = $target;
    }

    # Create the PAGI::App::Directory instance
    my $dir_app = PAGI::App::Directory->new(%opts)->to_app;

    # Store the handler with its prefix
    push @{$self->{_static_handlers}}, {
        prefix => $prefix,
        app    => $dir_app,
    };

    return $self;
}

=head2 group

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) { ... });   # /api/users
        $app->get('/posts' => sub ($c) { ... });   # /api/posts
    });

    $app->group('/admin' => [qw(auth admin_only)] => sub ($app) {
        $app->get('/dashboard' => sub ($c) { ... });  # /admin/dashboard with auth, admin_only
        $app->get('/settings' => sub ($c) { ... });   # /admin/settings with auth, admin_only
    });

Group routes under a common path prefix with optional shared middleware.
Routes defined inside the callback will have the prefix prepended and
any group middleware applied before route-specific middleware.

Groups can be nested:

    $app->group('/api' => [qw(auth)] => sub ($app) {
        $app->group('/v1' => sub ($app) {
            $app->get('/users' => sub ($c) { ... });  # /api/v1/users with auth
        });
    });

Returns $app for chaining.

=cut

sub group ($self, $prefix, @args) {
    my ($group_middleware, $callback);

    if (@args == 1) {
        # No middleware: ($callback)
        $callback = $args[0];
        $group_middleware = [];
    }
    elsif (@args == 2 && ref($args[0]) eq 'ARRAY') {
        # With middleware: ($middleware_arrayref, $callback)
        $group_middleware = $args[0];
        $callback = $args[1];
    }
    else {
        die 'Invalid group arguments: expected ($callback) or (\@middleware, $callback)';
    }

    # Save current context
    my $saved_prefix = $self->{_prefix};
    my $saved_middleware = $self->{_group_middleware};

    # Update context for this group
    $self->{_prefix} = $saved_prefix . $prefix;
    $self->{_group_middleware} = [@$saved_middleware, @$group_middleware];

    # Call the callback
    $callback->($self);

    # Restore context
    $self->{_prefix} = $saved_prefix;
    $self->{_group_middleware} = $saved_middleware;

    return $self;
}

# Internal: Add a route with optional middleware
# Args can be: ($handler) or ($middleware_arrayref, $handler)
# Applies current group prefix and middleware
sub _add_route ($self, $method, $path, @args) {
    my ($route_middleware, $handler);

    if (@args == 1) {
        # No middleware: ($handler)
        $handler = $args[0];
        $route_middleware = [];
    }
    elsif (@args == 2 && ref($args[0]) eq 'ARRAY') {
        # With middleware: ($middleware_arrayref, $handler)
        $route_middleware = $args[0];
        $handler = $args[1];
    }
    else {
        die 'Invalid route arguments: expected ($handler) or (\@middleware, $handler)';
    }

    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    # Combine group middleware + route middleware
    my @combined_middleware = (@{$self->{_group_middleware}}, @$route_middleware);

    $self->{router}->add($method, $full_path, $handler, middleware => \@combined_middleware);
}

=head1 SEE ALSO

L<PAGI>, L<PAGI::Server>, L<PAGI::Simple::Context>

=head1 AUTHOR

PAGI Contributors

=cut

1;
