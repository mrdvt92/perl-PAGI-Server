use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: PAGI::Simple module loading and basic construction

# Test 1: Module loads
subtest 'module loads' => sub {
    my $loaded = eval { require PAGI::Simple; 1 };
    ok($loaded, 'PAGI::Simple loads') or diag $@;
    ok(PAGI::Simple->can('new'), 'has new() method');
    ok(PAGI::Simple->can('to_app'), 'has to_app() method');
};

# Import the module for subsequent tests
use PAGI::Simple;

# Test 2: Constructor returns blessed object
subtest 'constructor' => sub {
    my $app = PAGI::Simple->new;

    ok(defined $app, 'new() returns defined value');
    ok(ref $app, 'new() returns reference');
    isa_ok($app, 'PAGI::Simple');
};

# Test 3: Constructor with options
subtest 'constructor with options' => sub {
    my $app = PAGI::Simple->new(name => 'MyApp');

    is($app->name, 'MyApp', 'name option sets name');
};

# Test 4: Default name
subtest 'default name' => sub {
    my $app = PAGI::Simple->new;

    is($app->name, 'PAGI::Simple', 'default name is PAGI::Simple');
};

# Test 5: stash accessor
subtest 'stash' => sub {
    my $app = PAGI::Simple->new;

    ok(ref $app->stash eq 'HASH', 'stash returns hashref');

    $app->stash->{foo} = 'bar';
    is($app->stash->{foo}, 'bar', 'can store and retrieve from stash');
};

# Test 6: to_app returns coderef
subtest 'to_app' => sub {
    my $app = PAGI::Simple->new;
    my $pagi_app = $app->to_app;

    ok(defined $pagi_app, 'to_app returns defined value');
    ok(ref $pagi_app eq 'CODE', 'to_app returns coderef');
};

# Test 7: Lifecycle hooks can be registered
subtest 'lifecycle hooks' => sub {
    my $app = PAGI::Simple->new;

    my $startup_called = 0;
    my $shutdown_called = 0;

    # Register hooks
    my $result = $app->on(startup => sub { $startup_called++ });
    ok($result == $app, 'on() returns $self for chaining');

    $app->on(shutdown => sub { $shutdown_called++ });

    # Hooks are stored (we can verify via internal structure)
    is(scalar @{$app->{_startup_hooks}}, 1, 'startup hook registered');
    is(scalar @{$app->{_shutdown_hooks}}, 1, 'shutdown hook registered');
};

# Test 8: Invalid lifecycle event dies
subtest 'invalid lifecycle event' => sub {
    my $app = PAGI::Simple->new;

    like(
        dies { $app->on(invalid => sub {}) },
        qr/Unknown lifecycle event/,
        'dies on invalid lifecycle event'
    );
};

# Test 9: Multiple apps are independent
subtest 'multiple independent apps' => sub {
    my $app1 = PAGI::Simple->new(name => 'App1');
    my $app2 = PAGI::Simple->new(name => 'App2');

    $app1->stash->{value} = 'one';
    $app2->stash->{value} = 'two';

    isnt($app1, $app2, 'different app instances');
    is($app1->name, 'App1', 'app1 has correct name');
    is($app2->name, 'App2', 'app2 has correct name');
    is($app1->stash->{value}, 'one', 'app1 stash independent');
    is($app2->stash->{value}, 'two', 'app2 stash independent');
};

done_testing;
