use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Error Handling in PAGI::Simple

use PAGI::Simple;

# Helper to simulate HTTP request
sub simulate_http ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path = $opts{path} // '/';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => $path,
        headers => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.disconnect' }) };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
        status => $sent[0]{status},
        headers => { map { @$_ } @{$sent[0]{headers} // []} },
        body => $sent[1]{body} // '',
    };
}

# Test 1: error method exists
subtest 'error method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('error'), 'app has error method');
};

# Test 2: error returns $app for chaining
subtest 'error returns app' => sub {
    my $app = PAGI::Simple->new;
    my $result = $app->error(404 => sub { });
    is($result, $app, 'error returns $app');
};

# Test 3: Custom 404 handler
subtest 'custom 404 handler' => sub {
    my $app = PAGI::Simple->new;

    $app->error(404 => sub ($c, $msg = undef) {
        $c->json({ error => 'Resource not found', path => $c->path });
    });

    my $result = simulate_http($app, path => '/nonexistent');

    is($result->{status}, 200, 'custom handler sets status');
    like($result->{body}, qr/"error"\s*:\s*"Resource not found"/, 'custom body');
    like($result->{body}, qr/"path"\s*:\s*"\/nonexistent"/, 'path included');
};

# Test 4: Custom 405 handler
subtest 'custom 405 handler' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/resource' => sub ($c) {
        $c->text('OK');
    });

    $app->error(405 => sub ($c, $msg = undef) {
        $c->status(405)->json({ error => 'Method not supported' });
    });

    my $result = simulate_http($app, method => 'POST', path => '/resource');

    is($result->{status}, 405, 'status 405');
    like($result->{body}, qr/Method not supported/, '405 custom body');
};

# Test 5: Custom 500 handler receives error
subtest 'custom 500 handler' => sub {
    my $app = PAGI::Simple->new;
    my $received_error;

    $app->error(500 => sub ($c, $error) {
        $received_error = $error;
        $c->status(500)->json({ error => 'Something went wrong' });
    });

    $app->get('/boom' => sub ($c) {
        die "Kaboom!";
    });

    my $result = simulate_http($app, path => '/boom');

    is($result->{status}, 500, 'status 500');
    like($received_error, qr/Kaboom/, 'error passed to handler');
    like($result->{body}, qr/Something went wrong/, 'custom error body');
};

# Test 6: abort method exists in context
subtest 'abort method exists' => sub {
    my $app = PAGI::Simple->new;
    my $has_abort = 0;

    $app->get('/test' => sub ($c) {
        $has_abort = $c->can('abort') ? 1 : 0;
        $c->text('OK');
    });

    simulate_http($app, path => '/test');
    ok($has_abort, 'context has abort method');
};

# Test 7: abort stops processing
subtest 'abort stops processing' => sub {
    my $app = PAGI::Simple->new;
    my $reached_after = 0;

    $app->get('/admin' => sub ($c) {
        $c->abort(403);
        $reached_after = 1;  # Should not reach here
        $c->text('Admin area');
    });

    my $result = simulate_http($app, path => '/admin');

    is($result->{status}, 403, 'abort status');
    like($result->{body}, qr/Forbidden/, 'default forbidden text');
    ok(!$reached_after, 'code after abort not reached');
};

# Test 8: abort with custom message
subtest 'abort with custom message' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/item/:id' => sub ($c) {
        $c->abort(404, "Item not found in database");
    });

    my $result = simulate_http($app, path => '/item/999');

    is($result->{status}, 404, 'status 404');
    like($result->{body}, qr/Item not found in database/, 'custom message');
};

# Test 9: abort uses custom error handler
subtest 'abort uses custom error handler' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->error(403 => sub ($c, $msg) {
        $handler_called = 1;
        $c->status(403)->json({
            error => 'Access denied',
            detail => $msg // 'No details',
        });
    });

    $app->get('/admin' => sub ($c) {
        $c->abort(403, "Admin only");
    });

    my $result = simulate_http($app, path => '/admin');

    ok($handler_called, 'custom handler called by abort');
    is($result->{status}, 403, 'status 403');
    like($result->{body}, qr/Access denied/, 'custom handler body');
    like($result->{body}, qr/Admin only/, 'message passed to handler');
};

# Test 10: Default error responses work
subtest 'default error responses' => sub {
    my $app = PAGI::Simple->new;

    # 404
    my $result1 = simulate_http($app, path => '/nothing');
    is($result1->{status}, 404, 'default 404 status');
    like($result1->{body}, qr/Not Found/, 'default 404 body');

    # 405
    $app->get('/only-get' => sub ($c) { $c->text('OK'); });
    my $result2 = simulate_http($app, method => 'DELETE', path => '/only-get');
    is($result2->{status}, 405, 'default 405 status');
    like($result2->{body}, qr/Method Not Allowed/, 'default 405 body');

    # 500
    $app->get('/error' => sub ($c) { die "Oops"; });
    my $result3 = simulate_http($app, path => '/error');
    is($result3->{status}, 500, 'default 500 status');
    like($result3->{body}, qr/Internal Server Error/, 'default 500 body');
};

# Test 11: Method chaining with error
subtest 'method chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app
        ->error(404 => sub ($c) { $c->text('Not here'); })
        ->error(500 => sub ($c, $e) { $c->text('Broken'); })
        ->get('/' => sub ($c) { $c->text('Hi'); });

    is($result, $app, 'chaining works');
};

# Test 12: Multiple error handlers coexist
subtest 'multiple error handlers' => sub {
    my $app = PAGI::Simple->new;
    my %called;

    $app->error(404 => sub ($c, $msg = undef) {
        $called{404} = 1;
        $c->status(404)->text('Custom 404');
    });

    $app->error(500 => sub ($c, $e = undef) {
        $called{500} = 1;
        $c->status(500)->text('Custom 500');
    });

    $app->get('/error' => sub ($c) { die "boom"; });

    # Trigger 404
    simulate_http($app, path => '/missing');
    ok($called{404}, '404 handler called');

    # Trigger 500
    simulate_http($app, path => '/error');
    ok($called{500}, '500 handler called');
};

# Test 13: Error handler can access request info
subtest 'error handler accesses request' => sub {
    my $app = PAGI::Simple->new;
    my $captured_method;
    my $captured_path;

    $app->error(404 => sub ($c, $msg = undef) {
        $captured_method = $c->method;
        $captured_path = $c->path;
        $c->status(404)->text('Gone');
    });

    simulate_http($app, method => 'POST', path => '/api/users');

    is($captured_method, 'POST', 'method captured');
    is($captured_path, '/api/users', 'path captured');
};

# Test 14: abort with various status codes
subtest 'abort with various codes' => sub {
    my $app = PAGI::Simple->new;

    my @codes = (400, 401, 403, 404, 409, 422, 500, 503);

    for my $code (@codes) {
        $app->get("/test-$code" => sub ($c) {
            $c->abort($code);
        });
    }

    for my $code (@codes) {
        my $result = simulate_http($app, path => "/test-$code");
        is($result->{status}, $code, "abort($code) works");
    }
};

# Test 15: after hooks run after abort
subtest 'after hooks run after abort' => sub {
    my $app = PAGI::Simple->new;
    my $after_ran = 0;

    $app->hook(after => sub ($c) {
        $after_ran = 1;
    });

    $app->get('/admin' => sub ($c) {
        $c->abort(403);
    });

    simulate_http($app, path => '/admin');

    ok($after_ran, 'after hook ran after abort');
};

# Test 16: get_error_handler method
subtest 'get_error_handler method' => sub {
    my $app = PAGI::Simple->new;

    my $handler = sub { };
    $app->error(404 => $handler);

    is($app->get_error_handler(404), $handler, 'get_error_handler returns handler');
    is($app->get_error_handler(500), undef, 'get_error_handler returns undef for unset');
};

# Test 17: Error handler returning JSON
subtest 'error handler returns JSON' => sub {
    my $app = PAGI::Simple->new;

    $app->error(404 => sub ($c, $msg = undef) {
        $c->status(404)->json({
            success => 0,
            error => {
                code => 'NOT_FOUND',
                message => 'The requested resource was not found',
            },
        });
    });

    my $result = simulate_http($app, path => '/api/missing');

    is($result->{status}, 404, 'status 404');
    is($result->{headers}{'content-type'}, 'application/json; charset=utf-8', 'JSON content-type');
    like($result->{body}, qr/"success"\s*:\s*0/, 'JSON body success field');
    like($result->{body}, qr/"code"\s*:\s*"NOT_FOUND"/, 'JSON body error code');
};

# Test 18: Override handler replaces previous
subtest 'override error handler' => sub {
    my $app = PAGI::Simple->new;

    $app->error(404 => sub ($c, $msg = undef) {
        $c->status(404)->text('First handler');
    });

    $app->error(404 => sub ($c, $msg = undef) {
        $c->status(404)->text('Second handler');
    });

    my $result = simulate_http($app, path => '/missing');

    like($result->{body}, qr/Second handler/, 'second handler used');
};

# Test 19: abort in before hook
subtest 'abort in before hook' => sub {
    my $app = PAGI::Simple->new;
    my $route_called = 0;

    $app->hook(before => sub ($c) {
        $c->abort(401, "Login required");
    });

    $app->get('/' => sub ($c) {
        $route_called = 1;
        $c->text('Hello');
    });

    my $result = simulate_http($app, path => '/');

    is($result->{status}, 401, 'abort status from before hook');
    ok(!$route_called, 'route handler not called');
};

# Test 20: Integration - API-style error handling
subtest 'integration: API error handling' => sub {
    my $app = PAGI::Simple->new;

    # Set up API-style error handlers
    $app->error(400 => sub ($c, $msg) {
        $c->status(400)->json({ error => 'Bad Request', detail => $msg });
    });

    $app->error(401 => sub ($c, $msg) {
        $c->status(401)->json({ error => 'Unauthorized', detail => $msg // 'Login required' });
    });

    $app->error(404 => sub ($c, $msg) {
        $c->status(404)->json({ error => 'Not Found', path => $c->path });
    });

    # Set up routes
    $app->get('/api/users/:id' => sub ($c) {
        my $id = $c->path_params->{id};
        if ($id !~ /^\d+$/) {
            $c->abort(400, "Invalid user ID");
        }
        if ($id eq '0') {
            $c->abort(404, "User not found");
        }
        $c->json({ id => $id, name => "User $id" });
    });

    # Test valid request
    my $r1 = simulate_http($app, path => '/api/users/123');
    is($r1->{status}, 200, 'valid request OK');
    like($r1->{body}, qr/"id"\s*:\s*"?123"?/, 'user data returned');

    # Test invalid ID
    my $r2 = simulate_http($app, path => '/api/users/abc');
    is($r2->{status}, 400, 'invalid ID returns 400');
    like($r2->{body}, qr/Invalid user ID/, 'error detail');

    # Test not found
    my $r3 = simulate_http($app, path => '/api/users/0');
    is($r3->{status}, 404, 'not found returns 404');

    # Test unknown route
    my $r4 = simulate_http($app, path => '/api/unknown');
    is($r4->{status}, 404, 'unknown route 404');
    like($r4->{body}, qr/\/api\/unknown/, 'path in error');
};

done_testing;
