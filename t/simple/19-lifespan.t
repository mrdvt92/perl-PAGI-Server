use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Lifespan Hooks in PAGI::Simple

use PAGI::Simple;

# Helper to simulate lifespan events
sub simulate_lifespan ($app, @events) {
    my @sent;
    my $event_index = 0;

    my $scope = { type => 'lifespan' };

    my $receive = sub {
        if ($event_index < @events) {
            return Future->done($events[$event_index++]);
        }
        # Default to shutdown after all events consumed
        return Future->done({ type => 'lifespan.shutdown' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
    };
}

# Test 1: on() method exists
subtest 'on() method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('on'), 'app has on method');
};

# Test 2: Register startup hook
subtest 'register startup hook' => sub {
    my $app = PAGI::Simple->new;
    my $result = $app->on(startup => sub { });
    is($result, $app, 'on() returns $app for chaining');
};

# Test 3: Register shutdown hook
subtest 'register shutdown hook' => sub {
    my $app = PAGI::Simple->new;
    my $result = $app->on(shutdown => sub { });
    is($result, $app, 'on() returns $app for chaining');
};

# Test 4: Unknown event type dies
subtest 'unknown event type dies' => sub {
    my $app = PAGI::Simple->new;
    my $died = 0;

    eval { $app->on(unknown => sub { }) };
    $died = 1 if $@;

    ok($died, 'unknown event type dies');
    like($@, qr/Unknown lifecycle event/, 'error message correct');
};

# Test 5: Startup hook called on lifespan.startup
subtest 'startup hook called' => sub {
    my $app = PAGI::Simple->new;
    my $startup_called = 0;

    $app->on(startup => sub ($app) {
        $startup_called = 1;
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    ok($startup_called, 'startup hook was called');
};

# Test 6: Shutdown hook called on lifespan.shutdown
subtest 'shutdown hook called' => sub {
    my $app = PAGI::Simple->new;
    my $shutdown_called = 0;

    $app->on(shutdown => sub ($app) {
        $shutdown_called = 1;
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    ok($shutdown_called, 'shutdown hook was called');
};

# Test 7: Startup hook receives $app
subtest 'startup hook receives app' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    my $received_app;

    $app->on(startup => sub ($a) {
        $received_app = $a;
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    is($received_app, $app, 'hook received app instance');
    is($received_app->name, 'TestApp', 'can access app properties');
};

# Test 8: Shutdown hook receives $app
subtest 'shutdown hook receives app' => sub {
    my $app = PAGI::Simple->new;
    my $received_app;

    $app->on(shutdown => sub ($a) {
        $received_app = $a;
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    is($received_app, $app, 'hook received app instance');
};

# Test 9: Multiple startup hooks execute in order
subtest 'multiple startup hooks in order' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->on(startup => sub { push @order, 'first' });
    $app->on(startup => sub { push @order, 'second' });
    $app->on(startup => sub { push @order, 'third' });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    is(\@order, ['first', 'second', 'third'], 'hooks run in registration order');
};

# Test 10: Multiple shutdown hooks execute in order
subtest 'multiple shutdown hooks in order' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->on(shutdown => sub { push @order, 'first' });
    $app->on(shutdown => sub { push @order, 'second' });
    $app->on(shutdown => sub { push @order, 'third' });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    is(\@order, ['first', 'second', 'third'], 'hooks run in registration order');
};

# Test 11: Startup complete sent after hooks
subtest 'startup complete sent' => sub {
    my $app = PAGI::Simple->new;

    $app->on(startup => sub { });

    my $result = simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    my @startup_complete = grep { $_->{type} eq 'lifespan.startup.complete' } @{$result->{sent}};
    is(scalar @startup_complete, 1, 'lifespan.startup.complete sent');
};

# Test 12: Shutdown complete sent after hooks
subtest 'shutdown complete sent' => sub {
    my $app = PAGI::Simple->new;

    $app->on(shutdown => sub { });

    my $result = simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    my @shutdown_complete = grep { $_->{type} eq 'lifespan.shutdown.complete' } @{$result->{sent}};
    is(scalar @shutdown_complete, 1, 'lifespan.shutdown.complete sent');
};

# Test 13: App stash accessible in startup hook
subtest 'app stash in startup hook' => sub {
    my $app = PAGI::Simple->new;

    $app->on(startup => sub ($a) {
        $a->stash->{db} = 'database_connection';
        $a->stash->{initialized} = 1;
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    is($app->stash->{db}, 'database_connection', 'stash set in hook');
    is($app->stash->{initialized}, 1, 'stash value persists');
};

# Test 14: App stash accessible in shutdown hook
subtest 'app stash in shutdown hook' => sub {
    my $app = PAGI::Simple->new;
    my $cleanup_done = 0;

    $app->on(startup => sub ($a) {
        $a->stash->{resource} = 'open';
    });

    $app->on(shutdown => sub ($a) {
        if ($a->stash->{resource} eq 'open') {
            $a->stash->{resource} = 'closed';
            $cleanup_done = 1;
        }
    });

    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    ok($cleanup_done, 'shutdown hook saw startup data');
    is($app->stash->{resource}, 'closed', 'resource cleaned up');
};

# Test 15: Startup error sends startup.failed
subtest 'startup error sends failed' => sub {
    my $app = PAGI::Simple->new;

    $app->on(startup => sub {
        die "Database connection failed";
    });

    my $result = simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    my @failed = grep { $_->{type} eq 'lifespan.startup.failed' } @{$result->{sent}};
    is(scalar @failed, 1, 'lifespan.startup.failed sent');
    like($failed[0]{message}, qr/Database connection failed/, 'error message included');
};

# Test 16: No startup.complete after startup failure
subtest 'no complete after failure' => sub {
    my $app = PAGI::Simple->new;

    $app->on(startup => sub {
        die "Startup failed";
    });

    my $result = simulate_lifespan($app,
        { type => 'lifespan.startup' },
    );

    my @complete = grep { $_->{type} eq 'lifespan.startup.complete' } @{$result->{sent}};
    is(scalar @complete, 0, 'lifespan.startup.complete not sent');
};

# Test 17: Shutdown still completes even if hook errors
subtest 'shutdown completes on error' => sub {
    my $app = PAGI::Simple->new;

    $app->on(shutdown => sub {
        die "Cleanup failed";
    });

    my $result = simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    my @complete = grep { $_->{type} eq 'lifespan.shutdown.complete' } @{$result->{sent}};
    is(scalar @complete, 1, 'lifespan.shutdown.complete still sent');
};

# Test 18: Method chaining works
subtest 'method chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app
        ->on(startup => sub { })
        ->on(shutdown => sub { })
        ->on(startup => sub { });

    is($result, $app, 'chained on() calls return $app');
};

# Test 19: Hooks not called for HTTP requests
subtest 'hooks not called for http' => sub {
    my $app = PAGI::Simple->new;
    my $startup_called = 0;
    my $shutdown_called = 0;

    $app->on(startup => sub { $startup_called = 1 });
    $app->on(shutdown => sub { $shutdown_called = 1 });

    $app->get('/' => sub ($c) {
        $c->text('Hello');
    });

    # Simulate HTTP request instead of lifespan
    my @sent;
    my $scope = { type => 'http', method => 'GET', path => '/' };

    my $receive = sub {
        Future->done({ type => 'http.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    ok(!$startup_called, 'startup hook not called for HTTP');
    ok(!$shutdown_called, 'shutdown hook not called for HTTP');
};

# Test 20: Integration - startup initializes data used in routes
subtest 'integration: startup data in routes' => sub {
    my $app = PAGI::Simple->new;
    my $config_used;

    $app->on(startup => sub ($a) {
        $a->stash->{config} = { version => '1.0', env => 'test' };
    });

    $app->get('/version' => sub ($c) {
        my $version = $c->app->stash->{config}{version};
        $config_used = $version;
        $c->text("Version: $version");
    });

    # First simulate lifespan startup
    simulate_lifespan($app,
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );

    # Check stash was set
    is($app->stash->{config}{version}, '1.0', 'config set by startup');

    # Simulate HTTP request
    my @sent;
    my $scope = { type => 'http', method => 'GET', path => '/version' };

    my $send = sub ($event) {
        push @sent, $event;
        Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, sub { Future->done({ type => 'http.disconnect' }) }, $send)->get;

    is($config_used, '1.0', 'route accessed startup config');
};

done_testing;
