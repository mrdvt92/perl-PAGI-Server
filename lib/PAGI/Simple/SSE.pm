package PAGI::Simple::SSE;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use JSON::MaybeXS qw(encode_json);
use PAGI::Simple::PubSub;

=head1 NAME

PAGI::Simple::SSE - Server-Sent Events context for PAGI::Simple

=head1 SYNOPSIS

    $app->sse('/events' => sub ($sse) {
        $sse->send_event(
            data  => { message => "Hello" },
            event => 'greeting',
            id    => 1,
        );

        $sse->on(close => sub {
            # Client disconnected
        });
    });

=head1 DESCRIPTION

PAGI::Simple::SSE provides a context object for handling Server-Sent Events
connections. It wraps the low-level PAGI SSE protocol with a convenient API.

=head1 METHODS

=cut

=head2 new

    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => $scope,
        receive     => $receive,
        send        => $send,
        path_params => \%params,
    );

Create a new SSE context.

=cut

sub new ($class, %args) {
    my $self = bless {
        app         => $args{app},
        scope       => $args{scope},
        receive     => $args{receive},
        send        => $args{send},
        path_params => $args{path_params} // {},
        stash       => {},
        _handlers   => {
            close   => [],
            error   => [],
        },
        _started    => 0,
        _closed     => 0,
        _channels   => {},  # channel => 1 for tracking subscribed channels
        _pubsub_cb  => undef,  # Callback for receiving broadcast messages
    }, $class;

    # Create the pubsub callback for this connection
    $self->{_pubsub_cb} = sub ($message) {
        # Send the message as an SSE event to this client
        $self->send_event(data => $message) unless $self->{_closed};
    };

    return $self;
}

=head2 app

    my $app = $sse->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 scope

    my $scope = $sse->scope;

Returns the raw PAGI scope hashref.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 stash

    my $stash = $sse->stash;
    $sse->stash->{user} = $user;

Per-connection storage hashref.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 path_params

    my $params = $sse->path_params;

Returns the path parameters captured from the route.

=cut

sub path_params ($self) {
    return $self->{path_params};
}

=head2 param

    my $value = $sse->param('id');

Get a path parameter by name.

=cut

sub param ($self, $name) {
    return $self->{path_params}{$name};
}

=head2 on

    $sse->on(close => sub { ... });
    $sse->on(error => sub ($error) { ... });

Register event handlers. Multiple handlers can be registered for each event.

Events:
- C<close>: Called when the connection is closed
- C<error>: Called when an error occurs

=cut

sub on ($self, $event, $callback) {
    if (exists $self->{_handlers}{$event}) {
        push @{$self->{_handlers}{$event}}, $callback;
    }
    else {
        die "Unknown event type: $event (expected close or error)";
    }
    return $self;
}

=head2 send_event

    await $sse->send_event(
        data  => "Hello",           # Required
        event => 'message',         # Optional event type
        id    => '123',             # Optional event ID
        retry => 3000,              # Optional retry interval (ms)
    );

    # Data can be a hashref (will be JSON encoded)
    await $sse->send_event(
        data  => { user => 'alice', action => 'joined' },
        event => 'user',
    );

Send a Server-Sent Event to the client. Returns a Future.

=cut

async sub send_event ($self, %opts) {
    return if $self->{_closed};

    # Auto-start if not already started
    await $self->_start unless $self->{_started};

    # Convert data to string if it's a reference
    my $data = $opts{data} // '';
    if (ref $data) {
        $data = encode_json($data);
    }

    my %event = (
        type => 'sse.send',
        data => $data,
    );

    $event{event} = $opts{event} if defined $opts{event};
    $event{id}    = "$opts{id}"  if defined $opts{id};
    $event{retry} = int($opts{retry}) if defined $opts{retry};

    await $self->{send}->(\%event);
}

=head2 close

    $sse->close;

Close the SSE connection. After this, no more events can be sent.

=cut

sub close ($self) {
    $self->{_closed} = 1;
    return $self;
}

=head2 is_closed

    if ($sse->is_closed) { ... }

Returns true if the connection has been closed.

=cut

sub is_closed ($self) {
    return $self->{_closed};
}

=head2 subscribe

    $sse->subscribe('news:breaking');

Subscribe to a channel. Messages published to this channel will be sent
to this connection as SSE events.

Returns $self for chaining.

=cut

sub subscribe ($self, $channel) {
    return $self if $self->{_channels}{$channel};  # Already subscribed

    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->subscribe($channel, $self->{_pubsub_cb});
    $self->{_channels}{$channel} = 1;

    return $self;
}

=head2 unsubscribe

    $sse->unsubscribe('news:breaking');

Unsubscribe from a channel. Stops receiving events from this channel.

Returns $self for chaining.

=cut

sub unsubscribe ($self, $channel) {
    return $self unless $self->{_channels}{$channel};  # Not subscribed

    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    delete $self->{_channels}{$channel};

    return $self;
}

=head2 unsubscribe_all

    $sse->unsubscribe_all;

Unsubscribe from all channels. Called automatically on disconnect.

Returns $self for chaining.

=cut

sub unsubscribe_all ($self) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    for my $channel (keys %{$self->{_channels}}) {
        $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    }
    $self->{_channels} = {};

    return $self;
}

=head2 channels

    my @channels = $sse->channels;

Returns a list of channels this connection has subscribed to.

=cut

sub channels ($self) {
    return keys %{$self->{_channels}};
}

=head2 in_channel

    if ($sse->in_channel('news:breaking')) { ... }

Returns true if this connection is subscribed to the specified channel.

=cut

sub in_channel ($self, $channel) {
    return exists $self->{_channels}{$channel};
}

=head2 publish

    $sse->publish('news:breaking', 'Extra! Extra!');

Publish a message to all connections subscribed to a channel,
INCLUDING this connection.

Returns the number of connections that received the message.

=cut

sub publish ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;
    return $pubsub->publish($channel, $message);
}

=head2 publish_others

    $sse->publish_others('news:breaking', 'News for others!');

Publish a message to all connections subscribed to a channel,
EXCLUDING this connection.

Returns the number of connections that received the message (excluding self).

=cut

sub publish_others ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    # Temporarily unsubscribe, publish, then resubscribe
    my $was_subscribed = $self->{_channels}{$channel};

    if ($was_subscribed) {
        $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    }

    my $count = $pubsub->publish($channel, $message);

    if ($was_subscribed) {
        $pubsub->subscribe($channel, $self->{_pubsub_cb});
    }

    return $count;
}

# Internal: Start the SSE stream
async sub _start ($self) {
    return if $self->{_started};
    $self->{_started} = 1;

    await $self->{send}->({
        type    => 'sse.start',
        status  => 200,
        headers => [
            ['content-type', 'text/event-stream'],
            ['cache-control', 'no-cache'],
            ['connection', 'keep-alive'],
        ],
    });
}

# Internal: Run the event loop for this connection
async sub _run ($self, $handler) {
    # Start the SSE stream
    await $self->_start;

    # Call the user's handler to set up event callbacks and/or send events
    my $result = $handler->($self);
    if (blessed($result) && $result->isa('Future')) {
        await $result;
    }

    # Wait for disconnect
    while (!$self->{_closed}) {
        my $event = await $self->{receive}->();
        my $type = $event->{type} // '';

        if ($type eq 'sse.disconnect') {
            $self->{_closed} = 1;
            $self->_trigger_close;
            last;
        }
    }
}

# Internal: Trigger close handlers
sub _trigger_close ($self) {
    # Auto-unsubscribe from all channels
    $self->unsubscribe_all;

    for my $cb (@{$self->{_handlers}{close}}) {
        eval { $cb->() };
        if ($@) {
            warn "Error in close handler: $@";
        }
    }
}

# Internal: Trigger error handlers
sub _trigger_error ($self, $error) {
    for my $cb (@{$self->{_handlers}{error}}) {
        eval { $cb->($error) };
    }
    # If no error handlers, warn
    if (!@{$self->{_handlers}{error}}) {
        warn "SSE error: $error";
    }
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>, L<PAGI::Simple::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut

1;
