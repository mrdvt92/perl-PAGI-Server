# PAGI::Simple Hello World Example

A basic example demonstrating core routing and response features of the PAGI::Simple micro web framework.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/simple-01-hello/app.pl --port 5000
```

**2. Demo with curl (in another terminal):**

```bash
# Basic hello
curl http://localhost:5000/
# => Hello, World!

# Greet by name
curl http://localhost:5000/greet/Alice
# => Hello, Alice!

# JSON response
curl http://localhost:5000/json
# => {"message":"Hello, World!","timestamp":...}

# HTML page
curl http://localhost:5000/html
# => <!DOCTYPE html>...
```

## Features

- Basic text responses
- Path parameters (`:name`)
- Query parameters
- JSON and HTML responses
- Custom status codes and headers
- Redirects
- Custom error handlers (404)

## Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Returns "Hello, World!" as plain text |
| GET | `/greet/:name` | Greets the specified name |
| GET | `/json` | Returns a JSON response with message and timestamp |
| GET | `/html` | Returns an HTML page |
| GET | `/search?q=...` | Demonstrates query parameters |
| GET | `/created` | Returns 201 status with custom header |
| GET | `/old-path` | Redirects to `/` |

## Usage Examples

```bash
# Basic hello
curl http://localhost:5000/
# => Hello, World!

# Greet by name
curl http://localhost:5000/greet/Alice
# => Hello, Alice!

# JSON response
curl http://localhost:5000/json
# => {"message":"Hello, World!","timestamp":1701234567}

# Query parameters
curl "http://localhost:5000/search?q=test"
# => {"query":"test","results":["Result for: test"]}

# Custom status code and header
curl -i http://localhost:5000/created
# => HTTP/1.1 201 Created
# => X-Custom-Header: Custom Value
# => {"status":"created"}

# Redirect
curl -L http://localhost:5000/old-path
# => Hello, World!

# 404 error (custom handler)
curl http://localhost:5000/nonexistent
# => {"error":"Not Found","path":"/nonexistent"}
```

## Code Highlights

### Path Parameters

```perl
$app->get('/greet/:name' => sub ($c) {
    my $name = $c->path_params->{name};
    $c->text("Hello, $name!");
});
```

### Custom Headers and Status

```perl
$app->get('/created' => sub ($c) {
    $c->res_header('X-Custom-Header' => 'Custom Value');
    $c->status(201)->json({ status => 'created' });
});
```

### Custom Error Handler

```perl
$app->error(404 => sub ($c, $msg = undef) {
    $c->status(404)->json({
        error => 'Not Found',
        path => $c->path,
    });
});
```
