use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Response building in PAGI::Simple::Context

# Test 1: Response module loads
subtest 'Response module loads' => sub {
    my $loaded = eval { require PAGI::Simple::Response; 1 };
    ok($loaded, 'PAGI::Simple::Response loads') or diag $@;
};

use PAGI::Simple::Response;
use PAGI::Simple::Context;

# Test 2: JSON encode/decode
subtest 'JSON encoding' => sub {
    my $data = { name => 'John', age => 30, active => \1 };
    my $json = PAGI::Simple::Response->json_encode($data);

    ok($json, 'json_encode returns string');
    like($json, qr/"name"/, 'JSON contains name');
    like($json, qr/"age"/, 'JSON contains age');

    my $decoded = PAGI::Simple::Response->json_decode($json);
    is($decoded->{name}, 'John', 'decoded name');
    is($decoded->{age}, 30, 'decoded age');
};

# Test 3: Status text
subtest 'status text' => sub {
    is(PAGI::Simple::Response->status_text(200), 'OK', '200 OK');
    is(PAGI::Simple::Response->status_text(201), 'Created', '201 Created');
    is(PAGI::Simple::Response->status_text(404), 'Not Found', '404 Not Found');
    is(PAGI::Simple::Response->status_text(500), 'Internal Server Error', '500 ISE');
    is(PAGI::Simple::Response->status_text(999), 'Unknown', '999 Unknown');
};

# Helper to create a mock context that captures send calls
sub mock_context (%args) {
    my @sent;
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;  # Return completed future
    };

    my $c = PAGI::Simple::Context->new(
        scope   => $args{scope} // { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({ type => 'http.request' }) },
        send    => $send,
    );

    return ($c, \@sent);
}

# Test 4: status() builder
subtest 'status builder' => sub {
    my ($c, $sent) = mock_context();

    my $result = $c->status(201);
    is($result, $c, 'status() returns $c for chaining');
    is($c->{_status}, 201, 'status is set');
};

# Test 5: res_header() builder
subtest 'res_header builder' => sub {
    my ($c, $sent) = mock_context();

    my $result = $c->res_header('X-Custom', 'value1');
    is($result, $c, 'res_header() returns $c for chaining');

    $c->res_header('X-Custom', 'value2');
    $c->res_header('X-Another', 'test');

    is(scalar @{$c->{_headers}}, 3, 'three headers added');
    is($c->{_headers}[0][0], 'X-Custom', 'first header name');
    is($c->{_headers}[0][1], 'value1', 'first header value');
};

# Test 6: content_type() builder
subtest 'content_type builder' => sub {
    my ($c, $sent) = mock_context();

    my $result = $c->content_type('application/xml');
    is($result, $c, 'content_type() returns $c for chaining');

    is(scalar @{$c->{_headers}}, 1, 'one header added');
    is($c->{_headers}[0][0], 'content-type', 'header is content-type');
    is($c->{_headers}[0][1], 'application/xml', 'correct content-type');
};

# Test 7: Method chaining
subtest 'method chaining' => sub {
    my ($c, $sent) = mock_context();

    $c->status(201)
      ->res_header('X-Custom', 'value')
      ->content_type('text/html');

    is($c->{_status}, 201, 'status set via chain');
    is(scalar @{$c->{_headers}}, 2, 'two headers from chain');
};

# Test 8: text() sends response
subtest 'text() terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->text("Hello, World!")->get;

    is(scalar @$sent, 2, 'two events sent');

    # Check response.start
    is($sent->[0]{type}, 'http.response.start', 'first event is response.start');
    is($sent->[0]{status}, 200, 'default status 200');

    # Check content-type header
    my @ct = grep { $_->[0] eq 'content-type' } @{$sent->[0]{headers}};
    is(scalar @ct, 1, 'has content-type header');
    like($ct[0][1], qr{text/plain}, 'content-type is text/plain');

    # Check body
    is($sent->[1]{type}, 'http.response.body', 'second event is response.body');
    is($sent->[1]{body}, 'Hello, World!', 'body content');
    is($sent->[1]{more}, 0, 'no more body');
};

# Test 9: text() with status
subtest 'text() with status' => sub {
    my ($c, $sent) = mock_context();

    $c->text("Created!", 201)->get;

    is($sent->[0]{status}, 201, 'status 201');
};

# Test 10: html() sends response
subtest 'html() terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->html("<h1>Hello</h1>")->get;

    my @ct = grep { $_->[0] eq 'content-type' } @{$sent->[0]{headers}};
    like($ct[0][1], qr{text/html}, 'content-type is text/html');
    is($sent->[1]{body}, '<h1>Hello</h1>', 'body is HTML');
};

# Test 11: json() sends response
subtest 'json() terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->json({ message => 'Hello', count => 42 })->get;

    my @ct = grep { $_->[0] eq 'content-type' } @{$sent->[0]{headers}};
    like($ct[0][1], qr{application/json}, 'content-type is application/json');

    my $body = $sent->[1]{body};
    ok($body, 'has body');
    like($body, qr/"message"/, 'JSON contains message');
    like($body, qr/"count"/, 'JSON contains count');
};

# Test 12: json() with status
subtest 'json() with status' => sub {
    my ($c, $sent) = mock_context();

    $c->json({ id => 1 }, 201)->get;

    is($sent->[0]{status}, 201, 'status 201 for created');
};

# Test 13: redirect() sends response
subtest 'redirect() terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->redirect('/other-page')->get;

    is($sent->[0]{status}, 302, 'default redirect status 302');

    my @loc = grep { $_->[0] eq 'location' } @{$sent->[0]{headers}};
    is(scalar @loc, 1, 'has location header');
    is($loc[0][1], '/other-page', 'location is /other-page');

    is($sent->[1]{body}, '', 'redirect body is empty');
};

# Test 14: redirect() with custom status
subtest 'redirect() with custom status' => sub {
    my ($c, $sent) = mock_context();

    $c->redirect('/permanent', 301)->get;

    is($sent->[0]{status}, 301, 'status 301 for permanent redirect');
};

# Test 15: status() + terminal method
subtest 'status() with terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->status(201)->json({ created => 1 })->get;

    is($sent->[0]{status}, 201, 'status from builder');
};

# Test 16: res_header() + terminal method
subtest 'res_header() with terminal' => sub {
    my ($c, $sent) = mock_context();

    $c->res_header('X-Request-Id', 'abc123')
      ->res_header('X-Version', '1.0')
      ->text('OK')->get;

    my @custom = grep { $_->[0] =~ /^X-/ } @{$sent->[0]{headers}};
    is(scalar @custom, 2, 'two custom headers');
};

# Test 17: response_started flag
subtest 'response_started flag' => sub {
    my ($c, $sent) = mock_context();

    ok(!$c->response_started, 'not started initially');

    $c->text('Hello')->get;

    ok($c->response_started, 'started after send');
};

# Test 18: Cannot send twice
subtest 'cannot send twice' => sub {
    my ($c, $sent) = mock_context();

    $c->text('First')->get;

    my $error;
    eval { $c->text('Second')->get };
    $error = $@;

    like($error, qr/Response already started/, 'error on double send');
};

done_testing;
