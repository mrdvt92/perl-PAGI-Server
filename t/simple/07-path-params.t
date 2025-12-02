use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Path parameters in PAGI::Simple routes

use PAGI::Simple;
use PAGI::Simple::Route;

# Test 1: Route pattern detection - static
subtest 'static route pattern' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/users',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/users');
    ok(defined $params, 'static route matches');
    is(ref $params, 'HASH', 'returns hashref');
    is(scalar keys %$params, 0, 'no params for static route');

    ok(!defined $route->matches('GET', '/users/123'), 'does not match longer path');
};

# Test 2: Route pattern detection - single param
subtest 'single param route' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/users/:id',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/users/123');
    ok(defined $params, 'param route matches');
    is($params->{id}, '123', 'id captured correctly');

    $params = $route->matches('GET', '/users/abc');
    is($params->{id}, 'abc', 'string id captured');

    ok(!defined $route->matches('GET', '/users'), 'does not match without param');
    ok(!defined $route->matches('GET', '/users/123/extra'), 'does not match longer path');
};

# Test 3: Multiple params
subtest 'multiple params route' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/users/:user_id/posts/:post_id',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/users/42/posts/100');
    ok(defined $params, 'multi-param route matches');
    is($params->{user_id}, '42', 'first param captured');
    is($params->{post_id}, '100', 'second param captured');
};

# Test 4: Wildcard param
subtest 'wildcard param route' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/files/*path',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/files/docs/readme.txt');
    ok(defined $params, 'wildcard route matches');
    is($params->{path}, 'docs/readme.txt', 'path captured with slashes');

    $params = $route->matches('GET', '/files/a/b/c/d.txt');
    is($params->{path}, 'a/b/c/d.txt', 'deep path captured');

    $params = $route->matches('GET', '/files/single');
    is($params->{path}, 'single', 'single segment captured');
};

# Test 5: Mixed static and param segments
subtest 'mixed static and param' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/api/v1/users/:id/profile',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/api/v1/users/123/profile');
    ok(defined $params, 'mixed route matches');
    is($params->{id}, '123', 'param captured correctly');

    ok(!defined $route->matches('GET', '/api/v1/users/123/settings'), 'does not match wrong trailing segment');
    ok(!defined $route->matches('GET', '/api/v2/users/123/profile'), 'does not match wrong prefix');
};

# Test 6: Special characters in param values
subtest 'special characters in params' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/search/:query',
        handler => sub { },
    );

    my $params = $route->matches('GET', '/search/hello-world');
    is($params->{query}, 'hello-world', 'hyphen in param');

    $params = $route->matches('GET', '/search/foo_bar');
    is($params->{query}, 'foo_bar', 'underscore in param');

    $params = $route->matches('GET', '/search/test%20value');
    is($params->{query}, 'test%20value', 'encoded space in param');
};

# Test 7: matches_path ignores method
subtest 'matches_path ignores method' => sub {
    my $route = PAGI::Simple::Route->new(
        method => 'GET',
        path   => '/users/:id',
        handler => sub { },
    );

    my $params = $route->matches_path('/users/123');
    ok(defined $params, 'matches_path works');
    is($params->{id}, '123', 'param captured');

    # matches() would fail because of method mismatch
    ok(!defined $route->matches('POST', '/users/123'), 'matches fails for wrong method');
    # but matches_path ignores method
    ok(defined $route->matches_path('/users/123'), 'matches_path ignores method');
};

# Helper to simulate a PAGI HTTP request
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';

    my @sent;
    my $scope = {
        type   => 'http',
        method => $method,
        path   => $path,
    };

    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Test 8: Path params in route handlers
subtest 'path params in handler' => sub {
    my $app = PAGI::Simple->new;
    my $captured_id;

    $app->get('/users/:id' => sub ($c) {
        # param() is async, use then() to chain
        $c->param('id')->then(sub ($id) {
            $captured_id = $id;
            $c->json({ user_id => $id });
        });
    });

    my $sent = simulate_request($app, method => 'GET', path => '/users/42');

    is($sent->[0]{status}, 200, 'status is 200');
    is($captured_id, '42', 'param captured in handler');
    like($sent->[1]{body}, qr/"user_id"/, 'response contains user_id');
};

# Test 9: Multiple params in handler
subtest 'multiple params in handler' => sub {
    my $app = PAGI::Simple->new;
    my ($captured_org, $captured_repo);

    $app->get('/orgs/:org/repos/:repo' => sub ($c) {
        # Use path_params for sync access to multiple params
        my $params = $c->path_params;
        $captured_org = $params->{org};
        $captured_repo = $params->{repo};
        $c->json({ org => $captured_org, repo => $captured_repo });
    });

    simulate_request($app, path => '/orgs/anthropic/repos/claude');

    is($captured_org, 'anthropic', 'org param captured');
    is($captured_repo, 'claude', 'repo param captured');
};

# Test 10: Wildcard in handler
subtest 'wildcard param in handler' => sub {
    my $app = PAGI::Simple->new;
    my $captured_path;

    $app->get('/static/*path' => sub ($c) {
        # Use path_params for sync access to wildcard
        $captured_path = $c->path_params->{path};
        $c->text("Serving: $captured_path");
    });

    simulate_request($app, path => '/static/css/styles/main.css');

    is($captured_path, 'css/styles/main.css', 'wildcard path captured');
};

# Test 11: path_params accessor
subtest 'path_params accessor' => sub {
    my $app = PAGI::Simple->new;
    my $captured_params;

    $app->get('/a/:first/b/:second' => sub ($c) {
        $captured_params = $c->path_params;
        $c->text('ok');
    });

    simulate_request($app, path => '/a/hello/b/world');

    is(ref $captured_params, 'HASH', 'path_params is hashref');
    is($captured_params->{first}, 'hello', 'first param');
    is($captured_params->{second}, 'world', 'second param');
};

# Test 12: Non-existent param returns undef
subtest 'non-existent param' => sub {
    my $app = PAGI::Simple->new;
    my $captured;

    $app->get('/users/:id' => sub ($c) {
        # param() is async, use then() to chain
        $c->param('nonexistent')->then(sub ($val) {
            $captured = $val;
            $c->text('ok');
        });
    });

    simulate_request($app, path => '/users/123');

    ok(!defined $captured, 'non-existent param is undef');
};

# Test 13: Static and param routes can coexist
subtest 'static and param routes coexist' => sub {
    my $app = PAGI::Simple->new;
    my $which_route;

    $app->get('/users' => sub ($c) {
        $which_route = 'list';
        $c->text('list');
    });

    $app->get('/users/:id' => sub ($c) {
        $which_route = 'show';
        $c->text('show');
    });

    simulate_request($app, path => '/users');
    is($which_route, 'list', 'static route matched for /users');

    simulate_request($app, path => '/users/123');
    is($which_route, 'show', 'param route matched for /users/123');
};

# Test 14: 405 works with param routes
subtest '405 with param routes' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/users/:id' => sub ($c) { $c->text('get'); });
    $app->put('/users/:id' => sub ($c) { $c->text('put'); });

    my $sent = simulate_request($app, method => 'DELETE', path => '/users/123');

    is($sent->[0]{status}, 405, 'status is 405');
    my @allow = grep { $_->[0] eq 'Allow' } @{$sent->[0]{headers}};
    like($allow[0][1], qr/GET/, 'Allow includes GET');
    like($allow[0][1], qr/PUT/, 'Allow includes PUT');
};

# Test 15: 404 when no route matches
subtest '404 when path param route does not match' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/users/:id' => sub ($c) { $c->text('ok'); });

    my $sent = simulate_request($app, path => '/posts/123');

    is($sent->[0]{status}, 404, 'status is 404');
};

done_testing;
