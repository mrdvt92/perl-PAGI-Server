use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Request body parsing in PAGI::Simple

use PAGI::Simple::Request;

# Test 1: Body methods exist
subtest 'body methods exist' => sub {
    my $req = PAGI::Simple::Request->new({});
    ok($req->can('body'), 'has body method');
    ok($req->can('body_params'), 'has body_params method');
    ok($req->can('body_param'), 'has body_param method');
    ok($req->can('json_body'), 'has json_body method');
    ok($req->can('json_body_safe'), 'has json_body_safe method');
};

# Helper to create a mock receive that returns body chunks
sub mock_receive (@chunks) {
    my @events = map { { type => 'http.request', body => $_, more => 1 } } @chunks;
    push @events, { type => 'http.request', body => '', more => 0 };

    return sub {
        my $event = shift @events // { type => 'http.disconnect' };
        return Future->done($event);
    };
}

# Test 2: Empty body
subtest 'empty body' => sub {
    my $receive = mock_receive();
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $body = $req->body->get;
    is($body, '', 'empty body returns empty string');
};

# Test 3: Simple body
subtest 'simple body' => sub {
    my $receive = mock_receive('Hello, World!');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $body = $req->body->get;
    is($body, 'Hello, World!', 'simple body returned');
};

# Test 4: Chunked body
subtest 'chunked body' => sub {
    my $receive = mock_receive('Hello', ', ', 'World', '!');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $body = $req->body->get;
    is($body, 'Hello, World!', 'chunked body concatenated');
};

# Test 5: Body caching
subtest 'body caching' => sub {
    my $call_count = 0;
    my @events = (
        { type => 'http.request', body => 'data', more => 0 },
    );
    my $receive = sub {
        $call_count++;
        return Future->done(shift @events // { type => 'http.disconnect' });
    };

    my $req = PAGI::Simple::Request->new({}, $receive);

    my $body1 = $req->body->get;
    my $body2 = $req->body->get;

    is($body1, 'data', 'first call returns body');
    is($body2, 'data', 'second call returns cached body');
    is($call_count, 1, 'receive only called once');
};

# Test 6: No receive function
subtest 'no receive function' => sub {
    my $req = PAGI::Simple::Request->new({});

    my $body = $req->body->get;
    is($body, '', 'no receive returns empty body');
};

# Test 7: Form body parsing
subtest 'form body parsing' => sub {
    my $receive = mock_receive('name=John&email=john%40example.com&age=30');
    my $scope = {
        headers => [['content-type', 'application/x-www-form-urlencoded']],
    };
    my $req = PAGI::Simple::Request->new($scope, $receive);

    my $params = $req->body_params->get;

    is(ref $params, 'Hash::MultiValue', 'body_params returns Hash::MultiValue');
    is($params->get('name'), 'John', 'name param decoded');
    is($params->get('email'), 'john@example.com', 'email param URL decoded');
    is($params->get('age'), '30', 'age param');
};

# Test 8: body_param shortcut
subtest 'body_param shortcut' => sub {
    my $receive = mock_receive('foo=bar&baz=qux');
    my $scope = {
        headers => [['content-type', 'application/x-www-form-urlencoded']],
    };
    my $req = PAGI::Simple::Request->new($scope, $receive);

    my $foo = $req->body_param('foo')->get;
    my $baz = $req->body_param('baz')->get;
    my $missing = $req->body_param('missing')->get;

    is($foo, 'bar', 'body_param returns value');
    is($baz, 'qux', 'body_param returns another value');
    ok(!defined $missing, 'body_param returns undef for missing');
};

# Test 9: Multiple values in form
subtest 'multiple values in form' => sub {
    my $receive = mock_receive('tags=perl&tags=cpan&tags=async');
    my $scope = {
        headers => [['content-type', 'application/x-www-form-urlencoded']],
    };
    my $req = PAGI::Simple::Request->new($scope, $receive);

    my $params = $req->body_params->get;
    my @tags = $params->get_all('tags');

    is(scalar @tags, 3, 'three values for tags');
    is($tags[0], 'perl', 'first tag');
    is($tags[1], 'cpan', 'second tag');
    is($tags[2], 'async', 'third tag');
};

# Test 10: Non-form content-type
subtest 'non-form content-type' => sub {
    my $receive = mock_receive('not=form&data');
    my $scope = {
        headers => [['content-type', 'text/plain']],
    };
    my $req = PAGI::Simple::Request->new($scope, $receive);

    my $params = $req->body_params->get;

    is(ref $params, 'Hash::MultiValue', 'returns Hash::MultiValue');
    is(scalar $params->keys, 0, 'no params for non-form content');
};

# Test 11: JSON body parsing
subtest 'JSON body parsing' => sub {
    my $receive = mock_receive('{"name":"John","age":30,"active":true}');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $data = $req->json_body->get;

    is(ref $data, 'HASH', 'json_body returns hashref');
    is($data->{name}, 'John', 'name field');
    is($data->{age}, 30, 'age field');
    ok($data->{active}, 'active field is true');
};

# Test 12: JSON array
subtest 'JSON array' => sub {
    my $receive = mock_receive('[1,2,3,"four"]');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $data = $req->json_body->get;

    is(ref $data, 'ARRAY', 'json_body returns arrayref');
    is(scalar @$data, 4, 'four elements');
    is($data->[3], 'four', 'fourth element');
};

# Test 13: Invalid JSON dies
subtest 'invalid JSON dies' => sub {
    my $receive = mock_receive('not valid json');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $died = 0;
    eval { $req->json_body->get };
    $died = 1 if $@;

    ok($died, 'json_body dies on invalid JSON');
};

# Test 14: json_body_safe returns undef on error
subtest 'json_body_safe on invalid JSON' => sub {
    my $receive = mock_receive('not valid json');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $data = $req->json_body_safe->get;

    ok(!defined $data, 'json_body_safe returns undef on invalid JSON');
};

# Test 15: json_body_safe on valid JSON
subtest 'json_body_safe on valid JSON' => sub {
    my $receive = mock_receive('{"ok":true}');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $data = $req->json_body_safe->get;

    is($data->{ok}, 1, 'json_body_safe returns data on valid JSON');
};

done_testing;
