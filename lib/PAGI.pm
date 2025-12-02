package PAGI;

use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

PAGI - Perl Asynchronous Gateway Interface

=head1 VERSION

Version 0.001 (Beta)

=head1 SYNOPSIS

    # Raw PAGI application
    use Future::AsyncAwait;
    use experimental 'signatures';

    async sub app ($scope, $receive, $send) {
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Hello from PAGI!',
            more => 0,
        });
    }

    # Or use the PAGI::Simple micro-framework
    use PAGI::Simple;

    my $app = PAGI::Simple->new(name => 'My App');

    $app->get('/' => sub ($c) {
        $c->text('Hello, World!');
    });

    $app->to_app;

=head1 DESCRIPTION

PAGI (Perl Asynchronous Gateway Interface) is a specification for asynchronous
Perl web applications, designed as a spiritual successor to PSGI. It defines a
standard interface between async-capable Perl web servers, frameworks, and
applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

=head2 Beta Software Notice

B<WARNING: This is beta software.>

This code is provided for developers interested in exploring and advancing
asynchronous web programming in Perl. The only guarantee made is that the
test suite passes.

B<Do not use this in production.>

If you are interested in contributing to the future of async Perl web
development, your feedback, bug reports, and contributions are welcome.

=head1 COMPONENTS

This distribution includes:

=over 4

=item L<PAGI::Server>

Reference server implementation supporting HTTP/1.1, WebSocket, SSE, and
multi-worker mode with pre-forking.

=item L<PAGI::Simple>

Express-like micro-framework for building PAGI applications with routing,
middleware, sessions, and more.

=item L<PAGI::Middleware::*>

Collection of middleware components for common web application needs.

=item L<PAGI::App::*>

Bundled applications for common functionality (static files, health checks,
metrics, etc.).

=back

=head1 PAGI APPLICATION INTERFACE

PAGI applications are async coderefs with this signature:

    async sub app ($scope, $receive, $send) { ... }

=head2 Parameters

=over 4

=item C<$scope>

Hashref containing connection metadata including type, headers, path, method,
query string, and server-advertised extensions.

=item C<$receive>

Async coderef that returns a Future resolving to the next event from the
client (e.g., request body chunks, WebSocket messages).

=item C<$send>

Async coderef that takes an event hashref and returns a Future. Used to send
responses back to the client.

=back

=head2 Scope Types

Applications dispatch on C<< $scope->{type} >>:

=over 4

=item C<http>

HTTP request/response (one scope per request)

=item C<websocket>

Persistent WebSocket connection

=item C<sse>

Server-Sent Events stream

=item C<lifespan>

Process startup/shutdown lifecycle events

=back

=head1 QUICK START

    # Install dependencies
    cpanm --installdeps .

    # Run the test suite
    prove -l t/

    # Start a server with a raw PAGI app
    pagi-server --app examples/01-hello-http/app.pl --port 5000

    # Or with a PAGI::Simple app
    pagi-server --app examples/simple-01-hello/app.pl --port 5000

    # Test it
    curl http://localhost:5000/

=head1 REQUIREMENTS

=over 4

=item * Perl 5.32+ (required for native subroutine signatures)

=item * IO::Async (event loop)

=item * Future::AsyncAwait (async/await support)

=back

=head1 SEE ALSO

=over 4

=item L<PAGI::Server> - Reference server implementation

=item L<PAGI::Simple> - Micro-framework for PAGI applications

=item L<PSGI> - The synchronous predecessor to PAGI

=item L<IO::Async> - Event loop used by PAGI::Server

=item L<Future::AsyncAwait> - Async/await for Perl

=back

=head1 CONTRIBUTING

This project is in active development. If you're interested in advancing
async web programming in Perl, contributions are welcome:

=over 4

=item * Bug reports and feature requests

=item * Documentation improvements

=item * Test coverage

=item * Protocol support (HTTP/2, HTTP/3)

=item * Performance optimizations

=back

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This software is licensed under the same terms as Perl itself.

=cut
