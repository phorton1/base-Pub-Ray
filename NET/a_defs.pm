#---------------------------------------------
# a_defs.pm
#---------------------------------------------

package Pub::Ray::NET::a_defs;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket qw(pack_sockaddr_in inet_aton);
use Pub::Utils;
use Pub::Prefs;






BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		initServices
	
		$LOCAL_IP

		$RAYDP_NAME
		$RAYDP_SID
		$RAYDP_IP
		$RAYDP_PORT
		$RAYDP_ADDR

		$SPORT_FILESYS
        $SPORT_WPMGR
        $SPORT_TRACK
        $SPORT_DBNAV
		$SPORT_DB

		$SID_DIAG

		%DEVICE_TYPE
		%KNOWN_DEVICES
		%KNOWN_SERVER_IPS
		$SHARK_DEVICE_ID

		%KNOWN_SERVICES
		%FIXED_PORT_DEFS
		%TAIL_SERVICE_DEFS

		$DIRECTION_RECV
		$DIRECTION_SEND
		$DIRECTION_INFO
		$DIRECTION_EVENT
		%DIRECTION_NAME

		$RNS_FILESYS_PORT
        $FILESYS_SERVICE_ID
        $FILESYS_PORT
		$HIDDEN_PORT1

		$LOCAL_UDP_PORT_BASE
        $LOCAL_UDP_SEND_PORT

		$SUCCESS_SIG
		$RAYDP_WAKEUP_PACKET

		$ROUTE_COLOR_RED
		$ROUTE_COLOR_YELLOW
		$ROUTE_COLOR_GREEN
		$ROUTE_COLOR_BLUE
		$ROUTE_COLOR_PURPLE
		$ROUTE_COLOR_BLACK
		$NUM_ROUTE_COLORS

		$E80_MAX_NAME
		$E80_MAX_COMMENT
		$E80_MAX_TRACK_POINTS
		$E80_MAX_TRACKS

		$PI
		$PI_OVER_2
		$SCALE_LATLON
		$METERS_PER_NM
		$FEET_PER_METER
		$SECS_PER_DAY
		$KNOTS_TO_METERS_PER_SEC
		$PSI_TO_MILLIBARS
		$GALLONS_TO_LITRES

		$E80_0A_IP
		$E80_1_IP
        $E80_2_IP
		$E80_3_IP
		$E80_4_IP
    );
}




# Interesting factoids that I want to remember

our $E80_0A_IP = '10.0.18.120';
our $E80_1_IP = '10.0.241.54';
our $E80_2_IP = '10.0.240.83';
our $E80_3_IP = '10.0.42.39';
our $E80_4_IP = '10.0.166.121';

#----------------------------------------
# main stuff
#----------------------------------------
# our local IP is fixed by ethernet config

our $LOCAL_IP = '10.0.0.200';

# raydp is at a known mcast address with service_id 0

our $RAYDP_NAME = 'RAYDP';
our $RAYDP_SID  = 0;
our $RAYDP_IP   = '224.0.0.1';
our $RAYDP_PORT = 5800;
our $RAYDP_ADDR = pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP));


our $SPORT_FILESYS 	= 2049;
our $SPORT_WPMGR 	= 2052;
our $SPORT_TRACK 	= 2053;
our $SPORT_DBNAV 	= 2562;
our $SPORT_DB 		= 2050;

our $SID_DIAG 		= 0xdddd;	# Service ID of the Diagnostics service


our $LOCAL_UDP_PORT_BASE		= 9000;
our $LOCAL_UDP_SEND_PORT 		= $LOCAL_UDP_PORT_BASE;
	# the recognizable port of the single
	# global udp send-only socket
	# created (in a_utils.pm)


our $RNS_FILESYS_PORT		= 0x4800;	# 18432
our $FILESYS_SERVICE_ID 	= 0x0005;	# 5 = 0x005 = '0500'
our $FILESYS_PORT 			= $LOCAL_UDP_PORT_BASE + $FILESYS_SERVICE_ID;

# Found tcp port on E80 Master

our $HIDDEN_PORT1 = 6668;

# our local ports are at recognizable numbers distinct from RAYNET port ranges
# udp listeners, when needed, will be created at $LOCAL_UDP_PORT_BASE + func
# tcp ports, when needed, will be created at  $LOCAL_TCP_PORT_BASE + func



#-------------------------------------------
# fixed packets or parts of them
#-------------------------------------------

our $SUCCESS_SIG = '00000400';
our $RAYDP_WAKEUP_PACKET = 'ABCDEFGHIJKLMNOP',

# The direction nibble of the command word seems to
# be consistent across all services

our $DIRECTION_RECV		= 0x000;
our $DIRECTION_SEND		= 0x100;
our $DIRECTION_INFO		= 0x200;
our $DIRECTION_EVENT 	= 0x500;	# added for e_DB.pm

our %DIRECTION_NAME = (
	$DIRECTION_RECV => 'recv',
	$DIRECTION_SEND => 'send',
	$DIRECTION_INFO => 'info',
	$DIRECTION_EVENT => 'event',
);



#------------------------------
# E80 transport limits
#------------------------------
# Empirically confirmed hard limits on the E80 hardware.
# Exceeding these causes silent data loss on the device.
# The NET layer enforces these as hard errors; the DB has no such limits.

our $E80_MAX_NAME    = 15;    # waypoints, groups, routes, tracks
our $E80_MAX_COMMENT = 31;    # waypoints, groups, routes (tracks have no comment field)
our $E80_MAX_TRACK_POINTS = 1000;   # E80 CTrack is a fixed 1000-point buffer (navMate e80_stuff/abstracts/TRACK_writing.md)
our $E80_MAX_TRACKS       = 10;     # E80 saved-track database holds at most 10 tracks


#------------------------------
# E80 color constants
#------------------------------

our $ROUTE_COLOR_RED 	= 0;
our $ROUTE_COLOR_YELLOW = 1;
our $ROUTE_COLOR_GREEN	= 2;
our $ROUTE_COLOR_BLUE	= 3;
our $ROUTE_COLOR_PURPLE	= 4;
our $ROUTE_COLOR_BLACK	= 5;
our $NUM_ROUTE_COLORS   = 6;


#------------------------------
# mathematical constants
#------------------------------

our $PI 			= 3.14159265358979323846;
our $PI_OVER_2 		= $PI / 2;
our $SECS_PER_DAY 	= 86400;
our $SCALE_LATLON 	= 1e7;
our $METERS_PER_NM 	= 1852;
our $FEET_PER_METER	= 3.28084;
our $KNOTS_TO_METERS_PER_SEC = 0.5144;
our $PSI_TO_MILLIBARS	= 68.9476;
our $GALLONS_TO_LITRES 	= 3.78541;


#--------------------------------------------------
# Device types & IDENT packet comments
#--------------------------------------------------
# IDENT PACKETS START with 01
#
#                       _D_TYPE_ ---ID--- VERS     ---IP---                                                                       MASTER v
#	E80 #1 M - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#	E80 #1 S - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#
#	E80 #1 S - 01000000 00000000 37a681b2 39020000 36f1000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000
#	E80 #2 M - 01000000 00000000 37ad80b2 39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000100
#   RNS      - 01000000 03000000 ffffffff 76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000
#
# my $FAKE_RNS_2  = '01000000 03000000'.$SHARK_DEVICE_ID.'76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000';
# my $FAKE_E80_3  = '01000000 00000000'.$SHARK_DEVICE_ID.'39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000';

our %DEVICE_TYPE =(
	0 	=> 'E80',
	1 	=> 'E120',
	2 	=> 'DSM300',
	3 	=> 'RAYTECH',
	4 	=> 'SR100',
	5 	=> 'GPM400',
	6 	=> 'GVM400',
	7 	=> 'DSM400',
	8 	=> 'DSM30',
	9 	=> 'DIGITAL OPEN ARRAY',
	10	=> 'DIGITAL RADOME',
	11  => 'SEATALK HS RADOME', );
	#  12 = []
	#  13+ = Unknown


# I use a friendly name in place of the Service's id for
# known E80s in my system.  These Ids are visible on the
# E80's in the Diagnostics-ExternalInterfaces-Ehernet-Devices
# dialog when one E80 identifies others on the network.

our $SHARK_DEVICE_ID = 'aaaaaaaa';

our %KNOWN_DEVICES = (
	'c48a80b2' =>	'E80_0A',
	'37a681b2' =>	'E80_1',
	'37ad80b2' =>	'E80_2',
	'67e280b2' =>	'E80_3',
	'66af81b2' => 	'E80_4',
	'ffffffff' =>	'RNS',
	$SHARK_DEVICE_ID =>   'shark' );

our %KNOWN_SERVER_IPS = (
	$E80_0A_IP =>	'E80_0A',
	$E80_1_IP =>	'E80_1',
	$E80_2_IP =>	'E80_2',
	$E80_3_IP =>	'E80_3',
	$E80_4_IP =>	'E80_4',
	$LOCAL_IP =>	'RNS',	);



#------------------------------------------------------------------------
# Raymarine Service Names and our service_port names
#------------------------------------------------------------------------
# The E80 enumerates its Services on the unit at
#     Menu - System Diagnostics - External Interfaces - Ethernet - "Services"
# The leftmost column below is that Raymarine Service Name.
#
# Our own service_port names use a capitalization convention that shows how far
# we have gotten with a given service:
#
#     UPPERCASE    - a known Raymarine function I have decoded and implemented
#     Capitalized  - a known Raymarine function I have connected to, seen traffic
#                    from, and/or communicated with
#     lowercase    - a known Raymarine function I have not seen packets from
#     lowercase?   - a possible known Raymarine function
#
# The sid (Service ID) is the definitive identifier, carried in the RAYDP
# advertisement.  A service_port's port falls into one of two groups:
#
#     FIXED  - a deterministic port, known before any advertisement
#     TAIL   - a port taken first-come from 2056+ / 2563+ as instruments appear;
#              the sid identifies the service, the port does not
#
#   Raymarine Name    TCP    UDP    MCAST    My Name      sid    group
#   ------------------------------------------------------------------------------
#   Radar                    UDP    MCAST    Radar        1      TAIL
#   Fishfinder               UDP    MCAST    Sonar2       24     TAIL
#   Fishfinder               UDP    MCAST    Sonar3       32     TAIL
#   Database          TCP                    DB           16     FIXED
#   Database                 UDP             data_udp     16     FIXED
#   Database                        MCAST    DBNAV        16     FIXED
#   Waypoint          TCP                    WPMGR        15     FIXED
#   Track             TCP                    TRACK        19     FIXED
#   Navigation        TCP                    Navig        7      FIXED
#   Chart                    UDP             chart        23     consume-only
#   CF Access                UDP             FILESYS      5      FIXED
#   CF Access                       MCAST    filecast     5      FIXED
#   GPS                      UDP    MCAST    Gps          8      TAIL
#   DGPS                     UDP    MCAST    Dgps         21     TAIL
#   Compass                  UDP    MCAST    Compass      26     TAIL
#   Navtex                   UDP    MCAST    Navtex       29     TAIL
#   AIS                      UDP    MCAST    Ais          30     TAIL
#   Auto Pilot               UDP    MCAST    AutoPilot    9      TAIL
#   Alarm                    UDP             alarm_u      27     FIXED
#   Alarm                           MCAST    Alarm        27     FIXED
#   Sys                             MCAST    RAYDP        0      FIXED
#   GVM                                                          non-advertised
#   Monitor                                                      non-advertised
#   Keyboard                                                     non-advertised
#   RML Monitors                                                 non-advertised
#
# Sys is the RAYDP discovery mcast itself (sid 0); the "Sys" UDP activity on the
# unit tracks the advertising bursts on 224.0.0.1:5800.  GVM, Monitor, Keyboard
# and RML Monitors are internal, carry no sid, and never advertise.
#
# Advertised, but not shown on the unit's Services screen, so they have no
# Raymarine Service Name: DataMaster (sid 35), FishHistory (sid 22), and the
# Diagnostics binds (sid 0xdddd, the 6667/6668 ports).

our %KNOWN_SERVICES = (
	0	=> 'RAYDP',
	1	=> 'Radar',
	5	=> 'FILESYS',
	7	=> 'Navig',
	8	=> 'Gps',
	9	=> 'AutoPilot',
	15	=> 'WPMGR',
	16	=> 'DB',
	19	=> 'TRACK',
	21	=> 'Dgps',
	22	=> 'FishHistory',
	24	=> 'Sonar2',
	26	=> 'Compass',
	27	=> 'Alarm',
	29	=> 'Navtex',
	30	=> 'Ais',
	32	=> 'Sonar3',
	35	=> 'DataMaster',
	$SID_DIAG => 'Diagnostics',
);


#--------------------------------------------------------------------------------------
# Service port definitions
#--------------------------------------------------------------------------------------
# Two tables describe the service_ports.  %FIXED_PORT_DEFS, keyed by port, holds the
# deterministic ports -- the always-on allocator block, the Alarm and RAYDP binds, and
# the unadvertised Diagnostics binds -- which are known before any advertisement and so
# can be pre-seeded.  %TAIL_SERVICE_DEFS, keyed by sid, holds the instrument tail, whose
# port is taken first-come from 2056+/2563+ and is only known at discovery, where the
# wire sid names the service.
#
# These definitions drive RAYDP (the ports b_sock connects to, with their parsers) and
# form the basis of the sniffer (the tshark monitoring of RNS<->E80 traffic).  The
# per-port default monitoring characteristics live in a_mon.pm, which keeps a separate
# set for RAYDP (%SHARK_DEFAULTS) and the sniffer (%SNIFFER_DEFAULTS).
#
# General Behavioral Notes
#
# - No new ports show up on bare E80 with chart card
#
# PORT Specific Behavioral Notes
#
#	2055 - FishHistory
#		I am able to connect with TCP with 2055, but no new connections show in E80 Services list.
# 		Immediatly starts receiving 9 byte messags with command_word(0000) func(1600) dword(00570200) byte(00)
#	2563 - a tail mcast slot
#		start getting udp packets when RNS running and E80 has Fix/Heading
#			224.30.38.196:2563   <-- 10.0.241.54:1219
#			00000800 05f40500 dc000000 01000000 74f88210 914f0000 00000000 00000000
#		no new Service UDP byte tx/rx seen
#	the instrument tail ports move as instruments come and go (e.g. 2056/2563 vs 2057/2564)
#
# Additional "possibly open" udp ports between 1000 and 10000
#
#	PORT(69) 	may be open - adds to E80 rx queue
#	PORT(1000) 	may be open - adds to E80 rx queue
#	PORT(1001) 	may be open - no longer after I terminated RNS
#	PORT(1002) 	may be open - no longer after I terminated RNS
#	PORT(6667) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(8443) 	may be open - adds to E80 rx queue; adds to E80 dropped packets stats
#	PORT(10000) may be open - no longer after I terminated RNS
#
# 2025-10-26 - found a potentially unadvertised 'self' mcast service on RNS
#	at 224.0.0.252:5355

our %FIXED_PORT_DEFS = (

	# allocator always-on block, unicast 2048-2055
	2048 => { sid => 35, name => 'DataMaster',    proto => 'udp'   },
	2049 => { sid => 5,  name => 'FILESYS',       proto => 'udp'   },
	2050 => { sid => 16, name => 'DB',            proto => 'tcp'   },
	2051 => { sid => 16, name => 'data_udp',      proto => 'udp'   },
	2052 => { sid => 15, name => 'WPMGR',         proto => 'tcp'   },
	2053 => { sid => 19, name => 'TRACK',         proto => 'tcp'   },
	2054 => { sid => 7,  name => 'Navig',         proto => 'tcp'   },
	2055 => { sid => 22, name => 'FishHistory',   proto => 'tcp'   },

	# allocator always-on block, mcast 2560-2562
	2560 => { sid => 35, name => 'DataMaster',    proto => 'mcast' },
	2561 => { sid => 5,  name => 'filecast',      proto => 'mcast' },
	2562 => { sid => 16, name => 'DBNAV',         proto => 'mcast' },

	# fixed, outside the allocator
	5800 => { sid => 0,  name => 'RAYDP',         proto => 'mcast' },
	5801 => { sid => 27, name => 'Alarm',         proto => 'mcast' },
	5802 => { sid => 27, name => 'alarm_u',       proto => 'udp'   },

	# unadvertised; reached only by pre-seeding (never arrive via RAYDP)
	6667 => { sid => $SID_DIAG, name => 'Diagnostics',   proto => 'udp' },
	6668 => { sid => $SID_DIAG, name => 'DiagnosticTCP', proto => 'tcp' },
);


our %TAIL_SERVICE_DEFS = (
	1  => { name => 'Radar',     protos => ['udp','mcast'] },
	8  => { name => 'Gps',       protos => ['udp','mcast'] },
	9  => { name => 'AutoPilot', protos => ['udp','mcast'] },
	21 => { name => 'Dgps',      protos => ['udp','mcast'] },
	24 => { name => 'Sonar2',    protos => ['udp','mcast'] },
	26 => { name => 'Compass',   protos => ['udp','mcast'] },
	29 => { name => 'Navtex',    protos => ['udp','mcast'] },
	30 => { name => 'Ais',       protos => ['udp','mcast'] },
	32 => { name => 'Sonar3',    protos => ['udp','mcast'] },
);


sub initServices
{
	my (%want) = @_;
	# Resolve the E-Series adapter IP from prefs (default = the $LOCAL_IP constant
	# above).  BOTH apps call initServices AFTER their prefs are loaded and BEFORE
	# the NET services bind, so this shared hook makes a wizard-written (or hand-
	# edited) navMate.prefs "LOCAL_IP" take effect for navMate -- and for shark too,
	# with no code change there.  With no prefs loaded (shark today) getPref returns
	# undef and the default is kept.
	$LOCAL_IP = getPref('LOCAL_IP') // $LOCAL_IP;
	my $auto_query = $want{auto_query} // 0;
	mergeHash($FIXED_PORT_DEFS{$SPORT_FILESYS},{
		parser_class	=> 'Pub::Ray::NET::e_FILESYS',
		implemented 	=> $want{filesys} || 0,
		auto_connect 	=> 1,
		auto_populate	=> $auto_query });
	mergeHash($FIXED_PORT_DEFS{$SPORT_WPMGR},{
		parser_class	=> 'Pub::Ray::NET::e_WPMGR',
		implemented 	=> $want{wpmgr} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($FIXED_PORT_DEFS{$SPORT_TRACK},{
		parser_class	=> 'Pub::Ray::NET::e_TRACK',
		implemented 	=> $want{track} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($FIXED_PORT_DEFS{$SPORT_DBNAV},{
		parser_class	=> 'Pub::Ray::NET::e_DBNAV',
		implemented 	=> $want{dbnav} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
	mergeHash($FIXED_PORT_DEFS{$SPORT_DB},{
		parser_class	=> 'Pub::Ray::NET::e_DB',
		implemented 	=> $want{db} || 0,
		auto_connect 	=> 1,
		auto_populate 	=> $auto_query });
}



1;
