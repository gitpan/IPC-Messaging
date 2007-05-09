use Test::More tests => 1;

BEGIN {
	delete $ENV{PERL_DL_NONLAZY};
	use_ok( 'IPC::Messaging' );
}
