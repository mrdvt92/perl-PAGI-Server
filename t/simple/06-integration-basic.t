use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: PAGI::Simple integration - end-to-end HTTP handling

use PAGI::Simple;

# Helper to simulate a PAGI HTTP request
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $query  = $opts{query_string} // '';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
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

# Test 1: 404 for unregistered route
subtest '404 for unregistered route' => sub {
    my $app = PAGI::Simple->new;

    my $sent = simulate_request($app, path => '/nonexistent');

    is(scalar @$sent, 2, 'two events sent');
    is($sent->[0]{type}, 'http.response.start', 'response started');
    is($sent->[0]{status}, 404, 'status is 404');
    is($sent->[1]{body}, 'Not Found', 'body is Not Found');
};

# Test 2: Simple GET route
subtest 'simple GET route' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/' => sub ($c) {
        $c->text('Hello, World!');
    });

    my $sent = simulate_request($app, method => 'GET', path => '/');

    is(scalar @$sent, 2, 'two events sent');
    is($sent->[0]{status}, 200, 'status is 200');
    is($sent->[1]{body}, 'Hello, World!', 'body is correct');
};

# Test 3: POST route
subtest 'POST route' => sub {
    my $app = PAGI::Simple->new;

    $app->post('/users' => sub ($c) {
        $c->status(201)->json({ created => 1 });
    });

    my $sent = simulate_request($app, method => 'POST', path => '/users');

    is($sent->[0]{status}, 201, 'status is 201');
    like($sent->[1]{body}, qr/"created"/, 'JSON body contains created');
};

# Test 4: 405 Method Not Allowed
subtest '405 Method Not Allowed' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/resource' => sub ($c) { $c->text('OK'); });
    $app->post('/resource' => sub ($c) { $c->text('Created'); });

    my $sent = simulate_request($app, method => 'DELETE', path => '/resource');

    is($sent->[0]{status}, 405, 'status is 405');

    # Check Allow header
    my @allow = grep { $_->[0] eq 'Allow' } @{$sent->[0]{headers}};
    is(scalar @allow, 1, 'has Allow header');
    like($allow[0][1], qr/GET/, 'Allow includes GET');
    like($allow[0][1], qr/POST/, 'Allow includes POST');
};

# Test 5: Multiple routes
subtest 'multiple routes' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/' => sub ($c) { $c->text('home'); })
        ->get('/about' => sub ($c) { $c->text('about'); })
        ->get('/contact' => sub ($c) { $c->text('contact'); });

    my $home = simulate_request($app, path => '/');
    my $about = simulate_request($app, path => '/about');
    my $contact = simulate_request($app, path => '/contact');

    is($home->[1]{body}, 'home', 'home route works');
    is($about->[1]{body}, 'about', 'about route works');
    is($contact->[1]{body}, 'contact', 'contact route works');
};

# Test 6: JSON response
subtest 'JSON response' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/api/status' => sub ($c) {
        $c->json({ status => 'ok', count => 42 });
    });

    my $sent = simulate_request($app, path => '/api/status');

    my @ct = grep { $_->[0] eq 'content-type' } @{$sent->[0]{headers}};
    like($ct[0][1], qr{application/json}, 'content-type is application/json');

    my $body = $sent->[1]{body};
    like($body, qr/"status"/, 'JSON contains status');
    like($body, qr/"count"/, 'JSON contains count');
};

# Test 7: HTML response
subtest 'HTML response' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/page' => sub ($c) {
        $c->html('<html><body>Hello</body></html>');
    });

    my $sent = simulate_request($app, path => '/page');

    my @ct = grep { $_->[0] eq 'content-type' } @{$sent->[0]{headers}};
    like($ct[0][1], qr{text/html}, 'content-type is text/html');
    is($sent->[1]{body}, '<html><body>Hello</body></html>', 'body is HTML');
};

# Test 8: Redirect
subtest 'redirect response' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/old' => sub ($c) {
        $c->redirect('/new');
    });

    my $sent = simulate_request($app, path => '/old');

    is($sent->[0]{status}, 302, 'status is 302');
    my @loc = grep { $_->[0] eq 'location' } @{$sent->[0]{headers}};
    is($loc[0][1], '/new', 'location header is /new');
};

# Test 9: Custom headers
subtest 'custom headers' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/api' => sub ($c) {
        $c->res_header('X-Request-Id', 'abc123')
          ->res_header('X-Version', '1.0')
          ->json({ ok => 1 });
    });

    my $sent = simulate_request($app, path => '/api');

    my @custom = grep { $_->[0] =~ /^X-/ } @{$sent->[0]{headers}};
    is(scalar @custom, 2, 'two custom headers');
};

# Test 10: Context has access to request
subtest 'context has request' => sub {
    my $app = PAGI::Simple->new;
    my $captured_method;
    my $captured_path;

    $app->get('/info' => sub ($c) {
        $captured_method = $c->req->method;
        $captured_path = $c->req->path;
        $c->text('ok');
    });

    simulate_request($app, method => 'GET', path => '/info');

    is($captured_method, 'GET', 'request method accessible');
    is($captured_path, '/info', 'request path accessible');
};

# Test 11: Query parameters accessible
subtest 'query parameters accessible' => sub {
    my $app = PAGI::Simple->new;
    my $captured_name;

    $app->get('/search' => sub ($c) {
        $captured_name = $c->req->query_param('q');
        $c->text('searched');
    });

    simulate_request($app, path => '/search', query_string => 'q=hello');

    is($captured_name, 'hello', 'query param accessible');
};

# Test 12: any() matches multiple methods
subtest 'any() matches multiple methods' => sub {
    my $app = PAGI::Simple->new;

    $app->any('/ping' => sub ($c) {
        $c->text('pong');
    });

    my $get = simulate_request($app, method => 'GET', path => '/ping');
    my $post = simulate_request($app, method => 'POST', path => '/ping');
    my $put = simulate_request($app, method => 'PUT', path => '/ping');

    is($get->[1]{body}, 'pong', 'GET works');
    is($post->[1]{body}, 'pong', 'POST works');
    is($put->[1]{body}, 'pong', 'PUT works');
};

# Test 13: Stash is available
subtest 'stash is available' => sub {
    my $app = PAGI::Simple->new;
    my $stash_value;

    $app->get('/stash-test' => sub ($c) {
        $c->stash->{key} = 'value';
        $stash_value = $c->stash->{key};
        $c->text('ok');
    });

    simulate_request($app, path => '/stash-test');

    is($stash_value, 'value', 'stash is usable');
};

# Test 14: App stash available in handler
subtest 'app stash available' => sub {
    my $app = PAGI::Simple->new;
    $app->stash->{config} = { debug => 1 };

    my $captured_debug;

    $app->get('/config' => sub ($c) {
        $captured_debug = $c->app->stash->{config}{debug};
        $c->text('ok');
    });

    simulate_request($app, path => '/config');

    is($captured_debug, 1, 'app stash accessible in handler');
};

# Test 15: Error handling - handler throws
subtest 'error handling' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/error' => sub ($c) {
        die "Something went wrong";
    });

    my $sent = simulate_request($app, path => '/error');

    is($sent->[0]{status}, 500, 'status is 500');
    like($sent->[1]{body}, qr/Internal Server Error/, 'body indicates error');
};

done_testing;
