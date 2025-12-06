use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use charnames ':full';

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

subtest 'decodes utf8 across chunk boundaries' => sub {
    my $receive = mock_receive('h', "\xC3", "\xA9llo");
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream(decode => 'UTF-8');

    my @out;
    while (!$stream->is_done) {
        my $chunk = $stream->next_chunk->get;
        push @out, $chunk if defined $chunk && length $chunk;
    }

    my $expected = "h\N{LATIN SMALL LETTER E WITH ACUTE}llo";
    is(join('', @out), $expected, 'chunked utf8 decoded correctly');
};

subtest 'default decoding replaces invalid bytes' => sub {
    my $receive = mock_receive("ok\xFF", 'done');
    my $stream = PAGI::Simple::Request->new({}, $receive)->body_stream(decode => 'UTF-8');

    my @out;
    while (!$stream->is_done) {
        my $chunk = $stream->next_chunk->get;
        push @out, $chunk if defined $chunk;
    }

    is(join('', @out), "ok\N{REPLACEMENT CHARACTER}done", 'replacement character used for invalid byte');
};

subtest 'strict decoding croaks on invalid utf8' => sub {
    my $stream = PAGI::Simple::Request->new({}, mock_receive("bad\xFF"))->body_stream(
        decode => 'UTF-8',
        strict => 1,
    );

    my $err;
    eval { $stream->next_chunk->get; 1 } or $err = $@;
    like($err, qr/utf-?8/i, 'strict mode croaks on invalid sequence');
};

subtest 'strict decoding croaks on truncated ending' => sub {
    my @events = ({ type => 'http.request', body => "caf\xC3", more => 0 });
    my $receive = sub { Future->done(shift @events // { type => 'http.disconnect' }) };
    my $stream = PAGI::Simple::Request->new({}, $receive)->body_stream(
        decode => 'UTF-8',
        strict => 1,
    );

    my $err;
    eval { $stream->next_chunk->get; 1 } or $err = $@;
    like($err, qr/utf-?8/i, 'strict mode detects truncated sequence');
};

subtest 'last_raw_chunk preserves bytes when decoding' => sub {
    my $receive = mock_receive("\xC3", "\xA9llo");
    my $stream = PAGI::Simple::Request->new({}, $receive)->body_stream(decode => 'UTF-8');

    my $decoded = $stream->next_chunk->get;
    is($decoded, "\N{LATIN SMALL LETTER E WITH ACUTE}llo", 'decoded value returned');
    is($stream->last_raw_chunk, "\xC3\xA9llo", 'raw bytes that produced the decoded chunk');
};

ok(1, 'finished streaming decode tests');

done_testing;
