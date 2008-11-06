package IPC::Messaging;
use 5.008;
use warnings;
use strict;
require Exporter;
use base 'Exporter';
use vars qw(@EXPORT $VERSION);
use B::Generate;
use IO::Socket::UNIX;
use IO::Socket::INET;
use Socket qw(:all);
use Storable;
use Time::HiRes;
use Carp;
use Module::Load::Conditional "can_load";

$VERSION = '0.01_12';
sub spawn (&);
sub receive (&);
sub receive_loop (&);
sub got;
sub then (&);
sub after ($$);

@EXPORT = qw(spawn receive receive_loop got then after);

my $MAX_DGRAM_SIZE = 16384;
my $TCP_READ_SIZE  = 65536;
my $secret;
my $root;
my $messaging_dir;
my $i_am_root;
my $my_sock;
my $my_sock_fileno;
my %their_sock;
my @msg_queue;
my $recv;
my %read_socks;
my %write_socks;
my ($use_kqueue, $use_epoll, $use_select);
my $kq;
my $epfd;

sub debug
{
	# print STDERR @_;
}

sub spawn (&)
{
	my ($psub) = @_;
	my $pid = CORE::fork;
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
	return unless @{$r->{pats}};
	for (my $i = 0; $i < @msg_queue; $i++) {
		my $m = $msg_queue[$i];
		for my $pat (@{$r->{pats}}) {
			if ($pat->{name} ne $m->{m} && $pat->{name} ne "_") {
				# does not match if message name is different
				next;
			}
			if ($pat->{proc} && $m->{f} && $m->{f} != $pat->{proc}) {
				# does not match if sender process is different
				next;
			}
			my $msock = $m->{fsock} || $m->{sock};
			if ($pat->{sock} && $msock && $msock->fileno != $pat->{sock}) {
				# does not match if sender socket is different
				next;
			}
			my $h = $pat->{match} || {};
			my $match = 1;
			for my $k (keys %$h) {
				unless (exists $m->{d}{$k} && $m->{d}{$k} eq $h->{$k}) {
					$match = 0;
					last;
				}
			}
			next unless $match;
			debug "MATCH $m->{m}!\n";
			if ($pat->{filter}) {
				next unless $pat->{filter}->($m->{m}, $m->{d});
			}
			splice @msg_queue, $i, 1;
			my $proc_or_sock = $m->{sock} || ($m->{f} ? IPC::Messaging::Process->_new($m->{f}) : undef);
			$_ = $proc_or_sock;
			my $ignore = ${$pat->{then}}->($m->{m}, $m->{d}, $proc_or_sock);
			return 1;
		}
	}
}

sub watch_fd
{
	my ($fd, $write) = @_;
	if ($kq) {
		if ($write) {
			$kq->EV_SET($fd, &IO::KQueue::EVFILT_WRITE, &IO::KQueue::EV_ADD, 0, 0);
		} else {
			$kq->EV_SET($fd, &IO::KQueue::EVFILT_READ, &IO::KQueue::EV_ADD, 0, 0);
		}
	} elsif ($epfd) {
		if ($write) {
			IO::Epoll::epoll_ctl($epfd, &IO::Epoll::EPOLL_CTL_ADD, $fd, &IO::Epoll::EPOLLOUT);
		} else {
			IO::Epoll::epoll_ctl($epfd, &IO::Epoll::EPOLL_CTL_ADD, $fd, &IO::Epoll::EPOLLIN);
		}
	}
}

sub unwatch_fd
{
	my ($fd) = @_;
	my $rd = delete $read_socks{$fd};
	my $wr = delete $write_socks{$fd};
	if ($kq) {
		$kq->EV_SET($fd, &IO::KQueue::EVFILT_READ, &IO::KQueue::EV_DELETE, 0, 0) if $rd;
		$kq->EV_SET($fd, &IO::KQueue::EVFILT_WRITE, &IO::KQueue::EV_DELETE, 0, 0) if $wr;
	} elsif ($epfd) {
		IO::Epoll::epoll_ctl($epfd, &IO::Epoll::EPOLL_CTL_DEL, $fd, &IO::Epoll::EPOLLIN) if $rd;
		IO::Epoll::epoll_ctl($epfd, &IO::Epoll::EPOLL_CTL_DEL, $fd, &IO::Epoll::EPOLLOUT) if $wr;
	}
}

sub pickup_one_message
{
	my ($t) = @_;
	debug "$$: select $my_sock $t\n";
	my @fd;
	if ($use_kqueue) {
		# XXX errors are ignored, bad
		@fd = map { $_->[&IO::KQueue::KQ_IDENT] } $kq->kevent($t*1000);
	} elsif ($use_epoll) {
		# XXX errors are ignored, bad
		@fd = map { $_->[0] } @{IO::Epoll::epoll_wait($epfd, 100, $t*1000) || []};
	} else {
		my $to_read  = IO::Select->new($my_sock,map { $_->{sock} } values %read_socks);
		my $to_write = IO::Select->new(map { $_->{sock} } values %write_socks);
		my ($r,$w) = IO::Select->select($to_read, $to_write, undef, $t);
		@fd = map { $_->fileno } @$w, @$r;
	}
	for my $fd (@fd) {
		if ($fd == $my_sock_fileno) {
			my $data = "";
			$my_sock->recv($data, $MAX_DGRAM_SIZE);
			return unless $data;
			debug "$$: got something:\n\t$data\n";
			my $msg = eval { Storable::thaw($data) };
			debug "$$: cannot thaw: $@\n" if !$msg && $@;
			return unless $msg;
			return unless $msg->{s} && $msg->{s} eq $secret && $msg->{m} && $msg->{f};
			$msg->{d} ||= {};
			push @msg_queue, $msg;
			if ($msg->{m} eq "EXIT") {
				use POSIX ":sys_wait_h";
				waitpid($msg->{f}, WNOHANG);
			}
		} elsif ($write_socks{$fd}) {
			my $s = $write_socks{$fd};
			unwatch_fd($fd);
			if ($s->{type} eq "tcp_connecting") {
				my $sock = $s->{sock};
				my $peer = $sock->peerhost;
				my $peer_port = $sock->peerport;
				my $opt = getsockopt($sock, SOL_SOCKET, SO_ERROR);
				$opt = unpack("I", $opt) if defined $opt;
				if ($opt) {
					push @msg_queue, {
						m     => "tcp_error",
						sock  => $sock,
						d     => {
							errno => $opt,
						},
					};
				} else {
					push @msg_queue, {
						m     => "tcp_connected",
						sock  => $sock,
						d     => {
							peer      => $peer,
							peer_port => $peer_port,
						},
					};
					$read_socks{$fd} = {
						sock      => $s->{sock},
						type      => "tcp",
						by_line   => $s->{by_line},
						from      => $peer,
						from_port => $peer_port,
					};
					watch_fd($fd);
				}
			}
		} elsif ($read_socks{$fd}) {
			my $s = $read_socks{$fd};
			if ($s->{type} eq "tcp_listen") {
				my $sock = $s->{sock}->accept;
				my $from = $sock->peerhost;
				my $from_port = $sock->peerport;
				push @msg_queue, {
					m     => "tcp_connect",
					fsock => $s->{sock},
					sock  => $sock,
					d     => {
						from      => $from,
						from_port => $from_port,
					},
				};
				$read_socks{$sock->fileno} = {
					sock      => $sock,
					type      => "tcp",
					from      => $from,
					from_port => $from_port,
					by_line   => $s->{by_line},
					buf       => "",
				};
				watch_fd($sock->fileno);
			} elsif ($s->{type} eq "tcp") {
				my $d = "";
				my $sock = $s->{sock};
				my $len = sysread $sock, $d, $TCP_READ_SIZE;
				if (!defined $len || $len <= 0) {
					if ($s->{buf} && $s->{by_line}) {
						push @msg_queue, {
							m    => "tcp_line",
							sock => $sock,
							d    => {
								from      => $s->{from},
								from_port => $s->{from_port},
								line      => $s->{buf},
							},
						};
					}
					push @msg_queue, {
						m    => "tcp_disconnect",
						d    => {
							from      => $s->{from},
							from_port => $s->{from_port},
						},
					};
					unwatch_fd($fd);
					$sock->close;
				} elsif ($s->{by_line}) {
					$s->{buf} .= $d;
					while ($s->{buf} =~ s/^(.*?\n)//) {
						push @msg_queue, {
							m    => "tcp_line",
							sock => $sock,
							d    => {
								from      => $s->{from},
								from_port => $s->{from_port},
								line      => $1,
							},
						};
					}
				} else {
					push @msg_queue, {
						m    => "tcp_data",
						sock => $sock,
						d    => {
							from      => $s->{from},
							from_port => $s->{from_port},
							data      => $d,
						},
					};
				}
			} elsif ($s->{type} eq "udp") {
				my $d = "";
				my $sock = $s->{sock};
				$sock->recv($d, $MAX_DGRAM_SIZE);
				return unless $d;
				debug "$$: got udp\n";
				push @msg_queue, {
					m    => "udp",
					sock => $sock,
					d    => {
						from      => $sock->peerhost,
						from_port => $sock->peerport,
						data      => $d,
					},
				};
			} else {
				# XXX
				# Something is fishy, we don't know what to do with this
				# socket, so unwatch it in order to not have the "always ready"
				# condition.
				unwatch_fd($fd);
			}
		}
	}
}

sub tcp_server
{
	my (undef, $port, %p) = @_;
	my $sock = IO::Socket::INET->new(
		Listen    => $p{listen_queue} || 5,
		($p{bind} ? (LocalAddr => $p{bind}) : ()),
		LocalPort => $port,
		Proto     => "tcp",
		ReuseAddr => 1,
	) or die $@;
	$read_socks{$sock->fileno} = {
		sock    => $sock,
		type    => "tcp_listen",
		by_line => $p{by_line},
	};
	watch_fd($sock->fileno);
	return $sock;
}

sub tcp_client
{
	my (undef, $host, $port, %p) = @_;
	my $sock = IO::Socket::INET->new(
		Proto     => "tcp",
		PeerHost  => $host,
		PeerPort  => $port,
		Blocking  => 0,
	) or die $@;
	$write_socks{$sock->fileno} = {
		sock    => $sock,
		type    => "tcp_connecting",
		by_line => $p{by_line},
	};
	watch_fd($sock->fileno, "write");
	return $sock;
}

sub udp
{
	my (undef, $port, $bind) = @_;
	$port ||= 0;
	my $sock = IPC::Messaging::UDP->new(
		Proto     => "udp",
		LocalPort => $port,
		($bind ? (LocalAddr => $bind) : ()),
		ReuseAddr => 1,
	) or die $@;
	$read_socks{$sock->fileno} = {
		sock => $sock,
		type => "udp",
	};
	watch_fd($sock->fileno);
	return $sock;
}

sub receive_parse
{
	my ($rsub) = @_;
	die "internal error: non-empty \$recv" if $recv;
	my $r = $recv = { then_balance => 0 };
	eval { $rsub->(); };
	$recv = undef;
	die $@ if $@;
	croak "dangling \"then\"" if $r->{then_balance};
	unless ($r->{pats} || $r->{timeout}) {
		die "an empty \"receive\"";
	}
	$r;
}

sub receive_once
{
	my ($r) = @_;
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
			${$r->{timeout}[1]}->();
			last;
		}
	}
}

sub receive (&)
{
	my $r = receive_parse(@_);
	receive_once($r);
}

sub receive_loop (&)
{
	my $r = receive_parse(@_);
	receive_once($r) while 1;
}

sub got
{
	my (@p) = @_;
	die "\"got\" outside \"receive\"" unless $recv;
	die "invalid \"got\" syntax: not enough arguments" unless @p >= 2;
	my $pat = {};
	$pat->{then} = pop @p;
	die "invalid \"got\" syntax: missing \"then\""
		unless UNIVERSAL::isa($pat->{then}, "IPC::Messaging::Then");
	if (UNIVERSAL::isa($p[0], "ARRAY")) {
		if (@p != 1) {
			die "invalid \"got\" syntax: arrayref not by itself";
		}
		@p = @{$p[0]};
	}
	die "invalid \"got\" syntax: missing message name" unless @p;
	my $name = shift @p;
	die "invalid \"got\" syntax: message name must not be a reference" if ref $name;
	$pat->{name} = $name;
	if (@p) {
		my $from = $p[0];
		if (UNIVERSAL::isa($from, "IPC::Messaging::Process")) {
			$pat->{proc} = "$from";
			shift @p;
		} elsif (UNIVERSAL::isa($from, "IO::Handle")) {
			$pat->{sock} = $from->fileno;
			shift @p;
		}
	}
	if (@p) {
		if (UNIVERSAL::isa($p[0], "CODE")) {
			$pat->{filter} = shift @p;
		}
	}
	if (@p) {
		if (UNIVERSAL::isa($p[0], "HASH")) {
			die "invalid \"got\" syntax: unexpected hashref" unless @p == 1;
			@p = %{$p[0]};
		} elsif (@p % 2 != 0) {
			die "invalid \"got\" syntax: odd number of matching elements";
		}
	}
	$pat->{match} = {@p} if @p;
	push @{$recv->{pats}}, $pat;
	$recv->{then_balance}--;
}

sub then (&)
{
	my ($act) = @_;
	die "\"then\" outside \"receive\"" unless $recv;
	$recv->{then_balance}++;
	bless \$act, "IPC::Messaging::Then";
}

sub after ($$)
{
	my ($t, $then) = @_;
	die "\"after\" outside \"receive\"" unless $recv;
	die "invalid \"after\" syntax: missing \"then\""
		unless UNIVERSAL::isa($then, "IPC::Messaging::Then");
	die "duplicate \"after\" in \"receive\"" if $recv->{timeout};
	$recv->{then_balance}--;
	$recv->{timeout} = [$t, $then];
}

sub timer
{
	my (undef, $interval, %msg) = @_;
	die "timers are not implemented yet\n";
	return IPC::Messaging::Timer->new($interval, %msg);
}

sub global_init
{
	$secret = int(rand(10000))+1;
	$root = $$;
	$i_am_root = 1;
	$messaging_dir = "/tmp/ipc-messaging-$>/$root";
	system("rm -rf $messaging_dir") if -e $messaging_dir && !-l $messaging_dir;
	system("mkdir -p $messaging_dir");
	$use_kqueue = can_load(modules => { "IO::KQueue" => 0 });
	$use_epoll = can_load(modules => { "IO::Epoll" => 0 });
	$use_select = !$use_kqueue && !$use_epoll && can_load(modules => { "IO::Select" => 0 });
	die "cannot find neither IO::KQueue nor IO::Epoll nor IO::Select"
		unless $use_kqueue || $use_epoll || $use_select;
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

	$kq = IO::KQueue->new if $use_kqueue;
	$epfd = IO::Epoll::epoll_create(100) if $use_epoll;

	$my_sock = IO::Socket::UNIX->new(
		Local     => "$messaging_dir/$$.sock",
		Type      => SOCK_DGRAM)
	or die $@;
	$my_sock_fileno = $my_sock->fileno;
	watch_fd($my_sock_fileno);
	%their_sock       = ();
	@msg_queue        = ();
	%read_socks       = ();
}

package IPC::Messaging::Process;
use warnings;
use strict;
use vars qw($AUTOLOAD);
use IO::Socket::UNIX;
use Storable;

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
	my $data = Storable::freeze($m);
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

package IPC::Messaging::Then;

package IPC::Messaging::UDP;
use Socket;
use base 'IO::Socket::INET';

sub sendto
{
	my ($socket, $data, $addr, $port) = @_;
	my $iaddr = Socket::inet_aton($addr);
	send $socket, $data, 0, scalar Socket::sockaddr_in($port, $iaddr);
}

package IPC::Messaging::Timer;

our $COUNT;
our %ACTIVE;
our %SUSPENDED;

sub new
{
	my ($class, $interval, %msg) = @_;

	my $me = {
		interval => $interval,
		start    => Time::HiRes::time,
		id       => ++$COUNT,
	};
}

sub reset
{
	my ($me) = @_;
	$me->{start} = Time::HiRes::time;
}

package IPC::Messaging;

BEGIN {
	initpid();
	*CORE::GLOBAL::fork = sub {
		my $r = fork;
		if (defined $r && !$r) {
			$secret = 0;
			initpid();
		}
		$r;
	};
}

1;
__END__

=head1 NAME

IPC::Messaging - process handling and message passing, Erlang style

=head1 VERSION

This document describes IPC::Messaging version 0.01_12.

=head1 SYNOPSIS

 use IPC::Messaging;
 
 # Process creation
 my $proc = spawn {
   receive {
     got ping => then {
       print "$$: got ping from $_\n";
       $_->pong;
     };
   };
 };
 
 # Message sending
 $proc->ping;
 # Message matching
 receive {
   # matching message name
   got somemsg => then {
   };
   # matching message name and sender
   got pong => $proc => then {
   };
   # matching message name and content
   got msg => x => 1 => then {
   };
   # matching with a custom filter
   got msg => \&is_something => then {
   };
   # matching any message
   got _ => then {
     my ($message, $message_data, $from) = @_;
     print "$$: got $message from $from\n";
 	# $_ is the same as $from:
     print "$$: got $_[0] from $_\n";
   };
   after 2 => then {
     print "$$: timeout\n";
   };
 };
 
 # TCP via message matching
 IPC::Messaging->tcp_server(1111);
 while (1) {
   receive {
     got tcp_connect => then {
       print "connect from $_[1]->{from}\n";
       print $_ "hi\n"; 
     };
     got tcp_data => then {
       print "got data: $_[1]->{data}\n";
     };
     got tcp_disconnect => then {
       print "disconnect from $_[1]->{from}\n";
     };
   };
 }


=head1 DESCRIPTION

This is a preliminary development version, and as such it is extremely
poorly documented.

=head1 DEPENDENCIES

Perl 5.8.4 or above, B::Generate, Module::Load::Conditional.

=head1 INCOMPATIBILITIES

This module, in all likelihood, will only work on Unix-like operating systems.

=head1 BUGS AND LIMITATIONS

No bugs known.  The API is a moving target.  To be useful,
reads from sockets in form of messages must be supported
to a greater degree than they are now.

=head1 AUTHOR

Anton Berezin  C<< <tobez@tobez.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007, 2008, Anton Berezin C<< <tobez@tobez.org> >>. All rights reserved.

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
