#!/usr/bin/env perl

use Mojo::Base -strict;

# Disable IPv6 and libev
BEGIN {
    $ENV{MOJO_NO_IPV6} = 1;
    $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;

use Mojolicious::Lite;
use Test::Mojo;

# disable log output written with Mojo::Log methods
app->log->unsubscribe('message');

my ($b, $inbound, $outbound);

plugin 'AccessLog', log => sub { $b = $_[0] }, format => '%I %O';

post '/' => sub {
    my $c = shift;

    $inbound = $c->req->to_string;

    $c->render(text => $inbound);

    $outbound = $c->res->to_string;
};

my $t = Test::Mojo->new;

sub req_ok {
    # issue request
    $t->post_ok('/', @_)->status_is(200);

    my ($log_i, $log_o) = $b =~ /^(\d+)\s+(\d+)$/;

    is $log_i, length($inbound),  "count inbound bytes";
    is $log_o, length($outbound), "count outbound bytes";

}

req_ok("abcdefghi\n" x 100);
req_ok("abcdefghi\n" x 1_000);
req_ok("abcdefghi\n" x 10_000);
req_ok("abcdefghi\n" x 100_000);
req_ok(form => {upload => {filename => 'F', content => "abcdefghi\n" x 100}});
req_ok(form => {upload => {filename => 'F', content => "abcdefghi\n" x 1_000}});
req_ok(form => {upload => {filename => 'F', content => "abcdefghi\n" x 10_000}});
req_ok(form => {upload => {filename => 'F', content => "abcdefghi\n" x 100_000}});

done_testing;
