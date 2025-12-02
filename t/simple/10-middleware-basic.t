use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Basic middleware (hooks) in PAGI::Simple

use PAGI::Simple;

# Helper to simulate a PAGI HTTP request
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';

    my @sent;
    my $scope = {
        type   => 'http',
        method => $method,
        path   => $path,
    };

    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Test 1: hook() method exists
subtest 'hook method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('hook'), 'app has hook method');
};

# Test 2: before hook runs before handler
subtest 'before hook runs before handler' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app);

    is(\@order, ['before', 'handler'], 'before hook runs first');
};

# Test 3: after hook runs after handler
subtest 'after hook runs after handler' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(after => sub ($c) {
        push @order, 'after';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app);

    is(\@order, ['handler', 'after'], 'after hook runs after handler');
};

# Test 4: before and after hooks together
subtest 'before and after hooks together' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
    });

    $app->hook(after => sub ($c) {
        push @order, 'after';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app);

    is(\@order, ['before', 'handler', 'after'], 'hooks run in correct order');
};

# Test 5: Multiple before hooks run in order
subtest 'multiple before hooks run in order' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before1';
    });

    $app->hook(before => sub ($c) {
        push @order, 'before2';
    });

    $app->hook(before => sub ($c) {
        push @order, 'before3';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app);

    is(\@order, ['before1', 'before2', 'before3', 'handler'], 'before hooks run in registration order');
};

# Test 6: Multiple after hooks run in order
subtest 'multiple after hooks run in order' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    $app->hook(after => sub ($c) {
        push @order, 'after1';
    });

    $app->hook(after => sub ($c) {
        push @order, 'after2';
    });

    simulate_request($app);

    is(\@order, ['handler', 'after1', 'after2'], 'after hooks run in registration order');
};

# Test 7: before hook can short-circuit by responding
subtest 'before hook can short-circuit' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
        $c->status(403)->text('Forbidden');
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    my $sent = simulate_request($app);

    is(\@order, ['before'], 'handler not called after short-circuit');
    is($sent->[0]{status}, 403, 'response from before hook');
    is($sent->[1]{body}, 'Forbidden', 'body from before hook');
};

# Test 8: after hooks run even when short-circuited
subtest 'after hooks run after short-circuit' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
        $c->status(403)->text('Forbidden');
    });

    $app->hook(after => sub ($c) {
        push @order, 'after';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    simulate_request($app);

    is(\@order, ['before', 'after'], 'after hook runs even when short-circuited');
};

# Test 9: hooks can modify stash
subtest 'hooks can modify stash' => sub {
    my $app = PAGI::Simple->new;
    my $elapsed;

    $app->hook(before => sub ($c) {
        $c->stash->{start} = 100;
    });

    $app->hook(after => sub ($c) {
        $elapsed = 200 - $c->stash->{start};
    });

    $app->get('/' => sub ($c) {
        $c->text('ok');
    });

    simulate_request($app);

    is($elapsed, 100, 'stash shared between hooks and handler');
};

# Test 10: hooks receive context
subtest 'hooks receive context' => sub {
    my $app = PAGI::Simple->new;
    my ($before_ctx, $after_ctx, $handler_ctx);

    $app->hook(before => sub ($c) {
        $before_ctx = $c;
    });

    $app->hook(after => sub ($c) {
        $after_ctx = $c;
    });

    $app->get('/' => sub ($c) {
        $handler_ctx = $c;
        $c->text('ok');
    });

    simulate_request($app);

    ok($before_ctx->isa('PAGI::Simple::Context'), 'before hook gets Context');
    ok($after_ctx->isa('PAGI::Simple::Context'), 'after hook gets Context');
    is($before_ctx, $handler_ctx, 'same context in before and handler');
    is($after_ctx, $handler_ctx, 'same context in after and handler');
};

# Test 11: hook returns $app for chaining
subtest 'hook returns app for chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->hook(before => sub ($c) { });

    is($result, $app, 'hook returns $app');
};

# Test 12: invalid hook type dies
subtest 'invalid hook type dies' => sub {
    my $app = PAGI::Simple->new;

    my $died = 0;
    eval {
        $app->hook(invalid => sub { });
    };
    $died = 1 if $@;

    ok($died, 'invalid hook type dies');
    like($@, qr/Unknown hook type/, 'error message mentions unknown hook type');
};

# Test 13: hooks work with path params
subtest 'hooks work with path params' => sub {
    my $app = PAGI::Simple->new;
    my $captured_id;

    $app->hook(before => sub ($c) {
        $captured_id = $c->path_params->{id};
    });

    $app->get('/users/:id' => sub ($c) {
        $c->text("user $captured_id");
    });

    simulate_request($app, path => '/users/42');

    is($captured_id, '42', 'before hook can access path params');
};

# Test 14: chaining multiple hooks
subtest 'chaining multiple hooks' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) { push @order, 'b1' })
        ->hook(before => sub ($c) { push @order, 'b2' })
        ->hook(after  => sub ($c) { push @order, 'a1' })
        ->hook(after  => sub ($c) { push @order, 'a2' })
        ->get('/' => sub ($c) {
            push @order, 'h';
            $c->text('ok');
        });

    simulate_request($app);

    is(\@order, ['b1', 'b2', 'h', 'a1', 'a2'], 'chained hooks work correctly');
};

# Test 15: hooks don't run for 404
subtest 'hooks dont run for unmatched routes' => sub {
    my $app = PAGI::Simple->new;
    my @order;

    $app->hook(before => sub ($c) {
        push @order, 'before';
    });

    $app->hook(after => sub ($c) {
        push @order, 'after';
    });

    $app->get('/' => sub ($c) {
        push @order, 'handler';
        $c->text('ok');
    });

    my $sent = simulate_request($app, path => '/nonexistent');

    is(\@order, [], 'hooks not called for 404');
    is($sent->[0]{status}, 404, 'returns 404');
};

done_testing;
