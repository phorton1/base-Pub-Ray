#===========================================================================
# d_DB - the E80 DATABASE service (TCP port 2050)
#===========================================================================
# The point-to-point control side of the E80 Database service (the broadcast
# side is d_DBNAV.pm; both are service_id 16 / 0x10).  This module implements
# the full firmware protocol decoded in docs/e80_firmware (DATABASE.md /
# DB_DECODE.md / DB_FIDS.md) and wire-confirmed against
# NET/docs/logs/rns_db_field_enum.txt:
#
#   - subscribe (SUB_VALUE / SUB_DIR) -- adds a fid to the DBNAV broadcast;
#   - read    (getItem  -> CMD_GET_VALUE) -- the preferred source's value
#             and its source uuid;
#   - write   (putItem  -> CMD_PUT_ITEM)  -- mint or update a value (see the
#             read-before-write contract documented on the API methods).
#
# The packet parser and the transaction-form value-record codec live in
# e_DB.pm, the way e_TRACK pairs with d_TRACK.  This file holds the service
# class, the command constants, %DB_PARSE_RULES and %DB_FIELDS.
#
# ASYNC MODEL (B-): getItem / putItem are SYNCHRONOUS and BLOCK up to the
# b_sock command_timeout.  A client must call them from a thread it spawns,
# never the wx main thread, and must keep only one such call in flight per
# d_DB socket at a time.

package Pub::Ray::NET::d_DB;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Pub::Ray::NET::a_utils;
use Pub::Ray::NET::a_defs;
use base qw(Pub::Ray::NET::b_sock);
require Pub::Ray::NET::e_DB;


my $dbg     = 0;
my $dbg_api = 0;
my $dbg_sub = 1;		# per-fid subscription tracing; lower to show it


# onIdle registers fids with the E80 so the DBNAV multicast 'goes rich';
# $HOW_INIT picks the set.
our $INIT_DB_NONE  = 0;		# register nothing (only the 5 always-on fids broadcast)
our $INIT_DB_KNOWN = 1;		# register the named %DB_FIELDS fids
our $INIT_DB_ALL   = 2;		# register every fid 0x02..0xff

our $HOW_INIT_DB = $INIT_DB_ALL;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$self_db

		$DB_SERVICE_ID
		$SUCCESS2_SIG

		$DB_CMD_SUB_DIR
		$DB_CMD_DEF
		$DB_CMD_SUB_VALUE
		$DB_CMD_EXISTS
		$DB_CMD_LIST
		$DB_CMD_GET_VALUE
		$DB_CMD_GET_ITEM
		$DB_CMD_PUT_ITEM
		$DB_CMD_DEL_ITEM

		$DB_REPLY_PUSH_DIR
		$DB_REPLY_PUSH_VALUE
		$DB_REPLY_ITEM_LIST
		$DB_REPLY_VALUE
		$DB_REPLY_ITEM

		$DB_INFO_START
		$DB_INFO_RECORD
		$DB_INFO_END
		$DB_PUSH_START
		$DB_PUSH_RECORD
		$DB_PUSH_END

		$DB_EVENT_PING

		%DB_MSG_NAME
		%DB_PARSE_RULES
		%DB_FIELDS

		$DB_FIELD_WIND_ANGLE_APP
		$DB_FIELD_WIND_ANGLE_TRUE

		$HOW_INIT_DB
		$INIT_DB_NONE
		$INIT_DB_KNOWN
		$INIT_DB_ALL

	);
}

our $self_db:shared;


#------------------------------------------
# protocol constants
#------------------------------------------

our $DB_SERVICE_ID = 16;
	# 16 == 0x10 == '1000' in streams

our $SUCCESS2_SIG = '04000000';
	# the DB StartTransaction status word (0x00000004), distinct from the
	# FILESYS/WPMGR success signature '00000400'

# Command codes are the LOW byte of the 16-bit cmd_word; the high byte is the
# $DIRECTION_* nibble (a_defs).  The full firmware cmd_word is shown in each
# comment.  Wire-confirmed against NET/docs/logs/rns_db_field_enum.txt.

# requests (client -> server, used with $DIRECTION_SEND)
our $DB_CMD_SUB_DIR    = 0x00;	# 0x100 RegisterForUpdates           subscribe all of a fid's sources
our $DB_CMD_DEF        = 0x01;	# 0x101 (field-definition probe)     no reply to a bare request
our $DB_CMD_SUB_VALUE  = 0x02;	# 0x102 RegisterForPreferredUpdates  subscribe a fid's preferred value
our $DB_CMD_EXISTS     = 0x03;	# 0x103 (existence probe)            no reply to a bare request
our $DB_CMD_LIST       = 0x04;	# 0x104 GetItemList                  enumerate a fid's sources
our $DB_CMD_GET_VALUE  = 0x05;	# 0x105 GetPreferredItem             read the preferred source's value
our $DB_CMD_GET_ITEM   = 0x06;	# 0x106 GetItemWithTransport         keyed read of one specific source
our $DB_CMD_PUT_ITEM   = 0x07;	# 0x107 SetItemUnconfirmed           the value write (no reply)
our $DB_CMD_DEL_ITEM   = 0x08;	# 0x108 DeleteItem                   delete one source (UNTESTED on hw)

# responses + unsolicited pushes (server -> client, used with $DIRECTION_RECV)
our $DB_REPLY_PUSH_DIR   = 0x00;	# 0x000 directory-change announce (zero seq)
our $DB_REPLY_PUSH_VALUE = 0x01;	# 0x001 value-change announce     (zero seq)
our $DB_REPLY_ITEM_LIST  = 0x02;	# 0x002 ItemList                      reply to CMD_LIST
our $DB_REPLY_VALUE      = 0x03;	# 0x003 GetPreferredItemResponse      reply to CMD_GET_VALUE
our $DB_REPLY_ITEM       = 0x04;	# 0x004 GetItemWithTransportResponse  reply to CMD_GET_ITEM

# transaction phases (bidirectional, used with $DIRECTION_INFO)
our $DB_INFO_START   = 0x00;	# 0x200 StartTransaction
our $DB_INFO_RECORD  = 0x01;	# 0x201 SendData        (carries the value-record)
our $DB_INFO_END     = 0x02;	# 0x202 EndTransaction
our $DB_PUSH_START   = 0x03;	# 0x203 UpdateStartTransaction (unsolicited)
our $DB_PUSH_RECORD  = 0x04;	# 0x204 UpdateSendData
our $DB_PUSH_END     = 0x05;	# 0x205 UpdateEndTransaction

# event (used with $DIRECTION_EVENT)
our $DB_EVENT_PING   = 0x00;	# 0x500 Ping (accepted no-op keepalive; NOT a close)


our %DB_MSG_NAME = (
	($DIRECTION_SEND | $DB_CMD_SUB_DIR)    => 'SUB_DIR',
	($DIRECTION_SEND | $DB_CMD_DEF)        => 'DEF',
	($DIRECTION_SEND | $DB_CMD_SUB_VALUE)  => 'SUB_VALUE',
	($DIRECTION_SEND | $DB_CMD_EXISTS)     => 'EXISTS',
	($DIRECTION_SEND | $DB_CMD_LIST)       => 'LIST',
	($DIRECTION_SEND | $DB_CMD_GET_VALUE)  => 'GET_VALUE',
	($DIRECTION_SEND | $DB_CMD_GET_ITEM)   => 'GET_ITEM',
	($DIRECTION_SEND | $DB_CMD_PUT_ITEM)   => 'PUT_ITEM',
	($DIRECTION_SEND | $DB_CMD_DEL_ITEM)   => 'DEL_ITEM',

	($DIRECTION_RECV | $DB_REPLY_PUSH_DIR)   => 'PUSH_DIR',
	($DIRECTION_RECV | $DB_REPLY_PUSH_VALUE) => 'PUSH_VALUE',
	($DIRECTION_RECV | $DB_REPLY_ITEM_LIST)  => 'REPLY_ITEM_LIST',
	($DIRECTION_RECV | $DB_REPLY_VALUE)      => 'REPLY_VALUE',
	($DIRECTION_RECV | $DB_REPLY_ITEM)       => 'REPLY_ITEM',

	($DIRECTION_INFO | $DB_INFO_START)   => 'INFO_START',
	($DIRECTION_INFO | $DB_INFO_RECORD)  => 'INFO_RECORD',
	($DIRECTION_INFO | $DB_INFO_END)     => 'INFO_END',
	($DIRECTION_INFO | $DB_PUSH_START)   => 'PUSH_START',
	($DIRECTION_INFO | $DB_PUSH_RECORD)  => 'PUSH_RECORD',
	($DIRECTION_INFO | $DB_PUSH_END)     => 'PUSH_END',

	($DIRECTION_EVENT | $DB_EVENT_PING)  => 'EVENT_PING',
);


# Parse rules, keyed by the full 16-bit cmd_word ($DIRECTION_* | code).
# pieces are consumed in order by e_DB::parsePiece (and the a_parser base);
# 'terminal' marks the frame that completes a reply (a value read also
# completes early on a not-found REPLY_VALUE -- handled in e_DB).

our %DB_PARSE_RULES = (

	# requests (SEND) -- parsed for outgoing monitoring only
	($DIRECTION_SEND | $DB_CMD_SUB_DIR)    => { pieces => ['fid'],        terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_SUB_VALUE)  => { pieces => ['fid'],        terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_DEF)        => { pieces => ['seq','fid'],  terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_EXISTS)     => { pieces => ['seq','fid'],  terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_LIST)       => { pieces => ['seq','fid'],  terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_GET_VALUE)  => { pieces => ['seq','fid'],  terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_GET_ITEM)   => { pieces => ['seq','key'],  terminal => 0 },
	($DIRECTION_SEND | $DB_CMD_PUT_ITEM)   => { pieces => ['seq','word'], terminal => 0 },  # word = 2-byte persist flag
	($DIRECTION_SEND | $DB_CMD_DEL_ITEM)   => { pieces => ['seq','key'],  terminal => 0 },

	# responses (RECV)
	($DIRECTION_RECV | $DB_REPLY_VALUE)      => { pieces => ['seq','fid','db_bits','word'], terminal => 0 },
	($DIRECTION_RECV | $DB_REPLY_ITEM_LIST)  => { pieces => ['seq','fid','count','ids'],    terminal => 0 },
	($DIRECTION_RECV | $DB_REPLY_ITEM)       => { pieces => ['seq'],                        terminal => 0 },
	($DIRECTION_RECV | $DB_REPLY_PUSH_VALUE) => { pieces => ['zero','fid','db_bits','word'],terminal => 1, is_event => 1 },
	($DIRECTION_RECV | $DB_REPLY_PUSH_DIR)   => { pieces => ['zero'],                       terminal => 1, is_event => 1 },

	# transaction / INFO (bidirectional)
	($DIRECTION_INFO | $DB_INFO_START)   => { pieces => ['seq','uuid','success2'],      terminal => 0 },
	($DIRECTION_INFO | $DB_INFO_RECORD)  => { pieces => ['seq','biglen','record'],      terminal => 0 },
	($DIRECTION_INFO | $DB_INFO_END)     => { pieces => ['seq','uuid'],                 terminal => 1 },
	($DIRECTION_INFO | $DB_PUSH_START)   => { pieces => ['zero','uuid','success2'],     terminal => 0 },
	($DIRECTION_INFO | $DB_PUSH_RECORD)  => { pieces => ['zero','biglen','fid','record'],terminal => 0 },
	($DIRECTION_INFO | $DB_PUSH_END)     => { pieces => ['zero','uuid'],                terminal => 1, is_event => 1 },

	# event
	($DIRECTION_EVENT | $DB_EVENT_PING)  => { pieces => [], terminal => 1, is_event => 1 },

);


#--------------------------------------------------------------
# FID mapping -- the %DB_FIELDS table d_DBNAV decodes against
#--------------------------------------------------------------

our $DB_FIELD_WIND_ANGLE_APP	= 0x59;		# 360 relative to bow heading
our $DB_FIELD_WIND_ANGLE_TRUE	= 0x5b;		# 360 relative to bow heading

# This deserves a comment.  The fuel math is just plain weird.
# Given two tanks with a level 0..100 and a capacity in gallons, litres whatever,
# - they give level2 (scaled by 250) as 0..100 in the engine section
# - they give the total fuel remaining as (capacity1 * level1 + capacity2 * level2) in the summary section
# - the give the capacity of tank2 in the total section, as the final FID
# Its asymetric, sparse, and you would have to solve a pair of equations in two variables
# 	to figure out tank1's level and capacity, though tank1 is arguably the 'main' fuel tank
# 	on the boat.
# Furthermore, just so you know, they DONT follow the NMEA2000 spec for sending the levels
# 	to the E80, which states they *should* be scaled by 250 on input, 

our %DB_FIELDS = (

	0x03	=> { name => 'SPEED', 			type => 'centiMetersPerSec', },		# thru water
	0x04	=> { name => 'SOG', 			type => 'centiMetersPerSec', },     #
	0x07	=> { name => 'LOG_TOTAL',		type => 'distanceMeters', },		#
	0x08	=> { name => 'LOG_TRIP',		type => 'distanceMeters', },		#
	0x09	=> { name => 'DEPTH',			type => 'depth',     },             #
	0x12	=> { name => 'TIME',			type => 'time',      },             #
	0x13	=> { name => 'DATE',			type => 'date',      },             #
	0x17	=> { name => 'HEADING',			type => 'heading',   },             #
	0x18	=> { name => 'SET',				type => 'heading',   },             #
	0x19	=> { name => 'DRIFT',			type => 'centiMetersPerSec', },   	#
	0x1a	=> { name => 'COG',				type => 'heading',   },             #
	0x1c	=> { name => 'HEAD_MAYBE',		type => 'heading',   },             # just a guess
	0x21	=> { name => 'ENG_OIL_PRESS1',	type => 'millibarsToPSI', },		# psi
	0x22	=> { name => 'ENG_OIL_TEMP1',	type => 'kelvinOver10', },			# farenheight
	0x24	=> { name => 'ENG_COOL_TEMP1',	type => 'kelvinOver100', },			# farenheight
	0x25	=> { name => 'ENG_ALT_VOLT1',   type => 'wordOver100',},			#
	0x26	=> { name => 'ENG_FUEL_RATE',   type => 'deciLitresToGallons',},	# gph
	0x30	=> { name => 'ENG_RPM1',   		type => 'intWordOver4',},			# rpms
	0x32	=> { name => 'FUEL_LEVEL2',		type => 'wordOver250',},			# 0..100 percent; weirdly stored as *250
	0x34	=> { name => 'XTE',				type => 'distanceCentiMeters', },   # centimeters, was $DB_FIELD_WP_TIME_2000 from NMEA2000
	0x44	=> { name => 'LATLON',			type => 'latLon',    },             #
	0x47	=> { name => 'HEADING_MAG',		type => 'heading',   },             #
	0x48	=> { name => 'HEADING_MAG2',	type => 'heading',   },             #
	0x49	=> { name => 'SET_MAG',			type => 'heading',   },             #
	0x55	=> { name => 'VMG_WIND', 		type => 'centiMetersPerSec', },     #
	0x58	=> { name => 'WIND_SPEED_APP', 	type => 'deciMetersPerSec', },		#
	0x59	=> { name => 'WIND_ANGLE_APP',	type => 'heading',   },             # 360 relative to bow heading
	0x5a	=> { name => 'WIND_SPEED_TRUE', type => 'deciMetersPerSec', },		# 360 relative to bow heading
	0x5b	=> { name => 'WIND_ANGLE_TRUE',	type => 'heading',   },             #
	0x5c	=> { name => 'WIND_SPEED_GND', 	type => 'deciMetersPerSec', },		#
	0x5d	=> { name => 'WIND_ANGLE_GND',	type => 'heading',   },             # note that the E80 shows MAG despite the "T" it shows
	0x66	=> { name => 'WP_HEADING',		type => 'heading', 	 },				#
	0x67	=> { name => 'WP_HEADING_MAG',	type => 'heading', 	 },				#
	0x6a	=> { name => 'WP_DISTANCE',		type => 'distanceMeters', },		#
	0x69	=> { name => 'WP_ID',			type => 'string',	 },				# only to two decimal places (60 feet)
	0x93	=> { name => 'NORTHEAST',		type => 'northEast', },             #
	0x70	=> { name => 'WP_HEADING2',		type => 'heading', 	 },				#
	0x7f	=> { name => 'VMG_WIND', 		type => 'centiMetersPerSec', },     #
	0x99	=> { name => 'LATLON2',			type => 'latLon',    },             #
	0x9c	=> { name => 'TIME2',			type => 'time',  	 },      		#
	0xaa	=> { name => 'DATE2',			type => 'date',      },             #
	0xb6	=> { name => 'VMG_WPT', 		type => 'centiMetersPerSec', },     #
	0xba	=> { name => 'HEAD2',			type => 'heading',   },             #
	0xbb	=> { name => 'HEAD3',			type => 'heading',   },             #
	0xbc	=> { name => 'HEAD4',			type => 'heading',   },             #
	0xbd	=> { name => 'HEAD5_MAG',		type => 'heading',   },             #
	0xbe	=> { name => 'SPEED_AVG', 		type => 'centiMetersPerSec', },		#
	0xbf	=> { name => 'DEPTH_AVG',		type => 'depth',     },             #
	0xc1	=> { name => 'COG2',			type => 'heading',   },             #
	0xc3	=> { name => 'WP_HEADING3',		type => 'heading', 	 },				#
	0xc4	=> { name => 'WP_LATLON',		type => 'latLon',    },             #
	0xc5	=> { name => 'WP_NORTHEAST',	type => 'northEast', },             #
	0xcf	=> { name => 'WP_LEG_DIST?',	type => 'distanceMeters', },		#
	0xd0	=> { name => 'WP_TIME',			type => 'seconds',      },          # seconds
	0xd8	=> { name => 'WP_NAME',			type => 'string15',  },				# might be null terminated; remove empty spaces
	0xdf	=> { name => 'TIME3',			type => 'time',      },             #
	0xee	=> { name => 'TIME4',			type => 'time',      },             #
	0xef	=> { name => 'DATE2',			type => 'date',      },             #
	0xf2	=> { name => 'SET_AVG',			type => 'heading',   },             #
	0xf3	=> { name => 'SET_MAG_AVG',		type => 'heading',   },             #
	0xfa	=> { name => 'TOTAL_FUEL',		type => 'deciLitresToGallons',},	# gallons
	0xff	=> { name => 'FUEL_CAPACITY2',	type => 'deciLitresToGallons',},	# gallons

);



#===================================================================
# API -- two primitives: getItem and putItem
#===================================================================
# MODEL B-: both BLOCK on the socket round-trip, so a client must call them
# from a thread IT spawns (never the wx main thread), and keep only one such
# call in flight per d_DB socket at a time.
#
# READ-BEFORE-WRITE CONTRACT.  The E80 keys a value by (fid, source-uuid).
# A fid can have several sources; getItem returns the PREFERRED source and
# its uuid.  On an INITIAL write of a fid the E80 MINTS its own source uuid
# and ignores whatever uuid we send -- so a brand-new item is created simply
# by calling putItem (omit the uuid).  To UPDATE an item that already exists
# you must address the SAME source the E80 minted, so you have to getItem
# first, take its $rec->{uuid}, and pass that uuid to putItem -- otherwise
# the write does not land on the existing source.  Writes are unacknowledged
# (silence == accepted); confirm by reading the value back.
#
# So a client that wants to set fid F to value V does:
#
#     my $rec  = $db->getItem($F);                       # learn current state
#     my $uuid = (ref $rec) ? $rec->{uuid} : undef;      # undef => not present => mint
#     $db->putItem($F, $ENC, $V, $persist, $uuid);       # uuid omitted on a mint
#     # then optionally: $db->getItem($F) again to confirm $rec->{value} == $V
#
# (e.g. the mod003 timed-track toggle is fid 0x05ff0001, enc 0x0054 BOOL8;
#  nonzero == stock tracks, absent/0 == timed.  That policy lives in the
#  client, not here.)


sub getItem
	# Read a fid's preferred-source value (CMD_GET_VALUE).
	# RETURNS:
	#   - the decoded value-record hash on success: { fid, enc, size, value,
	#     value_hex, A, B, descriptor, uuid } -- where 'uuid' is the E80
	#     source uuid you feed back to putItem to UPDATE this item;
	#   - undef       if the fid is not found / not currently feeding;
	#   - '' / false  on a send or wait-reply error.
	# BLOCKS up to command_timeout -- call from a spawned worker thread.
{
	my ($this, $fid) = @_;
	display($dbg_api,0,sprintf("d_DB getItem(0x%x)",$fid));
	return error("getItem: d_DB not connected") if !$this->{connected};

	my $seq = $this->{next_seqnum}++;
	my $msg = createDBMsg($seq, $DIRECTION_SEND | $DB_CMD_GET_VALUE, pack('V',$fid));
	return '' if !$this->sendRequest($seq, sprintf("getItem(0x%x)",$fid), $msg);

	my $reply = $this->waitReply(0);
	return $reply if !$reply || !ref($reply);		# '' timeout / undef death pass-through

	if (!$reply->{found})
	{
		display($dbg_api,1,sprintf("getItem(0x%x) not found (db_bits=0x%04x)",$fid,$reply->{db_bits}||0));
		return undef;
	}

	my $record = $reply->{record};
	$record->{uuid} = $reply->{uuid} if $record && $reply->{uuid};
	return $record;
}


sub putItem
	# Write a fid's value (CMD_PUT_ITEM): a four-frame transaction the
	# protocol does NOT acknowledge.  Returns 1 once the frames are queued
	# to the socket; there is no wire confirmation, so to verify the write
	# took, the caller reads the value back with getItem.
	#
	# See the READ-BEFORE-WRITE CONTRACT above: call getItem FIRST.
	#   - item already exists -> pass $uuid = the getItem record's {uuid}
	#     so the write updates that same source;
	#   - item does not exist -> omit $uuid (or pass any) -- the E80 mints
	#     its own uuid on this first write; a getItem afterwards then yields
	#     the real uuid for any future updates.
	#
	#   $fid      the field id
	#   $enc      the encoding id (e.g. 0x0054 BOOL8); fixes the value width
	#             (see e_DB::buildDBRecord / %ENC_SIZE)
	#   $value    the integer value to write
	#   $persist  1 = write through to flash (survives reboot), 0 = RAM only
	#             (defaults to 1)
	#   $uuid     16-hex-char source uuid; omit on a mint, pass getItem's on
	#             an update (defaults to a throwaway the E80 replaces)
	# BLOCKS only on the socket send -- call from a spawned worker thread.
{
	my ($this, $fid, $enc, $value, $persist, $uuid) = @_;
	$persist = 1 if !defined $persist;
	$uuid    = 'dddddddddddddddd' if !$uuid;		# initial-write throwaway; E80 mints its own
	display($dbg_api,0,sprintf("d_DB putItem(0x%x, enc=0x%04x, value=%d, persist=%d, uuid=%s)",$fid,$enc,$value,$persist,$uuid));
	return error("putItem: d_DB not connected") if !$this->{connected};
	return error(sprintf("putItem(0x%x): uuid '%s' must be 16 hex chars",$fid,$uuid))
		if length($uuid) != 16;

	my $uuid_bytes = pack('H*', $uuid);
	my $succ2      = pack('H*', $SUCCESS2_SIG);
	my $record     = Pub::Ray::NET::e_DB::buildDBRecord({ fid => $fid, enc => $enc, value => $value });
	my $biglen     = length($record);

	my $seq = $this->{next_seqnum}++;
	$this->sendPacket(createDBMsg($seq, $DIRECTION_SEND | $DB_CMD_PUT_ITEM, pack('v',$persist)));
	$this->sendPacket(createDBMsg($seq, $DIRECTION_INFO | $DB_INFO_START,   $uuid_bytes . $succ2));
	$this->sendPacket(createDBMsg($seq, $DIRECTION_INFO | $DB_INFO_RECORD,  pack('V',$biglen) . $record));
	$this->sendPacket(createDBMsg($seq, $DIRECTION_INFO | $DB_INFO_END,     $uuid_bytes));
	return 1;
}



#---------------------------------------------------
# service lifecycle
#---------------------------------------------------

sub init
{
	my ($this) = @_;
	display($dbg,0,"d_DB init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip} = $LOCAL_IP;
	$this->{inited} = 0;
	$this->{exists} = shared_clone({});
		# the shared set d_DBNAV marks each broadcast fid into
	$self_db = $this;
	return $this;
}


sub destroy
{
	my ($this) = @_;
	display($dbg,0,"d_DB destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::destroy();
	$self_db = undef;
	return $this;
}


sub uiInit
{
	my ($this) = @_;
	display($dbg,0,"d_DB uiInit()");
	$this->{inited} = 0;
}


sub onConnect
{
	my ($this) = @_;
	$this->{inited} = 0;
}


sub onIdle
	# Register fids with the E80 so the DBNAV multicast 'goes rich'.
	# $HOW_INIT picks the set.  {exists} is the shared set of fids already
	# registered or already arriving on the broadcast (d_DBNAV marks each
	# fid it decodes), so each fid is registered once and the pass repeats
	# across idle ticks until nothing new is left.
{
	my ($this) = @_;
	return if $this->{inited};

	if ($HOW_INIT_DB == $INIT_DB_NONE)
	{
		$this->{inited} = 1;
		return;
	}

	my @fids = $HOW_INIT_DB == $INIT_DB_KNOWN ?
		(sort {$a <=> $b} keys %DB_FIELDS) :
		(0x02 .. 0xff);

	my $any = 0;
	my $exists = $this->{exists};
	for my $fid (@fids)
	{
		next if $exists->{$fid};
		$any++;
		my $name = $DB_FIELDS{$fid} ? $DB_FIELDS{$fid}->{name} : sprintf("UNKNOWN(%02x)",$fid);
		display($dbg_sub,0,sprintf("subscribe fid(0x%02x) %s",$fid,$name));
		$this->sendSubscribe($fid);
		$exists->{$fid} = 1;
	}

	$this->{inited} = 1 if !$any;
}


#---------------------------------------------------
# wire framing
#---------------------------------------------------

sub createDBMsg
	# build one DB wire message: [len:2][cmd_word:2][sid:2][body].
	# A zero $seq is omitted (subscribe frames carry no seq).
{
	my ($seq, $cmd_word, $body) = @_;
	$body = '' if !defined $body;
	my $data =
		pack('v', $cmd_word) .
		pack('v', $DB_SERVICE_ID);
	$data .= pack('V', $seq) if $seq;
	$data .= $body;
	return pack('v', length($data)) . $data;
}


sub sendSubscribe
	# fire-and-forget CMD_SUB_VALUE (no seq, no reply) -- adds a fid to the
	# DBNAV broadcast lists.
{
	my ($this, $fid) = @_;
	#$this->sendPacket(createDBMsg(0, $DIRECTION_SEND | $DB_CMD_SUB_VALUE, pack('V',$fid)));
	$this->sendPacket(createDBMsg(0, $DIRECTION_SEND | $DB_CMD_SUB_DIR, pack('V',$fid)));
}


sub sendRequest
	# send a seq'd request and arm waitReply for its reply.
{
	my ($this, $seq, $name, $msg) = @_;
	$this->sendPacket($msg);
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $name;
	return 1;
}




1;
