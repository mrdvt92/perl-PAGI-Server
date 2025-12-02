#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

# PAGI::Simple Form Processing Example
# Run with: pagi-server --app examples/simple-02-forms/app.pl

use PAGI::Simple;

my $app = PAGI::Simple->new(name => 'Form Example');

# In-memory "database" for demo
my @contacts = (
    { id => 1, name => 'John Doe', email => 'john@example.com' },
    { id => 2, name => 'Jane Smith', email => 'jane@example.com' },
);
my $next_id = 3;

# Show form
$app->get('/' => sub ($c) {
    $c->html(<<'HTML');
<!DOCTYPE html>
<html>
<head><title>Contact Form</title></head>
<body>
    <h1>Add Contact</h1>
    <form method="POST" action="/contacts">
        <p>
            <label>Name: <input type="text" name="name" required></label>
        </p>
        <p>
            <label>Email: <input type="email" name="email" required></label>
        </p>
        <button type="submit">Add Contact</button>
    </form>
    <p><a href="/contacts">View All Contacts</a></p>
</body>
</html>
HTML
});

# List contacts (JSON API)
$app->get('/contacts' => sub ($c) {
    $c->json({ contacts => \@contacts });
});

# Get single contact
$app->get('/contacts/:id' => sub ($c) {
    my $id = $c->path_params->{id};
    my ($contact) = grep { $_->{id} == $id } @contacts;

    if ($contact) {
        $c->json($contact);
    } else {
        $c->abort(404, "Contact $id not found");
    }
});

# Create contact (POST form data)
$app->post('/contacts' => async sub ($c) {
    my $name = await $c->param('name');
    my $email = await $c->param('email');

    # Validation
    my @errors;
    push @errors, 'Name is required' unless $name && length($name);
    push @errors, 'Email is required' unless $email && length($email);
    push @errors, 'Invalid email format' if $email && $email !~ /\@/;

    if (@errors) {
        $c->status(400)->json({
            success => 0,
            errors => \@errors
        });
        return;
    }

    # Create new contact
    my $contact = {
        id => $next_id++,
        name => $name,
        email => $email,
    };
    push @contacts, $contact;

    $c->status(201)->json({
        success => 1,
        contact => $contact
    });
});

# Update contact (PUT with JSON body)
$app->put('/contacts/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my ($contact) = grep { $_->{id} == $id } @contacts;

    unless ($contact) {
        $c->abort(404, "Contact $id not found");
    }

    my $body = await $c->req->json_body;

    # Update fields if provided
    $contact->{name} = $body->{name} if exists $body->{name};
    $contact->{email} = $body->{email} if exists $body->{email};

    $c->json({ success => 1, contact => $contact });
});

# Delete contact
$app->delete('/contacts/:id' => sub ($c) {
    my $id = $c->path_params->{id};
    my $before = scalar @contacts;
    @contacts = grep { $_->{id} != $id } @contacts;

    if (scalar @contacts < $before) {
        $c->json({ success => 1, message => "Contact $id deleted" });
    } else {
        $c->abort(404, "Contact $id not found");
    }
});

# Search contacts (query params)
$app->get('/search' => sub ($c) {
    my $q = lc($c->req->query_param('q') // '');

    return $c->json({ contacts => [] }) unless length($q);

    my @matches = grep {
        lc($_->{name}) =~ /\Q$q\E/ || lc($_->{email}) =~ /\Q$q\E/
    } @contacts;

    $c->json({ query => $q, contacts => \@matches });
});

# Bulk create (JSON array)
$app->post('/contacts/bulk' => async sub ($c) {
    my $body = await $c->req->json_body;

    unless (ref($body) eq 'ARRAY') {
        $c->abort(400, "Expected JSON array");
    }

    my @created;
    for my $item (@$body) {
        next unless $item->{name} && $item->{email};
        my $contact = {
            id => $next_id++,
            name => $item->{name},
            email => $item->{email},
        };
        push @contacts, $contact;
        push @created, $contact;
    }

    $c->status(201)->json({
        success => 1,
        created => scalar(@created),
        contacts => \@created,
    });
});

# Custom 404
$app->error(404 => sub ($c, $msg = undef) {
    $c->status(404)->json({
        error => 'Not Found',
        detail => $msg // 'Resource not found',
    });
});

# Custom 400
$app->error(400 => sub ($c, $msg = undef) {
    $c->status(400)->json({
        error => 'Bad Request',
        detail => $msg,
    });
});

# Return the PAGI app
$app->to_app;
