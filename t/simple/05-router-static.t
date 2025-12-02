use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: PAGI::Simple Router and static routes

# Test 1: Route module loads
subtest 'Route module loads' => sub {
    my $loaded = eval { require PAGI::Simple::Route; 1 };
    ok($loaded, 'PAGI::Simple::Route loads') or diag $@;
};

# Test 2: Router module loads
subtest 'Router module loads' => sub {
    my $loaded = eval { require PAGI::Simple::Router; 1 };
    ok($loaded, 'PAGI::Simple::Router loads') or diag $@;
};

use PAGI::Simple::Route;
use PAGI::Simple::Router;
use PAGI::Simple;

# Test 3: Route creation
subtest 'Route creation' => sub {
    my $handler = sub { 'test' };
    my $route = PAGI::Simple::Route->new(
        method  => 'GET',
        path    => '/users',
        handler => $handler,
        name    => 'list_users',
    );

    ok($route, 'route created');
    is($route->method, 'GET', 'method accessor');
    is($route->path, '/users', 'path accessor');
    is($route->handler, $handler, 'handler accessor');
    is($route->name, 'list_users', 'name accessor');
};

# Test 4: Route matching - basic
subtest 'Route matching basic' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/users',
        handler => sub { },
    );

    ok($route->matches('GET', '/users'), 'matches correct method and path');
    ok(!$route->matches('POST', '/users'), 'does not match wrong method');
    ok(!$route->matches('GET', '/posts'), 'does not match wrong path');
    ok(!$route->matches('GET', '/users/'), 'does not match path with trailing slash');
};

# Test 5: Route matching - any method
subtest 'Route matching any method' => sub {
    my $route = PAGI::Simple::Route->new(
        method => '*',
        path   => '/ping',
        handler => sub { },
    );

    ok($route->matches('GET', '/ping'), 'matches GET');
    ok($route->matches('POST', '/ping'), 'matches POST');
    ok($route->matches('DELETE', '/ping'), 'matches DELETE');
    ok(!$route->matches('GET', '/pong'), 'does not match wrong path');
};

# Test 6: Router creation
subtest 'Router creation' => sub {
    my $router = PAGI::Simple::Router->new;

    ok($router, 'router created');
    is(scalar $router->routes, 0, 'no routes initially');
};

# Test 7: Router add routes
subtest 'Router add routes' => sub {
    my $router = PAGI::Simple::Router->new;

    my $h1 = sub { 'home' };
    my $h2 = sub { 'users' };

    my $r1 = $router->add('GET', '/', $h1);
    my $r2 = $router->add('POST', '/users', $h2, name => 'create_user');

    is(scalar $router->routes, 2, 'two routes added');

    isa_ok($r1, 'PAGI::Simple::Route');
    is($r1->method, 'GET', 'first route method');
    is($r1->path, '/', 'first route path');

    isa_ok($r2, 'PAGI::Simple::Route');
    is($r2->name, 'create_user', 'second route name');
};

# Test 8: Router match - found
subtest 'Router match found' => sub {
    my $router = PAGI::Simple::Router->new;
    my $handler = sub { 'found' };

    $router->add('GET', '/', $handler);
    $router->add('GET', '/users', sub { 'users' });
    $router->add('POST', '/users', sub { 'create' });

    my $match = $router->match('GET', '/');
    ok($match, 'match found');
    is($match->{route}->path, '/', 'correct route matched');
    is(ref $match->{params}, 'HASH', 'params is hashref');
    is(scalar keys %{$match->{params}}, 0, 'no params for static route');
};

# Test 9: Router match - not found
subtest 'Router match not found' => sub {
    my $router = PAGI::Simple::Router->new;

    $router->add('GET', '/', sub { });

    my $match = $router->match('GET', '/nonexistent');
    ok(!defined $match, 'no match for nonexistent path');
};

# Test 10: Router match - method mismatch
subtest 'Router match method mismatch' => sub {
    my $router = PAGI::Simple::Router->new;

    $router->add('GET', '/users', sub { });

    my $match = $router->match('POST', '/users');
    ok(!defined $match, 'no match when method differs');
};

# Test 11: Router find_path_match
subtest 'Router find_path_match' => sub {
    my $router = PAGI::Simple::Router->new;

    $router->add('GET', '/users', sub { });
    $router->add('POST', '/users', sub { });
    $router->add('DELETE', '/users', sub { });
    $router->add('GET', '/posts', sub { });

    my ($route, $methods) = $router->find_path_match('/users');
    ok($route, 'path match found');
    is(ref $methods, 'ARRAY', 'methods is arrayref');
    is(scalar @$methods, 3, 'three methods for /users');
    ok((grep { $_ eq 'GET' } @$methods), 'GET in methods');
    ok((grep { $_ eq 'POST' } @$methods), 'POST in methods');
    ok((grep { $_ eq 'DELETE' } @$methods), 'DELETE in methods');

    my ($no_route, $no_methods) = $router->find_path_match('/nothing');
    ok(!defined $no_route, 'no route for unknown path');
};

# Test 12: PAGI::Simple routing methods
subtest 'PAGI::Simple routing methods' => sub {
    my $app = PAGI::Simple->new;

    ok($app->can('get'), 'has get method');
    ok($app->can('post'), 'has post method');
    ok($app->can('put'), 'has put method');
    ok($app->can('del'), 'has del method');
    ok($app->can('patch'), 'has patch method');
    ok($app->can('any'), 'has any method');
    ok($app->can('route'), 'has route method');
    ok($app->can('router'), 'has router method');
};

# Test 13: PAGI::Simple route registration
subtest 'PAGI::Simple route registration' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->get('/' => sub { });
    is($result, $app, 'get returns $app for chaining');

    $app->post('/users' => sub { });
    $app->put('/users' => sub { });
    $app->del('/users' => sub { });
    $app->patch('/users' => sub { });

    my @routes = $app->router->routes;
    is(scalar @routes, 5, 'five routes registered');
};

# Test 14: PAGI::Simple any method
subtest 'PAGI::Simple any method' => sub {
    my $app = PAGI::Simple->new;

    $app->any('/ping' => sub { });

    my $router = $app->router;
    my $match_get = $router->match('GET', '/ping');
    my $match_post = $router->match('POST', '/ping');

    ok($match_get, 'any matches GET');
    ok($match_post, 'any matches POST');
};

# Test 15: PAGI::Simple route method
subtest 'PAGI::Simple route method' => sub {
    my $app = PAGI::Simple->new;

    $app->route('OPTIONS', '/resource' => sub { });
    $app->route('HEAD', '/resource' => sub { });

    my $router = $app->router;
    my $match_options = $router->match('OPTIONS', '/resource');
    my $match_head = $router->match('HEAD', '/resource');

    ok($match_options, 'OPTIONS route matches');
    ok($match_head, 'HEAD route matches');
};

# Test 16: Method chaining
subtest 'method chaining' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/' => sub { })
        ->post('/users' => sub { })
        ->get('/users' => sub { });

    is(scalar $app->router->routes, 3, 'three routes via chaining');
};

done_testing;
