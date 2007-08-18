# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package LocalNetwork;
BEGIN {
	&Janus::load('Network');
	&Janus::load('Channel');
}
use Persist 'Network';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @cparms :Persist(cparms); # currently active parameters
my @lreq   :Persist(lreq);
my @synced :Persist(synced) :Get(is_synced);
my @ponged :Persist(ponged);
my @nicks  :Persist(nicks);
my @chans  :Persist(chans);

sub _init {
	my $net = shift;
	$nicks[$$net] = {};
	$chans[$$net] = {};
}

sub param {
	my $net = shift;
	$Conffile::netconf{$net->id()}{$_[0]};
}
sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub pong {
	my $net = shift;
	$ponged[$$net] = time;
}

sub pongcheck {
	my $p = shift;
	my $net = $p->{net};
	if ($net && !isweak($p->{net})) {
		warn "Reference is strong! Weakening";
		weaken($p->{net});
		$net = $p->{net}; #possibly skip
	}
	unless ($net) {
		delete $p->{repeat};
		&Conffile::connect_net(undef, $p->{netid});
		return;
	}
	unless ($Janus::nets{$net->id()} eq $net) {
		delete $p->{repeat};
		warn "Network $net not deallocated quickly enough!";
		return;
	}
	my $last = $ponged[$$net];
	if ($last + 90 <= time) {
		print "PING TIMEOUT!\n";
		&Janus::delink($net, 'Ping timeout');
		&Conffile::connect_net(undef, $p->{netid});
		delete $p->{net};
		delete $p->{repeat};
	} elsif ($last + 29 <= time) {
		$net->send(+{
			type => 'PING',
		});
	}
}

sub intro {
	my $net = shift;
	$cparms[$$net] = { %{$Conffile::netconf{$net->id()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
	$ponged[$$net] = time;
	my $pinger = {
		repeat => 30,
		net => $net,
		netid => $net->id(),
		code => \&pongcheck,
	};
	weaken($pinger->{net});
	&Janus::schedule($pinger);
}

################################################################################
# Channel actions
################################################################################

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $chans[$$net]{lc $name}) {
		return undef unless $new;
		print "Creating channel $name\n" if $new;
		$chans[$$net]{lc $name} = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
	}
	$chans[$$net]{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	warn "replacing nonexistant channel" unless exists $chans[$$net]{lc $name};
	if (defined $new) {
		$chans[$$net]{lc $name} = $new;
	} else {
		delete $chans[$$net]{lc $name};
	}
}

sub all_chans {
	my $net = shift;
	values %{$chans[$$net]};
}

sub _modeargs {
	my $net = shift;
	my $mode = shift;
	my @modes;
	my @args;
	local $_;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		my $txt = $net->cmode2txt($_) || 'UNK';
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			push @args, $net->nick(shift);
		} elsif ($type eq 'l') {
			push @args, shift;
		} elsif ($type eq 'v') {
			push @args, shift;
		} elsif ($type eq 's') {
			push @args, shift if $pm eq '+';
		} elsif ($type ne 'r') {
			warn "Unknown mode '$_' ($txt)";
			next;
		}
		push @modes, $pm.$txt;
	}
	(\@modes, \@args);
}

sub _mode_interp {
	my($net, $mods, $args) = @_;
	my $pm = '';
	my $mode;
	my @argin = @$args;
	my @args;
	for my $mtxt (@$mods) {
		my($ipm,$txt) = ($mtxt =~ /^([-+])(.*)/) or warn $mtxt;
		my $itm = ($txt =~ /^[nlv]/ || $mtxt =~ /^\+s/) ? shift @argin : undef;
		if (defined $net->txt2cmode($txt)) {
			push @args, ref $itm ? $itm->str($net) : $itm if defined $itm;
			$mode .= $ipm if $ipm ne $pm;
			$mode .= $net->txt2cmode($txt);
			$pm = $ipm;
		} else {
			warn "Unsupported channel mode '$txt' for network";
		}
	}
	$mode, @args;
}

sub add_req {
	my($net, $lchan, $onet, $ochan) = @_;
	$lreq[$$net]{$lchan}{$onet->id()} = $ochan;
}

sub is_req {
	my($net, $lchan, $onet) = @_;
	$lreq[$$net]{$lchan}{$onet->id()};
}

sub del_req {
	my($net, $lchan, $onet) = @_;
	delete $lreq[$$net]{$lchan}{$onet->id()};
}

################################################################################
# Nick actions
################################################################################

sub mynick {
	my($net, $name) = @_;
	my $nick = $nicks[$$net]{lc $name};
	unless ($nick) {
		print "Nick '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet()->id() ne $net->id()) {
		print "Nick '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $nicks[$$net]{lc $name} if $nicks[$$net]{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $old = delete $nicks[$$net]->{lc $name};
	unless ($old) {
		$nicks[$$net]->{lc $name} = $new;
		return 1;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	$nicks[$$net]->{lc $name} = $new if $tsctl > 0;
	$nicks[$$net]->{lc $name} = $old if $tsctl < 0;
	
	my @rv = ($tsctl > 0);
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet()->id() eq $net->id()) {
			warn "Nick collision on home network!";
		} else {
			push @rv, +{
				type => 'RECONNECT',
				dst => $new,
				net => $net,
				killed => 1,
				nojlink => 1,
			};
		}
	}
	@rv;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given;
	if ($nick->homenet()->id() eq $net->id()) {
		$given = $reqnick;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		my $maxlen = $net->nicklen();
		$given = substr $reqnick, 0, $maxlen;

		$tagged = 1 if exists $nicks[$$net]->{lc $given};

		my $tagre = $net->param('force_tag');
		$tagged = 1 if $tagre && $given =~ /$tagre/;
		
		if ($tagged) {
			my $tagsep = $net->param('tag_prefix');
			$tagsep = '/' unless defined $tagsep;
			my $tag = $tagsep . $nick->homenet()->id();
			my $i = 0;
			$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
			while (exists $nicks[$$net]->{lc $given}) {
				my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
				$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
			}
		}
	}
	$nicks[$$net]->{lc $given} = $nick;
	return $given;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
	delete $nicks[$$net]->{lc $req};
}

sub all_nicks {
	my $net = shift;
	values %{$nicks[$$net]};
}

###############################################################################
# General actions
###############################################################################

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $nicks[$$net]{lc $item} if exists $nicks[$$net]{lc $item};
	return $chans[$$net]{lc $item} if exists $chans[$$net]{lc $item};
	return $net if $item =~ /\./;
	return undef;
}

&Janus::hook_add(
 	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
		undef;
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa('LocalNetwork');
		my $tid = $net->id();
		if (%{$nicks[$$net]}) {
			my @clean;
			warn "nicks remain after a netsplit, killing...";
			for my $nick ($net->all_nicks()) {
				push @clean, +{
					type => 'KILL',
					dst => $nick,
					net => $net,
					msg => 'JanusSplit',
					nojlink => 1,
				};
			}
			&Janus::insert_full(@clean);
			warn "nicks still remain after netsplit kills" if %{$nicks[$$net]};
			$nicks[$$net] = undef;
		}
		if (%{$chans[$$net]}) {
			my @clean;
			warn "channels remain after a netsplit, delinking...";
			for my $chan ($net->all_chans()) {
				push @clean, +{
					type => 'DELINK',
					dst => $chan,
					net => $net,
					nojlink => 1,
				};
			}
			&Janus::insert_full(@clean);
			warn "channels still remain after double delinks" if %{$chans[$$net]};
			$chans[$$net] = undef;
		}
	},
);

1;
