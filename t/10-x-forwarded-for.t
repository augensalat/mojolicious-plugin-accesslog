#!/usr/bin/env perl

use Mojo::Base -strict;

# Disable IPv6 and libev
BEGIN {
    $ENV{MOJO_NO_IPV6} = 1;
    $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use lib 't/lib';

use Test::More;

use Mojolicious::Lite;
use Test::Mojo;

{
    package Logger;

    sub new {
        my ($class, $logref) = @_;
        bless $logref, $class;
    }

    sub print {
        my $self = shift;

        $$self = join '', @_;
    }

    sub peek { ${$_[0]} }
}

# and now disable log output written with Mojo::Log methods
app->log->unsubscribe('message');

my $log = Logger->new(\my $b);

plugin 'AccessLog', log => $log, format => '%x %h "%{X-Forwarded-For}i"';

any '/' => sub { $_[0]->render(text => 'done'); };

my $t = Test::Mojo->new;

sub logs_ok {
	my ($method, $url, $code, $opts, $expects_log) = @_;
	my $m = $t->can($method . '_ok')
	  or return fail "Cannot $method $url";
	$m->($t, $url, $opts)->status_is($code);
	my $l = $log->peek;
	chomp $l;
	is($l, $expects_log);
}

# Request with no XFF-header
logs_ok(
	get => '/' => 200,
	{},
	'- 127.0.0.1 "-"');

# Request with XFF set but only one client in chain
logs_ok(
	get => '/' => 200,
	{'X-Forwarded-For' => '127.0.0.1'},
	'127.0.0.1 127.0.0.1 "127.0.0.1"');

# Request with XFF and two clients in chain
logs_ok(
	get => '/' => 200,
	{'X-Forwarded-For' => '172.16.0.2, 127.0.0.1'},
	'172.16.0.2 127.0.0.1 "172.16.0.2, 127.0.0.1"');

# Request with upstream proxy mangling XFF. A note on this:
# It is not our responsibility to make sure that upstream follows
# the XFF-spec. Instead of hard-failing when there is invalid data
# set in the header we do as requested and log the value.
logs_ok(
	get => '/' => 200,
	{'X-Forwarded-For' => '172.16.0.2 127.0.0.1'},
	'172.16.0.2 127.0.0.1 127.0.0.1 "172.16.0.2 127.0.0.1"');

done_testing;
