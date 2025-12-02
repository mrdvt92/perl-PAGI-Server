use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Route groups in PAGI::Simple

use PAGI::Simple;

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

    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Test 1: group method exists
subtest 'group method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('group'), 'app has group method');
};

# Test 2: Basic group with prefix
subtest 'basic group with prefix' => sub {
    my $app = PAGI::Simple->new;
    my $handler_path;

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) {
            $handler_path = '/api/users';
            $c->text('users');
        });
    });

    my $sent = simulate_request($app, path => '/api/users');

    is($handler_path, '/api/users', 'handler was called');
    is($sent->[0]{status}, 200, 'returns 200');
};

# Test 3: Group prefix not matching without it
subtest 'group prefix required' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) {
            $handler_called = 1;
            $c->text('users');
        });
    });

    # Request without prefix should 404
    my $sent = simulate_request($app, path => '/users');

    ok(!$handler_called, 'handler not called without prefix');
    is($sent->[0]{status}, 404, 'returns 404');
};

# Test 4: Multiple routes in a group
subtest 'multiple routes in group' => sub {
    my $app = PAGI::Simple->new;
    my @handlers_called;

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) {
            push @handlers_called, 'users';
            $c->text('users');
        });
        $app->get('/posts' => sub ($c) {
            push @handlers_called, 'posts';
            $c->text('posts');
        });
        $app->post('/comments' => sub ($c) {
            push @handlers_called, 'comments';
            $c->text('comments');
        });
    });

    simulate_request($app, path => '/api/users');
    simulate_request($app, path => '/api/posts');
    simulate_request($app, method => 'POST', path => '/api/comments');

    is(\@handlers_called, ['users', 'posts', 'comments'], 'all handlers called');
};

# Test 5: Group with middleware
subtest 'group with middleware' => sub {
    my $app = PAGI::Simple->new;
    my $auth_called = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_called = 1;
        $next->();
    });

    $app->group('/api' => [qw(auth)] => sub ($app) {
        $app->get('/users' => sub ($c) {
            $c->text('users');
        });
    });

    simulate_request($app, path => '/api/users');

    ok($auth_called, 'middleware was called');
};

# Test 6: Group middleware applies to all routes
subtest 'group middleware applies to all routes' => sub {
    my $app = PAGI::Simple->new;
    my $auth_count = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_count++;
        $next->();
    });

    $app->group('/api' => [qw(auth)] => sub ($app) {
        $app->get('/users' => sub ($c) { $c->text('users') });
        $app->get('/posts' => sub ($c) { $c->text('posts') });
        $app->get('/comments' => sub ($c) { $c->text('comments') });
    });

    simulate_request($app, path => '/api/users');
    simulate_request($app, path => '/api/posts');
    simulate_request($app, path => '/api/comments');

    is($auth_count, 3, 'middleware called for each route');
};

# Test 7: Routes outside group don't get middleware
subtest 'routes outside group unaffected' => sub {
    my $app = PAGI::Simple->new;
    my $auth_called = 0;

    $app->middleware(auth => sub ($c, $next) {
        $auth_called = 1;
        $next->();
    });

    $app->get('/public' => sub ($c) {
        $c->text('public');
    });

    $app->group('/api' => [qw(auth)] => sub ($app) {
        $app->get('/private' => sub ($c) {
            $c->text('private');
        });
    });

    # Request public route
    $auth_called = 0;
    simulate_request($app, path => '/public');
    ok(!$auth_called, 'auth not called for public route');

    # Request private route
    $auth_called = 0;
    simulate_request($app, path => '/api/private');
    ok($auth_called, 'auth called for private route');
};

# Test 8: Nested groups
subtest 'nested groups' => sub {
    my $app = PAGI::Simple->new;
    my $handler_path;

    $app->group('/api' => sub ($app) {
        $app->group('/v1' => sub ($app) {
            $app->get('/users' => sub ($c) {
                $handler_path = 'v1-users';
                $c->text('v1 users');
            });
        });
        $app->group('/v2' => sub ($app) {
            $app->get('/users' => sub ($c) {
                $handler_path = 'v2-users';
                $c->text('v2 users');
            });
        });
    });

    $handler_path = '';
    simulate_request($app, path => '/api/v1/users');
    is($handler_path, 'v1-users', 'v1 users reached');

    $handler_path = '';
    simulate_request($app, path => '/api/v2/users');
    is($handler_path, 'v2-users', 'v2 users reached');
};

# Test 9: Nested groups accumulate middleware
subtest 'nested groups accumulate middleware' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(outer => sub ($c, $next) {
        push @order, 'outer-in';
        $next->();
        push @order, 'outer-out';
    });

    $app->middleware(inner => sub ($c, $next) {
        push @order, 'inner-in';
        $next->();
        push @order, 'inner-out';
    });

    $app->group('/api' => [qw(outer)] => sub ($app) {
        $app->group('/v1' => [qw(inner)] => sub ($app) {
            $app->get('/users' => sub ($c) {
                push @order, 'handler';
                $c->text('users');
            });
        });
    });

    simulate_request($app, path => '/api/v1/users');

    is(\@order, [
        'outer-in',
        'inner-in',
        'handler',
        'inner-out',
        'outer-out',
    ], 'middleware accumulated and chained correctly');
};

# Test 10: Group + route middleware
subtest 'group and route middleware combine' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(group_mw => sub ($c, $next) {
        push @order, 'group-in';
        $next->();
        push @order, 'group-out';
    });

    $app->middleware(route_mw => sub ($c, $next) {
        push @order, 'route-in';
        $next->();
        push @order, 'route-out';
    });

    $app->group('/api' => [qw(group_mw)] => sub ($app) {
        $app->get('/special' => [qw(route_mw)] => sub ($c) {
            push @order, 'handler';
            $c->text('special');
        });
    });

    simulate_request($app, path => '/api/special');

    # Group middleware runs first, then route middleware
    is(\@order, [
        'group-in',
        'route-in',
        'handler',
        'route-out',
        'group-out',
    ], 'group middleware before route middleware');
};

# Test 11: Group returns $app for chaining
subtest 'group returns app for chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->group('/api' => sub ($app) {
        $app->get('/test' => sub ($c) { $c->text('ok') });
    });

    is($result, $app, 'group returns $app');
};

# Test 12: Chaining groups
subtest 'chaining groups' => sub {
    my $app = PAGI::Simple->new;
    my @handlers;

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) {
            push @handlers, 'api-users';
            $c->text('users');
        });
    })->group('/admin' => sub ($app) {
        $app->get('/dashboard' => sub ($c) {
            push @handlers, 'admin-dashboard';
            $c->text('dashboard');
        });
    });

    simulate_request($app, path => '/api/users');
    simulate_request($app, path => '/admin/dashboard');

    is(\@handlers, ['api-users', 'admin-dashboard'], 'chained groups work');
};

# Test 13: Group context restored after callback
subtest 'group context restored' => sub {
    my $app = PAGI::Simple->new;
    my @handlers;

    $app->group('/api' => sub ($app) {
        $app->get('/inner' => sub ($c) {
            push @handlers, 'inner';
            $c->text('inner');
        });
    });

    # Route after group should not have prefix
    $app->get('/outer' => sub ($c) {
        push @handlers, 'outer';
        $c->text('outer');
    });

    simulate_request($app, path => '/api/inner');
    simulate_request($app, path => '/outer');

    # Check /outer works at root, not /api/outer
    my $sent = simulate_request($app, path => '/api/outer');
    is($sent->[0]{status}, 404, '/api/outer should 404');

    is(\@handlers, ['inner', 'outer'], 'handlers called correctly');
};

# Test 14: Group with root path
subtest 'group with root path handler' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->group('/api' => sub ($app) {
        $app->get('/' => sub ($c) {
            $handler_called = 1;
            $c->text('api root');
        });
    });

    my $sent = simulate_request($app, path => '/api/');

    ok($handler_called, 'handler called');
    is($sent->[0]{status}, 200, 'returns 200');
};

# Test 15: Group with all HTTP methods
subtest 'group with all HTTP methods' => sub {
    my $app = PAGI::Simple->new;
    my @methods_called;

    $app->group('/api' => sub ($app) {
        $app->get('/resource' => sub ($c) {
            push @methods_called, 'GET';
            $c->text('get');
        });
        $app->post('/resource' => sub ($c) {
            push @methods_called, 'POST';
            $c->text('post');
        });
        $app->put('/resource' => sub ($c) {
            push @methods_called, 'PUT';
            $c->text('put');
        });
        $app->del('/resource' => sub ($c) {
            push @methods_called, 'DELETE';
            $c->text('delete');
        });
        $app->patch('/resource' => sub ($c) {
            push @methods_called, 'PATCH';
            $c->text('patch');
        });
    });

    simulate_request($app, method => 'GET', path => '/api/resource');
    simulate_request($app, method => 'POST', path => '/api/resource');
    simulate_request($app, method => 'PUT', path => '/api/resource');
    simulate_request($app, method => 'DELETE', path => '/api/resource');
    simulate_request($app, method => 'PATCH', path => '/api/resource');

    is(\@methods_called, [qw(GET POST PUT DELETE PATCH)], 'all methods work in group');
};

# Test 16: Invalid group arguments
subtest 'invalid group arguments dies' => sub {
    my $app = PAGI::Simple->new;

    my $died = 0;
    eval {
        $app->group('/api', 'not-a-callback');
    };
    $died = 1 if $@;

    ok($died, 'invalid arguments die');
    # Perl strict refs catches non-coderef before our custom error
    ok($@, 'error message present');
};

# Test 17: Three-level nesting
subtest 'three-level nesting' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->group('/a' => sub ($app) {
        $app->group('/b' => sub ($app) {
            $app->group('/c' => sub ($app) {
                $app->get('/deep' => sub ($c) {
                    $handler_called = 1;
                    $c->text('deep');
                });
            });
        });
    });

    my $sent = simulate_request($app, path => '/a/b/c/deep');

    ok($handler_called, 'deep handler called');
    is($sent->[0]{status}, 200, 'returns 200');
};

# Test 18: Group with path params
subtest 'group with path params' => sub {
    my $app = PAGI::Simple->new;
    my $captured_org;
    my $captured_repo;

    $app->group('/orgs/:org' => sub ($app) {
        $app->get('/repos/:repo' => sub ($c) {
            $captured_org = $c->path_params->{org};
            $captured_repo = $c->path_params->{repo};
            $c->text('repo');
        });
    });

    simulate_request($app, path => '/orgs/acme/repos/widgets');

    is($captured_org, 'acme', 'captured org param');
    is($captured_repo, 'widgets', 'captured repo param');
};

# Test 19: Multiple middleware in group
subtest 'multiple middleware in group' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->middleware(a => sub ($c, $next) {
        push @order, 'a';
        $next->();
    });
    $app->middleware(b => sub ($c, $next) {
        push @order, 'b';
        $next->();
    });
    $app->middleware(c => sub ($c, $next) {
        push @order, 'c';
        $next->();
    });

    $app->group('/api' => [qw(a b c)] => sub ($app) {
        $app->get('/test' => sub ($c) {
            push @order, 'handler';
            $c->text('test');
        });
    });

    simulate_request($app, path => '/api/test');

    is(\@order, ['a', 'b', 'c', 'handler'], 'all middleware called in order');
};

# Test 20: Group with global hooks
subtest 'group with global hooks' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
    });

    $app->hook(after => sub ($c) {
        push @order, 'after';
    });

    $app->middleware(group_mw => sub ($c, $next) {
        push @order, 'group-in';
        $next->();
        push @order, 'group-out';
    });

    $app->group('/api' => [qw(group_mw)] => sub ($app) {
        $app->get('/test' => sub ($c) {
            push @order, 'handler';
            $c->text('test');
        });
    });

    simulate_request($app, path => '/api/test');

    is(\@order, [
        'before',
        'group-in',
        'handler',
        'group-out',
        'after',
    ], 'global hooks wrap group middleware');
};

done_testing;
