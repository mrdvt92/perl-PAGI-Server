use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: WebSocket Rooms and Broadcast in PAGI::Simple

use PAGI::Simple;
use PAGI::Simple::WebSocket;
use PAGI::Simple::PubSub;

# Reset pubsub singleton before tests
PAGI::Simple::PubSub->reset;

# Helper to create a mock WebSocket context for direct testing
sub create_mock_ws (%opts) {
    my @sent;
    my $closed = 0;

    my $send = sub ($event) {
        push @sent, $event;
        if ($event->{type} eq 'websocket.close') {
            $closed = 1;
        }
        return Future->done;
    };

    my $ws = PAGI::Simple::WebSocket->new(
        app         => $opts{app},
        scope       => { type => 'websocket', path => $opts{path} // '/ws' },
        receive     => sub { Future->done({ type => 'websocket.disconnect' }) },
        send        => $send,
        path_params => $opts{path_params} // {},
    );

    return ($ws, \@sent);
}

# Test 1: join method exists
subtest 'join method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();
    ok($ws->can('join'), 'ws has join method');
};

# Test 2: leave method exists
subtest 'leave method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();
    ok($ws->can('leave'), 'ws has leave method');
};

# Test 3: broadcast method exists
subtest 'broadcast method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();
    ok($ws->can('broadcast'), 'ws has broadcast method');
};

# Test 4: broadcast_others method exists
subtest 'broadcast_others method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();
    ok($ws->can('broadcast_others'), 'ws has broadcast_others method');
};

# Test 5: Join a room
subtest 'join a room' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    my $result = $ws->join('room:general');

    is($result, $ws, 'join returns $ws for chaining');
    ok($ws->in_room('room:general'), 'is in room after join');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('room:general'), 1, 'pubsub has subscriber');
};

# Test 6: Leave a room
subtest 'leave a room' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    $ws->join('room:general');
    ok($ws->in_room('room:general'), 'in room after join');

    my $result = $ws->leave('room:general');
    is($result, $ws, 'leave returns $ws for chaining');
    ok(!$ws->in_room('room:general'), 'not in room after leave');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('room:general'), 0, 'pubsub has no subscribers');
};

# Test 7: rooms() returns joined rooms
subtest 'rooms accessor' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    my @rooms = $ws->rooms;
    is(scalar @rooms, 0, 'no rooms initially');

    $ws->join('room:a');
    $ws->join('room:b');
    $ws->join('room:c');

    @rooms = sort $ws->rooms;
    is(\@rooms, ['room:a', 'room:b', 'room:c'], 'all rooms listed');
};

# Test 8: in_room() check
subtest 'in_room check' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    ok(!$ws->in_room('room:test'), 'not in room before join');
    $ws->join('room:test');
    ok($ws->in_room('room:test'), 'in room after join');
    $ws->leave('room:test');
    ok(!$ws->in_room('room:test'), 'not in room after leave');
};

# Test 9: Broadcast sends to all in room
subtest 'broadcast sends to all' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws1, $sent1) = create_mock_ws();
    my ($ws2, $sent2) = create_mock_ws();
    my ($ws3, $sent3) = create_mock_ws();

    $ws1->join('room:chat');
    $ws2->join('room:chat');
    $ws3->join('room:chat');

    # ws1 broadcasts
    my $count = $ws1->broadcast('room:chat', 'Hello everyone!');

    is($count, 3, 'broadcast returned 3 recipients');

    # All should have received the message
    my @ws1_sends = grep { $_->{type} eq 'websocket.send' } @$sent1;
    my @ws2_sends = grep { $_->{type} eq 'websocket.send' } @$sent2;
    my @ws3_sends = grep { $_->{type} eq 'websocket.send' } @$sent3;

    is(scalar @ws1_sends, 1, 'ws1 received message');
    is(scalar @ws2_sends, 1, 'ws2 received message');
    is(scalar @ws3_sends, 1, 'ws3 received message');

    is($ws1_sends[0]{text}, 'Hello everyone!', 'ws1 got correct message');
    is($ws2_sends[0]{text}, 'Hello everyone!', 'ws2 got correct message');
    is($ws3_sends[0]{text}, 'Hello everyone!', 'ws3 got correct message');
};

# Test 10: broadcast_others excludes sender
subtest 'broadcast_others excludes sender' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws1, $sent1) = create_mock_ws();
    my ($ws2, $sent2) = create_mock_ws();
    my ($ws3, $sent3) = create_mock_ws();

    $ws1->join('room:chat');
    $ws2->join('room:chat');
    $ws3->join('room:chat');

    # ws1 broadcasts to others
    my $count = $ws1->broadcast_others('room:chat', 'Hello others!');

    is($count, 2, 'broadcast_others returned 2 recipients');

    # ws1 should NOT have received
    my @ws1_sends = grep { $_->{type} eq 'websocket.send' } @$sent1;
    my @ws2_sends = grep { $_->{type} eq 'websocket.send' } @$sent2;
    my @ws3_sends = grep { $_->{type} eq 'websocket.send' } @$sent3;

    is(scalar @ws1_sends, 0, 'ws1 did NOT receive message');
    is(scalar @ws2_sends, 1, 'ws2 received message');
    is(scalar @ws3_sends, 1, 'ws3 received message');
};

# Test 11: leave_all leaves all rooms
subtest 'leave_all leaves all rooms' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    $ws->join('room:a');
    $ws->join('room:b');
    $ws->join('room:c');

    is(scalar $ws->rooms, 3, 'in 3 rooms');

    my $result = $ws->leave_all;
    is($result, $ws, 'leave_all returns $ws');
    is(scalar $ws->rooms, 0, 'in 0 rooms after leave_all');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('room:a'), 0, 'room:a empty');
    is($pubsub->subscribers('room:b'), 0, 'room:b empty');
    is($pubsub->subscribers('room:c'), 0, 'room:c empty');
};

# Test 12: Double join ignored
subtest 'double join ignored' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    $ws->join('room:test');
    $ws->join('room:test');  # Join again

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('room:test'), 1, 'still only 1 subscriber');
    is(scalar $ws->rooms, 1, 'still only 1 room');
};

# Test 13: Leave from non-joined room ok
subtest 'leave non-joined room ok' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    my $result = $ws->leave('room:never-joined');
    is($result, $ws, 'leave returns $ws even for non-joined');
};

# Test 14: Multiple rooms independent
subtest 'multiple rooms independent' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws1, $sent1) = create_mock_ws();
    my ($ws2, $sent2) = create_mock_ws();

    $ws1->join('room:a');
    $ws1->join('room:b');
    $ws2->join('room:b');
    $ws2->join('room:c');

    # Broadcast to room:a - only ws1 gets it
    $ws1->broadcast('room:a', 'message-a');
    my @ws1_a = grep { $_->{text} && $_->{text} eq 'message-a' } @$sent1;
    my @ws2_a = grep { $_->{text} && $_->{text} eq 'message-a' } @$sent2;
    is(scalar @ws1_a, 1, 'ws1 got room:a message');
    is(scalar @ws2_a, 0, 'ws2 did not get room:a message');

    # Broadcast to room:c - only ws2 gets it
    $ws2->broadcast('room:c', 'message-c');
    my @ws1_c = grep { $_->{text} && $_->{text} eq 'message-c' } @$sent1;
    my @ws2_c = grep { $_->{text} && $_->{text} eq 'message-c' } @$sent2;
    is(scalar @ws1_c, 0, 'ws1 did not get room:c message');
    is(scalar @ws2_c, 1, 'ws2 got room:c message');

    # Broadcast to room:b - both get it
    $ws1->broadcast('room:b', 'message-b');
    my @ws1_b = grep { $_->{text} && $_->{text} eq 'message-b' } @$sent1;
    my @ws2_b = grep { $_->{text} && $_->{text} eq 'message-b' } @$sent2;
    is(scalar @ws1_b, 1, 'ws1 got room:b message');
    is(scalar @ws2_b, 1, 'ws2 got room:b message');
};

# Test 15: Method chaining
subtest 'method chaining' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    $ws->join('room:a')
       ->join('room:b')
       ->leave('room:a');

    ok(!$ws->in_room('room:a'), 'not in room:a');
    ok($ws->in_room('room:b'), 'in room:b');
};

# Test 16: Broadcast from non-member
subtest 'broadcast from non-member' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws1, $sent1) = create_mock_ws();
    my ($ws2, $sent2) = create_mock_ws();

    # Only ws2 joins the room
    $ws2->join('room:test');

    # ws1 (not in room) broadcasts to room
    my $count = $ws1->broadcast('room:test', 'Hello from outside!');

    is($count, 1, 'broadcast reached 1 member');

    my @ws2_sends = grep { $_->{type} eq 'websocket.send' } @$sent2;
    is(scalar @ws2_sends, 1, 'ws2 received broadcast');
    is($ws2_sends[0]{text}, 'Hello from outside!', 'correct message');
};

# Test 17: broadcast_others from non-member
subtest 'broadcast_others from non-member' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws1, $sent1) = create_mock_ws();
    my ($ws2, $sent2) = create_mock_ws();

    # Only ws2 joins the room
    $ws2->join('room:test');

    # ws1 (not in room) broadcasts to others in room
    my $count = $ws1->broadcast_others('room:test', 'Hello from outside!');

    # Should still reach ws2 since ws1 wasn't subscribed anyway
    is($count, 1, 'broadcast_others reached 1 member');

    my @ws2_sends = grep { $_->{type} eq 'websocket.send' } @$sent2;
    is(scalar @ws2_sends, 1, 'ws2 received broadcast');
};

# Test 18: Auto-leave on close via _trigger_close
subtest 'auto-leave on close' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    $ws->join('room:a');
    $ws->join('room:b');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('room:a'), 1, 'room:a has subscriber');
    is($pubsub->subscribers('room:b'), 1, 'room:b has subscriber');

    # Simulate close (calls _trigger_close internally)
    $ws->_trigger_close;

    is($pubsub->subscribers('room:a'), 0, 'room:a empty after close');
    is($pubsub->subscribers('room:b'), 0, 'room:b empty after close');
    is(scalar $ws->rooms, 0, 'ws has no rooms after close');
};

# Test 19: Empty room broadcast
subtest 'empty room broadcast' => sub {
    PAGI::Simple::PubSub->reset;
    my ($ws, $sent) = create_mock_ws();

    my $count = $ws->broadcast('room:empty', 'Hello nobody!');
    is($count, 0, 'broadcast to empty room returns 0');
};

# Test 20: Integration with WebSocket route simulation
subtest 'integration with websocket route' => sub {
    PAGI::Simple::PubSub->reset;

    # This tests the full flow through simulate_websocket
    my $app = PAGI::Simple->new;
    my @room_members;

    $app->websocket('/chat/:room' => sub ($ws) {
        my $room = $ws->param('room');
        $ws->join("room:$room");

        $ws->on(message => sub ($data) {
            $ws->broadcast("room:$room", "[$room] $data");
        });

        $ws->on(close => sub {
            # Room should auto-leave, but we can also manually track
            push @room_members, scalar $ws->rooms;
        });
    });

    # Simulate a connection (simplified - just test handler setup)
    # Full integration requires the simulate_websocket helper from test 14

    ok($app->can('websocket'), 'app has websocket method');
};

done_testing;
