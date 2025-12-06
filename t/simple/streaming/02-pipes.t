use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempfile tempdir);

use PAGI::Simple::Request;

my $loop = IO::Async::Loop->new;

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

sub counted_receive (@chunks) {
    my $count = 0;
    my @events = map { { type => 'http.request', body => $_, more => 1 } } @chunks;
    $events[-1]{more} = 0 if @events;
    my $cb = sub {
        $count++;
        my $event = shift @events // { type => 'http.disconnect' };
        return Future->done($event);
    };
    return ($cb, \$count);
}

sub slurp ($path) {
    open my $fh, '<:raw', $path or die "Cannot read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

subtest 'stream_to_file truncates then writes in order' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "old data";
    close $fh;

    my $receive = mock_receive('ab', 'cd');
    my $req = PAGI::Simple::Request->new({ pagi => { loop => $loop } }, $receive);
    my $stream = $req->body_stream;

    my $written = $stream->stream_to_file($filename)->get;

    is($written, 4, 'byte count returned');
    is(slurp($filename), 'abcd', 'file content replaced with streamed data');
};

subtest 'stream_to_file append mode preserves existing content' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "start-";
    close $fh;

    my $receive = mock_receive('x', 'y');
    my $req = PAGI::Simple::Request->new({ pagi => { loop => $loop } }, $receive);

    my $written = $req->body_stream->stream_to_file($filename, mode => 'append')->get;

    is($written, 2, 'byte count for append');
    is(slurp($filename), 'start-xy', 'append mode keeps prior content');
};

subtest 'max_bytes stops piping and leaves empty truncated file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "stale";
    close $fh;

    my $receive = mock_receive('toolong');
    my $req = PAGI::Simple::Request->new({ pagi => { loop => $loop } }, $receive);
    my $stream = $req->body_stream(max_bytes => 2);

    my $err;
    eval { $stream->stream_to_file($filename)->get; 1 } or $err = $@;
    like($err, qr/max_bytes/, 'croaks on limit exceeded');
    is(slurp($filename), '', 'file truncated even when limit trips');
};

subtest 'stream_to supports filehandles and code refs' => sub {
    my $receive = mock_receive('12', '34');
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream;

    my $buffer = '';
    open my $fh, '>', \$buffer or die "Cannot open scalar handle: $!";
    my $written = $stream->stream_to($fh)->get;
    is($written, 4, 'bytes written to handle');
    is($buffer, '1234', 'content written');

    my @chunks;
    my $receive2 = mock_receive('a', 'b');
    my $stream2 = PAGI::Simple::Request->new({}, $receive2)->body_stream;
    my $written2 = $stream2->stream_to(sub ($chunk) { push @chunks, $chunk; Future->done })->get;
    is($written2, 2, 'bytes counted for code sink');
    is(\@chunks, ['a', 'b'], 'code sink saw chunks');
};

subtest 'backpressure: only one receive per chunk' => sub {
    my ($receive, $count_ref) = counted_receive('x', 'y');
    my $req = PAGI::Simple::Request->new({}, $receive);
    my $stream = $req->body_stream;

    my $buf = '';
    open my $fh, '>', \$buf or die "Cannot open scalar handle: $!";
    $stream->stream_to($fh)->get;

    is($$count_ref, 2, 'receive invoked per chunk without prefetch');
    is($buf, 'xy', 'data streamed');
};

ok(1, 'finished streaming pipe tests');

done_testing;
