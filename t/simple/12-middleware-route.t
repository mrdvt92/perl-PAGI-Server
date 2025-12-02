use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Per-route middleware in PAGI::Simple

use PAGI::Simple;

# Helper to simulate a PAGI HTTP request
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => $path,
        headers => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Test 1: Route with single middleware
subtest 'route with single middleware' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(log => sub ($c, $next) {
        push @order, 'log-before';
        $next->();
        push @order, 'log-after';
    });

    $app->get('/test' => [qw(log)] => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app, path => '/test');

    is(\@order, ['log-before', 'handler', 'log-after'], 'middleware wraps handler');
};

# Test 2: Route with multiple middleware
subtest 'route with multiple middleware' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(first => sub ($c, $next) {
        push @order, 'first-before';
        $next->();
        push @order, 'first-after';
    });

    $app->middleware(second => sub ($c, $next) {
        push @order, 'second-before';
        $next->();
        push @order, 'second-after';
    });

    $app->get('/test' => [qw(first second)] => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app, path => '/test');

    # First middleware wraps second, which wraps handler
    is(\@order, [
        'first-before',
        'second-before',
        'handler',
        'second-after',
        'first-after',
    ], 'middleware chain in correct order');
};

# Test 3: Route without middleware still works
subtest 'route without middleware' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->middleware(unused => sub ($c, $next) {
        die "Should not be called";
    });

    $app->get('/test' => sub ($c) {
        $handler_called = 1;
        $c->text('ok');
    });

    my $sent = simulate_request($app, path => '/test');

    ok($handler_called, 'handler was called');
    is($sent->[0]{status}, 200, 'returns 200');
};

# Test 4: Middleware can short-circuit
subtest 'middleware can short-circuit' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->middleware(auth => sub ($c, $next) {
        # Don't call $next, just respond
        $c->status(401)->text('Unauthorized');
    });

    $app->get('/protected' => [qw(auth)] => sub ($c) {
        $handler_called = 1;
        $c->text('secret');
    });

    my $sent = simulate_request($app, path => '/protected');

    ok(!$handler_called, 'handler not called');
    is($sent->[0]{status}, 401, 'returns 401');
    is($sent->[1]{body}, 'Unauthorized', 'returns auth message');
};

# Test 5: Middleware only applies to specific route
subtest 'middleware applies only to specific route' => sub {
    my $app = PAGI::Simple->new;
    my $auth_called = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_called = 1;
        $next->();
    });

    $app->get('/public' => sub ($c) {
        $c->text('public');
    });

    $app->get('/private' => [qw(auth)] => sub ($c) {
        $c->text('private');
    });

    # Request public route
    $auth_called = 0;
    simulate_request($app, path => '/public');
    ok(!$auth_called, 'auth not called for public route');

    # Request private route
    $auth_called = 0;
    simulate_request($app, path => '/private');
    ok($auth_called, 'auth called for private route');
};

# Test 6: Per-route middleware with global hooks
subtest 'per-route middleware with global hooks' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'global-before';
    });

    $app->hook(after => sub ($c) {
        push @order, 'global-after';
    });

    $app->middleware(route_mw => sub ($c, $next) {
        push @order, 'route-mw-before';
        $next->();
        push @order, 'route-mw-after';
    });

    $app->get('/test' => [qw(route_mw)] => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app, path => '/test');

    is(\@order, [
        'global-before',
        'route-mw-before',
        'handler',
        'route-mw-after',
        'global-after',
    ], 'global hooks wrap route middleware');
};

# Test 7: Unknown middleware dies
subtest 'unknown middleware dies' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/test' => [qw(nonexistent)] => sub ($c) {
        $c->text('ok');
    });

    my $sent = simulate_request($app, path => '/test');

    # Should return 500 error
    is($sent->[0]{status}, 500, 'returns 500 for unknown middleware');
    like($sent->[1]{body}, qr/Unknown middleware/, 'error message mentions unknown middleware');
};

# Test 8: Middleware works with POST routes
subtest 'middleware works with POST' => sub {
    my $app = PAGI::Simple->new;
    my $auth_called = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_called = 1;
        $next->();
    });

    $app->post('/users' => [qw(auth)] => sub ($c) {
        $c->json({ created => 1 });
    });

    simulate_request($app, method => 'POST', path => '/users');

    ok($auth_called, 'middleware called for POST');
};

# Test 9: Middleware works with PUT routes
subtest 'middleware works with PUT' => sub {
    my $app = PAGI::Simple->new;
    my $log_called = 0;

    $app->middleware(log => sub ($c, $next) {
        $log_called = 1;
        $next->();
    });

    $app->put('/users/:id' => [qw(log)] => sub ($c) {
        $c->json({ updated => 1 });
    });

    simulate_request($app, method => 'PUT', path => '/users/42');

    ok($log_called, 'middleware called for PUT');
};

# Test 10: Middleware works with DELETE routes
subtest 'middleware works with DELETE' => sub {
    my $app = PAGI::Simple->new;
    my $admin_called = 0;

    $app->middleware(admin => sub ($c, $next) {
        $admin_called = 1;
        $next->();
    });

    $app->del('/users/:id' => [qw(admin)] => sub ($c) {
        $c->json({ deleted => 1 });
    });

    simulate_request($app, method => 'DELETE', path => '/users/42');

    ok($admin_called, 'middleware called for DELETE');
};

# Test 11: Middleware works with PATCH routes
subtest 'middleware works with PATCH' => sub {
    my $app = PAGI::Simple->new;
    my $validate_called = 0;

    $app->middleware(validate => sub ($c, $next) {
        $validate_called = 1;
        $next->();
    });

    $app->patch('/users/:id' => [qw(validate)] => sub ($c) {
        $c->json({ patched => 1 });
    });

    simulate_request($app, method => 'PATCH', path => '/users/42');

    ok($validate_called, 'middleware called for PATCH');
};

# Test 12: Middleware works with any() routes
subtest 'middleware works with any()' => sub {
    my $app = PAGI::Simple->new;
    my $cors_called = 0;

    $app->middleware(cors => sub ($c, $next) {
        $cors_called = 1;
        $next->();
    });

    $app->any('/api/ping' => [qw(cors)] => sub ($c) {
        $c->text('pong');
    });

    # Test GET
    $cors_called = 0;
    simulate_request($app, method => 'GET', path => '/api/ping');
    ok($cors_called, 'middleware called for GET on any()');

    # Test POST
    $cors_called = 0;
    simulate_request($app, method => 'POST', path => '/api/ping');
    ok($cors_called, 'middleware called for POST on any()');
};

# Test 13: Middleware context has access to path params
subtest 'middleware can access path params' => sub {
    my $app = PAGI::Simple->new;
    my $captured_id;

    $app->middleware(capture => sub ($c, $next) {
        $captured_id = $c->path_params->{id};
        $next->();
    });

    $app->get('/users/:id' => [qw(capture)] => sub ($c) {
        $c->text('ok');
    });

    simulate_request($app, path => '/users/123');

    is($captured_id, '123', 'middleware can access path params');
};

# Test 14: Middleware can modify stash for handler
subtest 'middleware can modify stash' => sub {
    my $app = PAGI::Simple->new;
    my $handler_user;

    $app->middleware(load_user => sub ($c, $next) {
        $c->stash->{user} = { id => 42, name => 'Alice' };
        $next->();
    });

    $app->get('/profile' => [qw(load_user)] => sub ($c) {
        $handler_user = $c->stash->{user};
        $c->json($c->stash->{user});
    });

    simulate_request($app, path => '/profile');

    is($handler_user, { id => 42, name => 'Alice' }, 'handler received stash from middleware');
};

# Test 15: Multiple routes with different middleware
subtest 'multiple routes with different middleware' => sub {
    my $app = PAGI::Simple->new;
    my @called;

    $app->middleware(auth => sub ($c, $next) {
        push @called, 'auth';
        $next->();
    });

    $app->middleware(admin => sub ($c, $next) {
        push @called, 'admin';
        $next->();
    });

    $app->middleware(log => sub ($c, $next) {
        push @called, 'log';
        $next->();
    });

    $app->get('/users' => [qw(auth)] => sub ($c) {
        $c->text('users');
    });

    $app->get('/admin' => [qw(auth admin)] => sub ($c) {
        $c->text('admin');
    });

    $app->get('/debug' => [qw(log)] => sub ($c) {
        $c->text('debug');
    });

    # Test /users
    @called = ();
    simulate_request($app, path => '/users');
    is(\@called, ['auth'], '/users only has auth');

    # Test /admin
    @called = ();
    simulate_request($app, path => '/admin');
    is(\@called, ['auth', 'admin'], '/admin has auth and admin');

    # Test /debug
    @called = ();
    simulate_request($app, path => '/debug');
    is(\@called, ['log'], '/debug only has log');
};

# Test 16: Chained route definition with middleware
subtest 'chained route definition' => sub {
    my $app = PAGI::Simple->new;
    my $auth_count = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_count++;
        $next->();
    });

    $app->get('/a' => [qw(auth)] => sub ($c) { $c->text('a') })
        ->get('/b' => [qw(auth)] => sub ($c) { $c->text('b') })
        ->get('/c' => sub ($c) { $c->text('c') });

    # Test /a
    $auth_count = 0;
    simulate_request($app, path => '/a');
    is($auth_count, 1, '/a called auth');

    # Test /b
    $auth_count = 0;
    simulate_request($app, path => '/b');
    is($auth_count, 1, '/b called auth');

    # Test /c (no middleware)
    $auth_count = 0;
    simulate_request($app, path => '/c');
    is($auth_count, 0, '/c did not call auth');
};

# Test 17: route() method with explicit method
subtest 'route() method with middleware' => sub {
    my $app = PAGI::Simple->new;
    my $cors_called = 0;

    $app->middleware(cors => sub ($c, $next) {
        $cors_called = 1;
        $c->res_header('Access-Control-Allow-Origin', '*');
        $next->();
    });

    $app->route('OPTIONS', '/api/resource' => [qw(cors)] => sub ($c) {
        $c->status(204)->text('');
    });

    simulate_request($app, method => 'OPTIONS', path => '/api/resource');

    ok($cors_called, 'middleware called for OPTIONS');
};

# Test 18: Three middleware deep chain
subtest 'three middleware deep chain' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(a => sub ($c, $next) {
        push @order, 'a-in';
        $next->();
        push @order, 'a-out';
    });

    $app->middleware(b => sub ($c, $next) {
        push @order, 'b-in';
        $next->();
        push @order, 'b-out';
    });

    $app->middleware(c => sub ($c, $next) {
        push @order, 'c-in';
        $next->();
        push @order, 'c-out';
    });

    $app->get('/deep' => [qw(a b c)] => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app, path => '/deep');

    is(\@order, [
        'a-in', 'b-in', 'c-in',
        'handler',
        'c-out', 'b-out', 'a-out',
    ], 'three deep middleware chain works');
};

done_testing;
