use inc::Module::Install;
BEGIN { require 5.006 } # please CPAN::Reporter

# Define metadata
name            'IPC-Messaging';
all_from        'lib/IPC/Messaging.pm';
license         'bsd';

# Specific dependencies
requires        'B::Generate'      => 0;
requires        'IO::Socket::UNIX' => 0;
requires        'IO::Socket::INET' => 0;
requires        'Storable'         => 0;
requires        'Time::HiRes'      => 0;
requires        'IO::Select'       => 0;
requires        'Module::Load::Conditional' => 0;

recommends      'IO::KQueue'       => 0;
recommends      'IO::Epoll'        => 0;

build_requires  'Test::More'       => 0;

no_index        'directory'        => 'devel';

if ( $^O eq 'MSWin32' ) {
	die "This distribution would not work on Windows platform.\n";
}

auto_install;
WriteAll;
