package PAGI::Simple::PubSub;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Scalar::Util qw(weaken refaddr);

=head1 NAME

PAGI::Simple::PubSub - In-memory pub/sub system for PAGI::Simple

=head1 SYNOPSIS

    use PAGI::Simple::PubSub;

    my $pubsub = PAGI::Simple::PubSub->instance;

    # Subscribe to a channel
    my $callback = sub ($message) {
        print "Got: $message\n";
    };
    $pubsub->subscribe('chat:general', $callback);

    # Publish to all subscribers
    $pubsub->publish('chat:general', { text => 'Hello!' });

    # Unsubscribe
    $pubsub->unsubscribe('chat:general', $callback);

    # Get subscriber count
    my $count = $pubsub->subscribers('chat:general');

=head1 DESCRIPTION

PAGI::Simple::PubSub provides a simple in-memory pub/sub system for
coordinating messages between WebSocket and SSE connections. It uses
a singleton pattern to ensure all connections share the same state.

This is an internal module primarily used by L<PAGI::Simple::WebSocket>
and L<PAGI::Simple::SSE> for room management and broadcasting.

=head1 METHODS

=cut

# Singleton instance
my $instance;

=head2 instance

    my $pubsub = PAGI::Simple::PubSub->instance;

Returns the singleton PubSub instance. Creates it if it doesn't exist.

=cut

sub instance ($class) {
    return $instance //= $class->new;
}

=head2 reset

    PAGI::Simple::PubSub->reset;

Resets the singleton instance. Primarily useful for testing.

=cut

sub reset ($class) {
    $instance = undef;
}

=head2 new

    my $pubsub = PAGI::Simple::PubSub->new;

Creates a new PubSub instance. Normally you should use C<instance()>
instead to get the shared singleton.

=cut

sub new ($class) {
    my $self = bless {
        channels => {},  # channel => { callback_id => callback }
    }, $class;
    return $self;
}

=head2 subscribe

    $pubsub->subscribe($channel, $callback);

Subscribe to a channel. The callback will be called with the message
whenever something is published to the channel.

The callback receives a single argument: the message (which can be
any scalar, hashref, or arrayref).

Returns the pubsub instance for chaining.

=cut

sub subscribe ($self, $channel, $callback) {
    $self->{channels}{$channel} //= {};

    # Use refaddr as key to allow same callback to subscribe to multiple channels
    my $id = refaddr($callback);
    $self->{channels}{$channel}{$id} = $callback;

    return $self;
}

=head2 unsubscribe

    $pubsub->unsubscribe($channel, $callback);

Unsubscribe from a channel. The callback must be the same reference
that was passed to subscribe().

Returns the pubsub instance for chaining.

=cut

sub unsubscribe ($self, $channel, $callback) {
    return $self unless exists $self->{channels}{$channel};

    my $id = refaddr($callback);
    delete $self->{channels}{$channel}{$id};

    # Clean up empty channels
    if (!keys %{$self->{channels}{$channel}}) {
        delete $self->{channels}{$channel};
    }

    return $self;
}

=head2 unsubscribe_all

    $pubsub->unsubscribe_all($callback);

Unsubscribe a callback from all channels. Useful for cleanup when
a connection is closed.

Returns the pubsub instance for chaining.

=cut

sub unsubscribe_all ($self, $callback) {
    my $id = refaddr($callback);

    for my $channel (keys %{$self->{channels}}) {
        delete $self->{channels}{$channel}{$id};

        # Clean up empty channels
        if (!keys %{$self->{channels}{$channel}}) {
            delete $self->{channels}{$channel};
        }
    }

    return $self;
}

=head2 publish

    $pubsub->publish($channel, $message);

Publish a message to all subscribers of a channel.

The message can be any Perl value (scalar, hashref, arrayref).
Each subscriber callback receives the message as its argument.

Returns the number of subscribers that received the message.

=cut

sub publish ($self, $channel, $message) {
    return 0 unless exists $self->{channels}{$channel};

    my $callbacks = $self->{channels}{$channel};
    my $count = 0;

    for my $id (keys %$callbacks) {
        my $callback = $callbacks->{$id};
        if ($callback) {
            eval { $callback->($message) };
            if ($@) {
                warn "Error in pubsub callback: $@";
            }
            $count++;
        }
    }

    return $count;
}

=head2 subscribers

    my $count = $pubsub->subscribers($channel);

Returns the number of subscribers to a channel.

=cut

sub subscribers ($self, $channel) {
    return 0 unless exists $self->{channels}{$channel};
    return scalar keys %{$self->{channels}{$channel}};
}

=head2 channels

    my @channels = $pubsub->channels;

Returns a list of all active channels (channels with at least one subscriber).

=cut

sub channels ($self) {
    return keys %{$self->{channels}};
}

=head2 has_channel

    if ($pubsub->has_channel($channel)) { ... }

Returns true if the channel has any subscribers.

=cut

sub has_channel ($self, $channel) {
    return exists $self->{channels}{$channel}
        && keys %{$self->{channels}{$channel}} > 0;
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::WebSocket>, L<PAGI::Simple::SSE>

=head1 AUTHOR

PAGI Contributors

=cut

1;
