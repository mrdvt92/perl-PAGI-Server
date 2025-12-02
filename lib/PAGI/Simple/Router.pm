package PAGI::Simple::Router;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use PAGI::Simple::Route;

=head1 NAME

PAGI::Simple::Router - Route matching and dispatch for PAGI::Simple

=head1 SYNOPSIS

    my $router = PAGI::Simple::Router->new;

    $router->add('GET', '/', sub ($c) { ... });
    $router->add('POST', '/users', sub ($c) { ... });

    my $match = $router->match('GET', '/');
    if ($match) {
        my $route = $match->{route};
        $route->handler->($c);
    }

=head1 DESCRIPTION

PAGI::Simple::Router handles route registration and matching.
It maintains a list of routes and finds the best match for
incoming requests.

=head1 METHODS

=cut

=head2 new

    my $router = PAGI::Simple::Router->new;

Create a new router.

=cut

sub new ($class) {
    my $self = bless {
        routes => [],
    }, $class;

    return $self;
}

=head2 add

    $router->add($method, $path, $handler);
    $router->add($method, $path, $handler, %options);

Add a route to the router. Returns the created Route object.

Options:
- name: Optional route name
- middleware: Arrayref of middleware names

=cut

sub add ($self, $method, $path, $handler, %options) {
    my $route = PAGI::Simple::Route->new(
        method     => $method,
        path       => $path,
        handler    => $handler,
        name       => $options{name},
        middleware => $options{middleware} // [],
    );

    push @{$self->{routes}}, $route;

    return $route;
}

=head2 routes

    my @routes = $router->routes;

Returns all registered routes.

=cut

sub routes ($self) {
    return @{$self->{routes}};
}

=head2 match

    my $match = $router->match($method, $path);

Find a route matching the given method and path.

Returns a hashref with:
- route: The matching Route object
- params: Captured path parameters (empty for static routes)

Returns undef if no route matches.

=cut

sub match ($self, $method, $path) {
    for my $route (@{$self->{routes}}) {
        my $params = $route->matches($method, $path);
        if (defined $params) {
            return {
                route  => $route,
                params => $params,
            };
        }
    }

    return undef;
}

=head2 find_path_match

    my ($route, $allowed_methods) = $router->find_path_match($path);

Find if any route matches the path (regardless of method).
Returns the first matching route and an arrayref of all methods
that match the path.

This is useful for generating 405 Method Not Allowed responses.

=cut

sub find_path_match ($self, $path) {
    my $first_route;
    my @allowed_methods;

    for my $route (@{$self->{routes}}) {
        # Check path match only (ignore method)
        if (defined $route->matches_path($path)) {
            $first_route //= $route;
            push @allowed_methods, $route->method unless $route->method eq '*';
        }
    }

    return ($first_route, \@allowed_methods);
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Route>

=head1 AUTHOR

PAGI Contributors

=cut

1;
