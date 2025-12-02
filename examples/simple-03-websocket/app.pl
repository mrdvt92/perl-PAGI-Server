#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

# PAGI::Simple WebSocket Chat Example
# Run with: pagi-server --app examples/simple-03-websocket/app.pl

use PAGI::Simple;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new(utf8 => 1);
my $app = PAGI::Simple->new(name => 'WebSocket Chat');

# Chat page
$app->get('/' => sub ($c) {
    $c->html(<<'HTML');
<!DOCTYPE html>
<html>
<head>
    <title>WebSocket Chat</title>
    <style>
        #messages { height: 300px; overflow-y: scroll; border: 1px solid #ccc; padding: 10px; }
        .message { margin: 5px 0; }
        .system { color: #888; font-style: italic; }
    </style>
</head>
<body>
    <h1>WebSocket Chat</h1>
    <div id="messages"></div>
    <input type="text" id="input" placeholder="Type a message..." style="width: 300px;">
    <button id="send">Send</button>
    <script>
        const ws = new WebSocket(`ws://${location.host}/ws/general`);
        const messages = document.getElementById('messages');
        const input = document.getElementById('input');

        ws.onmessage = function(e) {
            const data = JSON.parse(e.data);
            const div = document.createElement('div');
            div.className = 'message ' + (data.type || 'chat');
            div.textContent = data.type === 'system' ? data.text : `${data.user}: ${data.text}`;
            messages.appendChild(div);
            messages.scrollTop = messages.scrollHeight;
        };

        document.getElementById('send').onclick = function() {
            if (input.value) {
                ws.send(JSON.stringify({ type: 'chat', text: input.value }));
                input.value = '';
            }
        };

        input.onkeypress = function(e) {
            if (e.key === 'Enter') document.getElementById('send').click();
        };
    </script>
</body>
</html>
HTML
});

# WebSocket endpoint with room support
$app->websocket('/ws/:room' => sub ($ws) {
    my $room = $ws->param('room') // 'general';
    my $user_id = int(rand(10000));

    # Join the room
    $ws->join("room:$room");
    $ws->stash->{user_id} = $user_id;

    # Announce arrival
    $ws->broadcast("room:$room", $json->encode({
        type => 'system',
        text => "User $user_id joined the room"
    }));

    # Handle incoming messages
    $ws->on(message => sub ($data) {
        my $msg = eval { $json->decode($data) } // {};
        my $text = $msg->{text} // '';

        return unless length($text);

        # Broadcast to all users in the room
        $ws->broadcast("room:$room", $json->encode({
            type => 'chat',
            user => "User $user_id",
            text => $text
        }));
    });

    # Handle disconnect
    $ws->on(close => sub {
        $ws->broadcast_others("room:$room", $json->encode({
            type => 'system',
            text => "User $user_id left the room"
        }));
    });
});

# Simple echo WebSocket
$app->websocket('/echo' => sub ($ws) {
    $ws->on(message => sub ($data) {
        $ws->send("Echo: $data");
    });
});

# Return the PAGI app
$app->to_app;
