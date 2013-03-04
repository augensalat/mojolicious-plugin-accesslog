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

open my $logfh, '>', $logfile
    or die "failed to open logfile $logfile for writing: $!";

# disable log output written with Mojo::Log methods
app->log->unsubscribe('message');

plugin 'AccessLog',
    log => $logfh,
    format =>
        '%% %a %A %b %B %D %h %H %m %p %P "%q" "%r" %>s %t %T "%u" %U %v %V ' .
        '"%{Referer}i" "%{User-Agent}i"';

any '/:any' => sub { shift->render_text('done') };

my $t = Test::Mojo->new;

open my $tail, '<', $logfile
    or die "failed to open logfile $logfile: $!";

seek $tail, 0, SEEK_END;   # goto eof

sub req_ok {
    my ($method, $url, $code, $opts) = @_;
    my $m = $t->can($method . '_ok')
        or return fail "Cannot $method $url";
    my $user = '-';
    my $query = '';
    my $pos;

    $opts = {} unless ref $opts eq 'HASH';

    if (index($url, '@') > -1) {
        ($user, $url) = split '@', $url, 2;
        $opts->{Authorization} = 'Basic ' . b64_encode($user . ':pass', '');
        $user =~ s/([^[:print:]])/'\x' . unpack('H*', $1)/eg;
    }
    elsif ($ENV{REMOTE_USER}) {
        $user = $ENV{REMOTE_USER};
    }

    $pos = index($url, '?');

    if ($pos > -1) {
        $query = substr $url, $pos;
        $url = substr $url, 0, $pos;
    }

    my $x = sprintf qq'^%% %s %s %s %s %s %s %s %s %s %s "%s" "%s" %u %s %s "%s" %s %s %s "%s" "%s"\$',
        '127\.0\.0\.1', '127\.0\.0\.1',
        '\d+', '\d+', '\d+',
        '127\.0\.0\.1',
        quotemeta('HTTP/1.1'),
        uc($method),
        '\d+', '\d+',
        quotemeta($query),
        uc($method) . ' ' . quotemeta($url . $query) . ' HTTP/1.1',
        $code,
        '\[\d{1,2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [\+\-]\d{4}\]',
        '\d+',
        quotemeta($user),
        quotemeta($url),
        'localhost', 'localhost',
        $opts->{Referer} ? quotemeta($opts->{Referer}) : '-',
        quotemeta('Mojolicious (Perl)');

    # issue request
    $m->($t, $url . $query, $opts)->status_is($code);

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
{
    local $ENV{REMOTE_USER} = 'good boy';
    req_ok(get => "3v!l b0y\ntoy\@/more?foo=bar&foo=baz" => 200);
    req_ok(get => "/more?foo=bar&foo=baz" => 200);
}
req_ok(delete => '/fb_account' => 200, {Referer => '/are_you_sure?'});

1 while unlink $logfile;

done_testing;
