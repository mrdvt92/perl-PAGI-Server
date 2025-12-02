use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Hello World Example App

# Load the example app
use FindBin qw($Bin);
my $app_file = "$Bin/../../../examples/simple-01-hello/app.pl";
ok(-f $app_file, 'example app file exists');

# Need to add lib to @INC for the app to load PAGI::Simple
use lib "$Bin/../../../lib";

my $pagi_app = do $app_file;
if ($@) {
    fail("Failed to load app: $@");
    done_testing;
    exit;
}
ok(ref($pagi_app) eq 'CODE', 'app returns a coderef');

# Helper to simulate HTTP request
sub simulate_http ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path = $opts{path} // '/';
    my $query = $opts{query} // '';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.disconnect' }) };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    $app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
        status => $sent[0]{status},
        headers => { map { @$_ } @{$sent[0]{headers} // []} },
        body => $sent[1]{body} // '',
    };
}

# Test 1: Root path returns Hello World
subtest 'root path' => sub {
    my $result = simulate_http($pagi_app, path => '/');

    is($result->{status}, 200, 'status 200');
    is($result->{body}, 'Hello, World!', 'body is Hello, World!');
    is($result->{headers}{'content-type'}, 'text/plain; charset=utf-8', 'text content type');
};

# Test 2: Greet with name parameter
subtest 'greet with name' => sub {
    my $result = simulate_http($pagi_app, path => '/greet/Alice');

    is($result->{status}, 200, 'status 200');
    is($result->{body}, 'Hello, Alice!', 'body greets Alice');
};

# Test 3: Different name parameter
subtest 'greet different name' => sub {
    my $result = simulate_http($pagi_app, path => '/greet/Bob');

    is($result->{status}, 200, 'status 200');
    is($result->{body}, 'Hello, Bob!', 'body greets Bob');
};

# Test 4: JSON endpoint
subtest 'json endpoint' => sub {
    my $result = simulate_http($pagi_app, path => '/json');

    is($result->{status}, 200, 'status 200');
    is($result->{headers}{'content-type'}, 'application/json; charset=utf-8', 'json content type');
    like($result->{body}, qr/"message"\s*:\s*"Hello, World!"/, 'json has message');
    like($result->{body}, qr/"timestamp"\s*:\s*\d+/, 'json has timestamp');
};

# Test 5: HTML endpoint
subtest 'html endpoint' => sub {
    my $result = simulate_http($pagi_app, path => '/html');

    is($result->{status}, 200, 'status 200');
    is($result->{headers}{'content-type'}, 'text/html; charset=utf-8', 'html content type');
    like($result->{body}, qr/<h1>Hello, World!<\/h1>/, 'html has h1');
    like($result->{body}, qr/PAGI::Simple/, 'html mentions PAGI::Simple');
};

# Test 6: Search with query parameter
subtest 'search with query' => sub {
    my $result = simulate_http($pagi_app, path => '/search', query => 'q=test+query');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"query"\s*:\s*"test query"/, 'query param decoded');
    like($result->{body}, qr/"results"/, 'has results');
};

# Test 7: Search without query parameter
subtest 'search without query' => sub {
    my $result = simulate_http($pagi_app, path => '/search');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"query"\s*:\s*""/, 'empty query');
};

# Test 8: Created endpoint with custom status and header
subtest 'created endpoint' => sub {
    my $result = simulate_http($pagi_app, path => '/created');

    is($result->{status}, 201, 'status 201');
    is($result->{headers}{'X-Custom-Header'}, 'Custom Value', 'custom header');
    like($result->{body}, qr/"status"\s*:\s*"created"/, 'created body');
};

# Test 9: Redirect
subtest 'redirect' => sub {
    my $result = simulate_http($pagi_app, path => '/old-path');

    is($result->{status}, 302, 'status 302');
    is($result->{headers}{'location'}, '/', 'redirects to /');
};

# Test 10: Custom 404 handler
subtest 'custom 404' => sub {
    my $result = simulate_http($pagi_app, path => '/nonexistent/path');

    is($result->{status}, 404, 'status 404');
    like($result->{body}, qr/"error"\s*:\s*"Not Found"/, 'custom 404 error');
    like($result->{body}, qr/"path"\s*:\s*"\/nonexistent\/path"/, 'path in error');
};

done_testing;
