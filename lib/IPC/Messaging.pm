package IPC::Messaging;
use 5.006;
use warnings;
use strict;
require Exporter;
use base 'Exporter';
use vars qw(@EXPORT $VERSION);
use B::Generate;
use IO::Socket::UNIX;
use JSON::XS;
use Time::HiRes;
use IO::Select;

$VERSION = '0.01_01';
sub spawn (&);
sub receive (&);
sub got ($);
sub then (&);
sub after ($);

@EXPORT = qw(spawn receive got then after);

my $MAX_DGRAM_SIZE = 16384;
my $secret;
my $root;
my $messaging_dir;
my $i_am_root;
my $my_sock;
my %their_sock;
my @msg_queue;
my $recv;

sub debug
{
	# print STDERR @_;
}

sub spawn (&)
{
	my ($psub) = @_;
	my $pid = fork;
	die "unable to fork: $!" unless defined $pid;
	if ($pid) {
		# parent
		my $child = IPC::Messaging::Process->_new($pid);
		receive {
			got [_READY => $child] => then {};
			after 5 => then { die "child $pid not ready" };
		};
		return $child;
	} else {
		# child
		$i_am_root = 0;
		initpid();
		my $parent = IPC::Messaging::Process->_new(getppid);
		$parent->_READY;
		$psub->();
		exit 0;
	}
}

sub END
{
	if ($messaging_dir && $i_am_root && -e $messaging_dir && !-l $messaging_dir) {
		# system("ls -l $messaging_dir");
		system("rm -rf $messaging_dir");
	} elsif ($messaging_dir && !$i_am_root) {
		my $parent = IPC::Messaging::Process->_new(getppid);
		$parent->EXIT;
	}
}

sub run_queue
{
	my ($r) = @_;
	return unless @{$r->{evs}};
	for (my $i = 0; $i < @msg_queue; $i++) {
		my $m = $msg_queue[$i];
		for my $ev_act (@{$r->{evs}}) {
			my $ev = $ev_act->[0];
			if (ref $ev eq "ARRAY" && $ev->[0] ne $m->{m} && $ev->[0] ne "_") {
				# does not match if message name is different
				# (complex message pattern)
				next;
			}
			if (!ref $ev && $ev ne $m->{m} && $ev ne "_") {
				# does not match if message name is different
				# (simple message pattern)
				next;
			}
			if (ref $ev eq "ARRAY" && $ev->[1] && ref $ev->[1] ne "HASH" &&
				"$ev->[1]" !~ /\D/ && "$ev->[1]" != $m->{f})
			{
				# does not match if sender is different
				next;
			}
			my $h = {};
			for (1,2) {
				if (ref $ev eq "ARRAY" && $ev->[$_] && ref $ev->[$_] eq "HASH") {
					$h = $ev->[$_];
					last;
				}
			}
			my $match = 1;
			for my $k (keys %$h) {
				unless (exists $m->{d}{$k} && $m->{data}{$k} eq $h->{$k}) {
					$match = 0;
					last;
				}
			}
			next unless $match;
			debug "MATCH $m->{m}!\n";
			splice @msg_queue, $i, 1;
			my $proc = IPC::Messaging::Process->_new($m->{f});
			$_ = $proc;
			$ev_act->[1]->($m->{m}, $m->{d}, $proc);
			return 1;
		}
	}
}

sub pickup_one_message
{
	my ($t) = @_;
	debug "$$: select $my_sock $t\n";
	my @r = IO::Select->new($my_sock)->can_read($t);
	if (@r) {
		my $data = "";
		$my_sock->recv($data, $MAX_DGRAM_SIZE);
		return unless $data;
		debug "$$: got something:\n\t$data\n";
		my $msg = eval { from_json($data) };
		return unless $msg;
		return unless $msg->{s} && $msg->{s} eq $secret && $msg->{m} && $msg->{f};
		$msg->{d} ||= {};
		push @msg_queue, $msg;
	}
}

sub receive (&)
{
	my ($rsub) = @_;
	die "internal error: non-empty \$recv" if $recv;
	my $r = $recv = {};
	debug "$$: receive\n";
	$rsub->();
	$recv = undef;
	die "\"got\" without \"then\"" if $r->{ev};
	unless ($r->{evs} || $r->{timeout}) {
		die "an empty \"receive\"";
	}
	my $start = Time::HiRes::time;
	while (1) {
		if (!$i_am_root && !kill 0, $root) {
			die "root process has quit, aborting";
		}
		if (run_queue($r)) {
			debug "$$: first pickup\n";
			pickup_one_message(0);
			last;
		}
		if ($r->{timeout}) {
			debug "$$: pickup with timeout\n";
			debug "$r->{timeout}[0] ", Time::HiRes::time(), " $start\n";
			next if pickup_one_message($r->{timeout}[0]-(Time::HiRes::time()-$start));
		} else {
			debug "$$: indefinite pickup\n";
			next if pickup_one_message(5);
		}
		if ($r->{timeout} && $r->{timeout}[0]-(Time::HiRes::time()-$start) < 0) {
			debug "$$: timeout!\n";
			$r->{timeout}[1]->();
			last;
		}
	}
	debug "$$: /receive\n";
}

sub got ($)
{
	my ($match) = @_;
	die "\"got\" outside \"receive\"" unless $recv;
	die "\"got\" without \"then\"" if $recv->{ev};
	die "\"after\" must come the last in \"receive\"" if $recv->{timeout};
	$recv->{ev} = $match;
	debug "$$: got [match]\n";
}

sub then (&)
{
	my ($act) = @_;
	die "\"then\" outside \"receive\"" unless $recv;
	if ($recv->{ev}) {
		push @{$recv->{evs}}, [$recv->{ev}, $act];
		$recv->{ev} = undef;
	} elsif ($recv->{timeout}) {
		die "\"then\" without \"got\"" if @{$recv->{timeout}} > 1;
		push @{$recv->{timeout}}, $act;
	} else {
		die "\"then\" without \"got\"";
	}
	debug "$$: then [act]\n";
}

sub after ($)
{
	my ($t) = @_;
	die "\"after\" outside \"receive\"" unless $recv;
	die "\"got\" without \"then\"" if $recv->{ev};
	die "duplicate \"after\" in \"receive\"" if $recv->{timeout};
	$recv->{timeout} = [$t];
	debug "$$: after [$t]\n";
}

sub global_init
{
	$secret = int(rand(10000))+1;
	$root = $$;
	$i_am_root = 1;
	$messaging_dir = "/tmp/ipc-messaging/$root";
	system("rm -rf $messaging_dir") if -e $messaging_dir && !-l $messaging_dir;
	system("mkdir -p $messaging_dir");
}

sub initpid
{
	return if ref $$;
	global_init() unless $secret;
	my $this = IPC::Messaging::Process->_new($$);
	my $pid = B::svref_2object(\$$);
	$pid->FLAGS($pid->FLAGS & ~B::SVf_READONLY);
	$$ = $this;
	$pid->FLAGS($pid->FLAGS | B::SVf_READONLY);

	$my_sock = IO::Socket::UNIX->new(
		Local     => "$messaging_dir/$$.sock",
		Type      => SOCK_DGRAM)
	or die $@;
	%their_sock = ();
	@msg_queue = ();
}

package IPC::Messaging::Process;
use warnings;
use strict;
use vars qw($AUTOLOAD);
use IO::Socket::UNIX;
use JSON::XS ();

use overload '0+'  => \&_numify;
use overload '""'  => \&_stringify;
use overload '<=>' => sub { "$_[0]" <=> "$_[1]" };

sub _new
{
	my ($pkg, $pid) = @_;
	my $me = {pid => $pid};
	bless $me, $pkg;
}

sub _numify
{
	return $_[0]->{pid};
}

sub _stringify
{
	return "$_[0]->{pid}";
}

sub DESTROY {}

sub AUTOLOAD
{
	my $proc = shift;
	my $name = $AUTOLOAD;
	$name =~ s/^IPC::Messaging::Process:://;
	my $m = {
		m => $name,
		f => "$$",
		s => $secret,
		d => {@_},
	};
	my $data = JSON::XS::to_json($m);
	my $sock = $their_sock{"$proc"};
	unless ($sock) {
		$sock = $their_sock{"$proc"} = IO::Socket::UNIX->new(
			Peer    => "$messaging_dir/$proc.sock",
			Type    => SOCK_DGRAM,
			Timeout => 10);
	}
	die "cannot create peer socket: $!" unless $sock;
	IPC::Messaging::debug "$$: sending to $messaging_dir/$proc.sock:\n\t$data\n";
	$sock->send($data);
}

package IPC::Messaging;

BEGIN { initpid() }

1;
__END__

=head1 NAME

IPC::Messaging - process handling and message passing, Erlang style

=head1 VERSION

This document describes IPC::Messaging version 0.01_01.

=head1 SYNOPSIS

my $proc = spawn {
  receive {
    got ping => then {
      print "$$: got ping from $_\n";
      $_->pong;
    };
  };
};

$proc->ping;
receive {
  got _ then {
    print "$$: got $_[0] from $_\n";
  };
  after 2 => then {
    print "$$: timeout\n";
  };
};

=head1 DESCRIPTION

This is a preliminary development version, and as such it is extremely
poorly documented.

=head1 DEPENDENCIES

Perl 5.8.2 or above, B::Generate, JSON::XS.

=head1 INCOMPATIBILITIES

This module, in all likelihood, will only work on Unix-like operating systems.

=head1 BUGS AND LIMITATIONS

No bugs known.  The API is a moving target.  To be useful,
reads from sockets in form of messages must be supported.

=head1 AUTHOR

Anton Berezin  C<< <tobez@tobez.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007, Anton Berezin C<< <tobez@tobez.org> >>. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
