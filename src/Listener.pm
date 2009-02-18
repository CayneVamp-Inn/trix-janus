# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Listener;
use strict;
use warnings;
use SocketHandler;
use Persist 'SocketHandler';

our @id;
Persist::register_vars('id');
Persist::autoget('id');

our %open;

sub _init {
	my($net, $arg) = @_;
	my $id = $id[$$net] = $arg->{id};
	$open{$id} = $net;
}

sub delink {
	my $net = shift;
	delete $open{$id[$$net]};
	Connection::drop_socket($net);
}

sub init_pending {
	my($self, $addr) = @_;

	for my $id (keys %Conffile::netconf) {
		next if $Janus::nets{$id} || $Janus::pending{$id} || $Janus::ijnets{$id};
		my $nconf = $Conffile::netconf{$id};
		Conffile::value(fb_max => $nconf);
		my $fb_max = $nconf->{fb_max};
		for my $fb_id (0..$fb_max) {
			my $laddr = $nconf->{'linkaddr'.($fb_id ? '.'.$fb_id : '')};
			next unless $laddr && $laddr eq $addr;
			$nconf->{fb_id} = $fb_id;
			my $type = 'Server::'.$nconf->{type};
			Janus::load($type) or next;
			my $net = Persist::new($type, id => $id);
			$Janus::pending{$id} = $net;
			Log::info("Incoming connection from $addr for $type network $id (server $fb_id)");
			$net->intro($nconf, $addr);
			return $net;
		}
	}
	Log::info("Rejecting connection from $addr, no matching network definition found");
	return undef;
}

sub dump_sendq { '' }

1;
