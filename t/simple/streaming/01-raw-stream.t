use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

use PAGI::Simple::Request;
use PAGI::Simple::Context;

# Helper to create a mock receive that yields chunks
sub mock_receive (@chunks) {
    my @events = map { { type => 'http.request', body => $_, more => 1 } } @chunks;
    if (@events) {
        $events[-1]{more} = 0;
    }
    else {
        push @events, { type => 'http.request', body => '', more => 0 };
    }
    return sub {
        my $event = shift @events // { type => 'http.disconnect' };
        return Future->done($event);
    };
}

subtest 'stream reads chunks and tracks bytes' => sub {
    my $receive = mock_receive('ab', 'cd', 'ef');
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream;

    my @chunks;
    push @chunks, $stream->next_chunk->get while !$stream->is_done;

    is(\@chunks, ['ab', 'cd', 'ef'], 'chunks read in order');
    is($stream->bytes_read, 6, 'byte count matches total');
    ok($stream->is_done, 'stream marks done');
};

subtest 'max_bytes enforced' => sub {
    my $receive = mock_receive('abc', 'def');
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream(max_bytes => 4);

    my $error;
    eval { $stream->next_chunk->get; $stream->next_chunk->get; 1 } or $error = $@;
    like($error, qr/max_bytes/, 'croaks when max_bytes exceeded');
};

subtest 'mutual exclusion with buffered body' => sub {
    my $receive = mock_receive('data');
    my $req = PAGI::Simple::Request->new({}, $receive);

    my $body = $req->body->get;
    is($body, 'data', 'body buffered');

    my $err;
    eval { $req->body_stream }; $err = $@;
    like($err, qr/Body already/, 'body_stream croaks after buffering');
};

subtest 'context shortcut returns same stream' => sub {
    my $receive = mock_receive('xy');
    my $context = PAGI::Simple::Context->new(
        scope       => { type => 'http', method => 'POST', path => '/' },
        receive     => $receive,
        send        => sub { Future->done },
        path_params => {},
    );

    my $s1 = $context->body_stream;
    is(ref $s1, 'PAGI::Simple::BodyStream', 'got BodyStream');
    my $err;
    eval { $context->req->body_stream }; $err = $@;
    like($err, qr/Body (already consumed|streaming already started)/, 'second stream request croaks');
};

subtest 'http.disconnect ends stream' => sub {
    my @events = (
        { type => 'http.request', body => 'hi', more => 1 },
        { type => 'http.disconnect' },
    );
    my $receive = sub { Future->done(shift @events // { type => 'http.disconnect' }) };
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream;

    my @chunks;
    while (!$stream->is_done) {
        my $chunk = $stream->next_chunk->get;
        push @chunks, $chunk if defined $chunk && length $chunk;
    }
    is($stream->bytes_read, 2, 'counted bytes before disconnect');
};

subtest 'body_params then body_stream croaks' => sub {
    my $receive = mock_receive('a=b');
    my $req = PAGI::Simple::Request->new({}, $receive);
    $req->body_params->get;
    my $err;
    eval { $req->body_stream }; $err = $@;
    like($err, qr/Body already consumed/, 'cannot stream after params parsed');
};

subtest 'json_body then body_stream croaks' => sub {
    my $receive = mock_receive('{"ok":1}');
    my $req = PAGI::Simple::Request->new({}, $receive);
    $req->json_body->get;
    my $err;
    eval { $req->body_stream }; $err = $@;
    like($err, qr/Body already consumed/, 'cannot stream after json_body');
};

ok(1, 'finished streaming raw tests');

done_testing;
