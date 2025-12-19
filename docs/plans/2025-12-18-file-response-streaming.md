# File Response Streaming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend PAGI spec to support `file` and `fh` in http.response.body, implement efficient streaming in PAGI::Server, and harden PAGI::App::File with security improvements from Plack::App::File.

**Architecture:** The spec will be extended to allow `file` (path string) and `fh` (filehandle) as alternatives to `body` in http.response.body events. Servers MUST accept both, SHOULD use sendfile() when possible, and MAY fall back to chunked read/write. PAGI::App::File will be rewritten to use the new `file` response type and include security hardening (null byte injection, proper path splitting, symlink awareness).

**Tech Stack:** Perl 5.32+, IO::Async, Future::AsyncAwait, POSIX (for sendfile on Linux), File::Spec::Unix

---

## Task 1: Update PAGI Spec - Add File/Filehandle Response Body Support

**Files:**
- Modify: `docs/specs/www.mkdn` (Response Body section, around line 100-106)

**Step 1: Run existing tests to establish baseline**

```bash
prove -l t/
```

Expected: All tests PASS (establishes no regressions from start)

**Step 2: Read current spec section**

Read `docs/specs/www.mkdn` lines 100-120 to understand current Response Body spec.

**Step 3: Update spec with file/fh support**

Replace lines 100-111 in `docs/specs/www.mkdn` with:

```markdown
### Response Body - `send` event

Keys:

- `type` -- `"http.response.body"`
- `body` (Bytes, default `""`) -- Response body chunk (mutually exclusive with `file`/`fh`)
- `file` (String, optional) -- Absolute file path to send (mutually exclusive with `body`/`fh`)
- `fh` (Filehandle, optional) -- Open filehandle to read from (mutually exclusive with `body`/`file`)
- `offset` (Int, default `0`) -- Byte offset to start reading (only with `file`/`fh`)
- `length` (Int, optional) -- Number of bytes to send; if omitted, send to EOF (only with `file`/`fh`)
- `more` (Int, default `0`) -- Indicates more body content to follow (`1` if true, otherwise `0`)

**Body Types (mutually exclusive):**

Exactly one of `body`, `file`, or `fh` should be provided:

1. **`body`** (Bytes): Traditional inline body chunk. Applications **must** provide encoded bytes.

2. **`file`** (String): Absolute path to a file. The server opens the file, seeks to `offset`,
   and sends `length` bytes (or to EOF if `length` is omitted). Servers **SHOULD** use
   `sendfile()` or equivalent zero-copy I/O when available, and **MAY** fall back to
   chunked read/write. The file must exist and be readable; servers should return
   appropriate HTTP errors (500) if the file cannot be opened.

3. **`fh`** (Filehandle): An already-open filehandle. The server reads from the current
   position (or seeks to `offset` if provided) and sends `length` bytes (or to EOF).
   The application retains ownership and must close the handle after the response completes.
   This is useful for temporary files, pipes, or custom I/O objects.

**Range Request Support:**

For HTTP Range requests (206 Partial Content), applications should:
- Set `offset` to the range start byte
- Set `length` to the range length
- The server handles the actual I/O; applications handle Range header parsing and response headers

**Example - Full File:**

```perl
await $send->({
    type => 'http.response.body',
    file => '/var/www/static/video.mp4',
    more => 0,
});
```

**Example - Range Request:**

```perl
await $send->({
    type => 'http.response.body',
    file => '/var/www/static/video.mp4',
    offset => 1000,
    length => 5000,
    more => 0,
});
```

**Example - Filehandle:**

```perl
open my $fh, '<:raw', $temp_file or die;
await $send->({
    type => 'http.response.body',
    fh => $fh,
    length => $file_size,
    more => 0,
});
close $fh;
```

Applications **must** provide `body` as encoded bytes when using the `body` key. For text
content, this typically means UTF-8 encoding before sending. The `Content-Length` header
(if present) must reflect byte length, not character length.
```

**Step 4: Run tests to verify no syntax issues in docs**

```bash
# Verify markdown is valid
head -150 docs/specs/www.mkdn
```

**Step 5: Commit spec changes**

```bash
git add docs/specs/www.mkdn
git commit -m "spec: add file and fh support to http.response.body

- Add 'file' key for path-based file responses (enables sendfile)
- Add 'fh' key for filehandle-based responses (temp files, pipes)
- Add 'offset' and 'length' keys for range request support
- Servers MUST accept both, SHOULD use sendfile, MAY fall back
- Document mutual exclusivity of body/file/fh"
```

---

## Task 2: Add File Response Tests to Connection Tests

**Files:**
- Create: `t/42-file-response.t`

**Step 1: Run existing tests**

```bash
prove -l t/
```

Expected: All PASS

**Step 2: Create comprehensive test file**

Create `t/42-file-response.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use File::Temp qw(tempfile tempdir);
use Future::AsyncAwait;

use PAGI::Server;

# Create test files
my $tempdir = tempdir(CLEANUP => 1);
my $test_content = "Hello from file response!\n" x 100;  # ~2.7KB
my $test_file = "$tempdir/test.txt";
open my $fh, '>:raw', $test_file or die "Cannot create test file: $!";
print $fh $test_content;
close $fh;

my $binary_content = pack("C*", 0..255) x 10;  # 2560 bytes of binary
my $binary_file = "$tempdir/binary.bin";
open $fh, '>:raw', $binary_file or die;
print $fh $binary_content;
close $fh;

subtest 'file response sends full file' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
                more => 0,
            });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die "Cannot connect: $!";

    print $sock "GET /test.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 200/, 'got 200 response');
    like($response, qr/\Q$test_content\E/, 'file content received');

    $server->shutdown->get;
};

subtest 'file response with offset and length (range)' => sub {
    my $loop = IO::Async::Loop->new;

    my $offset = 100;
    my $length = 500;
    my $expected = substr($test_content, $offset, $length);

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({
                type => 'http.response.start',
                status => 206,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', $length],
                    ['content-range', "bytes $offset-" . ($offset + $length - 1) . "/" . length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
                offset => $offset,
                length => $length,
                more => 0,
            });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET /test.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=$offset-" . ($offset + $length - 1) . "\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 206/, 'got 206 response');
    like($response, qr/\Q$expected\E/, 'partial content received');

    $server->shutdown->get;
};

subtest 'fh response sends from filehandle' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            open my $fh, '<:raw', $test_file or die "Cannot open: $!";

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
                length => length($test_content),
                more => 0,
            });

            close $fh;
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 200/, 'got 200 response');
    like($response, qr/\Q$test_content\E/, 'filehandle content received');

    $server->shutdown->get;
};

subtest 'binary file response preserves bytes' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', length($binary_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $binary_file,
                more => 0,
            });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET /binary.bin HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.2);

    local $/;
    my $response = <$sock>;
    close $sock;

    # Extract body after headers
    my ($headers, $body) = split /\r\n\r\n/, $response, 2;
    is(length($body), length($binary_content), 'binary length matches');
    is($body, $binary_content, 'binary content matches');

    $server->shutdown->get;
};

subtest 'file not found returns error' => sub {
    my $loop = IO::Async::Loop->new;
    my $error_caught = 0;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [],
            });
            eval {
                await $send->({
                    type => 'http.response.body',
                    file => '/nonexistent/file.txt',
                    more => 0,
                });
            };
            if ($@) {
                $error_caught = 1;
            }
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);
    close $sock;

    # Server should handle this gracefully
    ok($server->is_running, 'server still running after file error');

    $server->shutdown->get;
};

done_testing;
```

**Step 3: Run test to verify it fails (file response not implemented)**

```bash
prove -l t/42-file-response.t -v
```

Expected: FAIL (file response not yet implemented in Connection.pm)

**Step 4: Commit test file**

```bash
git add t/42-file-response.t
git commit -m "test: add tests for file and fh response body types"
```

---

## Task 3: Implement File Response in PAGI::Server::Connection

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm` (around line 714-751)

**Step 1: Run existing tests**

```bash
prove -l t/01-hello-http.t t/10-http-compliance.t
```

Expected: All PASS

**Step 2: Read current response body handling**

Read `lib/PAGI/Server/Connection.pm` lines 714-751 to understand current implementation.

**Step 3: Add constants for chunk size**

At the top of `lib/PAGI/Server/Connection.pm`, after the `use` statements (around line 10), add:

```perl
use constant FILE_CHUNK_SIZE => 65536;  # 64KB chunks for file streaming
```

**Step 4: Replace response body handling with file/fh support**

In `lib/PAGI/Server/Connection.pm`, replace the `elsif ($type eq 'http.response.body')` block (lines 714-751) with:

```perl
        elsif ($type eq 'http.response.body') {
            return unless $response_started;
            return if $body_complete;

            # For HEAD requests, suppress the body but track completion
            if ($is_head_request) {
                my $more = $event->{more} // 0;
                if (!$more) {
                    $body_complete = 1;
                }
                return;  # Don't send any body for HEAD
            }

            # Determine body source: body, file, or fh (mutually exclusive)
            my $body = $event->{body};
            my $file = $event->{file};
            my $fh = $event->{fh};
            my $offset = $event->{offset} // 0;
            my $length = $event->{length};
            my $more = $event->{more} // 0;

            if (defined $file) {
                # File path response - stream from file
                $weak_self->_send_file_response($file, $offset, $length, $chunked);
            }
            elsif (defined $fh) {
                # Filehandle response - stream from handle
                $weak_self->_send_fh_response($fh, $offset, $length, $chunked);
            }
            else {
                # Traditional body response
                $body //= '';
                if ($chunked) {
                    if (length $body) {
                        my $len = sprintf("%x", length($body));
                        $weak_self->{stream}->write("$len\r\n$body\r\n");
                    }
                }
                else {
                    $weak_self->{stream}->write($body) if length $body;
                }
            }

            # Handle completion
            if (!$more) {
                $body_complete = 1;
                if ($chunked && !$expects_trailers && !defined $file && !defined $fh) {
                    $weak_self->{stream}->write("0\r\n\r\n");
                }
            }
        }
```

**Step 5: Add file streaming methods**

After the `_on_connection` method (or at end of file before `1;`), add:

```perl
sub _send_file_response ($self, $file, $offset, $length, $chunked) {
    open my $fh, '<:raw', $file or do {
        $self->_log(error => "Cannot open file $file: $!");
        die "Cannot open file: $!";
    };

    $self->_send_fh_response($fh, $offset, $length, $chunked);
    close $fh;
}

sub _send_fh_response ($self, $fh, $offset, $length, $chunked) {
    # Seek to offset if specified
    if ($offset && $offset > 0) {
        seek($fh, $offset, 0) or do {
            $self->_log(error => "Cannot seek to offset $offset: $!");
            die "Cannot seek: $!";
        };
    }

    # Calculate how much to read
    my $remaining = $length;  # undef means read to EOF

    # Stream in chunks
    while (1) {
        my $to_read = FILE_CHUNK_SIZE;
        if (defined $remaining) {
            $to_read = $remaining if $remaining < $to_read;
            last if $to_read <= 0;
        }

        my $bytes_read = read($fh, my $chunk, $to_read);

        last if !defined $bytes_read;  # Error
        last if $bytes_read == 0;      # EOF

        if ($chunked) {
            my $len = sprintf("%x", length($chunk));
            $self->{stream}->write("$len\r\n$chunk\r\n");
        }
        else {
            $self->{stream}->write($chunk);
        }

        if (defined $remaining) {
            $remaining -= $bytes_read;
        }
    }

    # Send final chunk if chunked encoding
    if ($chunked) {
        $self->{stream}->write("0\r\n\r\n");
    }
}
```

**Step 6: Run file response tests**

```bash
prove -l t/42-file-response.t -v
```

Expected: All PASS

**Step 7: Run full test suite for regressions**

```bash
prove -l t/
```

Expected: All PASS

**Step 8: Commit implementation**

```bash
git add lib/PAGI/Server/Connection.pm
git commit -m "feat(server): implement file and fh response body streaming

- Add _send_file_response() for path-based file responses
- Add _send_fh_response() for filehandle-based responses
- Support offset and length for range requests
- Stream in 64KB chunks to avoid memory bloat
- Works with both chunked and fixed-length transfer encoding"
```

---

## Task 4: Add Security Tests for PAGI::App::File

**Files:**
- Modify: `t/app-file.t`

**Step 1: Run existing app-file tests**

```bash
prove -l t/app-file.t -v
```

Expected: PASS (understand current coverage)

**Step 2: Read current test file**

Read `t/app-file.t` to understand existing tests.

**Step 3: Add security tests**

Append to `t/app-file.t`:

```perl
subtest 'security: null byte injection blocked' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => PAGI::App::File->new(root => $test_dir)->to_app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Try null byte injection
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    # Send path with null byte (trying to bypass extension check)
    print $sock "GET /test.txt\x00.jpg HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 (400|403|404)/, 'null byte injection blocked');

    $server->shutdown->get;
};

subtest 'security: path traversal with encoded dots blocked' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => PAGI::App::File->new(root => $test_dir)->to_app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    # Various traversal attempts
    print $sock "GET /../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 (403|404)/, 'path traversal blocked');
    unlike($response, qr/root:/, 'did not expose /etc/passwd');

    $server->shutdown->get;
};

subtest 'security: triple dots blocked' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => PAGI::App::File->new(root => $test_dir)->to_app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET /foo/.../bar HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 (403|404)/, 'triple dots blocked');

    $server->shutdown->get;
};

subtest 'security: backslash traversal blocked' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => PAGI::App::File->new(root => $test_dir)->to_app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET /..\\..\\etc\\passwd HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $loop->loop_once(0.1);

    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    like($response, qr/HTTP\/1\.1 (403|404)/, 'backslash traversal blocked');

    $server->shutdown->get;
};
```

**Step 4: Run security tests to see failures**

```bash
prove -l t/app-file.t -v
```

Expected: Some security tests may FAIL (current implementation may not catch all cases)

**Step 5: Commit security tests**

```bash
git add t/app-file.t
git commit -m "test(app-file): add security tests for path traversal and injection"
```

---

## Task 5: Harden PAGI::App::File Path Validation

**Files:**
- Modify: `lib/PAGI/App/File.pm`

**Step 1: Run security tests**

```bash
prove -l t/app-file.t -v
```

Note which tests fail.

**Step 2: Read current path handling**

Read `lib/PAGI/App/File.pm` lines 76-102 to understand current path validation.

**Step 3: Replace path validation with hardened version**

Replace lines 76-102 in `lib/PAGI/App/File.pm` with:

```perl
        my $path = $scope->{path} // '/';

        # Security: Check for null bytes (Plack::App::File pattern)
        if ($path =~ /\0/) {
            await $self->_send_error($send, 400, 'Bad Request');
            return;
        }

        # Security: Split path on both forward and back slashes
        # The -1 limit is CRITICAL to preserve trailing empty strings for security
        my @path_parts = split /[\\\/]/, $path, -1;

        # Remove leading empty string from absolute path
        shift @path_parts if @path_parts && $path_parts[0] eq '';

        # Security: Block any component that is two or more dots (.. , ..., etc)
        # This is stricter than just checking for '..'
        if (grep { /^\.{2,}$/ } @path_parts) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        # Security: Block hidden files (starting with .)
        if (grep { /^\./ && $_ ne '.' } @path_parts) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        # Reconstruct safe path using File::Spec
        my $file_path;
        if (@path_parts) {
            $file_path = File::Spec->catfile($root, @path_parts);
        } else {
            $file_path = $root;
        }

        # Check for index files if directory
        if (-d $file_path) {
            for my $index (@{$self->{index}}) {
                my $index_path = File::Spec->catfile($file_path, $index);
                if (-f $index_path) {
                    $file_path = $index_path;
                    last;
                }
            }
        }

        # Security: Verify the resolved path is under root
        # This catches symlink escapes
        my $real_root = Cwd::realpath($root) // $root;
        my $real_path = Cwd::realpath($file_path);

        if (!$real_path || index($real_path, $real_root) != 0) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        unless (-f $real_path && -r $real_path) {
            await $self->_send_error($send, 404, 'Not Found');
            return;
        }

        # Use real_path from here on
        $file_path = $real_path;
```

**Step 4: Add required imports**

At the top of `lib/PAGI/App/File.pm`, after existing `use` statements, add:

```perl
use File::Spec;
use Cwd ();
```

And remove or comment out `use PAGI::Util::AsyncFile;` if no longer needed.

**Step 5: Run security tests**

```bash
prove -l t/app-file.t -v
```

Expected: All security tests PASS

**Step 6: Run full test suite**

```bash
prove -l t/
```

Expected: All PASS

**Step 7: Commit security hardening**

```bash
git add lib/PAGI/App/File.pm
git commit -m "security(app-file): harden path validation against traversal attacks

- Add null byte injection check (CVE prevention)
- Split on both / and \\ to prevent backslash traversal
- Use -1 limit in split to preserve trailing empties (critical)
- Block components with 2+ dots (.. , ..., etc)
- Block hidden files (starting with .)
- Verify resolved path stays under root (symlink escape prevention)
- Use Cwd::realpath for canonical path comparison"
```

---

## Task 6: Convert PAGI::App::File to Use File Response

**Files:**
- Modify: `lib/PAGI/App/File.pm`

**Step 1: Run existing tests**

```bash
prove -l t/app-file.t -v
```

Expected: All PASS

**Step 2: Read current file serving code**

Read `lib/PAGI/App/File.pm` lines 125-195 to understand current file serving.

**Step 3: Replace file serving with file response**

Replace the full file response section (after range handling, around lines 168-195) with:

```perl
        # Full file response using file response type
        my @stat = stat($file_path);
        my $size = $stat[7];
        my $mtime = $stat[9];
        my $etag = '"' . md5_hex("$mtime-$size") . '"';

        # Check If-None-Match for caching
        my $if_none_match = $self->_get_header($scope, 'if-none-match');
        if ($if_none_match && $if_none_match eq $etag) {
            await $send->({
                type => 'http.response.start',
                status => 304,
                headers => [['etag', $etag]],
            });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
            return;
        }

        # Determine MIME type
        my ($ext) = $file_path =~ /\.([^.]+)$/;
        my $content_type = $MIME_TYPES{lc($ext // '')} // $self->{default_type};

        # Check for Range request
        my $range = $self->_get_header($scope, 'range');
        if ($range && $range =~ /bytes=(\d*)-(\d*)/) {
            my ($start, $end) = ($1, $2);
            $start = 0 if $start eq '';
            $end = $size - 1 if $end eq '' || $end >= $size;

            if ($start > $end || $start >= $size) {
                await $self->_send_error($send, 416, 'Range Not Satisfiable');
                return;
            }

            my $length = $end - $start + 1;

            await $send->({
                type => 'http.response.start',
                status => 206,
                headers => [
                    ['content-type', $content_type],
                    ['content-length', $length],
                    ['content-range', "bytes $start-$end/$size"],
                    ['accept-ranges', 'bytes'],
                    ['etag', $etag],
                ],
            });

            # Use file response with offset/length for range
            if ($method ne 'HEAD') {
                await $send->({
                    type => 'http.response.body',
                    file => $file_path,
                    offset => $start,
                    length => $length,
                    more => 0,
                });
            } else {
                await $send->({ type => 'http.response.body', body => '', more => 0 });
            }
            return;
        }

        # Full file response
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [
                ['content-type', $content_type],
                ['content-length', $size],
                ['accept-ranges', 'bytes'],
                ['etag', $etag],
            ],
        });

        if ($method ne 'HEAD') {
            await $send->({
                type => 'http.response.body',
                file => $file_path,
                more => 0,
            });
        } else {
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }
```

**Step 4: Remove AsyncFile import**

Remove or comment out this line near the top:

```perl
# use PAGI::Util::AsyncFile;  # No longer needed - using file response
```

Also remove the `use IO::Async::Loop;` if it's only used for AsyncFile.

**Step 5: Run app-file tests**

```bash
prove -l t/app-file.t -v
```

Expected: All PASS

**Step 6: Run full test suite**

```bash
prove -l t/
```

Expected: All PASS

**Step 7: Commit conversion**

```bash
git add lib/PAGI/App/File.pm
git commit -m "refactor(app-file): use file response for streaming

- Replace in-memory file reading with file response type
- Server now handles streaming in chunks (no memory bloat)
- Range requests use offset/length parameters
- Remove dependency on PAGI::Util::AsyncFile
- Enables sendfile() optimization in server"
```

---

## Task 7: Add Large File Streaming Test

**Files:**
- Modify: `t/42-file-response.t`

**Step 1: Run existing tests**

```bash
prove -l t/42-file-response.t -v
```

Expected: All PASS

**Step 2: Add large file test**

Append to `t/42-file-response.t`:

```perl
subtest 'large file streams without memory bloat' => sub {
    my $loop = IO::Async::Loop->new;

    # Create a 1MB test file
    my $large_file = "$tempdir/large.bin";
    my $large_size = 1024 * 1024;  # 1MB
    open my $fh, '>:raw', $large_file or die;
    for (1..1024) {
        print $fh ('X' x 1024);  # 1KB at a time
    }
    close $fh;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', $large_size],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $large_file,
                more => 0,
            });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
    ) or die;

    print $sock "GET /large.bin HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    # Read response in chunks
    my $total_body = 0;
    my $headers_done = 0;
    my $buffer = '';

    while (1) {
        $loop->loop_once(0.01);
        my $chunk;
        my $bytes = sysread($sock, $chunk, 65536);
        last if !defined $bytes || $bytes == 0;
        $buffer .= $chunk;

        if (!$headers_done && $buffer =~ /\r\n\r\n/) {
            my ($headers, $body) = split /\r\n\r\n/, $buffer, 2;
            $headers_done = 1;
            $total_body = length($body);
            $buffer = '';
        } elsif ($headers_done) {
            $total_body += length($chunk);
        }
    }
    close $sock;

    is($total_body, $large_size, 'received full 1MB file');

    $server->shutdown->get;

    unlink $large_file;
};
```

**Step 3: Run large file test**

```bash
prove -l t/42-file-response.t -v
```

Expected: All PASS

**Step 4: Run full test suite**

```bash
prove -l t/
```

Expected: All PASS

**Step 5: Commit large file test**

```bash
git add t/42-file-response.t
git commit -m "test: add large file streaming test (1MB)"
```

---

## Task 8: Update Documentation

**Files:**
- Modify: `lib/PAGI/Server.pm` (POD)
- Modify: `lib/PAGI/App/File.pm` (POD)

**Step 1: Run tests**

```bash
prove -l t/
```

Expected: All PASS

**Step 2: Add file response documentation to Server.pm**

Find the POD section about response events and add:

```perl
=head2 File Response Streaming

PAGI::Server supports efficient file streaming via the C<file> and C<fh>
keys in C<http.response.body> events:

    # Stream entire file
    await $send->({
        type => 'http.response.body',
        file => '/path/to/file.mp4',
        more => 0,
    });

    # Stream partial file (for Range requests)
    await $send->({
        type => 'http.response.body',
        file => '/path/to/file.mp4',
        offset => 1000,
        length => 5000,
        more => 0,
    });

    # Stream from filehandle
    open my $fh, '<:raw', $file;
    await $send->({
        type => 'http.response.body',
        fh => $fh,
        length => $size,
        more => 0,
    });
    close $fh;

The server streams files in 64KB chunks to avoid memory bloat.
On supported platforms, sendfile() may be used for zero-copy I/O.

=cut
```

**Step 3: Update PAGI::App::File POD**

Update the description in `lib/PAGI/App/File.pm`:

```perl
=head1 DESCRIPTION

PAGI::App::File serves static files from a configured root directory.

Features:

=over 4

=item * Efficient streaming (no memory bloat for large files)

=item * ETag caching with If-None-Match support

=item * Range requests (HTTP 206 Partial Content)

=item * Automatic MIME type detection

=item * Security hardening against path traversal attacks

=back

=head2 Security

This module implements multiple layers of path traversal protection:

=over 4

=item * Null byte injection blocking

=item * Double-dot and triple-dot component blocking

=item * Backslash normalization (Windows path separator)

=item * Hidden file blocking (dotfiles)

=item * Symlink escape detection via realpath verification

=back

=cut
```

**Step 4: Verify docs render**

```bash
perldoc lib/PAGI/Server.pm | grep -A 20 "File Response"
perldoc lib/PAGI/App/File.pm | head -50
```

**Step 5: Run full test suite**

```bash
prove -l t/
```

Expected: All PASS

**Step 6: Commit documentation**

```bash
git add lib/PAGI/Server.pm lib/PAGI/App/File.pm
git commit -m "docs: document file response streaming and App::File security"
```

---

## Summary

After completing all tasks, PAGI will have:

| Feature | Implementation | Location |
|---------|---------------|----------|
| Spec: file/fh response | `file`, `fh`, `offset`, `length` keys | docs/specs/www.mkdn |
| Server: file streaming | `_send_file_response()`, `_send_fh_response()` | Connection.pm |
| Server: 64KB chunking | `FILE_CHUNK_SIZE` constant | Connection.pm |
| App::File: security | Null byte, traversal, symlink checks | App/File.pm |
| App::File: streaming | Uses file response type | App/File.pm |

**Security improvements from Plack::App::File:**
- Null byte injection blocking
- Split on `[\\\/]` with `-1` limit
- Block `..`, `...`, etc. components
- Hidden file blocking
- Symlink escape via realpath verification

**Total: 8 tasks, ~400 lines of code + tests + docs**
