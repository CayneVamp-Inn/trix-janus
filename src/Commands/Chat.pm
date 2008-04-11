# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Chat;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'chatto',
	help => 'Send a message to all opers on a specific network',
	details => [
		"Syntax: \002CHATTO\002 network|* message",
		'Note: The command /chatops, if available, may be relayed to all networks',
	],
	acl => 1,
	code => sub {
		my($nick,$msg) = @_;
		$msg =~ s/^(\S+) // or return &Janus::jmsg($nick, "Syntax: \002CHATTO\002 network message");
		my $net = $Janus::nets{$1};
		return &Janus::jmsg($nick, "Could not find that network") unless $net || $1 eq '*';
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			msg => $msg,
			sendto => ($1 eq '*' ? $Janus::global : [ $net ]),
		});
	},
});

1;