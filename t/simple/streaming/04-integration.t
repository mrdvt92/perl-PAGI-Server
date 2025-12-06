use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

use PAGI::Simple::Request;

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

subtest 'buffered helpers are blocked once streaming starts' => sub {
    my $receive = mock_receive('abc');
    my $req = PAGI::Simple::Request->new({}, $receive);
    $req->body_stream;  # start streaming mode

    my $err;
    eval { $req->body->get; 1 } or $err = $@;
    like($err, qr/streaming already started/i, 'body() after streaming croaks');
};

subtest 'content-length enforced by default' => sub {
    my $scope = { headers => [ [ 'content-length' => 3 ] ] };
    my $receive = mock_receive('abcd');
    my $stream = PAGI::Simple::Request->new($scope, $receive)->body_stream;

    my $err;
    eval { $stream->next_chunk->get; 1 } or $err = $@;
    like($err, qr/content-length/i, 'content-length limit triggers error');
};

subtest 'content-length exact size passes' => sub {
    my $scope = { headers => [ [ 'content-length' => 4 ] ] };
    my $receive = mock_receive('ab', 'cd');
    my $stream = PAGI::Simple::Request->new($scope, $receive)->body_stream;

    my @chunks;
    push @chunks, $stream->next_chunk->get while !$stream->is_done;
    is(join('', @chunks), 'abcd', 'body read matches content-length');
    is($stream->bytes_read, 4, 'byte count tracked');
};

subtest 'explicit max_bytes overrides content-length' => sub {
    my $scope = { headers => [ [ 'content-length' => 10 ] ] };
    my $receive = mock_receive('abcd');
    my $stream = PAGI::Simple::Request->new($scope, $receive)->body_stream(max_bytes => 2);

    my $err;
    eval { $stream->next_chunk->get; 1 } or $err = $@;
    like($err, qr/max_bytes/i, 'explicit limit wins');
};

ok(1, 'finished streaming integration tests');

done_testing;
