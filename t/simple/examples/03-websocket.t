use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: WebSocket Chat Example App

use FindBin qw($Bin);
use lib "$Bin/../../../lib";

my $app_file = "$Bin/../../../examples/simple-03-websocket/app.pl";
ok(-f $app_file, 'example app file exists');

my $pagi_app = do $app_file;
if ($@) {
    fail("Failed to load app: $@");
    done_testing;
    exit;
}
ok(ref($pagi_app) eq 'CODE', 'app returns a coderef');

# Helper to simulate HTTP request
sub simulate_http ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path = $opts{path} // '/';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => $path,
        headers => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.disconnect' }) };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    $app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
        status => $sent[0]{status},
        headers => { map { @$_ } @{$sent[0]{headers} // []} },
        body => $sent[1]{body} // '',
    };
}

# Helper to simulate WebSocket connection
sub simulate_websocket ($app, %opts) {
    my $path = $opts{path} // '/ws/general';
    my $messages = $opts{messages} // [];  # Messages to send to server

    my @sent;
    my @received_events;
    my $msg_idx = 0;

    my $scope = {
        type    => 'websocket',
        path    => $path,
        headers => [],
    };

    my $receive = sub {
        # First, return the connect event
        if (!@received_events) {
            push @received_events, 'connect';
            return Future->done({ type => 'websocket.connect' });
        }

        # Then, return any messages
        if ($msg_idx < @$messages) {
            my $msg = $messages->[$msg_idx++];
            push @received_events, "send:$msg";
            return Future->done({
                type => 'websocket.receive',
                text => $msg,
            });
        }

        # Finally, close
        push @received_events, 'close';
        return Future->done({ type => 'websocket.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    $app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
        events => \@received_events,
    };
}

# Test 1: Home page shows chat UI
subtest 'home page shows chat UI' => sub {
    my $result = simulate_http($pagi_app, path => '/');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/WebSocket Chat/, 'has title');
    like($result->{body}, qr/new WebSocket/, 'has WebSocket code');
    like($result->{body}, qr/messages/, 'has messages container');
};

# Test 2: WebSocket accepts connection
subtest 'websocket accepts connection' => sub {
    my $result = simulate_websocket($pagi_app, path => '/ws/general');

    # Find the accept event
    my ($accept) = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    ok($accept, 'connection accepted');
};

# Test 3: Echo WebSocket
subtest 'echo websocket' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/echo',
        messages => ['Hello'],
    );

    # Find the accept event
    my ($accept) = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    ok($accept, 'connection accepted');

    # Find the echoed message
    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    ok(@sends > 0, 'got send events');
    is($sends[0]{text}, 'Echo: Hello', 'echo response correct');
};

# Test 4: Chat room join message
subtest 'chat room join message' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/ws/test-room',
        messages => [],  # Just connect, don't send anything
    );

    my ($accept) = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    ok($accept, 'connection accepted');

    # Find the join message broadcast
    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    ok(@sends > 0, 'got broadcast messages');

    # The join message should contain "joined"
    my $join_msg = $sends[0]{text};
    like($join_msg, qr/joined/, 'has join message');
    like($join_msg, qr/system/, 'is system message');
};

# Test 5: Chat message broadcast
subtest 'chat message broadcast' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/ws/chat-room',
        messages => ['{"type":"chat","text":"Hello world!"}'],
    );

    # Find all send events
    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    ok(@sends >= 2, 'got multiple sends (join + chat)');

    # Find a chat message
    my @chat_msgs = grep { $_->{text} =~ /Hello world/ } @sends;
    ok(@chat_msgs > 0, 'chat message was broadcast');
    like($chat_msgs[0]{text}, qr/"type"\s*:\s*"chat"/, 'message type is chat');
};

# Test 6: Empty messages are ignored
subtest 'empty messages ignored' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/ws/filter-room',
        messages => ['{"type":"chat","text":""}'],
    );

    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    # Should only have the join message, not an empty chat message
    my @chat_msgs = grep { $_->{text} =~ /"type"\s*:\s*"chat"/ } @sends;
    is(scalar(@chat_msgs), 0, 'empty chat message not broadcast');
};

# Test 7: Different rooms are isolated
subtest 'rooms are isolated' => sub {
    use PAGI::Simple::PubSub;

    # Clear pubsub state
    PAGI::Simple::PubSub->instance->{channels} = {};

    # Connect to room1
    my $result1 = simulate_websocket($pagi_app,
        path => '/ws/room1',
        messages => [],
    );

    # Room 1 should have join message
    my @sends1 = grep { $_->{type} eq 'websocket.send' } @{$result1->{sent}};
    ok(@sends1 >= 1, 'room1 got join message');

    # After first connection closes, pubsub should be clean
    # Connect to room2
    my $result2 = simulate_websocket($pagi_app,
        path => '/ws/room2',
        messages => [],
    );

    # Room 2 should have its own join message
    my @sends2 = grep { $_->{type} eq 'websocket.send' } @{$result2->{sent}};
    ok(@sends2 >= 1, 'room2 got join message');
};

# Test 8: Path parameters work
subtest 'path parameters' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/ws/my-custom-room',
        messages => [],
    );

    my ($accept) = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    ok($accept, 'connection to custom room accepted');
};

# Test 9: Invalid JSON handled gracefully
subtest 'invalid JSON handled' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/ws/invalid-json-room',
        messages => ['not valid json'],
    );

    # Should not crash, connection should still be accepted
    my ($accept) = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    ok($accept, 'connection accepted despite invalid JSON');
};

# Test 10: Multiple messages
subtest 'multiple messages' => sub {
    my $result = simulate_websocket($pagi_app,
        path => '/echo',
        messages => ['First', 'Second', 'Third'],
    );

    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    is(scalar(@sends), 3, 'got 3 echo responses');
    is($sends[0]{text}, 'Echo: First', 'first echo');
    is($sends[1]{text}, 'Echo: Second', 'second echo');
    is($sends[2]{text}, 'Echo: Third', 'third echo');
};

done_testing;
