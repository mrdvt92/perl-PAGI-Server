package PAGI::Simple::Response;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use JSON::MaybeXS ();
use Encode ();

=head1 NAME

PAGI::Simple::Response - Response utilities for PAGI::Simple

=head1 SYNOPSIS

    # Response helpers are typically called on $c (Context):
    $c->text("Hello");
    $c->json({ status => "ok" });
    $c->html("<h1>Hello</h1>");
    $c->redirect("/other");

=head1 DESCRIPTION

PAGI::Simple::Response provides response building utilities.
Most users won't use this module directly - the helpers are
available on the Context object ($c).

=head1 CLASS METHODS

=cut

=head2 json_encode

    my $json = PAGI::Simple::Response->json_encode($data);

Encode a Perl data structure to JSON string.

=cut

sub json_encode ($class, $data) {
    return JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($data);
}

=head2 json_decode

    my $data = PAGI::Simple::Response->json_decode($json);

Decode a JSON string to Perl data structure.

=cut

sub json_decode ($class, $json) {
    return JSON::MaybeXS->new(utf8 => 1)->decode($json);
}

=head1 STATUS CODE HELPERS

=head2 status_text

    my $text = PAGI::Simple::Response->status_text(404);  # "Not Found"

Returns the standard status text for an HTTP status code.

=cut

my %STATUS_TEXT = (
    100 => 'Continue',
    101 => 'Switching Protocols',
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    204 => 'No Content',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',
    307 => 'Temporary Redirect',
    308 => 'Permanent Redirect',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    409 => 'Conflict',
    410 => 'Gone',
    415 => 'Unsupported Media Type',
    422 => 'Unprocessable Entity',
    429 => 'Too Many Requests',
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout',
);

sub status_text ($class, $code) {
    return $STATUS_TEXT{$code} // 'Unknown';
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>

=head1 AUTHOR

PAGI Contributors

=cut

1;
