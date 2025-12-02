use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: SSE Notifications Example App

use FindBin qw($Bin);
use lib "$Bin/../../../lib";

my $app_file = "$Bin/../../../examples/simple-04-sse/app.pl";
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
    my $headers = $opts{headers} // [];
    my $body = $opts{body} // '';

    my @sent;
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => $path,
        headers => $headers,
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

# Helper to simulate SSE connection
sub simulate_sse ($app, %opts) {
    my $path = $opts{path} // '/events';

    my @sent;
    my $scope = {
        type    => 'sse',
        path    => $path,
        headers => [],
    };

    my $disconnected = 0;
    my $receive = sub {
        if (!$disconnected) {
            $disconnected = 1;
            return Future->done({ type => 'sse.disconnect' });
        }
        return Future->done({ type => 'sse.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    $app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
    };
}

# Test 1: Home page shows notifications UI
subtest 'home page shows notifications UI' => sub {
    my $result = simulate_http($pagi_app, path => '/');

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/SSE Notifications/, 'has title');
    like($result->{body}, qr/EventSource/, 'has EventSource code');
    like($result->{body}, qr/\/events/, 'has events endpoint');
};

# Test 2: SSE stream starts correctly
subtest 'sse stream starts' => sub {
    my $result = simulate_sse($pagi_app, path => '/events');

    # Find the start event
    my ($start) = grep { $_->{type} eq 'sse.start' } @{$result->{sent}};
    ok($start, 'SSE stream started');
    is($start->{status}, 200, 'status 200');

    # Check headers
    my %headers = map { @$_ } @{$start->{headers}};
    is($headers{'content-type'}, 'text/event-stream', 'content-type is text/event-stream');
};

# Test 3: SSE sends welcome event
subtest 'sse sends welcome event' => sub {
    my $result = simulate_sse($pagi_app, path => '/events');

    # Find send events
    my @sends = grep { $_->{type} eq 'sse.send' } @{$result->{sent}};
    ok(@sends > 0, 'got send events');

    # First send should be welcome
    my $welcome = $sends[0];
    like($welcome->{data}, qr/Connected/, 'welcome message');
    is($welcome->{event}, 'notification', 'event type is notification');
    ok($welcome->{id}, 'has event id');
};

# Test 4: User-specific SSE endpoint
subtest 'user-specific sse endpoint' => sub {
    my $result = simulate_sse($pagi_app, path => '/events/alice');

    my @sends = grep { $_->{type} eq 'sse.send' } @{$result->{sent}};
    ok(@sends > 0, 'got send events');

    # Welcome should include user name
    my $welcome = $sends[0];
    like($welcome->{data}, qr/alice/, 'welcome includes user name');
    is($welcome->{event}, 'welcome', 'event type is welcome');
};

# Test 5: Trigger endpoint
subtest 'trigger endpoint' => sub {
    # Clear pubsub state first
    use PAGI::Simple::PubSub;
    PAGI::Simple::PubSub->instance->{channels} = {};

    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/trigger',
        headers => [['content-type', 'application/json']],
        body => '{"type":"notification","text":"Test notification"}',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"success"\s*:\s*1/, 'success');
    like($result->{body}, qr/Test notification/, 'published message');
};

# Test 6: Notify specific user endpoint
subtest 'notify user endpoint' => sub {
    use PAGI::Simple::PubSub;
    PAGI::Simple::PubSub->instance->{channels} = {};

    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/notify/bob',
        headers => [['content-type', 'application/json']],
        body => '{"text":"Hello Bob!"}',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"success"/, 'has success field');
    like($result->{body}, qr/"recipients"/, 'has recipients field');
};

# Test 7: Broadcast endpoint
subtest 'broadcast endpoint' => sub {
    use PAGI::Simple::PubSub;
    PAGI::Simple::PubSub->instance->{channels} = {};

    my $result = simulate_http($pagi_app,
        method => 'POST',
        path => '/broadcast',
        headers => [['content-type', 'application/json']],
        body => '{"text":"Broadcast message"}',
    );

    is($result->{status}, 200, 'status 200');
    like($result->{body}, qr/"success"\s*:\s*1/, 'success');
    like($result->{body}, qr/"recipients"/, 'has recipients field');
};

# Test 8: SSE headers are correct
subtest 'sse headers' => sub {
    my $result = simulate_sse($pagi_app, path => '/events');

    my ($start) = grep { $_->{type} eq 'sse.start' } @{$result->{sent}};
    ok($start, 'got start event');

    my %headers = map { @$_ } @{$start->{headers}};
    is($headers{'cache-control'}, 'no-cache', 'cache-control is no-cache');
    is($headers{'connection'}, 'keep-alive', 'connection is keep-alive');
};

# Test 9: Event has ID
subtest 'event has id' => sub {
    my $result = simulate_sse($pagi_app, path => '/events');

    my @sends = grep { $_->{type} eq 'sse.send' } @{$result->{sent}};
    ok(@sends > 0, 'got send events');

    my $event = $sends[0];
    ok(defined $event->{id}, 'event has id');
    like($event->{id}, qr/^\d+$/, 'id is numeric');
};

# Test 10: Different users get different channels
subtest 'different user channels' => sub {
    use PAGI::Simple::PubSub;
    PAGI::Simple::PubSub->instance->{channels} = {};

    # Connect as alice
    my $result1 = simulate_sse($pagi_app, path => '/events/alice');
    my @sends1 = grep { $_->{type} eq 'sse.send' } @{$result1->{sent}};

    # Connect as bob
    my $result2 = simulate_sse($pagi_app, path => '/events/bob');
    my @sends2 = grep { $_->{type} eq 'sse.send' } @{$result2->{sent}};

    # Each should have their own welcome
    like($sends1[0]{data}, qr/alice/, 'alice got her welcome');
    like($sends2[0]{data}, qr/bob/, 'bob got his welcome');
};

done_testing;
