#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Handler;

# =============================================================================
# Test app structure:
#   MainApp (PAGI::Simple subclass)
#     /api/todos -> TodosHandler
#     /api/users -> UsersHandler (with middleware)
# =============================================================================

# Service class (in-memory storage)
{
    package TestService;
    use experimental 'signatures';

    my @todos = (
        { id => 1, title => 'First' },
        { id => 2, title => 'Second' },
    );

    sub new ($class) { bless {}, $class }
    sub all ($self) { return @todos }
    sub find ($self, $id) { return (grep { $_->{id} == $id } @todos)[0] }
}

# Todos Handler
{
    package TestApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');

        # Test route-level middleware within handlers
        # IMPORTANT: specific routes must come BEFORE parameterized routes
        $r->get('/protected' => ['auth'], '#protected');

        $r->get('/:id' => '#load' => '#show');
    }

    async sub index ($self, $c) {
        # Access service via $c->app
        my @todos = $c->app->stash->{service}->all;
        $c->json({ todos => \@todos });
    }

    async sub load ($self, $c) {
        my $id = await $c->param('id');
        my $todo = $c->app->stash->{service}->find($id);
        return $c->status(404)->json({ error => 'Not found' }) unless $todo;
        $c->stash->{todo} = $todo;
    }

    async sub show ($self, $c) {
        $c->json($c->stash->{todo});
    }

    async sub protected ($self, $c) {
        $c->json({ message => 'You are authenticated!' });
    }

    $INC{'TestApp/Todos.pm'} = 1;
}

# Users Handler with mount-level middleware
{
    package TestApp::Users;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';
    use Future::AsyncAwait;

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
    }

    async sub index ($self, $c) {
        $c->json({ users => [] });
    }

    $INC{'TestApp/Users.pm'} = 1;
}

# Main App
{
    package MainApp;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub init ($class) {
        return (
            name  => 'MainApp',
            quiet => 1,
        );
    }

    sub routes ($class, $app, $r) {
        # Set up service
        $app->stash->{service} = TestService->new;

        # Define middleware
        $app->middleware(auth => sub ($c, $next) {
            my $token = $c->req->header('Authorization');
            return $c->status(401)->json({ error => 'Unauthorized' }) unless $token;
            $next->();
        });

        # Mount handlers - nested groups with handlers
        $app->group('/api' => sub ($app) {
            $app->mount('/todos' => 'TestApp::Todos');
            $app->mount('/users' => 'TestApp::Users', ['auth']);
        });

        # Root route
        $app->get('/' => sub ($c) { $c->text('ok') });
    }
}

# Helper to make requests
sub request ($app, $method, $path, %opts) {
    my $response_body = '';
    my $response_status;

    my $scope = {
        type => 'http',
        method => $method,
        path => $path,
        headers => $opts{headers} // [],
        query_string => '',
    };

    my $receive = async sub { { type => 'http.request', body => '' } };
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            $response_status = $event->{status};
        }
        elsif ($event->{type} eq 'http.response.body') {
            $response_body .= $event->{body} // '';
        }
    };

    $app->to_app->($scope, $receive, $send)->get;

    return ($response_status, $response_body);
}

my $app = MainApp->new;

subtest 'MainApp subclass with init() and routes()' => sub {
    ok($app, 'MainApp instantiated');
    is($app->name, 'MainApp', 'init() was called and name set');
};

subtest 'root route works' => sub {
    my ($status, $body) = request($app, 'GET', '/');
    is($status, 200, 'status ok');
    is($body, 'ok', 'body correct');
};

subtest 'handler index via $c->app->stash' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/');
    is($status, 200, 'status ok');
    like($body, qr/First/, 'has first todo');
    like($body, qr/Second/, 'has second todo');
};

subtest 'handler method chain (#load => #show)' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/1');
    is($status, 200, 'status ok');
    like($body, qr/"id".*1/, 'has correct id');
    like($body, qr/First/, 'has correct title');
};

subtest '404 handling in chains when load fails' => sub {
    my ($status, $body) = request($app, 'GET', '/api/todos/999');
    is($status, 404, 'status 404');
    like($body, qr/Not found/, 'error message');
};

subtest 'middleware on mounted handlers - no auth' => sub {
    my ($status, $body) = request($app, 'GET', '/api/users/');
    is($status, 401, 'status 401 without auth');
};

subtest 'middleware on mounted handlers - with auth' => sub {
    my ($status, $body) = request($app, 'GET', '/api/users/',
        headers => [['authorization', 'Bearer token']]);
    is($status, 200, 'status 200 with auth');
};

subtest 'nested groups with handlers' => sub {
    # This is already tested above - /api/todos is inside /api group
    my ($status, $body) = request($app, 'GET', '/api/todos/');
    is($status, 200, 'nested group + handler works');
};

subtest 'route-level middleware within handlers' => sub {
    # Test without auth
    my ($status, $body) = request($app, 'GET', '/api/todos/protected');
    is($status, 401, 'route-level middleware blocks without auth');
    like($body, qr/Unauthorized/, 'correct error message');

    # Test with auth
    ($status, $body) = request($app, 'GET', '/api/todos/protected',
        headers => [['authorization', 'Bearer token']]);
    is($status, 200, 'route-level middleware allows with auth');
    like($body, qr/authenticated/, 'correct response');
};

done_testing;
