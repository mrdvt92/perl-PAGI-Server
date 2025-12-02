package PAGI::Simple::Request;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Hash::MultiValue;
use Future::AsyncAwait;
use JSON::MaybeXS ();

my $json = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);

=head1 NAME

PAGI::Simple::Request - Request object for PAGI::Simple

=head1 SYNOPSIS

    # In a route handler:
    $app->get('/search' => sub ($c) {
        my $req = $c->req;

        my $method = $req->method;        # GET
        my $path   = $req->path;          # /search
        my $q      = $req->query_string;  # term=perl&page=1

        # Headers via Hash::MultiValue
        my $ct = $req->header('Content-Type');
        my $all_accepts = $req->headers->get_all('Accept');

        # Common header shortcuts
        my $content_type   = $req->content_type;
        my $content_length = $req->content_length;
    });

=head1 DESCRIPTION

PAGI::Simple::Request wraps the PAGI $scope hashref to provide
convenient access to request data. Headers are exposed via
Hash::MultiValue for proper handling of multi-value headers.

=head1 METHODS

=cut

=head2 new

    my $req = PAGI::Simple::Request->new($scope, $receive);

Create a new Request object wrapping the given PAGI scope.

=cut

sub new ($class, $scope, $receive = undef, $path_params = undef) {
    my $self = bless {
        scope        => $scope,
        receive      => $receive,
        _headers     => undef,  # Lazy-built Hash::MultiValue
        _query       => undef,  # Lazy-built Hash::MultiValue for query params
        _body        => undef,  # Cached raw body
        _body_read   => 0,      # Whether body has been drained
        _body_params => undef,  # Lazy-built Hash::MultiValue for form params
        _path_params => $path_params // {},
    }, $class;

    return $self;
}

=head2 scope

    my $scope = $req->scope;

Returns the raw PAGI scope hashref.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 method

    my $method = $req->method;  # GET, POST, PUT, DELETE, etc.

Returns the HTTP request method.

=cut

sub method ($self) {
    return $self->{scope}{method} // '';
}

=head2 path

    my $path = $req->path;  # /users/123

Returns the request path (without query string).

=cut

sub path ($self) {
    return $self->{scope}{path} // '/';
}

=head2 query_string

    my $qs = $req->query_string;  # foo=bar&baz=qux

Returns the raw query string (without the leading ?).

=cut

sub query_string ($self) {
    return $self->{scope}{query_string} // '';
}

=head2 query

    my $query = $req->query;  # Hash::MultiValue
    my @values = $query->get_all('tags');

Returns query parameters as a Hash::MultiValue object. Parameters are
URL-decoded automatically.

=cut

sub query ($self) {
    unless ($self->{_query}) {
        $self->{_query} = $self->_parse_query_string($self->query_string);
    }
    return $self->{_query};
}

=head2 query_param

    my $value = $req->query_param('name');

Returns a single query parameter value (first value if multiple exist).
Returns undef if the parameter is not present.

=cut

sub query_param ($self, $name) {
    # Hash::MultiValue's get() returns last value, but we want first
    my @values = $self->query->get_all($name);
    return @values ? $values[0] : undef;
}

=head2 query_params

    my $values = $req->query_params('tags');  # Returns arrayref

Returns all values for a query parameter as an arrayref.
Returns an empty arrayref if the parameter is not present.

=cut

sub query_params ($self, $name) {
    my @values = $self->query->get_all($name);
    return \@values;
}

# Internal: Parse query string into Hash::MultiValue
sub _parse_query_string ($self, $qs) {
    my @pairs;

    return Hash::MultiValue->new() unless defined $qs && length $qs;

    for my $pair (split /[&;]/, $qs) {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key && length $key;

        $key   = _url_decode($key);
        $value = defined $value ? _url_decode($value) : '';

        push @pairs, $key, $value;
    }

    return Hash::MultiValue->new(@pairs);
}

# Internal: URL decode a string
sub _url_decode ($str) {
    return '' unless defined $str;

    # Replace + with space
    $str =~ s/\+/ /g;

    # Decode %XX sequences
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

    return $str;
}

=head2 headers

    my $headers = $req->headers;  # Hash::MultiValue
    my @values = $headers->get_all('Accept');

Returns all headers as a Hash::MultiValue object. Headers are
lowercased for consistent access.

=cut

sub headers ($self) {
    unless ($self->{_headers}) {
        my @pairs;
        my $raw_headers = $self->{scope}{headers} // [];

        for my $header (@$raw_headers) {
            my ($name, $value) = @$header;
            # Lowercase header names for consistent access
            push @pairs, lc($name), $value;
        }

        $self->{_headers} = Hash::MultiValue->new(@pairs);
    }

    return $self->{_headers};
}

=head2 header

    my $value = $req->header('Content-Type');

Returns a single header value (first value if multiple).
Header names are case-insensitive.

=cut

sub header ($self, $name) {
    return $self->headers->get(lc $name);
}

=head2 content_type

    my $ct = $req->content_type;  # application/json

Returns the Content-Type header value.

=cut

sub content_type ($self) {
    return $self->header('content-type') // '';
}

=head2 content_length

    my $len = $req->content_length;  # 1234

Returns the Content-Length header value as a number.
Returns undef if not present.

=cut

sub content_length ($self) {
    my $len = $self->header('content-length');
    return defined $len ? 0 + $len : undef;
}

=head2 host

    my $host = $req->host;  # example.com:8080

Returns the Host header value.

=cut

sub host ($self) {
    return $self->header('host') // '';
}

=head2 user_agent

    my $ua = $req->user_agent;

Returns the User-Agent header value.

=cut

sub user_agent ($self) {
    return $self->header('user-agent') // '';
}

=head2 is_secure

    if ($req->is_secure) { ... }

Returns true if the request was made over HTTPS.

=cut

sub is_secure ($self) {
    return ($self->{scope}{scheme} // 'http') eq 'https';
}

=head2 scheme

    my $scheme = $req->scheme;  # http or https

Returns the request scheme.

=cut

sub scheme ($self) {
    return $self->{scope}{scheme} // 'http';
}

=head2 server_name

    my $name = $req->server_name;

Returns the server name from scope.

=cut

sub server_name ($self) {
    return $self->{scope}{server}[0] // '';
}

=head2 server_port

    my $port = $req->server_port;

Returns the server port from scope.

=cut

sub server_port ($self) {
    return $self->{scope}{server}[1] // 80;
}

=head2 client_ip

    my $ip = $req->client_ip;

Returns the client IP address from scope.

=cut

sub client_ip ($self) {
    return $self->{scope}{client}[0] // '';
}

=head2 client_port

    my $port = $req->client_port;

Returns the client port from scope.

=cut

sub client_port ($self) {
    return $self->{scope}{client}[1] // 0;
}

=head2 path_param

    my $id = $req->path_param('id');

Returns a path parameter captured from the route pattern.
Returns undef if the parameter doesn't exist.

=cut

sub path_param ($self, $name) {
    return $self->{_path_params}{$name};
}

=head2 path_params

    my $params = $req->path_params;

Returns a hashref of all captured path parameters.

=cut

sub path_params ($self) {
    return $self->{_path_params};
}

=head1 REQUEST BODY METHODS

=head2 body

    my $body = await $req->body;

Drains and returns the raw request body as a string. The body is cached
after the first call, so subsequent calls return the cached value.

This is an async method that returns a Future.

=cut

async sub body ($self) {
    # Return cached body if already read
    return $self->{_body} if $self->{_body_read};

    my $body = '';
    my $receive = $self->{receive};

    # If no receive function, return empty body
    unless ($receive) {
        $self->{_body_read} = 1;
        $self->{_body} = '';
        return '';
    }

    # Drain body chunks
    while (1) {
        my $event = await $receive->();
        my $type = $event->{type} // '';

        if ($type eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        }
        elsif ($type eq 'http.disconnect') {
            last;
        }
        else {
            # Unknown event type, stop reading
            last;
        }
    }

    $self->{_body_read} = 1;
    $self->{_body} = $body;

    return $body;
}

=head2 body_params

    my $params = await $req->body_params;  # Hash::MultiValue

Parses the request body as form data (application/x-www-form-urlencoded)
and returns a Hash::MultiValue object.

=cut

async sub body_params ($self) {
    return $self->{_body_params} if $self->{_body_params};

    my $body = await $self->body;
    my $ct = $self->content_type;

    # Only parse form data
    if ($ct =~ m{^application/x-www-form-urlencoded}i) {
        $self->{_body_params} = $self->_parse_query_string($body);
    }
    else {
        $self->{_body_params} = Hash::MultiValue->new();
    }

    return $self->{_body_params};
}

=head2 body_param

    my $value = await $req->body_param('email');

Returns a single form parameter value (first value if multiple exist).
Returns undef if the parameter is not present.

=cut

async sub body_param ($self, $name) {
    my $params = await $self->body_params;
    my @values = $params->get_all($name);
    return @values ? $values[0] : undef;
}

=head2 json_body

    my $data = await $req->json_body;

Parses the request body as JSON and returns the decoded data structure.
Dies if the body is not valid JSON.

=cut

async sub json_body ($self) {
    my $body = await $self->body;
    return $json->decode($body);
}

=head2 json_body_safe

    my $data = await $req->json_body_safe;

Parses the request body as JSON and returns the decoded data structure.
Returns undef if the body is not valid JSON (does not die).

=cut

async sub json_body_safe ($self) {
    my $body = await $self->body;
    my $data = eval { $json->decode($body) };
    return $data;
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>, L<Hash::MultiValue>

=head1 AUTHOR

PAGI Contributors

=cut

1;
