package PAGI::Simple::Context;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Hash::MultiValue;
use PAGI::Simple::Request;
use PAGI::Simple::Response;

=head1 NAME

PAGI::Simple::Context - Request context for PAGI::Simple handlers

=head1 SYNOPSIS

    # In a route handler:
    $app->get('/users/:id' => sub ($c) {
        my $id = $c->param('id');

        # Access raw PAGI primitives
        my $scope = $c->scope;
        my $method = $scope->{method};

        # Per-request storage
        $c->stash->{user} = load_user($id);

        $c->json({ user_id => $id });
    });

=head1 DESCRIPTION

PAGI::Simple::Context is the request context object passed to route handlers.
It provides convenient access to request data, response helpers, and per-request
storage while still allowing access to raw PAGI primitives when needed.

=head1 METHODS

=cut

=head2 new

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

Create a new context. This is called internally by PAGI::Simple when
dispatching to route handlers.

=cut

sub new ($class, %args) {
    my $self = bless {
        app     => $args{app},
        scope   => $args{scope},
        receive => $args{receive},
        send    => $args{send},
        stash   => {},
        _response_started => 0,
        _req     => undef,  # Lazy-built Request object
        _status  => 200,    # Response status code
        _headers => [],     # Response headers (array of pairs)
        _path_params => $args{path_params} // {},
    }, $class;

    return $self;
}

=head2 app

    my $app = $c->app;

Returns the PAGI::Simple application instance. Useful for accessing
application-level stash or configuration.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 scope

    my $scope = $c->scope;

Returns the raw PAGI scope hashref. Contains connection metadata like
method, path, headers, query_string, etc.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 receive

    my $receive = $c->receive;
    my $event = await $receive->();

Returns the raw PAGI receive coderef. Call it to receive events
from the client (request body chunks, WebSocket messages, etc.).

=cut

sub receive ($self) {
    return $self->{receive};
}

=head2 send

    my $send = $c->send;
    await $send->({ type => 'http.response.start', status => 200, ... });

Returns the raw PAGI send coderef. Use for low-level response control.

=cut

sub send ($self) {
    return $self->{send};
}

=head2 stash

    $c->stash->{user} = $user;
    my $user = $c->stash->{user};

Returns a per-request storage hashref. Data stored here is isolated
to this request and will not leak to other requests.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 param

    my $id = await $c->param('id');

Returns a parameter value by searching in order: path params, query params,
then body params. Returns the first value found.

This is an async method because body params may need to be read.

For path-only params (sync), use C<< $c->path_params->{name} >>.

=cut

async sub param ($self, $name) {
    # Check path params first (highest priority)
    if (exists $self->{_path_params}{$name}) {
        return $self->{_path_params}{$name};
    }

    # Check query params
    my $query_val = $self->req->query_param($name);
    if (defined $query_val) {
        return $query_val;
    }

    # Check body params (async)
    my $body_val = await $self->req->body_param($name);
    return $body_val;
}

=head2 path_params

    my $params = $c->path_params;

Returns a hashref of all captured path parameters.

=cut

sub path_params ($self) {
    return $self->{_path_params};
}

=head2 params

    my $all = await $c->params;  # Hash::MultiValue

Returns all parameters merged from path, query, and body as a Hash::MultiValue.
Path params take precedence over query, which takes precedence over body.

This is an async method because body params may need to be read.

=cut

async sub params ($self) {
    # Get body params first (async)
    my $body = await $self->req->body_params;

    # Start with body params
    my @pairs = $body->flatten;

    # Add query params (overrides body)
    my $query = $self->req->query;
    push @pairs, $query->flatten;

    # Add path params (highest priority)
    for my $key (keys %{$self->{_path_params}}) {
        push @pairs, $key, $self->{_path_params}{$key};
    }

    return Hash::MultiValue->new(@pairs);
}

=head2 req

    my $req = $c->req;

Returns a L<PAGI::Simple::Request> object wrapping the current scope.
The Request object is created lazily and cached.

=cut

sub req ($self) {
    unless ($self->{_req}) {
        $self->{_req} = PAGI::Simple::Request->new(
            $self->{scope},
            $self->{receive},
            $self->{_path_params},
        );
    }
    return $self->{_req};
}

=head2 response_started

    if ($c->response_started) { ... }

Returns true if the response has already been started (http.response.start
has been sent). Useful for middleware and error handlers.

=cut

sub response_started ($self) {
    return $self->{_response_started};
}

=head2 mark_response_started

    $c->mark_response_started;

Internal method to mark that the response has started. Called by
response helpers.

=cut

sub mark_response_started ($self) {
    $self->{_response_started} = 1;
    return $self;
}

=head1 CONVENIENCE ACCESSORS

These methods provide quick access to common scope values.

=cut

=head2 method

    my $method = $c->method;  # GET, POST, etc.

Returns the HTTP method.

=cut

sub method ($self) {
    return $self->{scope}{method};
}

=head2 path

    my $path = $c->path;  # /users/123

Returns the request path (without query string).

=cut

sub path ($self) {
    return $self->{scope}{path};
}

=head2 query_string

    my $qs = $c->query_string;  # foo=bar&baz=qux

Returns the raw query string (without the leading ?).

=cut

sub query_string ($self) {
    return $self->{scope}{query_string} // '';
}

=head1 RESPONSE BUILDER METHODS

These methods configure the response and return $c for chaining.

=cut

=head2 status

    $c->status(201)->json({ id => 1 });

Set the HTTP response status code. Returns $c for chaining.

=cut

sub status ($self, $code) {
    $self->{_status} = $code;
    return $self;
}

=head2 res_header

    $c->res_header('X-Custom' => 'value');
    $c->res_header('Set-Cookie' => 'session=abc');

Add a response header. Can be called multiple times for the same
header name. Returns $c for chaining.

=cut

sub res_header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

=head2 content_type

    $c->content_type('application/xml');

Set the Content-Type response header. Returns $c for chaining.

=cut

sub content_type ($self, $type) {
    return $self->res_header('content-type', $type);
}

=head1 RESPONSE TERMINAL METHODS

These methods send the response. They are async and should be awaited.

=cut

=head2 text

    await $c->text("Hello, World!");
    await $c->text("Created", 201);

Send a plain text response. Optionally specify status code.

=cut

async sub text ($self, $body, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('text/plain; charset=utf-8');
    await $self->send_response($body);
}

=head2 html

    await $c->html("<h1>Hello</h1>");
    await $c->html($content, 201);

Send an HTML response. Optionally specify status code.

=cut

async sub html ($self, $body, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('text/html; charset=utf-8');
    await $self->send_response($body);
}

=head2 json

    await $c->json({ message => "Hello" });
    await $c->json({ created => 1 }, 201);

Send a JSON response. Optionally specify status code.

=cut

async sub json ($self, $data, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('application/json; charset=utf-8');
    my $body = PAGI::Simple::Response->json_encode($data);
    await $self->send_response($body);
}

=head2 redirect

    await $c->redirect("/other");
    await $c->redirect("/other", 301);

Send a redirect response. Default status is 302 (Found).

=cut

async sub redirect ($self, $url, $status = 302) {
    $self->{_status} = $status;
    $self->res_header('location', $url);
    await $self->send_response('');
}

=head2 send_response

    await $c->send_response($body);

Low-level method to send the response with current status and headers.
Most users should use text(), html(), json(), or redirect() instead.

=cut

async sub send_response ($self, $body) {
    die "Response already started" if $self->{_response_started};

    $self->{_response_started} = 1;

    # Send response start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Send body
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

=head2 abort

    $c->abort(403);                          # Forbidden
    $c->abort(404, "Item not found");        # Custom message
    $c->abort(500, "Database error");        # Server error with message

Abort request processing with an error response. This method throws
a PAGI::Simple::Abort exception immediately to stop handler execution.
The framework catches this exception and sends the appropriate error
response (using custom error handler if registered, or default response).

Note: This is a synchronous method that throws immediately. The actual
error response is sent by the framework, not by this method.

=cut

sub abort ($self, $code, $message = undef) {
    # Don't abort if response already started
    if ($self->{_response_started}) {
        die "Cannot abort: response already started";
    }

    # Throw abort exception immediately - framework will handle sending response
    die bless { code => $code, message => $message, context => $self }, 'PAGI::Simple::Abort';
}

# Internal: Get default status text
sub _status_text ($code) {
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
    return $text{$code} // "Error $code";
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Request>, L<PAGI::Simple::Response>

=head1 AUTHOR

PAGI Contributors

=cut

# PAGI::Simple::Abort - Exception class for abort()
package PAGI::Simple::Abort;

sub code ($self) { return $self->{code}; }
sub message ($self) { return $self->{message}; }
sub context ($self) { return $self->{context}; }

1;
