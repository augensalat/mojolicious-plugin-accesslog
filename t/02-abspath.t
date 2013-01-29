#!/usr/bin/env perl

use Mojo::Base -strict;

# Disable IPv6 and libev
BEGIN {
    $ENV{MOJO_NO_IPV6} = 1;
    $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;

use Fcntl qw(:seek);
use File::Spec;
use Mojo::Util qw(b64_encode);
use Mojolicious::Lite;
use Test::Mojo;

my $logfile = File::Spec->catfile(
    File::Spec->tmpdir, join('.', 'accesslog', time, $$, int(rand(1000)))
);

# disable log output written with Mojo::Log methods
app->log->unsubscribe('message');

plugin 'AccessLog', log => $logfile, format => 'combined';

any '/:any' => sub { shift->render_text('done') };

my $t = Test::Mojo->new;

open my $tail, '<', $logfile
    or die "failed to open logfile $logfile for reading: $!";

seek $tail, 0, SEEK_END;   # goto eof

sub req_ok {
    my ($method, $url, $code, $opts) = @_;
    my $m = $t->can($method . '_ok')
        or return fail "Cannot $method $url";
    my $user = '-';

    $opts = {} unless ref $opts eq 'HASH';

    if (index($url, '@') > -1) {
        ($user, $url) = split '@', $url, 2;
        $opts->{Authorization} = 'Basic ' . b64_encode($user . ':pass', '');
    }

    my $x = sprintf qq'^%s - %s %s "%s %s HTTP/1.1" %d %s "%s" "%s"\$',
        '127\.0\.0\.1',
        $user,
        '\[\d{1,2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [\+\-]\d{4}\]',
        uc($method),
        quotemeta($url),
        $code,
        '\d+',
        $opts->{Referer} ? quotemeta($opts->{Referer}) : '-',
        quotemeta('Mojolicious (Perl)');

    # issue request
    $m->($t, $url, $opts)->status_is($code);

    # check last log line
    seek $tail, 0, SEEK_CUR;  # clear EOF condition

    defined(my $l = <$tail>)
        or return fail "no tail line in log file";
    chomp $l;

    eof $tail
        or return fail "not eof after reading last log line";

    like $l, qr{$x}, $l;
}

req_ok(get => '/' => 404, {Referer => 'http://www.example.com/'});
req_ok(post => '/a_letter' => 200, {Referer => '/'});
req_ok(put => '/option' => 200);
req_ok(delete => '/fb_account' => 200, {Referer => '/are_you_sure?'});

# XXX how to log password with space(s)? XXX
req_ok(get => '3v!l b0y@/more?foo=bar&foo=baz' => 200);

1 while unlink $logfile;

done_testing;
