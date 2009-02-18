# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modes;
use Persist;
use strict;
use warnings;
use Carp;

our %mtype;

$mtype{$_} = 'n' for qw/voice halfop op admin owner/;
$mtype{$_} = 'l' for qw/ban except invex badwords/;
$mtype{$_} = 'v' for qw/
	flood flood3.2 forward joinlimit key
	kicknorejoin limit nickflood
/;
$mtype{$_} = 'r' for qw/
	auditorium badword blockcaps chanhide colorblock
	ctcpblock invite moderated mustjoin noinvite
	nokick noknock nooperover norenick noticeblock
	oper operadmin opernetadm opersvsadm reginvite
	regmoderated sslonly topic delayjoin
	allinvite permanent jcommand
	cb_direct cb_modesync cb_topicsync cb_showjoin
/;

our @nmode_txt = qw{owner admin op halfop voice};
our @nmode_sym = qw{~ & @ % +};
Janus::static(qw(nmode_txt nmode_sym mtype));

=head1 IRC Mode utilities

Intended to be used by IRC server parsers

=over

=item type Modes::mtype(text)

Gives the channel mode type, which is one of:

 r - regular mode, value is integer 0/1 (or 2+ for tristate modes)
 v - text-valued mode, value is text of mode
 l - list-valued mode, value is listref; set/unset single list item
 n - nick-valued mode, value is nick object

=cut

sub mtype {
	my $m = $_[0];
	local $1;
	return $mtype{$m} || ($m =~ /^_(.)/ ? $1 : '');
}

=item (modes,args,dirs) Modes::from_irc(net,chan,mode,args...)

Translates an IRC-style mode string into a Janus mode change triplet

net must implement cmode2txt() and nick()

=cut

sub from_irc {
	my($net,$chan,$str) = (shift,shift,shift);
	my(@modes,@args,@dirs);
	local $_;
	my $pm = '+';
	for (split //, $str) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		my $txt = $net->cmode2txt($_) || '?';
		my $arg;
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			$arg = $net->nick(shift);
			next unless $arg; # that nick just quit, messages crossed on the wire
		} elsif ($type eq 'l') {
			$arg = shift;
		} elsif ($type eq 'v') {
			$arg = shift;
		} elsif ($type eq 's') {
			# "s" modes are emulated as "v" modes in janus
			if ($pm eq '+') {
				$arg = shift;
			} else {
				$arg = $chan->get_mode($txt);
			}
		} elsif ($type eq 't') {
			if ($txt =~ s/^t(\d+)/r/) {
				$arg = $1;
			} else {
				Log::warn_in($net, "Invalid mode text $txt for mode $_ in network $net");
				next;
			}
		} elsif ($type eq 'r') {
			$arg = 1;
		} else {
			Log::warn_in($net, "Invalid mode text $txt for mode $_ in network $net");
			next;
		}
		next if 3 > length $txt;
		push @modes, substr $txt, 2;
		push @args, $arg;
		push @dirs, $pm;
	}
	(\@modes, \@args, \@dirs, @_);
}

=item (mode, args...) Modes::to_irc(net, modes, args, dirs)

Translates a Janus triplet into its IRC equivalent

net must implement txt2cmode(), which must return undef for unknown modes

=cut

sub to_irc {
	my @m = to_multi(@_);
	carp "to_irc cannot handle overlong mode" if @m > 1;
	@m ? @{$m[0]} : ();
}

sub to_multi {
	my($net, $mods, $args, $dirs, $maxm, $maxl) = @_;
	$maxm ||= 100; # this will never be hit, maxl will be used instead
	$maxl ||= 450; # this will give enough room for a source, etc
	my @modin = @$mods;
	my @argin = @$args;
	my @dirin = @$dirs;
	my $pm = '';
	my @out;

	my($count,$len) = (0,0);
	my $mode = '';
	my @args;
	while (@modin) {
		my($txt,$arg,$dir) = (shift @modin, shift @argin, shift @dirin);
		my $type = mtype($txt);
		my $out = ($type ne 'r');

		my $char = $net->txt2cmode($type.'_'.$txt);
		if (!defined $char && $type eq 'v') {
			# maybe this is an s-type rather than a v-type command?
			$char = $net->txt2cmode('s_'.$txt);
			$out = 0 if $dir eq '-' && defined $char;
		}

		if (!defined $char && $type eq 'r') {
			# maybe a tristate mode?
			my $ar1 = $net->txt2cmode('t1_'.$txt);
			my $ar2 = $net->txt2cmode('t2_'.$txt);
			if ($ar1 && $ar2) {
				$char .= $ar1 if $arg & 1;
				$char .= $ar2 if $arg & 2;
			} elsif ($ar1 || $ar2) {
				# only one of the two available; use it
				$char = ($ar1 || $ar2);
			}
		}

		if (defined $char && $char ne '') {
			$count++;
			$len++ if $dir ne $pm;
			$len += length($char) + ($out ? 1 + length $arg : 0);
			if ($count > $maxm || $len > $maxl) {
				push @out, [ $mode, @args ];
				$pm = '';
				$mode = '';
				@args = ();
				$count = 1;
				$len = 1 + length($char) + ($out ? 1 + length $arg : 0);
			}
			$mode .= $dir if $dir ne $pm;
			$mode .= $char;
			$pm = $dir;
			push @args, $arg if $out;
		}
	}
	push @out, [ $mode, @args ] unless $mode =~ /^[-+]*$/;
	@out;
}

=item (modes, args, dirs) Modes::dump(chan)

Returns the non-list modes of the channel

=cut

sub dump {
	my $chan = shift;
	my %modes = %{$chan->all_modes()};
	my(@modes, @args, @dirs);
	for my $txt (keys %modes) {
		my $type = mtype($txt);
		next if $type eq 'l';
		push @modes, $txt;
		push @dirs, '+';
		push @args, $modes{$txt};
	}
	(\@modes, \@args, \@dirs);
}

=item (modes, args, dirs) Modes::delta(chan1, chan2)

Returns the mode change required to make chan1's modes equal to
those of chan2

=cut

sub delta {
	my($chan1, $chan2) = @_;
	my %current = $chan1 ? %{$chan1->all_modes()} : ();
	my %add =
		'HASH' eq ref $chan2 ? %$chan2 :
		$chan2 ? %{$chan2->all_modes()} :
		();
	my(@modes, @args, @dirs);
	for my $txt (keys %current) {
		my $type = mtype($txt);
		if ($type eq 'l') {
			my %torm = map { $_ => 1 } @{$current{$txt}};
			if (exists $add{$txt}) {
				for my $i (@{$add{$txt}}) {
					if (exists $torm{$i}) {
						delete $torm{$i};
					} else {
						push @modes, $txt;
						push @dirs, '+';
						push @args, $i;
					}
				}
			}
			for my $i (keys %torm) {
				push @modes, $txt;
				push @dirs, '-';
				push @args, $i;
			}
		} else {
			if (exists $add{$txt}) {
				if ($current{$txt} eq $add{$txt}) {
					# hey, isn't that nice
				} else {
					push @modes, $txt;
					push @dirs, '+';
					push @args, $add{$txt};
				}
			} else {
				push @modes, $txt;
				push @dirs, '-';
				push @args, $current{$txt};
			}
		}
		delete $add{$txt};
	}
	for my $txt (keys %add) {
		my $type = mtype($txt);
		if ($type eq 'l') {
			for my $i (@{$add{$txt}}) {
				push @modes, $txt;
				push @dirs, '+';
				push @args, $i;
			}
		} else {
			push @modes, $txt;
			push @dirs, '+';
			push @args, $add{$txt};
		}
	}
	(\@modes, \@args, \@dirs);
}

=item (modes, args, dirs) Modes::reops($chan)

Returns the mode change needed to re-op everyone in the channel.

=cut

sub reops {
	my $chan = shift;
	my(@modes, @args, @dirs);
	for my $nick ($chan->all_nicks) {
		for my $mode (qw/voice halfop op admin owner/) {
			next unless $chan->has_nmode($mode, $nick);
			push @modes, $mode;
			push @args, $nick;
			push @dirs, '+';
		}
	}
	(\@modes, \@args, \@dirs);
}

=item list Modes::make_chanmodes($net, $pfxmodes)

Create the CHANMODES list from the 005 output for this network.
Removes the modes in $pfxmodes from the list.
Example: CHANMODES=Ibe,k,jl,CKMNOQRTcimnprst

$net must support: all_cmodes, txt2cmode, cmode2txt.

=cut

sub modelist {
	my($net, $pfxmodes) = @_;
	my %split2c;
	$split2c{substr $_,0,1}{$_} = $net->txt2cmode($_) for $net->all_cmodes();

	# Without a prefix character, nick modes such as +qa appear in the "l" section
	$split2c{l}{$_} = $split2c{n}{$_} for keys %{$split2c{n}};
	delete $split2c{l}{$net->cmode2txt($_) || ''} for split //, $pfxmodes;

	# tristates show up in the 4th group
	$split2c{r}{$_} = $split2c{t}{$_} for keys %{$split2c{t}};

	join ',', map { join '', sort values %{$split2c{$_}} } qw(l v s r);
}

sub chan_pfx {
	my($chan, $nick) = @_;
	join '', map { $chan->has_nmode($nmode_txt[$_], $nick) ? $nmode_sym[$_] : '' } 0..$#nmode_txt;
}

=back

=cut

1;
