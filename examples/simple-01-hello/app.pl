#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';

# PAGI::Simple Hello World Example
# Run with: pagi-server --app examples/simple-01-hello/app.pl

use PAGI::Simple;

my $app = PAGI::Simple->new(name => 'Hello World');

# Simple text response
$app->get('/' => sub ($c) {
    $c->text("Hello, World!");
});

# Greet by name using path parameter
$app->get('/greet/:name' => sub ($c) {
    my $name = $c->path_params->{name};
    $c->text("Hello, $name!");
});

# JSON response
$app->get('/json' => sub ($c) {
    $c->json({
        message => "Hello, World!",
        timestamp => time(),
    });
});

# HTML response
$app->get('/html' => sub ($c) {
    $c->html(<<'HTML');
<!DOCTYPE html>
<html>
<head><title>Hello</title></head>
<body>
    <h1>Hello, World!</h1>
    <p>Welcome to PAGI::Simple!</p>
</body>
</html>
HTML
});

# Query parameters
$app->get('/search' => sub ($c) {
    my $q = $c->req->query_param('q') // '';
    $c->json({
        query => $q,
        results => ["Result for: $q"],
    });
});

# Status code and headers
$app->get('/created' => sub ($c) {
    $c->res_header('X-Custom-Header' => 'Custom Value');
    $c->status(201)->json({ status => 'created' });
});

# Redirect
$app->get('/old-path' => sub ($c) {
    $c->redirect('/');
});

# Custom error handler
$app->error(404 => sub ($c, $msg = undef) {
    $c->status(404)->json({
        error => 'Not Found',
        path => $c->path,
    });
});

# Return the PAGI app
$app->to_app;
