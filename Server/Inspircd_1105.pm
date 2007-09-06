# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::Inspircd_1105;
use Nick;
use Modes;
use Server::BaseNick;
use Server::ModularNetwork;
use Server::InspMods;

use Persist 'Server::BaseNick', 'Server::ModularNetwork', 'Server::InspMods';
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @sendq     :Persist(sendq);
my @servers   :Persist(servers);
my @serverdsc :Persist(serverdsc);

my @auth      :Persist(auth); # 0/undef = unauth connection; 1 = authed, in burst; 2 = after burst
my @capabs    :Persist(capabs);

my @txt2pfx   :Persist(txt2pfx);
my @pfx2txt   :Persist(pfx2txt);

sub _init {
	my $net = shift;
	$sendq[$$net] = [];
	$net->module_add('CORE');
	$auth[$$net] = 0;
}

sub ignore { () }

sub nicklen { 
	my $net = shift;
	($capabs[$$net]{NICKMAX} || 32) - 1;
}

sub debug {
	print @_, "\e[0m\n";
}

sub str {
	my $net = shift;
	$net->id().'.janus';
}

sub intro {
	my($net,$param) = @_;
	$net->SUPER::intro($param);
	my @out;
	push @out, ['INIT', 'CAPAB START'];
	# we cannot continue until we get the remote CAPAB list so we can
	# forge the module list. However, we can set up the other server introductions
	# as they will be sent after auth is done
	push @out, $net->ncmd(VERSION => 'Janus Hub');
	for my $id (keys %Janus::nets) {
		my $new = $Janus::nets{$id};
		next if $new->isa('Interface') || $id eq $net->id();
		push @out, $net->ncmd(SERVER => "$id.janus", '*', 1, $new->netname());
		push @out, $net->cmd2("$id.janus", VERSION => 'Remote Janus Server: '.ref $new);
	}
	$net->send(@out);
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	debug "\e[0;32m     IN@".$net->id().' '. $line;
	$net->pong();
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] !~ s/^://) {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	unless ($auth[$$net] || $cmd eq 'CAPAB' || $cmd eq 'SERVER') {
		$net->send(['INIT', 'ERROR :Not authorized yet']);
		return ();
	}
	$net->from_irc(@args);
}

sub send {
	my $net = shift;
	push @{$sendq[$$net]}, $net->to_irc(@_);
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = '';
	if ($auth[$$net] == 3) {
		for my $i (@{$sendq[$$net]}, '') {
			if (ref $i) {
				$q .= join "\n", @$i[1..$#$i],'';
			} else {
				$q .= $i."\n" if $i;
			}
		}
		$sendq[$$net] = [];
	} else {
		my @delayed;
		for my $i (@{$sendq[$$net]}) {
			if (ref $i) {
				$q .= join "\n", @$i[1..$#$i],'';
			} else {
				push @delayed, $i;
			}
		}
		$sendq[$$net] = \@delayed;
		$auth[$$net] = 3 if $auth[$$net] == 2;
	}
	$q =~ s/\n+/\r\n/g;
	print "\e[0;34m    OUT@".$net->id().' '.$_."\e[0m\n" for split /\r\n/, $q;
	$q;
}

sub _connect_ifo {
	my ($net, $nick) = @_;

	my @out;

	my $mode = '+';
	for my $m ($nick->umodes()) {
		my $um = $net->txt2umode($m);
		next unless defined $um;
		if (ref $um) {
			push @out, $um->($net, $nick, '+'.$m);
		} else {
			$mode .= $um;
		}
	}
	
	my $srv = $nick->homenet()->id() . '.janus';
	$srv = $net->cparam('linkname') if $srv eq 'janus.janus';

	my $ip = $nick->info('ip') || '0.0.0.0';
	$ip = '0.0.0.0' if $ip eq '*';
	unshift @out, $net->cmd2($srv, NICK => $nick->ts(), $nick, $nick->info('host'), $nick->info('vhost'),
		$nick->info('ident'), $mode, $ip, $nick->info('name'));
	if ($nick->has_mode('oper')) {
		my $type = $nick->info('opertype') || 'IRC Operator';
		my $len = $net->nicklen() - 9;
		$type = substr $type, 0, $len;
		$type .= ' (remote)';
		$type =~ s/ /_/g;
		push @out, $net->cmd2($nick, OPERTYPE => $type);
	}
	push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
	
	@out;
}

sub process_capabs {
	my $net = shift;
	# NICKMAX=32 - done below in nicklen()
	# HALFOP=1
	if ($capabs[$$net]{HALFOP}) {
		$net->module_add('CAPAB_HALFOP');
	}
	# CHANMAX=65 - not applicable, we never send channels we have not heard before
	# MAXMODES=20 - TODO
	# IDENTMAX=12 - TODO
	# MAXQUIT=255 - TODO
	# MAXTOPIC=307 - TODO
	# MAXKICK=255 - TODO
	# MAXGECOS=128 -TODO
	# MAXAWAY=200 - TODO
	# IP6NATIVE=1 IP6SUPPORT=1 - we currently require IPv6 support, and claim to be native because we're cool like that :)
	# PROTOCOL=1105 - TODO
	# PREFIX=(qaohv)~&@%+ 
	local $_ = $capabs[$$net]{PREFIX};
	my(%p2t,%t2p);
	while (s/\((.)(.*)\)(.)/($2)/) {
		my $txt = $net->cmode2txt($1);
		$t2p{$txt} = $3;
		$p2t{$3} = $txt;
	}
	$pfx2txt[$$net] = \%p2t;
	$txt2pfx[$$net] = \%t2p;

	# CHANMODES=Ibe,k,jl,CKMNOQRTcimnprst
	my %split2c;
	$split2c{substr $_,0,1}{$_} = $net->txt2cmode($_) for $net->all_cmodes();

	# Without a prefix character, nick modes such as +qa appear in the "l" section
	exists $t2p{$_} or $split2c{l}{$_} = $split2c{n}{$_} for keys %{$split2c{n}};
	# tristates show up in the 4th group
	exists $split2c{r}{$_} = $split2c{t}{$_} for keys %{$split2c{t}};

	my $expect = join ',', map { join '', sort values %{$split2c{$_}} } qw(l v s r);

	unless ($expect eq $capabs[$$net]{CHANMODES}) {
		$net->send($net->ncmd(OPERNOTICE => 'Possible desync - CHANMODES do not match module list: '.
				"expected $expect, got $capabs[$$net]{CHANMODES}"));
	}
}

# IRC Parser
# Arguments:
# 	$_[0] = Network
# 	$_[1] = source (not including leading ':') or 'undef'
# 	$_[2] = command (for multipurpose subs)
# 	3 ... = arguments to the irc line; last element has the leading ':' stripped
# Return:
#  list of hashrefs containing the Action(s) represented (can be empty)

sub _parse_umode {
	my($net, $nick, $mode) = @_;
	my @mode;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} else {
			my $txt = $net->umode2txt($_) or do {
				warn "Unknown umode '$_'";
				next;
			};
			push @mode, $pm.$txt;
		}
	}
	my @out;
	push @out, +{
		type => 'UMODE',
		dst => $nick,
		mode => \@mode,
	} if @mode;
	@out;
}

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		return $itm->str($net) if $itm->is_on($net);
		return $itm->homenet()->id() . '.janus';
	} elsif ($itm->isa('Channel')) {
		warn "This channel message must have been misrouted: ".$itm->keyname()
			unless $itm->is_on($net);
		return $itm->str($net);
	} elsif ($itm->isa('Network')) {
		return $itm->id(). '.janus';
	} else {
		warn "Unknown item $itm";
		$net->cparam('linkname');
	}
}

sub cmd1 {
	my $net = shift;
	$net->cmd2(undef, @_);
}

sub ncmd {
	my $net = shift;
	$net->cmd2($net->cparam('linkname'), @_);
}

sub cmd2 {
	my($net,$src,$cmd) = (shift,shift,shift);
	my $out = defined $src ? ':'.$net->_out($src).' ' : '';
	$out .= $cmd;
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

my %moddef;
$moddef{CAPAB_HALFOP} = {
	cmode => {
		h => 'n_halfop',
	}
};
$moddef{CORE} = {
  cmode => {
		b => 'l_ban',
		i => 'r_invite',
		k => 'v_key',
		l => 's_limit',
		'm' => 'r_moderated',
		n => 'r_mustjoin',
		o => 'n_op',
		p =>   't1_chanhide',
		's' => 't2_chanhide',
		t => 'r_topic',
		v => 'n_voice',
  },
  umode => {
		i => 'invisible',
		n => 'snomask',
		o => 'oper',
		's' => 'globops', # technically, server notices
		w => 'wallops',
  },
  cmds => {
  	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			my $nick = $net->mynick($_[0]) or return ();
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
				nickts => (@_ == 4 ? $_[3] : time),
			};
		}
		my $ip = $_[8];
		$ip = $1 if $ip =~ /^[0:]+:ffff:(\d+\.\d+\.\d+\.\d+)$/;
		my %nick = (
			net => $net,
			ts => $_[2],
			nick => $_[3],
			info => {
				home_server => $_[0],
				host => $_[4],
				vhost => $_[5],
				ident => $_[6],
				ip => $ip,
				name => $_[-1],
			},
		);
		my @m = split //, $_[7];
		warn unless '+' eq shift @m;
		$nick{mode} = +{ map {
			my $t = $net->umode2txt($_);
			defined $t ? ($t => 1) : do {
				warn "Unknown umode '$_'";
				();
			};
		} @m };

		my $nick = Nick->new(%nick);
		my($good, @out) = $net->nick_collide($_[3], $nick);
		if ($good) {
			push @out, +{
				type => 'NEWNICK',
				dst => $nick,
			};
		} else {
			$net->send($net->cmd1(KILL => $_[3], 'hub.janus (Nick collision)'));
		}
		@out;
	}, OPERTYPE => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		my $otype = $_[2];
		$otype =~ s/_/ /g;
		return +{
			type => 'UMODE',
			dst => $nick,
			mode => [ '+oper' ],
		},+{
			type => 'NICKINFO',
			dst => $nick,
			item => 'opertype',
			value => $otype,
		};
	}, OPERQUIT => sub {
		(); # that's only of interest to local opers
	}, AWAY => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			dst => $nick,
			type => 'NICKINFO',
			item => 'away',
			value => $_[2],
		};
	}, FHOST => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'vhost',
			value => $_[2],
		};
	}, FNAME => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'name',
			value => $_[2],
		};
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'QUIT',
			dst => $nick,
			msg => $_[-1],
		};	
	}, KILL => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->nick($_[2]) or return ();
		my $msg = $_[3];
		$msg =~ s/^\S+!//;

		if ($dst->homenet()->id() eq $net->id()) {
			return {
				type => 'QUIT',
				dst => $dst,
				msg => $msg,
				killer => $src,
			};
		}
		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			net => $net,
			msg => $msg,
		};
	}, FJOIN => sub {
		my $net = shift;
		my $ts = $_[3];
		my $chan = $net->chan($_[2], $ts);
		my $applied = ($chan->ts() >= $ts);
		my @acts;
		push @acts, +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $ts,
			oldts => $chan->ts(),
			wipe => 1,
		} if $chan->ts() > $ts;

		for my $nm (split / /, $_[-1]) {
			$nm =~ /(?:(.*),)?(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2);
			my %mh = map { $pfx2txt[$$net]{$_} => 1 } split //, $nmode;
			push @acts, +{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => ($applied ? \%mh : undef),
			};
		}
		@acts;
	}, JOIN => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]);
		my $ts = $_[3];
		map {
			my $chan = $net->chan($_, $ts);
			+{
				type => 'JOIN',
				src => $src,
				dst => $chan,
			};
		} split /,/, $_[2];
	}, FMODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]);
		my $ts = $_[3];
		return () if $ts > $chan->ts();
		my($modes,$args,$dirs) = &Modes::from_irc($net, $chan, @_[4 .. $#_]);
		return +{
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
			dirs => $dirs,
		};
	}, MODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->item($_[2]) or return ();
		if ($dst->isa('Nick')) {
			$net->_parse_umode($dst, $_[3]);
		} else {
			my($modes,$args,$dirs) = &Modes::from_irc($net, $dst, @_[3 .. $#_]);
			return +{
				type => 'MODE',
				src => $src,
				dst => $dst,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			};
		}
	}, REMSTATUS => sub {
		my $net = shift;
		my $chan = $net->chan($_[2]);
		return +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $chan->ts(),
			oldts => $chan->ts(),
			wipe => 1,
		};
	}, FTOPIC => sub {
		my $net = shift;
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			topicts => $_[3],
			topicset => $_[4],
			topic => $_[-1],
		};
	}, TOPIC => sub {
		my $net = shift;
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			topicts => time,
			topicset => $_[0],
			topic => $_[-1],
		};
	}, PART => sub {
		my $net = shift;
		return map +{
			type => 'PART',
			src => $net->mynick($_[0]),
			dst => $net->chan($_),
			msg => $_[3],
		}, split /,/, $_[2];
	}, KICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[3]) or return ();
		return {
			type => 'KICK',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			kickee => $nick,
			msg => $_[4],
		};
	},
	INVITE => \&ignore,

	SERVER => sub {
		my $net = shift;
		unless ($auth[$$net]) {
			if ($_[3] eq $net->cparam('recvpass')) {
				$auth[$$net] = 1;
				$net->send(['INIT', 'BURST '.time, $net->ncmd(VERSION => 'Janus')]);
			} else {
				$net->send(['INIT', 'ERROR :Bad password']);
			}
		} else {
			# recall parent
			$servers[$$net]{lc $_[2]} = lc $_[0];
		}
		$serverdsc[$$net]{lc $_[2]} = $_[-1];
		+{
			type => 'BURST',
			net => $net,
			sendto => [],
		};
	}, SQUIT => sub {
		my $net = shift;
		my $netid = $net->id();
		my $srv = $_[2];
		my $splitfrom = $servers[$$net]{lc $srv};
		
		my %sgone = (lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$servers[$$net]}) {
				$sgone{$_} = 1 if $sgone{$servers[$$net]{$_}};
			}
		}
		print 'Lost servers: '.join(' ', sort keys %sgone)."\n";
		delete $servers[$$net]{$_} for keys %sgone;
		delete $serverdsc[$$net]{$_} for keys %sgone;

		my @quits;
		for my $nick ($net->all_nicks()) {
			next unless $nick->homenet()->id() eq $netid;
			next unless $sgone{lc $nick->info('home_server')};
			push @quits, +{
				type => 'QUIT',
				src => $net,
				dst => $nick,
				msg => "$splitfrom $srv",
			}
		}
		@quits;
	}, RSQUIT => sub {
		# TODO we should really de- and re-introduce the server after this
		();
	}, PING => sub {
		my $net = shift;
		my $from = $_[3] || $net->cparam('linkname');
		$net->send($net->cmd2($from, 'PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	BURST => sub {
		my $net = shift;
		return () if $auth[$$net] != 1;
		$auth[$$net] = 2;
		();
	}, CAPAB => sub {
		my $net = shift;
		if ($_[2] eq 'MODULES') {
			$net->module_add($_) for split /,/, $_[-1];
		} elsif ($_[2] eq 'CAPABILITIES') {
			$_ = $_[3];
			while (s/^\s*(\S+)=(\S+)//) {
				$capabs[$$net]{$1} = $2;
			}
		} elsif ($_[2] eq 'END') {
			# yep, we lie about all this.
			my $mods = join ',', sort grep /so$/, $net->all_modules();
			my $capabs = join ' ', sort map {
				my($k,$v) = ($_, $capabs[$$net]{$_});
				$k = undef if $k eq 'CHALLENGE'; # TODO generate our own challenge and use SHA256 passwords
				$k ? "$k=$v" : ();
			} keys %{$capabs[$$net]};
			my @out = 'INIT';
			push @out, 'CAPAB MODULES '.$1 while $mods =~ s/(.{1,495})(,|$)//;
			push @out, 'CAPAB CAPABILITIES :'.$1 while $capabs =~ s/(.{1,450})( |$)//;
			push @out, 'CAPAB END';
			push @out, $net->cmd1(SERVER => $net->cparam('linkname'), $net->cparam('sendpass'), 0, 'Janus Network Link');
			$net->send(\@out);
			$net->process_capabs();
		} # ignore START and any others
		();
	}, ERROR => sub {
		my $net = shift;
		+{
			type => 'NETSPLIT',
			net => $net,
			msg => 'ERROR: '.$_[-1],
		};
	},
	PONG => \&ignore, # already got ->ponged() above
	VERSION => \&ignore,
	ADDLINE => sub {
		my $net = shift;
		return +{
			type => 'XLINE',
			dst => $net,
			ltype => $_[2],
			mask => $_[3],
			setter => $_[4],
			settime => $_[5],
			expire => ($_[6] ? ($_[5] + $_[6]) : 0),
			reason => $_[7],
		};
	},	
	GLINE => sub {
		my $net = shift;
		my $type = substr $_[1],0,1;
		if (@_ == 3) {
			return +{
				type => 'XLINE',
				dst => $net,
				ltype => $type,
				mask => $_[2],
				setter => $_[0],
				expire => 1,
			};
		} else {
			return +{
				type => 'XLINE',
				dst => $net,
				ltype => $type,
				mask => $_[2],
				setter => $_[0],
				settime => time,
				expire => ($_[3] ? time + $_[3] : 0),
				reason => $_[4],
			};
		}
	},
	ELINE => 'GLINE',
	ZLINE => 'GLINE',
	QLINE => 'GLINE',

	SVSJOIN => sub {
		my $net = shift;
		my $src = $net->mynick($_[2]) or return ();
		return map +{
			type => 'JOIN',
			src => $src,
			dst => $net->chan($_),
		}, split /,/, $_[3];
	},
	SVSNICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet->id() eq $net->id()) {
			warn "Misdirected SVSNICK!";
			return ();
		} elsif (lc $nick->homenick eq lc $_[2]) {
			$net->release_nick(lc $_[2]);
			return +{
				type => 'RECONNECT',
				src => $net->item($_[0]),
				dst => $nick,
				net => $net,
				killed => 0,
				sendto => [ $net ],
			};
		} else {
			print "Ignoring SVSNICK on already tagged nick\n";
			return ();
		}
	},
	SVSMODE => 'MODE',
	REHASH => sub {
		return +{
			type => 'REHASH',
			sendto => [],
		};
	},
	MODULES => \&ignore,
	ENDBURST => sub {
		my $net = shift;
		return (+{
			type => 'LINKED',
			net => $net,
			sendto => [ values %Janus::nets ],
		}, +{
			type => 'RAW',
			dst => $net,
			msg => 'ENDBURST',
		});
	},

	PRIVMSG => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		if ($_[2] =~ /^\$/) {
			# server broadcast message. No action; these are confined to source net
			return ();
		} elsif ($_[2] =~ /(.?)(#\S*)/) {
			# channel message, possibly to a mode prefix
			return {
				type => 'MSG',
				src => $src,
				prefix => $1,
				dst => $net->chan($2),
				msg => $_[3],
				msgtype => $_[1],
			};
		} elsif ($_[2] =~ /^(\S+?)(@\S+)?$/) {
			# nick message, possibly with a server mask
			# server mask is ignored as the server is going to be wrong anyway
			my $dst = $net->nick($1);
			return +{
				type => 'MSG',
				src => $src,
				dst => $dst,
				msg => $_[3],
				msgtype => $_[1],
			} if $dst;
		}
		();
	},
	NOTICE => 'PRIVMSG',
	OPERNOTICE => \&ignore,
	MODENOTICE => \&ignore,
	SNONOTICE => \&ignore,
	METADATA => sub {
		my $net = shift;
		my $key = $_[3];
		$net->do_meta($key, @_);
	},
	IDLE => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		my $dst = $net->nick($_[2]) or return ();
		if (@_ == 3) {
			return +{
				type => 'WHOIS',
				src => $src,
				dst => $dst,
			};
		} else {
			# we have to assume the requesting server is one like unreal that needs the whole thing sent
			# across. The important part for remote inspircd servers is the 317 line
			my $home_srv = $src->info('home_server');
			my @msgs = (
				[ 311, $src->info('ident'), $src->info('vhost'), '*', $src->info('name') ],
				[ 312, $home_srv, $serverdsc[$$net]{$home_srv} ],
			);
			push @msgs, [ 313, 'is a '.($src->info('opertype') || 'Unknown Oper') ] if $src->has_mode('oper');
			push @msgs, (
				[ 317, $_[4], $_[3], 'seconds idle, signon time'],
				[ 318, 'End of /WHOIS list' ],
			);
			return map +{
				type => 'MSG',
				src => $net,
				dst => $dst,
				msgtype => $_->[0], # first part of message
				msg => [$src, @$_[1 .. $#$_] ], # source nick, rest of message array
			}, @msgs;
		}
	}, PUSH => sub {
		my $net = shift;
		my $dst = $net->nick($_[2]) or return ();
		my($rmsg, $txt) = split /\s+:/, $_[-1], 2;
		my @msg = split /\s+/, $rmsg;
		push @msg, $txt if defined $txt;
		unshift @msg, undef unless $msg[0] =~ s/^://;
		
		if ($dst->info('_is_janus')) {
			# a PUSH to the janus nick. Don't send any events, for one.
			# However, it might be something we asked about, like the MODULES output
			if (@msg == 4 && $msg[1] eq '900' && $msg[0] && $msg[0] eq $net->cparam('linkto')) {
				if ($msg[3] =~ /^(\S+)$/) {
					$net->module_add($1);
				} elsif ($msg[3] =~ /^0x\S+ \S+ (\S+) \(.*\)$/) {
					# alternate form of above which is returned to opers
					$net->module_add($1);
				}
			}
			return ();
		}

		my $src = $net->item(shift @msg) || $net;
		my $cmd = shift @msg;
		shift @msg;
		return +{
			type => 'MSG',
			src => $net,
			dst => $dst,
			msgtype => $cmd,
			msg => (@msg == 1 ? $msg[0] : \@msg),
		};
	}, TIME => sub {
		my $net = shift;
		$net->send($net->cmd2(@_[2,1,0,3], time)) if @_ == 4;
		();
	},
	TIMESET => \&ignore,
  }, acts => {
	NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		return () if $net->id() eq $id;
		return () if $net->isa('Interface');
		return (
			$net->ncmd(SERVER => "$id.janus", '*', 1, $new->netname()),
			$net->ncmd(OPERNOTICE => "Janus network $id (".$new->netname().") is now linked"),
			$net->cmd2("$id.janus", VERSION => 'Remote Janus Server: '.ref $id),
		);
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $id = $gone->id();
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(OPERNOTICE => "Janus network $id (".$gone->netname().") has delinked: $msg"),
			$net->ncmd(SQUIT => "$id.janus", $msg),
		);
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();
		my @out = $net->_connect_ifo($nick);
		push @out, $net->cmd2($nick, MODULES => $net->cparam('linkto')) if $nick->info('_is_janus');
		@out;
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();

		if ($act->{killed}) {
			my @out = $net->_connect_ifo($nick);
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = join '', map {
					$chan->has_nmode($_, $nick) ? ($txt2pfx[$$net]{$_} || '') : ''
				} qw/n_voice n_halfop n_op n_admin n_owner/;
				push @out, $net->cmd1(FJOIN => $chan, $chan->ts(), $mode.','.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{from}, NICK => $act->{to}, $nick->ts());
		}
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $net->id();
		$net->cmd2($act->{from}{$id}, NICK => $act->{to}{$id});
	}, UMODE => sub {
		my($net,$act) = @_;
		my $pm = '';
		my $mode = '';
		my @out;
		for my $ltxt (@{$act->{mode}}) {
			my($d,$txt) = $ltxt =~ /^([-+])(.+)/;
			my $um = $net->txt2umode($txt);
			if (ref $um) {
				push @out, $um->($net, $act->{dst}, $ltxt);
			} else {
				$mode .= $d if $pm ne $d;
				$mode .= $um;
				$pm = $d;
			}
		}
		push @out, $net->cmd2($act->{dst}, MODE => $act->{dst}, $mode) if $mode;
		@out;
	}, QUIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		return () unless $act->{dst}->is_on($net);
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{src}->homenet()->id() eq $net->id()) {
			print "ERR: Trying to force channel join remotely (".$act->{src}->gid().$chan->str($net).")\n";
			return ();
		}
		my $mode = '';
		if ($act->{mode}) {
			$mode .= ($txt2pfx[$$net]{$_} || '') for keys %{$act->{mode}};
		}
		$net->cmd1(FJOIN => $chan, $chan->ts(), $mode.','.$net->_out($act->{src}));
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		my $src = $act->{src} || $net;
		my $dst = $act->{dst};
		my @interp = &Modes::to_irc($net, $act->{mode}, $act->{args}, $act->{dirs});
		return () unless @interp;
		return () if @interp == 1 && (!$interp[0] || $interp[0] =~ /^[+-]+$/);
		return $net->cmd2($src, FMODE => $dst, $dst->ts(), @interp);
	}, TOPIC => sub {
		my($net,$act) = @_;
		if ($act->{in_link}) {
			return $net->ncmd(FTOPIC => $act->{dst}, $act->{topicts}, $act->{topicset}, $act->{topic});
		}
		my $src = $act->{src};
		$src = $Janus::interface unless $src && $src->isa('Nick') && $src->is_on($net);
		return $net->cmd2($src, TOPIC => $act->{dst}, $act->{topic});
	}, NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'vhost') {
			return $net->cmd2($act->{dst}, FHOST => $act->{value});
		} elsif ($act->{item} eq 'name') {
			return $net->cmd2($act->{dst}, FNAME => $act->{value});
		} elsif ($act->{item} eq 'away') {
			return $net->cmd2($act->{dst}, AWAY => defined $act->{value} ? $act->{value} : ());
		} elsif ($act->{item} eq 'opertype') {
			return () unless $act->{value};
			my $len = $net->nicklen() - 9;
			my $type = substr $act->{value}, 0, $len;
			$type .= ' (remote)';
			$type =~ s/ /_/g;
			return $net->cmd2($act->{dst}, OPERTYPE => $type);
		}
		return ();
	}, TIMESYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{wipe}) {
			if ($act->{ts} == $act->{oldts}) {
				return $net->ncmd(REMSTATUS => $chan);
			} else {
				return $net->ncmd(FMODE => $chan, $act->{ts}, '+');
			}
		} else {
			my @interp = $net->_mode_interp($chan->mode_delta());
			# delta from channel to undef == remove all modes. We want to add.
			$interp[0] =~ tr/-+/+-/ unless $interp[0] eq '+';
			return $net->ncmd(FMODE => $chan, $act->{ts}, @interp);
		}
	}, MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 'PRIVMSG';
		my $dst = ($act->{prefix} || '').$net->_out($act->{dst});
		if ($type eq '317') {
			my @msg = @{$act->{msg}};
			return () unless @msg >= 3;
			return $net->cmd2($msg[0], IDLE => $act->{dst}, $msg[2], $msg[1]);
		} elsif ($type =~ /^[356789]\d\d$/) {
			# assume this is part of a WHOIS reply; discard
			return ();
		}
		if (($type eq 'PRIVMSG' || $type eq 'NOTICE') && $act->{src}->isa('Nick') && $act->{src}->is_on($net)) {
			return $net->cmd2($act->{src}, $type, $dst, $act->{msg});
		} elsif ($act->{dst}->isa('Nick')) {
			# sent to a single user - it's easier to just PUSH the result
			my $msg = $net->cmd2($act->{src}, $type, $dst, ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg});
			return $net->ncmd(PUSH => $act->{dst}, $msg);
		} elsif ($type eq 'PRIVMSG' || $type eq 'NOTICE') {
			# main case: people speaking in -n channels; a bunch of race conditions also come here
			# TODO this should be improved by m_janus.so if it gets written
			my $msg = $act->{msg};
			my $src = $act->{src};
			$src = $src->homenick() if $src && $src->isa('Nick');
			$msg = $msg =~ /^\001ACTION (.*?)\001?$/ ? '* '.$net->_out($src).' '.$msg : '<'.$net->_out($src).'> '.$msg;
			$net->cmd2($Janus::interface, $type, $act->{dst}, $msg);
		}
	}, WHOIS => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, IDLE => $act->{dst});
	}, PING => sub {
		my($net,$act) = @_;
		$net->ncmd(PING => $net->cparam('linkto'));
	}, LINKREQ => sub {
		my($net,$act) = @_;
		my $src = $act->{net};
		$net->ncmd(OPERNOTICE => $src->netname()." would like to link $act->{slink} to $act->{dlink}");
	}, RAW => sub {
		my($net,$act) = @_;
		$act->{msg};	
	}, CHATOPS => sub {
		my($net,$act) = @_;
		return () if $net->get_module('m_globops.so');
		$net->ncmd(OPERNOTICE => $net->str($act->{src}).': '.$act->{msg});
	},
}};

$moddef{$_} = $Server::InspMods::modules{$_} for keys %Server::InspMods::modules;

sub find_module {
	my($net,$name) = @_;
	$moddef{$name};
}

1;
