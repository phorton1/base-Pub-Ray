#!/usr/bin/perl
#---------------------------------------------------------------------------
# _probe.pl -- ad-hoc RAYNET / RAYDP probe tool
#---------------------------------------------------------------------------
# A throwaway-friendly replacement for the old b_probe.pm DSL: craft a packet,
# send it to an E80 service, and dump the reply.  Self-contained (core modules
# only, plain ASCII output) so it runs directly or from a temp script without
# pulling in the Pub:: stack.
#
#   perl _probe.pl <udp|tcp|mcast> <ip:port> [hex ...] [options]
#
# The hex payload is a hex string (whitespace ignored) with substitutions,
# carried over from the old probe DSL:
#
#   {seq}          4-byte LE sequence number          (--seq, default 0)
#   {sid}          2-byte LE service id               (--sid)
#   {port}         2-byte LE local / reply port       (--lport)
#   {string TEXT}  2-byte LE length + raw TEXT
#   {name16 TEXT}  TEXT as 16-bit (LE) chars, no terminator
#
# Options:
#   --seq N        value for {seq}
#   --sid N        value for {sid}
#   --lport P      local udp port to bind (and the value for {port})
#   --msg          tcp only: prepend a 2-byte LE length (the old MSG framing)
#   --wait SECS    seconds to collect replies (default 3)
#   --group IP     mcast group to join for proto 'mcast' (default = the ip arg)
#
# Examples:
#   # FishHistory (2055) emits 9-byte messages on connect -- just watch:
#   perl _probe.pl tcp 10.0.241.54:2055 --wait 5
#   # send a length-framed WPMGR request and dump the reply:
#   perl _probe.pl tcp 10.0.241.54:2052 0000{sid}00000000 --sid 15 --msg
#   # listen to a multicast instrument stream for 5s:
#   perl _probe.pl mcast 224.30.38.196:2563 --wait 5
#---------------------------------------------------------------------------

use strict;
use warnings;
use Socket;
use Time::HiRes qw(time);
use IO::Select;


my ($proto, $target, @rest) = @ARGV;
defined $proto && defined $target or die usage();
$proto =~ /^(udp|tcp|mcast)$/ or die "proto must be udp, tcp or mcast\n";

my ($ip, $port) = ($target =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/);
defined $port or die "target must be ip:port (got '$target')\n";

my %opt = (seq => 0, sid => 0, lport => 0, wait => 3, msg => 0, group => $ip, hex => '');
while (@rest)
{
	my $a = shift @rest;
	if    ($a eq '--seq')   { $opt{seq}   = shift @rest }
	elsif ($a eq '--sid')   { $opt{sid}   = shift @rest }
	elsif ($a eq '--lport') { $opt{lport} = shift @rest }
	elsif ($a eq '--wait')  { $opt{wait}  = shift @rest }
	elsif ($a eq '--group') { $opt{group} = shift @rest }
	elsif ($a eq '--msg')   { $opt{msg}   = 1 }
	elsif ($a =~ /^--/)     { die "unknown option '$a'\n" }
	else                    { $opt{hex} .= $a }
}

my $payload = build_payload($opt{hex}, %opt);

if    ($proto eq 'udp')   { do_udp($ip, $port, $payload, \%opt) }
elsif ($proto eq 'tcp')   { do_tcp($ip, $port, $payload, \%opt) }
else                      { do_mcast($opt{group}, $port, \%opt) }
exit 0;


#---------------------------------------------------------------------------

sub usage
{
	return "usage: perl _probe.pl <udp|tcp|mcast> <ip:port> [hex ...] ".
		   "[--sid N --seq N --lport P --msg --wait S --group IP]\n";
}


sub build_payload
{
	my ($spec, %o) = @_;
	return '' if !defined $spec || $spec eq '';
	$spec =~ s!\{seq\}!unpack('H*',pack('V',$o{seq}))!ge;
	$spec =~ s!\{sid\}!unpack('H*',pack('v',$o{sid}))!ge;
	$spec =~ s!\{port\}!unpack('H*',pack('v',$o{lport}))!ge;
	$spec =~ s!\{string\s+([^}]*)\}!unpack('H*',pack('v',length($1)).$1)!ge;
	$spec =~ s!\{name16\s+([^}]*)\}!join('',map { unpack('H*',pack('v',ord)) } split(//,$1))!ge;
	$spec =~ s!\s+!!g;
	$spec =~ /^[0-9a-fA-F]*$/ or die "payload not valid hex after substitution: '$spec'\n";
	return pack('H*', $spec);
}


sub do_udp
{
	my ($ip, $port, $payload, $o) = @_;
	socket(my $s, PF_INET, SOCK_DGRAM, getprotobyname('udp')) or die "socket: $!\n";
	if ($o->{lport})
	{
		bind($s, sockaddr_in($o->{lport}, INADDR_ANY)) or die "bind $o->{lport}: $!\n";
	}
	print "--> udp $ip:$port  (".length($payload)." bytes)".
		  ($o->{lport} ? " from local port $o->{lport}" : '')."\n";
	dump_bytes('    ', $payload) if length($payload);
	send($s, $payload, 0, sockaddr_in($port, inet_aton($ip))) or die "send: $!\n";
	collect($s, $o->{wait});
	close($s);
}


sub do_tcp
{
	my ($ip, $port, $payload, $o) = @_;
	socket(my $s, PF_INET, SOCK_STREAM, getprotobyname('tcp')) or die "socket: $!\n";
	connect($s, sockaddr_in($port, inet_aton($ip))) or die "connect $ip:$port: $!\n";
	my $out = $o->{msg} ? pack('v', length($payload)).$payload : $payload;
	print "--> tcp $ip:$port  (".length($out)." bytes".($o->{msg} ? ", msg-framed" : '').")\n";
	dump_bytes('    ', $out) if length($out);
	syswrite($s, $out) or die "write: $!\n" if length($out);
	collect($s, $o->{wait});
	close($s);
}


sub do_mcast
{
	my ($group, $port, $o) = @_;
	my $IPPROTO_IP        = eval { Socket::IPPROTO_IP() }        // 0;
	my $IP_ADD_MEMBERSHIP = eval { Socket::IP_ADD_MEMBERSHIP() } // 12;
	socket(my $s, PF_INET, SOCK_DGRAM, getprotobyname('udp')) or die "socket: $!\n";
	setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1);
	bind($s, sockaddr_in($port, INADDR_ANY)) or die "bind $port: $!\n";
	my $mreq = inet_aton($group).inet_aton('0.0.0.0');
	setsockopt($s, $IPPROTO_IP, $IP_ADD_MEMBERSHIP, $mreq) or die "join $group: $!\n";
	print "listening on mcast $group:$port for $o->{wait}s ...\n";
	collect($s, $o->{wait});
	close($s);
}


sub collect
	# read and dump everything that arrives within $wait seconds
{
	my ($s, $wait) = @_;
	my $sel = IO::Select->new($s);
	my $deadline = time() + $wait;
	my $got = 0;
	while (1)
	{
		my $remain = $deadline - time();
		last if $remain <= 0;
		last if !$sel->can_read($remain);
		my $from = recv($s, my $buf, 65536, 0);
		last if !defined $from;
		$got++;
		my $src = 'stream';
		if (length($from) >= 16)
		{
			my ($fp, $fa) = sockaddr_in($from);
			$src = inet_ntoa($fa).":$fp";
		}
		print "<-- reply from $src  (".length($buf)." bytes)\n";
		dump_bytes('    ', $buf);
	}
	print "(no reply within ${wait}s)\n" if !$got;
}


sub dump_bytes
{
	my ($ind, $buf) = @_;
	my $len = length($buf);
	for (my $off = 0; $off < $len; $off += 16)
	{
		my $chunk = substr($buf, $off, 16);
		my $hex = unpack('H*', $chunk);
		$hex =~ s!(........)!$1 !g;
		my $asc = $chunk;
		$asc =~ s![^\x20-\x7e]!.!g;
		printf "%s%04x: %-39s %s\n", $ind, $off, $hex, $asc;
	}
}
