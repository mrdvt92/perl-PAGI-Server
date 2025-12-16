package PAGI::Simple::Handler;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::Handler - Base class for controller-like route handlers

=head1 SYNOPSIS

    package MyApp::Todos;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
        $r->get('/:id' => '#show');
        $r->post('/' => '#create');
    }

    async sub index ($self, $c) {
        my $todos = $c->service('Todo')->all;
        $c->json({ todos => $todos });
    }

    async sub show ($self, $c) {
        my $id = $c->param('id');
        my $todo = $c->service('Todo')->find($id);
        $c->json($todo);
    }

    1;

=head1 DESCRIPTION

PAGI::Simple::Handler provides a base class for organizing routes into
controller-like classes. Handlers:

=over 4

=item * Share the root Application's services via C<< $c->app >>

=item * Define routes using the C<routes($class, $app, $r)> class method

=item * Reference handler methods using C<#method> syntax in routes

=item * Are instantiated once per application at mount time

=back

=head1 CLASS METHODS

=head2 routes

    sub routes ($class, $app, $r) {
        $r->get('/' => '#index');
    }

Override this method to define routes for the handler. Receives:

=over 4

=item * C<$class> - The handler class name

=item * C<$app> - The root Application (access services, config, etc.)

=item * C<$r> - A Router scoped to the handler's mount prefix

=back

The C<#method> syntax resolves to calling that method on the handler instance.

=cut

sub routes ($class, $app, $r) {
    # Override in subclass to define routes
}

=head1 INSTANCE METHODS

=head2 new

    my $handler = MyApp::Todos->new(app => $app);

Create a new handler instance. Called automatically by mount().

=cut

sub new ($class, %args) {
    my $self = bless {
        app => $args{app},
    }, $class;
    return $self;
}

=head2 app

    my $app = $handler->app;

Returns the root Application instance that this handler was mounted on.

=cut

sub app ($self) {
    return $self->{app};
}

=head1 WRITING HANDLER METHODS

Handler methods receive C<$self> (the handler instance) and C<$c> (the request context):

    async sub index ($self, $c) {
        # $self - this handler instance
        # $c    - PAGI::Simple::Context
        # $c->app - root Application (for services)

        my $todos = $c->service('Todo')->all;
        $c->json({ todos => $todos });
    }

B<Important:> Don't store per-request state in C<$self>. Handlers are
instantiated once and reused. Use C<< $c->stash >> for request-scoped data.

=head1 MIDDLEWARE CHAINS

Multiple C<#method> references create a middleware chain:

    $r->get('/:id' => '#load' => '#show');

The C<load> method runs first, then C<show>. If C<load> sends a response
(e.g., 404 not found), the chain stops.

    async sub load ($self, $c) {
        my $todo = $c->service('Todo')->find($c->param('id'));
        return $c->not_found unless $todo;
        $c->stash->{todo} = $todo;
    }

    async sub show ($self, $c) {
        $c->json($c->stash->{todo});
    }

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>

=cut

1;
