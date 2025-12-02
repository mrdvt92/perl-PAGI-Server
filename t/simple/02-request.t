use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: PAGI::Simple::Request class

# Test 1: Module loads
subtest 'module loads' => sub {
    my $loaded = eval { require PAGI::Simple::Request; 1 };
    ok($loaded, 'PAGI::Simple::Request loads') or diag $@;
    ok(PAGI::Simple::Request->can('new'), 'has new() method');
};

use PAGI::Simple::Request;

# Test 2: Constructor
subtest 'constructor' => sub {
    my $scope = {
        type   => 'http',
        method => 'GET',
        path   => '/test',
    };

    my $req = PAGI::Simple::Request->new($scope);

    ok(defined $req, 'new() returns defined value');
    isa_ok($req, 'PAGI::Simple::Request');
};

# Test 3: method accessor
subtest 'method accessor' => sub {
    my $req = PAGI::Simple::Request->new({ method => 'POST' });
    is($req->method, 'POST', 'method returns POST');

    my $req2 = PAGI::Simple::Request->new({ method => 'DELETE' });
    is($req2->method, 'DELETE', 'method returns DELETE');

    # Missing method defaults to empty string
    my $req3 = PAGI::Simple::Request->new({});
    is($req3->method, '', 'missing method returns empty string');
};

# Test 4: path accessor
subtest 'path accessor' => sub {
    my $req = PAGI::Simple::Request->new({ path => '/users/123' });
    is($req->path, '/users/123', 'path returns correct value');

    # Missing path defaults to /
    my $req2 = PAGI::Simple::Request->new({});
    is($req2->path, '/', 'missing path returns /');
};

# Test 5: query_string accessor
subtest 'query_string accessor' => sub {
    my $req = PAGI::Simple::Request->new({ query_string => 'foo=bar&baz=qux' });
    is($req->query_string, 'foo=bar&baz=qux', 'query_string returns correct value');

    # Missing query_string defaults to empty string
    my $req2 = PAGI::Simple::Request->new({});
    is($req2->query_string, '', 'missing query_string returns empty string');
};

# Test 6: headers returns Hash::MultiValue
subtest 'headers Hash::MultiValue' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [
            ['Content-Type', 'application/json'],
            ['Accept', 'text/html'],
            ['Accept', 'application/json'],
        ],
    });

    my $headers = $req->headers;
    isa_ok($headers, 'Hash::MultiValue');

    # Single value access (lowercase)
    is($headers->get('content-type'), 'application/json', 'single header via get()');

    # Multi-value access
    my @accepts = $headers->get_all('accept');
    is(scalar @accepts, 2, 'multi-value header has 2 values');
    is($accepts[0], 'text/html', 'first Accept value');
    is($accepts[1], 'application/json', 'second Accept value');
};

# Test 7: header() method for single value
subtest 'header() method' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [
            ['X-Custom-Header', 'custom-value'],
            ['Content-Type', 'text/plain'],
        ],
    });

    is($req->header('X-Custom-Header'), 'custom-value', 'header() with mixed case');
    is($req->header('x-custom-header'), 'custom-value', 'header() with lowercase');
    is($req->header('X-CUSTOM-HEADER'), 'custom-value', 'header() with uppercase');
    is($req->header('Content-Type'), 'text/plain', 'Content-Type header');

    # Non-existent header
    ok(!defined $req->header('X-Not-Exists'), 'non-existent header returns undef');
};

# Test 8: content_type convenience method
subtest 'content_type' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [['Content-Type', 'application/json; charset=utf-8']],
    });

    is($req->content_type, 'application/json; charset=utf-8', 'content_type returns full value');

    # Missing content-type
    my $req2 = PAGI::Simple::Request->new({ headers => [] });
    is($req2->content_type, '', 'missing content_type returns empty string');
};

# Test 9: content_length convenience method
subtest 'content_length' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [['Content-Length', '1234']],
    });

    is($req->content_length, 1234, 'content_length returns number');
    ok($req->content_length == 1234, 'content_length is numeric');

    # Missing content-length
    my $req2 = PAGI::Simple::Request->new({ headers => [] });
    ok(!defined $req2->content_length, 'missing content_length returns undef');
};

# Test 10: host convenience method
subtest 'host' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [['Host', 'example.com:8080']],
    });

    is($req->host, 'example.com:8080', 'host returns correct value');
};

# Test 11: user_agent convenience method
subtest 'user_agent' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [['User-Agent', 'Mozilla/5.0']],
    });

    is($req->user_agent, 'Mozilla/5.0', 'user_agent returns correct value');
};

# Test 12: scheme and is_secure
subtest 'scheme and is_secure' => sub {
    my $http_req = PAGI::Simple::Request->new({ scheme => 'http' });
    is($http_req->scheme, 'http', 'scheme returns http');
    ok(!$http_req->is_secure, 'http is not secure');

    my $https_req = PAGI::Simple::Request->new({ scheme => 'https' });
    is($https_req->scheme, 'https', 'scheme returns https');
    ok($https_req->is_secure, 'https is secure');

    # Default scheme
    my $default_req = PAGI::Simple::Request->new({});
    is($default_req->scheme, 'http', 'default scheme is http');
};

# Test 13: server_name and server_port
subtest 'server info' => sub {
    my $req = PAGI::Simple::Request->new({
        server => ['127.0.0.1', 8080],
    });

    is($req->server_name, '127.0.0.1', 'server_name correct');
    is($req->server_port, 8080, 'server_port correct');

    # Missing server info
    my $req2 = PAGI::Simple::Request->new({});
    is($req2->server_name, '', 'missing server_name returns empty');
    is($req2->server_port, 80, 'missing server_port returns 80');
};

# Test 14: client_ip and client_port
subtest 'client info' => sub {
    my $req = PAGI::Simple::Request->new({
        client => ['192.168.1.100', 54321],
    });

    is($req->client_ip, '192.168.1.100', 'client_ip correct');
    is($req->client_port, 54321, 'client_port correct');

    # Missing client info
    my $req2 = PAGI::Simple::Request->new({});
    is($req2->client_ip, '', 'missing client_ip returns empty');
    is($req2->client_port, 0, 'missing client_port returns 0');
};

# Test 15: scope accessor
subtest 'scope accessor' => sub {
    my $scope = {
        type   => 'http',
        method => 'GET',
        path   => '/test',
        custom => 'value',
    };
    my $req = PAGI::Simple::Request->new($scope);

    is($req->scope, $scope, 'scope returns original hashref');
    is($req->scope->{custom}, 'value', 'can access custom scope values');
};

# Test 16: headers are lazily built and cached
subtest 'headers caching' => sub {
    my $req = PAGI::Simple::Request->new({
        headers => [['X-Test', 'value']],
    });

    my $headers1 = $req->headers;
    my $headers2 = $req->headers;

    is($headers1, $headers2, 'headers returns same object on multiple calls');
};

done_testing;
