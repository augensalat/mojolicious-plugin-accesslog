package Mojolicious::Plugin::AccessLog;

use Mojo::Base 'Mojolicious::Plugin';

use Carp qw(croak);
use File::Spec;
use IO::File;
use POSIX qw(setlocale strftime LC_ALL);
use Scalar::Util qw(blessed reftype);
use Socket qw(inet_aton AF_INET);
use Time::HiRes qw(gettimeofday tv_interval);

our $VERSION = '0.001';

my $DEFAULT_FORMAT = 'common';
my %FORMATS = (
    $DEFAULT_FORMAT => '%h %l %u %t "%r" %>s %b',
    combined => '%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i"',
);

# some systems (Windows) don't support %z correctly
my $TZOFFSET = strftime('%z', localtime) !~ /^[+-]\d{4}$/ && do {
    require Time::Local;
    my $t = time;
    my $d = (Time::Local::timegm(localtime($t)) - $t) / 60;
    sprintf '%+03d%02u', int($d / 60), $d % 60;
};

sub register {
    my ($self, $app, $conf) = @_;
    my $log = $conf->{log} // $app->log->handle;

    unless ($log) { # somebody cleared $app->log->handle?
        # Log a warning nevertheless - there might be an event handler.
        $app->log->warn(__PACKAGE__ . ': Log handle is not defined');
        return;
    }

    my $reftype = reftype $log // '';
    my $logger;

    if ($reftype eq 'GLOB') {
        select((select($log), $| = 1)[0]);
        $logger = sub { print $log $_[0] };
    }
    elsif (blessed $log and my $l = $log->can('print') || $log->can('info')) {
        $logger = sub { $l->($log, $_[0]) };
    }
    elsif ($reftype eq 'CODE') {    # TEST
        $logger = $log;             # TEST
    }
    elsif (defined $log and not ref $log) {
        File::Spec->file_name_is_absolute($log)
            or $log = $app->home->rel_file($log);   # TEST

        my $logdir = File::Spec->catpath((File::Spec->splitpath($log))[0,-2], '');

        if (-w $logdir) {
            my $fh = IO::File->new($log, '>>')
                or croak qq{Can't open log file "$log": $!};

            $fh->autoflush(1);
            $logger = sub { $fh->print($_[0]) };
        }
        else {
            $app->log->error('Directory is not writable: ' . $logdir);
        }
    }

    if (ref $logger ne 'CODE') {
        $app->log->error(__PACKAGE__ . ': not a valid "log" value');
        return;
    }

    my $format = $FORMATS{$conf->{format} // $DEFAULT_FORMAT} || $conf->{format};   # TEST
    my @handler;
    my $strftime = sub {
        my ($fmt, @time) = @_;
        $fmt =~ s/%z/$TZOFFSET/g if $TZOFFSET;
        my $old_locale = setlocale(LC_ALL);
        setlocale(LC_ALL, 'C');
        my $out = strftime($fmt, @time);
        setlocale(LC_ALL, $old_locale);
        return $out;
    };

    # each handler is called with following parameters:
    # ($tx, $tx->req, $tx->res, $tx->req->url, $time)

    my $block_handler = sub {
        my ($block, $type) = @_;

        return sub { _safe($_[1]->headers->header($block) // '-') }
            if $type eq 'i';

        return sub { $_[2]->headers->header($block) // '-' }
            if $type eq 'o';

        return sub { '[' . $strftime->($block, localtime) . ']' }
            if $type eq 't';

        return sub { _safe($_[1]->cookie($block // '')) }
            if $type eq 'C';

        return sub { _safe($_[1]->env->{$block // ''}) }
            if $type eq 'e';

        $app->log->error("{$block}$type not supported");

        return '-';
    };

    my $servername_cb = sub { $_[3]->base->host || '-' };
    my $remoteaddr_cb = sub { $_[0]->remote_address || '-' };
    my %char_handler = (
        '%' => '%',
        a => $remoteaddr_cb,
        A => sub { $_[0]->local_address // '-' },
        b => sub { $_[2]->is_dynamic ? '-' : $_[2]->body_size || '-' },
        B => sub { $_[2]->is_dynamic ? '0' : $_[2]->body_size },
        D => sub { $_[4] * 1000000 },
        h => $remoteaddr_cb,
        H => sub { 'HTTP/' . $_[1]->version },
        l => '-',
        m => sub { $_[1]->method },
        p => sub { $_[0]->local_port },
        P => sub { $$ },
        q => sub {
            my $s = $_[3]->query->to_string or return '';
            return '?' . $s;
        },
        r => sub {
            $_[1]->method . ' ' . _safe($_[3]->to_string) .
            ' HTTP/' . $_[1]->version
        },
        s => sub { $_[2]->code },
        t => sub { '[' . $strftime->('%d/%b/%Y:%H:%M:%S %z', localtime) . ']' },
        T => sub { int $_[4] },
        u => sub { _safe((split ':', $_[3]->base->userinfo || '-:')[0]) },
        U => sub { $_[3]->path },
        v => $servername_cb,
        V => $servername_cb,
    );

    if ($conf->{hostname_lookups}) {
        $char_handler{h} = sub {
            my $ip = $_[0]->remote_address or return '-';
            return gethostbyaddr(inet_aton($ip), AF_INET);
        };
    }

    my $time_stats;
    my $char_handler = sub {
        my $char = shift;
        my $cb = $char_handler{$char};

        $time_stats = 1 if $char eq 'T' or $char eq 'D';

        return $char_handler{$char} if $char_handler{$char};

        $app->log->error("\%$char not supported.");

        return '-';
    };

    $format =~ s{
        (?:
         \%\{(.+?)\}([a-z]) |
         \%(?:[<>])?([a-zA-Z\%])
        )
    }
    {
        push @handler, $1 ? $block_handler->($1, $2) : $char_handler->($3);
        '%s';
    }egx;

    chomp $format;
    $format .= $conf->{lf} // $/ // "\n";

    if ($time_stats) {
        $app->hook(
            around_dispatch => sub {
                my ($next, $c) = @_;
                my @t0 = gettimeofday;

                $next->();

                $logger->(_log($c->tx, $format, \@handler, tv_interval(\@t0)));
            }
        );
    }
    else {
        $app->hook(
            after_dispatch => sub {
                $logger->(_log($_[0]->tx, $format, \@handler))
            }
        );
    }
}

sub _log {
    my ($tx, $format, $handler) = (shift, shift, shift);
    my $req = $tx->req;
    my @args = ($tx, $req, $tx->res, $req->url, @_);

    sprintf $format, map(ref() ? ($_->(@args))[0] // '' : $_, @$handler);
}

sub _safe {
    my $string = shift;

    $string =~ s/([^[:print:]])/"\\x" . unpack("H*", $1)/eg
        if defined $string;

    return $string;
}

1;

__END__

=head1 NAME

Mojolicious::Plugin::AccessLog - AccessLog Plugin

=head1 VERSION

Version 0.001

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin(AccessLog => {log => '/var/log/mojo/access.log'});

  # Mojolicious::Lite
  plugin AccessLog => {log => '/var/log/mojo/access.log'};

=head1 DESCRIPTION

L<Mojolicious::Plugin::AccessLog> is a plugin to easily generate an
access log.

=head1 OPTIONS

L<Mojolicious::Plugin::AccessLog> supports the following options.
 
=head2 C<log>

Log data destination.

Default: C<< $app->log->handle >>, so that access log lines go to the
same destination as lines created with C<< $app->log->$method(...) >>.

This option may be set to one of the following values:

=head3 Absolute path

  plugin AccessLog => {log => '/var/log/mojo/access.log'};

A string specifying an absolute path to the log file. If the file does
not exist already, it will be created, otherwise log output will be
appended to the file. The log directory must exist in every case though.

=head3 Relative path

  # Mojolicious::Lite
  plugin AccessLog => {log => 'log/access.log'};

Similar to absolute path, but relative to the application home directory.

=head3 File Handle

  open $fh, '>', '/var/log/mojo/access.log';
  plugin AccessLog => {log => $fh};

  plugin AccessLog => {log => \*STDERR};

A file handle to which log lines are printed.

=head3 Object

  $log = IO::File->new('/var/log/mojo/access.log', O_WRONLY|O_APPEND);
  plugin AccessLog => {log => $log};

  $log = Log::Dispatch->new(...);
  plugin AccessLog => {log => $log};

An object, that implements either a C<print> method (like L<IO::Handle>
based classes) or an C<info> method (i.e. L<Log::Dispatch> or
L<Log::Log4perl>).

=head3 Callback routine

  $log = Log::Dispatch->new(...);
  plugin AccessLog => {
    log => sub { $log->log(level => 'debug', message => @_) }
  };

A code reference. The provided subroutine will be called for every log
line, that it gets as a single argument.

=head2 C<format>

A string to specify the format of each line of log output.

Default: "common" (see below).

This plugin implements a subset of
L<Apache's LogFormat|http://httpd.apache.org/docs/2.0/mod/mod_log_config.html>.

=over

=item %%

A percent sign.

=item %a

Remote IP-address.

=item %A

Local IP-address.

=item %b

Size of response in bytes, excluding HTTP headers. In CLF format, i.e.
a '-' rather than a 0 when no bytes are sent.

=item %B

Size of response in bytes, excluding HTTP headers.

=item %D

The time taken to serve the request, in microseconds.

=item %h

Remote host. See L</hostname_lookups> below.

=item %H

The request protocol.

=item %l

The remote logname, not implemented: currently always '-'.

=item %m

The request method.

=item %p

The port of the server serving the request.

=item %P

The process ID of the child that serviced the request.

=item %r

First line of request: Request method, request URL and request protocol.
Synthesized from other fields, so it may not be the request verbatim.

=item %s

The HTTP status code of the response.

=item %t

Time the request was received (standard english format).

=item %T

Custom field for handling times in subclasses.

=item %u

Remote user, or '-'.

=item %U

The URL path requested, not including any query string.

=item %v

The name of the server serving the request.

=item %V

The name of the server serving the request.

=back

In addition, custom values can be referenced, using C<%{name}>,
with one of the mandatory modifier flags C<i>, C<o>, C<t>, C<C> or C<e>:

=over

=item %{RequestHeaderName}i

The contents of request header C<RequestHeaderName>.

=item %{ResponseHeaderName}o

The contents of response header C<ResponseHeaderName>.

=item %{Format}t

The time, in the form given by C<Format>, which should be in
L<strftime(3)> format.

=item %{CookieName}C

The contents of cookie C<CookieName> in the request sent to the server.

=item %{VariableName}e

The contents of environment variable C<VariableName>.

=back

For mostly historical reasons template names "common" or "combined" can
also be used (note, that these contain the unsupported C<%l> directive):

=over

=item common

  %h %l %u %t "%r" %>s %b

=item combined

  %h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i" 

=back

=head2 C<hostname_lookups>

Enable reverse DNS hostname lookup if C<true>. Keep in mind, that this
adds latency to every request, if C<%h> is part of the log line, because
it requires a DNS lookup to complete before the request is finished.
Default is C<false> (= disabled).

=head1 METHODS

L<Mojolicious::Plugin::AccessLog> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 C<register>

  $plugin->register(
    Mojolicious->new, {
      log => '/var/log/mojo/access.log',
      format => 'combined',
    }
  );

Register plugin hooks in L<Mojolicious> application.

=head1 SEE ALSO

L<Mojolicious>, L<Plack::Middleware::AccessLog>,
L<Catalyst::Plugin::AccessLog>,
L<http://httpd.apache.org/docs/2.0/mod/mod_log_config.html>.

=head1 ACKNOWLEDGEMENTS

Many thanks to Tatsuhiko Miyagawa for L<Plack::Middleware::AccessLog>
and Andrew Rodland for L<Catalyst::Plugin::AccessLog>.
C<Mojolicious:Plugin::AccessLog> borrows a lot of code and ideas from
those modules.

=head1 AUTHOR

Bernhard Graf <graf(a)cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 Bernhard Graf

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/> for more information.
