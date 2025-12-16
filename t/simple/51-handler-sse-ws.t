use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

use PAGI::Simple;
use PAGI::Simple::Handler;

# Helper to simulate SSE connection
sub simulate_sse ($app, %opts) {
    my $path = $opts{path} // '/events';
    my @sent;
    my $scope = { type => 'sse', path => $path };

    my @events = ({ type => 'sse.disconnect' });
    my $event_index = 0;

    my $receive = sub {
        return Future->done($events[$event_index++] // { type => 'sse.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return { sent => \@sent };
}

# Test handler class
{
    package TestApp::Events;
    use parent 'PAGI::Simple::Handler';
    use experimental 'signatures';

    our $live_called = 0;
    our $live_sse_ref;

    sub routes ($class, $app, $r) {
        $r->sse('/live' => '#live');
    }

    sub live ($self, $sse) {
        $live_called = 1;
        $live_sse_ref = $sse;
        $sse->send_event(data => 'connected');
    }

    $INC{'TestApp/Events.pm'} = 1;
}

# Test 1: SSE #method syntax works
subtest 'sse #method syntax resolves handler method' => sub {
    $TestApp::Events::live_called = 0;
    $TestApp::Events::live_sse_ref = undef;

    my $app = PAGI::Simple->new;
    $app->mount('/' => 'TestApp::Events');

    my $result = simulate_sse($app, path => '/live');

    ok($TestApp::Events::live_called, 'handler method was called');
    ok($TestApp::Events::live_sse_ref, 'received SSE context');
    ok($TestApp::Events::live_sse_ref->isa('PAGI::Simple::SSE'), 'context is SSE object');
};

done_testing;
