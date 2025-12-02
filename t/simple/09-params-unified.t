use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Unified parameter access in PAGI::Simple

use PAGI::Simple;
use PAGI::Simple::Context;
use PAGI::Simple::Request;

# Helper to create a mock receive that returns body
sub mock_receive ($body = '') {
    my @events = (
        { type => 'http.request', body => $body, more => 0 },
    );
    return sub {
        my $event = shift @events // { type => 'http.disconnect' };
        return Future->done($event);
    };
}

# Helper to create a mock context
sub mock_context (%opts) {
    my @sent;
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $c = PAGI::Simple::Context->new(
        scope       => $opts{scope} // { type => 'http', method => 'GET', path => '/' },
        receive     => $opts{receive} // sub { Future->done({ type => 'http.disconnect' }) },
        send        => $send,
        path_params => $opts{path_params} // {},
    );

    return ($c, \@sent);
}

# Test 1: path_param() on Request
subtest 'Request path_param' => sub {
    my $req = PAGI::Simple::Request->new(
        {},      # scope
        undef,   # receive
        { id => '123', name => 'john' },  # path_params
    );

    is($req->path_param('id'), '123', 'path_param returns id');
    is($req->path_param('name'), 'john', 'path_param returns name');
    ok(!defined $req->path_param('missing'), 'path_param returns undef for missing');
};

# Test 2: path_params() on Request
subtest 'Request path_params' => sub {
    my $req = PAGI::Simple::Request->new(
        {},
        undef,
        { a => '1', b => '2' },
    );

    my $params = $req->path_params;
    is(ref $params, 'HASH', 'path_params returns hashref');
    is($params->{a}, '1', 'a = 1');
    is($params->{b}, '2', 'b = 2');
};

# Test 3: param() finds path param
subtest 'param() finds path param' => sub {
    my ($c, $sent) = mock_context(
        path_params => { id => '42' },
    );

    my $id = $c->param('id')->get;
    is($id, '42', 'param finds path param');
};

# Test 4: param() finds query param
subtest 'param() finds query param' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'GET',
            path => '/',
            query_string => 'page=5&limit=20',
        },
    );

    my $page = $c->param('page')->get;
    my $limit = $c->param('limit')->get;

    is($page, '5', 'param finds query param page');
    is($limit, '20', 'param finds query param limit');
};

# Test 5: param() finds body param
subtest 'param() finds body param' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'POST',
            path => '/',
            headers => [['content-type', 'application/x-www-form-urlencoded']],
        },
        receive => mock_receive('email=test%40example.com'),
    );

    my $email = $c->param('email')->get;
    is($email, 'test@example.com', 'param finds body param');
};

# Test 6: param() precedence: path > query
subtest 'param() precedence: path over query' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'GET',
            path => '/',
            query_string => 'id=from_query',
        },
        path_params => { id => 'from_path' },
    );

    my $id = $c->param('id')->get;
    is($id, 'from_path', 'path param takes precedence over query');
};

# Test 7: param() precedence: query > body
subtest 'param() precedence: query over body' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'POST',
            path => '/',
            query_string => 'field=from_query',
            headers => [['content-type', 'application/x-www-form-urlencoded']],
        },
        receive => mock_receive('field=from_body'),
    );

    my $field = $c->param('field')->get;
    is($field, 'from_query', 'query param takes precedence over body');
};

# Test 8: param() returns undef for missing
subtest 'param() returns undef for missing' => sub {
    my ($c, $sent) = mock_context();

    my $missing = $c->param('nonexistent')->get;
    ok(!defined $missing, 'param returns undef for missing param');
};

# Test 9: params() returns Hash::MultiValue
subtest 'params() returns Hash::MultiValue' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'GET',
            path => '/',
            query_string => 'q=search',
        },
        path_params => { id => '123' },
    );

    my $params = $c->params->get;
    is(ref $params, 'Hash::MultiValue', 'params returns Hash::MultiValue');
};

# Test 10: params() merges all sources
subtest 'params() merges all sources' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'POST',
            path => '/',
            query_string => 'q=search',
            headers => [['content-type', 'application/x-www-form-urlencoded']],
        },
        receive => mock_receive('email=test@example.com'),
        path_params => { id => '123' },
    );

    my $params = $c->params->get;

    # All three sources should be present
    ok(defined $params->get('id'), 'has path param');
    ok(defined $params->get('q'), 'has query param');
    ok(defined $params->get('email'), 'has body param');
};

# Test 11: Source-specific accessors
subtest 'source-specific accessors' => sub {
    my ($c, $sent) = mock_context(
        scope => {
            type => 'http',
            method => 'POST',
            path => '/',
            query_string => 'q=search',
            headers => [['content-type', 'application/x-www-form-urlencoded']],
        },
        receive => mock_receive('email=test@example.com'),
        path_params => { id => '123' },
    );

    # Each source can be accessed specifically
    is($c->req->path_param('id'), '123', 'path_param via req');
    is($c->req->query_param('q'), 'search', 'query_param via req');
    is($c->req->body_param('email')->get, 'test@example.com', 'body_param via req');
};

# Test 12: Integration with app
subtest 'integration with app' => sub {
    my $app = PAGI::Simple->new;
    my $captured;

    $app->post('/users/:id' => sub ($c) {
        # Use the async param
        $c->param('id')->then(sub ($id) {
            $captured = $id;
            $c->text("got $id");
        });
    });

    # Simulate request
    my @sent;
    my $scope = {
        type   => 'http',
        method => 'POST',
        path   => '/users/42',
    };
    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    my $send = sub ($e) { push @sent, $e; Future->done };

    $app->to_app->($scope, $receive, $send)->get;

    is($captured, '42', 'param works in handler');
};

done_testing;
