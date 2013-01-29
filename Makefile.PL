use inc::Module::Install;

name            'Mojolicious-Plugin-AccessLog';
perl_version    '5.010001';
all_from        'lib/Mojolicious/Plugin/AccessLog.pm';
readme_from;
author          'Bernhard Graf <graf@cpan.org>';
license         'perl';
repository      'git://github.com/augensalat/mojolicious-plugin-accesslog.git';

build_requires  'Test::More';
build_requires  'Test::Mojo';

requires        'Mojolicious' => '2.0';
requires        'Carp';
requires        'File::Spec';
requires        'IO::File';
requires        'POSIX';
requires        'Scalar::Util';
requires        'Socket';
requires        'Time::HiRes';
requires        'Time::Local';

auto_install;

WriteAll;

