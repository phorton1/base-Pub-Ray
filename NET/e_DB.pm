#---------------------------------------------
# e_DB.pm
#---------------------------------------------
# DATABASE (TCP 2050) packet parser + the transaction-form value-record
# codec.  It pairs with d_DB.pm (the service class, command constants,
# %DB_PARSE_RULES and %DB_FIELDS) the way e_TRACK pairs with d_TRACK.
#
# d_DB 'require's this module, so anything that 'use's d_DB has the parser.
# This module 'use's d_DB for the definitions, and d_DB calls back by
# fully-qualified name (e.g. Pub::Ray::NET::e_DB::buildDBRecord) -- a one-way
# compile-time dependency, no use-cycle.
#
# The {tx} accumulator assembles a multi-frame value read
#   REPLY_VALUE -> INFO_START -> INFO_RECORD -> INFO_END
# into one seq-matched reply.  A not-found REPLY_VALUE (db_bits != 0, no
# INFO frames) is terminal on its own.
#
# Record codec: the transaction-form value-record (DB_DECODE.md):
#   fid(4) enc(2) size(2) reserved(4) value(size)
#   A(4) B(4) src_len(2) pad(2) descriptor(src_len)

package Pub::Ray::NET::e_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Ray::NET::a_defs;
use Pub::Ray::NET::a_mon;
use Pub::Ray::NET::a_utils;
use Pub::Ray::NET::d_DB;
use base qw(Pub::Ray::NET::a_parser);


my $dbg_ep = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		parseDBRecord
		buildDBRecord
		dbMsgName
		fidName
	);
}


#----------------------------------------------------
# names
#----------------------------------------------------

sub dbMsgName
{
	my ($cmd_word) = @_;
	return $DB_MSG_NAME{$cmd_word} || sprintf("UNKNOWN(0x%04x)",$cmd_word);
}


sub fidName
{
	my ($fid) = @_;
	my $def = $DB_FIELDS{$fid & 0xff};
	return $def ? $def->{name} : sprintf("UNKNOWN(%02x)",$fid & 0xff);
}


#----------------------------------------------------
# transaction-form value-record codec
#----------------------------------------------------

my %ENC_SIZE = (
	0x0054 => 1,	# BOOL8
	0x00c0 => 1,	# UINT8
	0x00ef => 4,	# UINT32
);

sub _encSize
{
	my ($enc) = @_;
	return $ENC_SIZE{$enc} || 1;
}


sub _decodeScalar
{
	my ($enc,$size,$bytes) = @_;
	my $signed = ($enc & 0x8000) ? 1 : 0;
	return unpack($signed ? 'c' : 'C',$bytes) if $size == 1;
	return unpack($signed ? 's' : 'v',$bytes) if $size == 2;
	return unpack($signed ? 'l' : 'V',$bytes) if $size == 4;
	return unpack('H*',$bytes);		# 8-byte / packed-struct: hex passthrough
}


sub _encodeScalar
{
	my ($enc,$size,$value) = @_;
	$value ||= 0;
	my $signed = ($enc & 0x8000) ? 1 : 0;
	return pack($signed ? 'c' : 'C',$value) if $size == 1;
	return pack($signed ? 's' : 'v',$value) if $size == 2;
	return pack($signed ? 'l' : 'V',$value) if $size == 4;
	return pack('H*',$value);		# var: caller passed a hex string
}


sub parseDBRecord
	# decode one transaction-form value-record; returns a shared hash, or
	# undef if the buffer is too short.  Scalars (1/2/4 byte) decode to an
	# int (signed-aware); packed-struct values pass through as hex.
{
	my ($buf) = @_;
	my $len = length($buf);
	return undef if $len < 12;

	my ($fid,$enc,$size,$reserved) = unpack('VvvV',substr($buf,0,12));
	my $value_bytes = substr($buf,12,$size);
	my $offset = 12 + $size;

	my $rec = shared_clone({
		fid        => $fid,
		enc        => $enc,
		size       => $size,
		value      => _decodeScalar($enc,$size,$value_bytes),
		value_hex  => unpack('H*',$value_bytes),
		A          => 0,
		B          => 0,
		descriptor => '',
	});

	if ($offset + 12 <= $len)
	{
		my ($a,$b,$src_len,$pad) = unpack('VVvv',substr($buf,$offset,12));
		$offset += 12;
		$rec->{A} = $a;
		$rec->{B} = $b;
		$rec->{descriptor} = ($src_len && $offset + $src_len <= $len) ?
			unpack('H*',substr($buf,$offset,$src_len)) : '';
	}

	return $rec;
}


sub buildDBRecord
	# encode a transaction-form value-record for a write (CMD_PUT_ITEM).
	# $rec: { fid, enc, value, [size], [value_bytes], [A], [B] }
	# A defaults to 7 (application/configuration family), B to 0, no descriptor.
{
	my ($rec) = @_;
	my $a = defined($rec->{A}) ? $rec->{A} : 7;
	my $b = defined($rec->{B}) ? $rec->{B} : 0;

	my $value_bytes = defined($rec->{value_bytes}) ?
		$rec->{value_bytes} :
		_encodeScalar($rec->{enc}, $rec->{size} || _encSize($rec->{enc}), $rec->{value});
	my $size = length($value_bytes);

	return
		pack('V',$rec->{fid}).
		pack('v',$rec->{enc}).
		pack('v',$size).
		pack('V',0).				# reserved
		$value_bytes.
		pack('V',$a).
		pack('V',$b).
		pack('v',0).				# src_len = 0 (no descriptor)
		pack('v',0);				# pad
}


#----------------------------------------------------
# parser
#----------------------------------------------------

sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_ep,0,"Pub::Ray::NET::e_DB::newParser($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	$this->resetTransaction();
	return $this;
}


sub resetTransaction
{
	my ($this) = @_;
	$this->{tx} = shared_clone({
		seq_num  => 0,
		fid      => 0,
		db_bits  => 0,
		word     => 0,
		found    => 0,
		uuid     => '',
		success  => 0,
		biglen   => 0,
		record   => undef,
		count    => 0,
		ids      => undef,
		is_event => 0,
	});
	delete $this->{reply_complete};
}


sub parseMessage
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_ep+2,0,"Pub::Ray::NET::e_DB::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	my $name = dbMsgName($cmd_word);
	my $dir_name = $DIRECTION_NAME{$dir} // sprintf('0x%04x',$dir);
	display($dbg_ep+2,1,"e_DB parseMessage dir($dir)=$dir_name cmd($cmd)=$name");

	my $mon = $packet->{mon};
	printConsole(1,$mon,$packet->{color},"$dir_name $name")
		if $mon & $MON_PARSE;

	my $rule = $DB_PARSE_RULES{$cmd_word};
	if (!$rule)
	{
		error("NO RULE dir($dir)=$dir_name cmd($cmd)=$name");
		return $packet;
	}

	my $offset = 4;
	for my $piece (@{$rule->{pieces}})
	{
		$this->parsePiece($packet,$piece,$part,\$offset);
	}

	# a not-found REPLY_VALUE (db_bits != 0) carries no INFO frames -> terminal
	if ($dir == $DIRECTION_RECV && $cmd == $DB_REPLY_VALUE && $this->{tx}{db_bits})
	{
		$this->{reply_complete} = 1;
	}

	if ($this->{reply_complete})
	{
		delete $this->{reply_complete};
		return shared_clone({ %{$this->{tx}} });
	}

	if ($rule->{terminal})
	{
		my $reply = shared_clone({ %{$this->{tx}} });
		$reply->{is_event} = 1 if $rule->{is_event};
		$reply->{seq_num}  = 0 if $rule->{is_event};
		return $reply;
	}

	return undef;
}


sub parsePiece
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon   = $packet->{mon};
	my $color = $packet->{color};
	my $tx    = $this->{tx};

	if ($piece eq 'fid')
	{
		my $fid = unpack('V',substr($part,$$poffset,4));
		$$poffset += 4;
		$tx->{fid} = $fid;
		printConsole(2,$mon,$color,sprintf("fid = 0x%x %s",$fid,fidName($fid)))
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'db_bits')
	{
		my $bits = unpack('v',substr($part,$$poffset,2));
		$$poffset += 2;
		$tx->{db_bits} = $bits;
		$tx->{found}   = $bits ? 0 : 1;
		printConsole(2,$mon,$color,sprintf("db_bits = 0x%04x (%s)",$bits,$bits?'not-found':'found'))
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'word')
	{
		my $word = unpack('v',substr($part,$$poffset,2));
		$$poffset += 2;
		$tx->{word} = $word;
		printConsole(2,$mon,$color,sprintf("word = 0x%04x",$word))
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'success2')
	{
		my $status = unpack('H*',substr($part,$$poffset,4));
		$$poffset += 4;
		$tx->{success} = ($status eq $SUCCESS2_SIG) ? 1 : 0;
		printConsole(2,$mon,$color,"success2 = $tx->{success}")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'biglen')
	{
		$tx->{biglen} = unpack('V',substr($part,$$poffset,4));
		$$poffset += 4;
		printConsole(2,$mon,$color,"biglen = $tx->{biglen}")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'record')
	{
		my $biglen = $tx->{biglen} || (length($part) - $$poffset);
		my $bytes  = substr($part,$$poffset,$biglen);
		$$poffset += $biglen;
		my $rec = parseDBRecord($bytes);
		$tx->{record} = $rec;
		if (($mon & $MON_PIECES) && $rec)
		{
			printConsole(2,$mon,$color,sprintf("record fid(0x%x) enc(0x%04x) size(%d) value(%s) A(%d) B(%d)",
				$rec->{fid},$rec->{enc},$rec->{size},_def($rec->{value}),$rec->{A},$rec->{B}));
		}
	}
	elsif ($piece eq 'count')
	{
		$tx->{count} = unpack('V',substr($part,$$poffset,4));
		$$poffset += 4;
		printConsole(2,$mon,$color,"count = $tx->{count}")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'ids')
	{
		my $ids = shared_clone([]);
		for (my $i=0; $i<$tx->{count} && $$poffset+2 <= length($part); $i++)
		{
			push @$ids, unpack('v',substr($part,$$poffset,2));
			$$poffset += 2;
		}
		$tx->{ids} = $ids;
		printConsole(2,$mon,$color,"ids = ".join(',',@$ids))
			if $mon & $MON_PIECES;
	}
	else
	{
		return $this->SUPER::parsePiece($packet,$piece,$part,$poffset);
	}

	return 1;
}


1;
