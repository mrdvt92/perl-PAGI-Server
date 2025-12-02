package PAGI::Simple::WebSocket;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use PAGI::Simple::PubSub;

=head1 NAME

PAGI::Simple::WebSocket - WebSocket context for PAGI::Simple

=head1 SYNOPSIS

    $app->websocket('/ws' => sub ($ws) {
        $ws->send("Welcome!");

        $ws->on(message => sub ($data) {
            $ws->send("Echo: $data");
        });

        $ws->on(close => sub {
            # Cleanup
        });
    });

=head1 DESCRIPTION

PAGI::Simple::WebSocket provides a context object for handling WebSocket
connections. It wraps the low-level PAGI WebSocket protocol with a
convenient callback-based API.

=head1 METHODS

=cut

=head2 new

    my $ws = PAGI::Simple::WebSocket->new(
        app         => $app,
        scope       => $scope,
        receive     => $receive,
        send        => $send,
        path_params => \%params,
    );

Create a new WebSocket context.

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
            message => [],
            close   => [],
            error   => [],
        },
        _accepted   => 0,
        _closed     => 0,
        _rooms      => {},  # channel => 1 for tracking joined rooms
        _pubsub_cb  => undef,  # Callback for receiving broadcast messages
    }, $class;

    # Create the pubsub callback for this connection
    $self->{_pubsub_cb} = sub ($message) {
        # Send the message to this client
        $self->send($message) unless $self->{_closed};
    };

    return $self;
}

=head2 app

    my $app = $ws->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 scope

    my $scope = $ws->scope;

Returns the raw PAGI scope hashref.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 stash

    my $stash = $ws->stash;
    $ws->stash->{user} = $user;

Per-connection storage hashref.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 path_params

    my $params = $ws->path_params;

Returns the path parameters captured from the route.

=cut

sub path_params ($self) {
    return $self->{path_params};
}

=head2 param

    my $value = $ws->param('id');

Get a path parameter by name.

=cut

sub param ($self, $name) {
    return $self->{path_params}{$name};
}

=head2 on

    $ws->on(message => sub ($data) { ... });
    $ws->on(close => sub { ... });
    $ws->on(error => sub ($error) { ... });

Register event handlers. Multiple handlers can be registered for each event.

Events:
- C<message>: Called when a message is received from the client
- C<close>: Called when the connection is closed
- C<error>: Called when an error occurs

=cut

sub on ($self, $event, $callback) {
    if (exists $self->{_handlers}{$event}) {
        push @{$self->{_handlers}{$event}}, $callback;
    }
    else {
        die "Unknown event type: $event (expected message, close, or error)";
    }
    return $self;
}

=head2 send

    await $ws->send("Hello");
    await $ws->send($binary_data, binary => 1);

Send a message to the client. Returns a Future.

Options:
- C<binary>: If true, send as binary frame (default: text)

=cut

async sub send ($self, $data, %opts) {
    return if $self->{_closed};

    my $type = $opts{binary} ? 'binary' : 'text';

    await $self->{send}->({
        type  => 'websocket.send',
        $type => $data,
    });
}

=head2 close

    await $ws->close;
    await $ws->close(1000);
    await $ws->close(1000, "Normal closure");

Close the WebSocket connection.

=cut

async sub close ($self, $code = 1000, $reason = '') {
    return if $self->{_closed};
    $self->{_closed} = 1;

    await $self->{send}->({
        type   => 'websocket.close',
        code   => $code,
        reason => $reason,
    });
}

=head2 is_closed

    if ($ws->is_closed) { ... }

Returns true if the connection has been closed.

=cut

sub is_closed ($self) {
    return $self->{_closed};
}

=head2 join

    $ws->join('room:general');

Join a room/channel. Messages broadcast to this room will be sent
to this connection.

Returns $self for chaining.

=cut

sub join ($self, $channel) {
    return $self if $self->{_rooms}{$channel};  # Already joined

    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->subscribe($channel, $self->{_pubsub_cb});
    $self->{_rooms}{$channel} = 1;

    return $self;
}

=head2 leave

    $ws->leave('room:general');

Leave a room/channel. Stops receiving broadcasts for this room.

Returns $self for chaining.

=cut

sub leave ($self, $channel) {
    return $self unless $self->{_rooms}{$channel};  # Not in room

    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    delete $self->{_rooms}{$channel};

    return $self;
}

=head2 leave_all

    $ws->leave_all;

Leave all rooms. Called automatically on disconnect.

Returns $self for chaining.

=cut

sub leave_all ($self) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    for my $channel (keys %{$self->{_rooms}}) {
        $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    }
    $self->{_rooms} = {};

    return $self;
}

=head2 rooms

    my @rooms = $ws->rooms;

Returns a list of rooms this connection has joined.

=cut

sub rooms ($self) {
    return keys %{$self->{_rooms}};
}

=head2 in_room

    if ($ws->in_room('room:general')) { ... }

Returns true if this connection is in the specified room.

=cut

sub in_room ($self, $channel) {
    return exists $self->{_rooms}{$channel};
}

=head2 broadcast

    $ws->broadcast('room:general', 'Hello everyone!');

Broadcast a message to all connections in a room, INCLUDING this connection.

Returns the number of connections that received the message.

=cut

sub broadcast ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;
    return $pubsub->publish($channel, $message);
}

=head2 broadcast_others

    $ws->broadcast_others('room:general', 'Hello others!');

Broadcast a message to all connections in a room, EXCLUDING this connection.

Returns the number of connections that received the message (excluding self).

=cut

sub broadcast_others ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    # Temporarily unsubscribe, publish, then resubscribe
    my $was_in_room = $self->{_rooms}{$channel};

    if ($was_in_room) {
        $pubsub->unsubscribe($channel, $self->{_pubsub_cb});
    }

    my $count = $pubsub->publish($channel, $message);

    if ($was_in_room) {
        $pubsub->subscribe($channel, $self->{_pubsub_cb});
    }

    return $count;
}

# Internal: Accept the WebSocket connection
async sub _accept ($self) {
    return if $self->{_accepted};
    $self->{_accepted} = 1;

    await $self->{send}->({
        type => 'websocket.accept',
    });
}

# Internal: Run the event loop for this connection
async sub _run ($self, $handler) {
    # First, receive the connect event
    my $connect = await $self->{receive}->();
    if ($connect->{type} ne 'websocket.connect') {
        # Unexpected event type
        await $self->close(4000, "Expected websocket.connect");
        return;
    }

    # Accept the connection
    await $self->_accept();

    # Call the user's handler to set up event callbacks
    my $result = $handler->($self);
    if (blessed($result) && $result->isa('Future')) {
        await $result;
    }

    # Enter the message loop
    while (!$self->{_closed}) {
        my $event = await $self->{receive}->();
        my $type = $event->{type} // '';

        if ($type eq 'websocket.receive') {
            # Got a message from the client
            my $data = $event->{text} // $event->{bytes};
            for my $cb (@{$self->{_handlers}{message}}) {
                eval {
                    my $r = $cb->($data);
                    if (blessed($r) && $r->isa('Future')) {
                        await $r;
                    }
                };
                if ($@) {
                    $self->_trigger_error($@);
                }
            }
        }
        elsif ($type eq 'websocket.disconnect') {
            # Client disconnected
            $self->{_closed} = 1;
            $self->_trigger_close();
            last;
        }
        elsif ($type eq 'websocket.close') {
            # Close requested (could be from client or server)
            $self->{_closed} = 1;
            $self->_trigger_close();
            last;
        }
    }
}

# Internal: Trigger close handlers
sub _trigger_close ($self) {
    # Auto-leave all rooms
    $self->leave_all;

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
        warn "WebSocket error: $error";
    }
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>

=head1 AUTHOR

PAGI Contributors

=cut

1;
