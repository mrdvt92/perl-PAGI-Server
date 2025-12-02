# PAGI::Simple WebSocket Chat Example

A real-time chat application demonstrating WebSocket support with rooms and broadcasting using the PAGI::Simple micro web framework.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/simple-03-websocket/app.pl --port 5000
```

**2. Demo with websocat (in another terminal):**

```bash
# Install websocat if needed (macOS)
brew install websocat

# Connect to the echo endpoint
websocat ws://localhost:5000/echo
# Type: Hello
# => Echo: Hello

# Connect to a chat room
websocat ws://localhost:5000/ws/general
# Type: {"type":"chat","text":"Hello everyone!"}
# => {"type":"chat","user":"User 1234","text":"Hello everyone!"}
```

**3. Or use the browser:**

Open http://localhost:5000/ to see the chat UI. Open multiple tabs to test real-time messaging.

## Features

- WebSocket connections
- Chat rooms with path parameters
- Message broadcasting to room members
- Join/leave notifications
- Simple echo WebSocket endpoint
- PubSub-based message distribution
- JSON message protocol

## Routes

| Type | Path | Description |
|------|------|-------------|
| HTTP GET | `/` | Chat UI (HTML page with JavaScript WebSocket client) |
| WebSocket | `/ws/:room` | Chat room connection (room name from path) |
| WebSocket | `/echo` | Simple echo WebSocket |

## Usage

### Browser

1. Start the server
2. Open `http://localhost:5000/` in your browser
3. Type messages and press Enter or click Send
4. Open multiple browser tabs to see real-time chat

### WebSocket Client (websocat)

```bash
# Install websocat if needed
brew install websocat        # macOS
# or: cargo install websocat  # with Rust

# Connect to the general room
websocat ws://localhost:5000/ws/general

# Send a chat message (JSON format) - type and press Enter:
{"type":"chat","text":"Hello everyone!"}

# Connect to a custom room
websocat ws://localhost:5000/ws/my-room
```

### Echo WebSocket

```bash
# Connect to echo endpoint
websocat ws://localhost:5000/echo

# Type any message and press Enter:
Hello
# => Echo: Hello
```

### JavaScript Client

```javascript
const ws = new WebSocket('ws://localhost:5000/ws/general');

ws.onmessage = function(e) {
    const data = JSON.parse(e.data);
    console.log(`[${data.type}] ${data.text || data.user + ': ' + data.text}`);
};

ws.onopen = function() {
    ws.send(JSON.stringify({ type: 'chat', text: 'Hello!' }));
};
```

## Message Protocol

### Incoming Messages (Client to Server)

```json
{
    "type": "chat",
    "text": "Your message here"
}
```

### Outgoing Messages (Server to Client)

**System Message (join/leave):**
```json
{
    "type": "system",
    "text": "User 1234 joined the room"
}
```

**Chat Message:**
```json
{
    "type": "chat",
    "user": "User 1234",
    "text": "Hello everyone!"
}
```

## Code Highlights

### Room-Based WebSocket

```perl
$app->websocket('/ws/:room' => sub ($ws) {
    my $room = $ws->param('room') // 'general';
    my $user_id = int(rand(10000));

    # Join the room
    $ws->join("room:$room");

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
```

### Simple Echo WebSocket

```perl
$app->websocket('/echo' => sub ($ws) {
    $ws->on(message => sub ($data) {
        $ws->send("Echo: $data");
    });
});
```

## Key Methods

| Method | Description |
|--------|-------------|
| `$ws->join($channel)` | Subscribe to a PubSub channel |
| `$ws->broadcast($channel, $msg)` | Send message to all subscribers (including self) |
| `$ws->broadcast_others($channel, $msg)` | Send message to all subscribers (excluding self) |
| `$ws->send($msg)` | Send message directly to this client |
| `$ws->on(message => sub)` | Handle incoming messages |
| `$ws->on(close => sub)` | Handle client disconnect |
| `$ws->param($name)` | Get path parameter value |
