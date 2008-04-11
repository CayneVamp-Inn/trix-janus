# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::InterJanus;
use Persist 'EventDump','RemoteJanus';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our $IJ_PROTO = 1.7;

our(@sendq, @auth);
&Persist::register_vars(qw(sendq auth));
&Persist::autoget(is_linked => \@auth);

sub str {
	warn;
	"";
}

sub intro {
	my($ij,$nconf) = @_;
	$sendq[$$ij] = '';

	$ij->send(+{
		type => 'InterJanus',
		version => $IJ_PROTO,
		id => $RemoteJanus::self->id(),
		rid => $nconf->{id},
		pass => $nconf->{sendpass},
		ts => $Janus::time,
	});
	# If we are the first mover (initiated connection), auth will be zero, and
	# will end up being 1 after a successful authorization. If we were listening,
	# then to get here we must have already authorized, so change it to 2.
	$auth[$$ij] = $auth[$$ij] ? 2 : 0;
}

sub jlink {
	$_[0];
}

sub send {
	my $ij = shift;
	my @out = $ij->dump_act(@_);
	&Debug::netout($ij, $_) for @out;
	$sendq[$$ij] .= join '', map "$_\n", @out;
}

sub dump_sendq {
	my $ij = shift;
	my $q = $sendq[$$ij];
	$sendq[$$ij] = '';
	$q;
}

sub parse {
	&Debug::netin(@_);
	my $ij = shift;
	local $_ = $_[0];

	s/^\s*<([^ >]+)// or do {
		&Debug::err_in($ij, "Invalid IJ line\n");
		return ();
	};
	my $act = { type => $1, IJ_RAW => $_[0] };
	$ij->kv_pairs($act);
	&Debug::err_in($ij, "bad line: $_[0]") unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->send({ type => 'PONG' });
	} elsif ($auth[$$ij]) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		my $id = $RemoteJanus::id[$$ij];
		if ($id && $act->{id} ne $id) {
			&Janus::err_jmsg(undef, "Unexpected ID reply $act->{id} from IJ $id");
		} else {
			$id = $RemoteJanus::id[$$ij] = $act->{id};
		}
		my $ts_delta = abs($Janus::time - $act->{ts});
		my $nconf = $Conffile::netconf{$id};
		if ($act->{version} ne $IJ_PROTO) {
			&Janus::err_jmsg(undef, "Unsupported InterJanus version $act->{version} (local $IJ_PROTO)");
		} elsif ($RemoteJanus::self->id() ne $act->{rid}) {
			&Janus::err_jmsg(undef, "Unexpected connection: remote was trying to connect to $act->{rid}");
		} elsif (!$nconf) {
			&Janus::err_jmsg(undef, "Unknown InterJanus server $id");
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			&Janus::err_jmsg(undef, "Failed authorization");
		} elsif ($Janus::ijnets{$id} && $Janus::ijnets{$id} ne $ij) {
			&Janus::err_jmsg(undef, "Already connected");
		} elsif ($ts_delta >= 20) {
			&Janus::err_jmsg(undef, "Clocks are too far off (delta=$ts_delta here=$Janus::time there=$act->{ts})");
		} else {
			$auth[$$ij] = 1;
			$act->{net} = $ij;
			$act->{type} = 'JNETLINK';
			delete $act->{$_} for qw/pass version ts id rid IJ_RAW/;
			return $act;
		}
		if ($Janus::ijnets{$id} && $Janus::ijnets{$id} eq $ij) {
			delete $Janus::ijnets{$id};
		}
	}
	return ();
}

&Janus::hook_add(
	JNETLINK => act => sub {
		my $act = shift;
		my $ij = $act->{net};
		return unless $ij->isa(__PACKAGE__);
		for my $net (values %Janus::ijnets) {
			next if $net eq $ij || $net eq $RemoteJanus::self;
			$ij->send(+{
				type => 'JNETLINK',
				net => $net,
			});
		}
		for my $net (values %Janus::nets) {
			$ij->send(+{
				type => 'NETLINK',
				net => $net,
			});
			$ij->send(+{
				type => 'LINKED',
				net => $net,
			}) if $net->is_synced();
		}
		$ij->send(+{
			type => 'JLINKED',
		});
	}
);

1;