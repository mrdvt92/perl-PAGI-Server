#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use experimental 'signatures';

use Future::AsyncAwait;
use PAGI::Simple;

# Run with:
#   pagi-server --app examples/simple-14-streaming/app.pl --port 5000

my $app = PAGI::Simple->new(name => 'PAGI::Simple streaming bodies');

my $UPLOAD_PATH   = '/tmp/pagi-simple-stream-upload.bin';
my $DEFAULT_LIMIT = 256 * 1024; # 256KB safety cap

$app->get('/' => async sub ($c) {
    return $c->html(_page());
});

$app->post('/stream/decode' => async sub ($c) {
    my $strict = $c->req->query_param('strict') ? 1 : 0;
    my $limit  = $c->req->query_param('limit');
    my $max_bytes = defined $limit ? $limit : $DEFAULT_LIMIT;

    my $stream = eval {
        $c->body_stream(
            decode    => 'UTF-8',
            strict    => $strict,
            max_bytes => $max_bytes,
        );
    };
    return await _stream_error($c, $@) if $@;

    my @chunks;
    my $err;
    eval {
        while (!$stream->is_done) {
            my $chunk = await $stream->next_chunk;
            push @chunks, $chunk if defined $chunk;
        }
        1;
    } or $err = $@;

    return await _stream_error($c, $err) if $err;

    return $c->json({
        decoded        => join('', @chunks),
        bytes_read     => $stream->bytes_read,
        strict         => $strict ? 1 : 0,
        limit_bytes    => $max_bytes,
        content_length => $c->req->content_length,
    });
});

$app->post('/stream/upload' => async sub ($c) {
    my $limit = $c->req->query_param('limit');
    my $max_bytes = defined $limit ? $limit : ($c->req->content_length // $DEFAULT_LIMIT);

    my $stream = eval { $c->body_stream(max_bytes => $max_bytes) };
    return await _stream_error($c, $@) if $@;

    my $bytes = eval { await $stream->stream_to_file($UPLOAD_PATH) };
    return await _stream_error($c, $@) if $@;

    return $c->json({
        saved_to       => $UPLOAD_PATH,
        bytes_written  => $bytes,
        limit_bytes    => $max_bytes,
        content_length => $c->req->content_length,
    });
});

async sub _stream_error ($c, $err) {
    my $msg = "$err";
    $msg =~ s/\s+at \S+ line \d+.*$//s;
    my $status = $msg =~ /exceeded/i ? 413 : 400;
    return $c->status($status)->json({ error => $msg });
}

sub _page {
    return <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>PAGI::Simple Streaming Bodies</title>
  <style>
    :root { color-scheme: light; }
    body { font-family: "Segoe UI", "Helvetica Neue", system-ui, sans-serif; background: #0b132b; color: #f5f7ff; margin: 0; padding: 2rem; }
    h1, h2 { margin: 0 0 0.5rem 0; }
    p { margin: 0.25rem 0 1rem 0; }
    section { background: #1c2541; border: 1px solid #3a506b; border-radius: 10px; padding: 1rem; margin-bottom: 1rem; box-shadow: 0 10px 30px rgba(0,0,0,0.25); }
    label { display: block; margin: 0.5rem 0 0.25rem 0; font-weight: 600; }
    textarea, input[type="number"], input[type="file"] { width: 100%; box-sizing: border-box; border-radius: 6px; border: 1px solid #3a506b; background: #0b132b; color: #f5f7ff; padding: 0.5rem; }
    button { background: linear-gradient(90deg, #5bc0be, #29a19c); border: none; color: #0b132b; padding: 0.6rem 1rem; border-radius: 6px; font-weight: 700; cursor: pointer; margin-right: 0.5rem; }
    button.secondary { background: #3a506b; color: #f5f7ff; }
    pre { background: #0b132b; border: 1px solid #3a506b; border-radius: 8px; padding: 0.75rem; overflow-x: auto; }
    small { color: #cbd5e1; }
  </style>
</head>
<body>
  <h1>PAGI::Simple Streaming Request Bodies</h1>
  <p>Send raw POST bodies without buffering. Try decoded text, strict UTF-8, and streaming to disk.</p>

  <section id="decode">
    <h2>Stream + Decode UTF-8</h2>
    <p>Reads the body in chunks with <code>decode =&gt; 'UTF-8'</code>. Set a limit to test the guard.</p>
    <form id="decode-form">
      <label for="decode-input">Text to stream</label>
      <textarea id="decode-input" rows="4">hello café 🌶️ streaming</textarea>

      <label for="decode-limit">Max bytes (default ${DEFAULT_LIMIT})</label>
      <input id="decode-limit" type="number" min="1" placeholder="${DEFAULT_LIMIT}" />

      <div style="margin-top: 0.75rem;">
        <button type="submit" data-strict="0">Send (lenient)</button>
        <button type="submit" data-strict="1" class="secondary">Send (strict)</button>
      </div>
    </form>
    <pre id="decode-output">Waiting...</pre>
  </section>

  <section id="upload">
    <h2>Stream to File</h2>
    <p>Streams the request body directly to <code>$UPLOAD_PATH</code> using <code>stream_to_file</code>.</p>
    <form id="upload-form">
      <label for="upload-file">Pick a file (or leave blank to stream the fallback text)</label>
      <input id="upload-file" type="file" />

      <label for="upload-fallback">Fallback body (used when no file is chosen)</label>
      <textarea id="upload-fallback" rows="3">some raw bytes to stream</textarea>

      <label for="upload-limit">Max bytes (defaults to content-length or ${DEFAULT_LIMIT})</label>
      <input id="upload-limit" type="number" min="1" placeholder="${DEFAULT_LIMIT}" />

      <div style="margin-top: 0.75rem;">
        <button type="submit">Upload</button>
      </div>
    </form>
    <pre id="upload-output">Waiting...</pre>
  </section>

  <script>
    const decodeForm = document.getElementById('decode-form');
    const decodeOutput = document.getElementById('decode-output');
    decodeForm.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const strict = ev.submitter?.dataset.strict === '1';
      const limit = document.getElementById('decode-limit').value;
      const params = new URLSearchParams();
      if (strict) params.set('strict', '1');
      if (limit) params.set('limit', limit);

      const res = await fetch('/stream/decode?' + params.toString(), {
        method: 'POST',
        headers: { 'content-type': 'text/plain; charset=utf-8' },
        body: document.getElementById('decode-input').value,
      });

      const payload = await res.text();
      try {
        decodeOutput.textContent = JSON.stringify(JSON.parse(payload), null, 2);
      } catch (_) {
        decodeOutput.textContent = payload;
      }
    });

    const uploadForm = document.getElementById('upload-form');
    const uploadOutput = document.getElementById('upload-output');
    uploadForm.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const fileInput = document.getElementById('upload-file');
      const limit = document.getElementById('upload-limit').value;
      const params = new URLSearchParams();
      if (limit) params.set('limit', limit);

      let body;
      if (fileInput.files && fileInput.files.length) {
        body = fileInput.files[0];
      } else {
        body = new Blob([document.getElementById('upload-fallback').value], { type: 'text/plain' });
      }

      const res = await fetch('/stream/upload?' + params.toString(), {
        method: 'POST',
        body,
      });

      const payload = await res.text();
      try {
        uploadOutput.textContent = JSON.stringify(JSON.parse(payload), null, 2);
      } catch (_) {
        uploadOutput.textContent = payload;
      }
    });
  </script>
</body>
</html>
HTML
}

$app->to_app;
