package PAGI::Simple::BodyStream;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Util::AsyncFile;
use Encode qw(decode find_encoding FB_CROAK FB_DEFAULT);

=head1 NAME

PAGI::Simple::BodyStream - Streaming helper for PAGI::Simple request bodies

=head1 SYNOPSIS

    my $stream = $c->body_stream(decode => 'UTF-8', max_bytes => 1024);

    while (!$stream->is_done) {
        my $chunk = await $stream->next_chunk;
        ...
    }

    my $bytes = await $stream->stream_to_file('/tmp/upload.bin');

=head1 DESCRIPTION

Internal streaming helper returned by C<< $c->body_stream >> / C<< $req->body_stream >>.
Supports chunk iteration (raw or decoded), optional byte limits, and piping
to files or handles with backpressure-friendly behavior.

=head1 METHODS

=over 4

=item * C<next_chunk> - await the next chunk (decoded if a C<decode> was requested)

=item * C<stream_to_file($path, %opts)> - pipe bytes to disk using async file I/O (respects limits)

=item * C<stream_to($sink, %opts)> - pipe bytes to a filehandle, code ref, or IO::Async::Stream

=item * C<bytes_read>, C<is_done>, C<error>, C<last_raw_chunk> - inspection helpers

=back

=cut

sub new ($class, %args) {
    my $self = bless {
        receive   => $args{receive},
        max_bytes => $args{max_bytes},
        loop      => $args{loop},
        bytes     => 0,
        done      => 0,
        error     => undef,
        decode    => undef,
        decode_name => undef,
        decode_is_utf8 => 0,
        decode_strict => 0,
        limit_name => $args{limit_name} || ($args{max_bytes} ? 'max_bytes' : undef),
        _decode_buffer => '',
        _last_event_raw => undef,
        _last_decoded_raw => undef,
    }, $class;
    croak 'receive is required' unless $self->{receive};

    if ($args{decode}) {
        my $enc = find_encoding($args{decode});
        croak "Unknown decode encoding: $args{decode}" unless $enc;
        $self->{decode} = $args{decode};
        $self->{decode_name} = $enc->name;
        $self->{decode_is_utf8} = $enc->name =~ /^utf-?8/i ? 1 : 0;
        $self->{decode_strict} = $args{strict} ? 1 : 0;
    }

    return $self;
}

async sub _pull_raw_chunk ($self) {
    return undef if $self->{done} || $self->{error};

    my $event = await $self->{receive}->();
    my $type  = $event->{type} // '';

    if ($type eq 'http.request') {
        my $chunk = $event->{body} // '';
        $self->{bytes} += length($chunk);
        if (defined $self->{max_bytes} && $self->{bytes} > $self->{max_bytes}) {
            my $label = $self->{limit_name} || 'max_bytes';
            $self->{error} = "$label exceeded";
            croak $self->{error};
        }
        $self->{done} = $event->{more} ? 0 : 1;
        $self->{_last_event_raw} = $chunk;
        return $chunk;
    }
    elsif ($type eq 'http.disconnect') {
        $self->{done} = 1;
        $self->{_last_event_raw} = undef;
        return undef;
    }
    else {
        $self->{done} = 1;
        $self->{_last_event_raw} = undef;
        return undef;
    }
}

async sub next_chunk ($self) {
    while (1) {
        return undef if $self->{done} && !length($self->{_decode_buffer} // '');

        my $raw = await $self->_pull_raw_chunk;
        my $data = ($self->{_decode_buffer} // '') . ($raw // '');
        $self->{_last_decoded_raw} = $data;

        my ($decoded, $leftover) = $self->_decode_bytes($data, $self->{done});
        $self->{_decode_buffer} = $leftover // '';

        return $decoded if defined $decoded;
        return '' if $self->{done};    # nothing else to decode
    }
}

sub bytes_read ($self) { return $self->{bytes} }
sub is_done ($self)   { return $self->{done} }
sub error ($self)     { return $self->{error} }
sub last_raw_chunk ($self) { return $self->{_last_decoded_raw} // $self->{_last_event_raw} }

sub _utf8_cut_point ($self, $bytes) {
    my $len = length $bytes;
    return $len if $len == 0;

    my $max_check = $len < 4 ? $len : 4;
    for my $i (0 .. $max_check - 1) {
        my $byte = ord(substr($bytes, $len - 1 - $i, 1));

        # Continuation byte, keep looking left
        next if ($byte & 0xC0) == 0x80;

        # ASCII byte - no partial sequence at end
        return $len if $byte < 0x80;

        my $expected = ($byte & 0xE0) == 0xC0 ? 2
                      : ($byte & 0xF0) == 0xE0 ? 3
                      : ($byte & 0xF8) == 0xF0 ? 4
                      : 1;
        my $have = $i + 1;
        return $expected > $have ? $len - ($expected - $have) : $len;
    }

    return $len;
}

sub _decode_bytes ($self, $data, $is_final) {
    my $encoding = $self->{decode_name} // $self->{decode} // return ($data, '');

    return (undef, '') unless length $data;

    # When not final, keep a potential partial UTF-8 sequence buffered
    if (!$is_final && $self->{decode_is_utf8}) {
        my $cut_at = $self->_utf8_cut_point($data);
        my $leftover = substr($data, $cut_at);
        my $to_decode = substr($data, 0, $cut_at);
        return (undef, $leftover) unless length $to_decode;

        my $decoded = eval { decode($encoding, $to_decode, $self->{decode_strict} ? FB_CROAK : FB_DEFAULT) };
        if (!$decoded) {
            my $err = $@ || 'decode failed';
            $self->{error} = $err;
            croak $err;
        }

        return ($decoded, $leftover);
    }

    my $decoded = eval { decode($encoding, $data, $self->{decode_strict} ? FB_CROAK : FB_DEFAULT) };
    if (!$decoded) {
        my $err = $@ || 'decode failed';
        $self->{error} = $err;
        croak $err;
    }

    return ($decoded, '');
}

async sub stream_to_file ($self, $path, %opts) {
    my $loop = $opts{loop} // $self->{loop};
    croak 'loop is required for stream_to_file' unless $loop;

    my $mode = $opts{mode} // 'truncate'; # truncate by default
    my $bytes_written = 0;

    if ($mode eq 'truncate') {
        await PAGI::Util::AsyncFile->write_file($loop, $path, '');
    }

    while (!$self->is_done) {
        my $chunk = await $self->_pull_raw_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        $bytes_written += await PAGI::Util::AsyncFile->append_file($loop, $path, $chunk);
    }

    return $bytes_written;
}

async sub stream_to ($self, $sink, %opts) {
    croak 'sink is required' unless $sink;

    my $bytes_written = 0;
    my $binmode = $opts{binmode};
    binmode($sink, $binmode) if defined $binmode && !blessed($sink) && ref($sink) ne 'CODE';

    while (!$self->is_done) {
        my $chunk = await $self->_pull_raw_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        if (ref($sink) eq 'CODE') {
            my $res = $sink->($chunk);
            $res = $res->get if blessed($res) && $res->can('get');
            $bytes_written += length($chunk);
        }
        elsif (blessed($sink) && $sink->can('write')) {
            await $sink->write($chunk);
            $bytes_written += length($chunk);
        }
        else {
            my $fd = fileno($sink);
            if (defined $fd && $fd >= 0) {
                my $written = syswrite($sink, $chunk);
                croak "Failed to write to sink: $!" unless defined $written;
                $bytes_written += $written;
            }
            else {
                my $ok = print {$sink} $chunk;
                croak "Failed to write to sink: $!" unless $ok;
                $bytes_written += length($chunk);
            }
        }
    }

    return $bytes_written;
}

1;
