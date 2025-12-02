use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Named middleware definition in PAGI::Simple

use PAGI::Simple;

# Test 1: middleware() method exists
subtest 'middleware method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('middleware'), 'app has middleware method');
    ok($app->can('get_middleware'), 'app has get_middleware method');
    ok($app->can('has_middleware'), 'app has has_middleware method');
};

# Test 2: Define a middleware
subtest 'define middleware' => sub {
    my $app = PAGI::Simple->new;
    my $called = 0;

    my $mw = sub ($c, $next) {
        $called = 1;
        $next->();
    };

    my $result = $app->middleware(test => $mw);

    is($result, $app, 'middleware returns $app for chaining');
    ok($app->has_middleware('test'), 'middleware is registered');
};

# Test 3: get_middleware returns the callback
subtest 'get_middleware returns callback' => sub {
    my $app = PAGI::Simple->new;

    my $original = sub ($c, $next) { $next->() };
    $app->middleware(auth => $original);

    my $retrieved = $app->get_middleware('auth');
    is($retrieved, $original, 'get_middleware returns the same callback');
};

# Test 4: get_middleware returns undef for unknown
subtest 'get_middleware returns undef for unknown' => sub {
    my $app = PAGI::Simple->new;

    my $mw = $app->get_middleware('nonexistent');
    ok(!defined $mw, 'get_middleware returns undef for unknown middleware');
};

# Test 5: has_middleware returns false for unknown
subtest 'has_middleware returns false for unknown' => sub {
    my $app = PAGI::Simple->new;

    ok(!$app->has_middleware('unknown'), 'has_middleware returns false for unknown');
};

# Test 6: Multiple middleware can be defined
subtest 'multiple middleware' => sub {
    my $app = PAGI::Simple->new;

    $app->middleware(auth => sub ($c, $next) { $next->() });
    $app->middleware(json_only => sub ($c, $next) { $next->() });
    $app->middleware(rate_limit => sub ($c, $next) { $next->() });

    ok($app->has_middleware('auth'), 'has auth');
    ok($app->has_middleware('json_only'), 'has json_only');
    ok($app->has_middleware('rate_limit'), 'has rate_limit');
    ok(!$app->has_middleware('missing'), 'missing is missing');
};

# Test 7: Middleware can be chained
subtest 'middleware chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app
        ->middleware(a => sub ($c, $next) { $next->() })
        ->middleware(b => sub ($c, $next) { $next->() })
        ->middleware(c => sub ($c, $next) { $next->() });

    is($result, $app, 'chaining returns $app');
    ok($app->has_middleware('a'), 'has a');
    ok($app->has_middleware('b'), 'has b');
    ok($app->has_middleware('c'), 'has c');
};

# Test 8: Middleware overwrites existing with same name
subtest 'middleware overwrites existing' => sub {
    my $app = PAGI::Simple->new;

    my $first = sub ($c, $next) { 'first' };
    my $second = sub ($c, $next) { 'second' };

    $app->middleware(test => $first);
    $app->middleware(test => $second);

    my $mw = $app->get_middleware('test');
    is($mw, $second, 'second middleware overwrites first');
};

# Test 9: Middleware callback signature test
subtest 'middleware callback signature' => sub {
    my $app = PAGI::Simple->new;
    my ($received_c, $received_next);

    $app->middleware(capture => sub ($c, $next) {
        $received_c = $c;
        $received_next = $next;
        $next->();
    });

    my $mw = $app->get_middleware('capture');
    ok(defined $mw, 'middleware is defined');
    is(ref $mw, 'CODE', 'middleware is a coderef');

    # Test calling it directly
    my $mock_c = bless {}, 'MockContext';
    my $next_called = 0;
    my $mock_next = sub { $next_called = 1 };

    $mw->($mock_c, $mock_next);

    is($received_c, $mock_c, 'middleware receives context');
    is(ref $received_next, 'CODE', 'middleware receives next as coderef');
    ok($next_called, 'next was called');
};

# Test 10: Middleware that doesn't call next
subtest 'middleware without next call' => sub {
    my $app = PAGI::Simple->new;
    my $next_called = 0;

    $app->middleware(block => sub ($c, $next) {
        # Intentionally don't call $next
        return 'blocked';
    });

    my $mw = $app->get_middleware('block');
    my $mock_next = sub { $next_called = 1 };

    my $result = $mw->({}, $mock_next);

    is($result, 'blocked', 'middleware returns its value');
    ok(!$next_called, 'next was not called');
};

# Test 11: Auth-style middleware pattern
subtest 'auth-style middleware pattern' => sub {
    my $app = PAGI::Simple->new;
    my ($auth_passed, $handler_called);

    $app->middleware(auth => sub ($c, $next) {
        if ($c->{authorized}) {
            $auth_passed = 1;
            $next->();
        } else {
            return 'unauthorized';
        }
    });

    my $mw = $app->get_middleware('auth');

    # Test unauthorized
    $auth_passed = 0;
    $handler_called = 0;
    my $result = $mw->({ authorized => 0 }, sub { $handler_called = 1 });
    is($result, 'unauthorized', 'returns unauthorized');
    ok(!$auth_passed, 'auth did not pass');
    ok(!$handler_called, 'handler not called');

    # Test authorized
    $auth_passed = 0;
    $handler_called = 0;
    $mw->({ authorized => 1 }, sub { $handler_called = 1 });
    ok($auth_passed, 'auth passed');
    ok($handler_called, 'handler was called');
};

# Test 12: Middleware names can be any string
subtest 'middleware names' => sub {
    my $app = PAGI::Simple->new;

    $app->middleware('with-hyphen' => sub ($c, $next) { $next->() });
    $app->middleware('with_underscore' => sub ($c, $next) { $next->() });
    $app->middleware('CamelCase' => sub ($c, $next) { $next->() });
    $app->middleware('123numeric' => sub ($c, $next) { $next->() });

    ok($app->has_middleware('with-hyphen'), 'hyphenated name works');
    ok($app->has_middleware('with_underscore'), 'underscore name works');
    ok($app->has_middleware('CamelCase'), 'CamelCase name works');
    ok($app->has_middleware('123numeric'), 'numeric prefix name works');
};

done_testing;
