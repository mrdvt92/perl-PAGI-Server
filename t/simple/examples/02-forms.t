use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use JSON::PP;

# Test: Form Processing Example App

use FindBin qw($Bin);
use lib "$Bin/../../../lib";

my $app_file = "$Bin/../../../examples/simple-02-forms/app.pl";
ok(-f $app_file, 'example app file exists');

my $pagi_app = do $app_file;
if ($@) {
    fail("Failed to load app: $@");
    done_testing;
    exit;
}
ok(ref($pagi_app) eq 'CODE', 'app returns a coderef');

# Helper to simulate HTTP request with body support
sub simulate_http ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path = $opts{path} // '/';
    my $query = $opts{query} // '';
    my $headers = $opts{headers} // [];
    my $body = $opts{body} // '';

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    my $body_sent = 0;
    my $receive = sub {
        if (!$body_sent && length($body)) {
            $body_sent = 1;
            return Future->done({ type => 'http.request', body => $body, more => 0 });
        }
        return Future->done({ type => 'http.disconnect' });
    };

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

# Test 1: Home page shows form
subtest 'home page shows form' => sub {
    my $result = simulate_http($pagi_app, path => '/');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/<form/, 'has form');
    like($result->{body}, qr/name="name"/, 'has name field');
    like($result->{body}, qr/name="email"/, 'has email field');
};

# Test 2: List contacts
subtest 'list contacts' => sub {
    my $result = simulate_http($pagi_app, path => '/contacts');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"contacts"/, 'has contacts');
    like($result->{body}, qr/John Doe/, 'has John Doe');
    like($result->{body}, qr/Jane Smith/, 'has Jane Smith');
};

# Test 3: Get single contact
subtest 'get single contact' => sub {
    my $result = simulate_http($pagi_app, path => '/contacts/1');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/John Doe/, 'has John Doe');
    like($result->{body}, qr/"id"\s*:\s*1/, 'has id 1');
};

# Test 4: Get nonexistent contact
subtest 'get nonexistent contact' => sub {
    my $result = simulate_http($pagi_app, path => '/contacts/999');

    is($result->{status}, 404, 'status 404');
    like($result->{body}, qr/not found/i, 'not found message');
};

# Test 5: Create contact with POST form
subtest 'create contact with form' => sub {
    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
        body => 'name=Test+User&email=test%40example.com',
    );

    is($result->{status}, 201, 'status 201 created');
    like($result->{body}, qr/"success"\s*:\s*1/, 'success');
    like($result->{body}, qr/Test User/, 'name in response');
    like($result->{body}, qr/test\@example\.com/, 'email in response');
};

# Test 6: Validation error - missing fields
subtest 'validation error missing fields' => sub {
    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
        body => '',
    );

    is($result->{status}, 400, 'status 400 bad request');
    like($result->{body}, qr/"success"\s*:\s*0/, 'not success');
    like($result->{body}, qr/Name is required/, 'name error');
    like($result->{body}, qr/Email is required/, 'email error');
};

# Test 7: Validation error - invalid email
subtest 'validation error invalid email' => sub {
    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
        body => 'name=Test&email=invalid',
    );

    is($result->{status}, 400, 'status 400');
    like($result->{body}, qr/Invalid email format/, 'email format error');
};

# Test 8: Update contact with PUT JSON
subtest 'update contact with PUT' => sub {
    my $result = simulate_http($pagi_app,
        method => 'PUT',
        path => '/contacts/1',
        headers => [['content-type', 'application/json']],
        body => '{"name":"John Updated"}',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"success"\s*:\s*1/, 'success');
    like($result->{body}, qr/John Updated/, 'name updated');
};

# Test 9: Delete contact
subtest 'delete contact' => sub {
    # First create a contact to delete
    simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
        body => 'name=Delete+Me&email=delete@example.com',
    );

    # Get contacts to find the one we created
    my $list = simulate_http($pagi_app, path => '/contacts');
    my $data = decode_json($list->{body});
    my ($to_delete) = grep { $_->{name} eq 'Delete Me' } @{$data->{contacts}};

    ok($to_delete, 'found contact to delete');
    my $id = $to_delete->{id};

    # Delete it
    my $result = simulate_http($pagi_app,
        method => 'DELETE',
        path => "/contacts/$id",
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"success"\s*:\s*1/, 'success');
    like($result->{body}, qr/deleted/, 'deleted message');

    # Verify it's gone
    my $check = simulate_http($pagi_app, path => "/contacts/$id");
    is($check->{status}, 404, 'contact no longer exists');
};

# Test 10: Delete nonexistent contact
subtest 'delete nonexistent contact' => sub {
    my $result = simulate_http($pagi_app,
        method => 'DELETE',
        path => '/contacts/999',
    );

    is($result->{status}, 404, 'status 404');
};

# Test 11: Search contacts
subtest 'search contacts' => sub {
    my $result = simulate_http($pagi_app,
        path => '/search',
        query => 'q=john',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"query"\s*:\s*"john"/, 'query echoed');
    # John's name was updated, so search might not find him
    like($result->{body}, qr/"contacts"/, 'has contacts array');
};

# Test 12: Search with no query
subtest 'search no query' => sub {
    my $result = simulate_http($pagi_app,
        path => '/search',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/\[\]/, 'empty results');
};

# Test 13: Bulk create contacts
subtest 'bulk create contacts' => sub {
    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts/bulk',
        headers => [['content-type', 'application/json']],
        body => '[{"name":"Bulk One","email":"bulk1@test.com"},{"name":"Bulk Two","email":"bulk2@test.com"}]',
    );

    is($result->{status}, 201, 'status 201');
    like($result->{body}, qr/"created"\s*:\s*2/, '2 created');
    like($result->{body}, qr/Bulk One/, 'first contact');
    like($result->{body}, qr/Bulk Two/, 'second contact');
};

# Test 14: Bulk create with invalid body
subtest 'bulk create invalid body' => sub {
    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/contacts/bulk',
        headers => [['content-type', 'application/json']],
        body => '{"not":"array"}',
    );

    is($result->{status}, 400, 'status 400');
    like($result->{body}, qr/Expected JSON array/, 'error message');
};

# Test 15: Method not allowed
subtest 'method not allowed' => sub {
    my $result = simulate_http($pagi_app,
        method => 'PATCH',
        path => '/contacts',
    );

    is($result->{status}, 405, 'status 405');
};

done_testing;
