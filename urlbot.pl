#!/usr/bin/env perl
package No::Jonis::IRC::Logger;

# This is written entirely in YOLOCODE, if you were wondering
use strict;
use warnings;
use utf8;

use FindBin;
use Config::YAML;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::NickReclaim;
use DBI;
use LWP::UserAgent;

use lib "$FindBin::Bin/lib";
use Data::Dumper;

my $V = '1.2';
my $c = Config::YAML->new( config => './conf/config.yml' );

my $db =
  DBI->connect( "DBI:" . $c->{dbtype} . ":database=" . $c->{dbname}, $c->{dbuser}, $c->{dbpass}, { AutoCommit => 1 } )
  or die $DBI::errstr;
my $ua = LWP::UserAgent->new;
my ($irc) = POE::Component::IRC->spawn();


POE::Session->create(
  inline_states => {
    _start           => \&bot_start,
    connect          => \&bot_connect,
    irc_disconnected => \&bot_reconnect,
    irc_error        => \&bot_reconnect,
    irc_socketerr    => \&bot_reconnect,
    irc_001          => \&bot_connected,
    irc_public       => \&channel_msg,
    irc_msg          => \&private_message,
    irc_ctcp_version => \&bot_ctcp_version,
    irc_ctcp_ping    => \&bot_ctcp_ping,
  }
);

# What to do when the bot starts, register actions, load plugin to reclaim nick when it's currently taken.
# And then connect to IRC.

sub bot_start {
  $irc->yield( register => 'all' );
  $irc->plugin_add( 'NickReclaim' => POE::Component::IRC::Plugin::NickReclaim->new( poll => 30 ) );
  &bot_connect;
}

# Connect to IRC.

sub bot_connect {
  $irc->yield(
    connect => {
      Nick     => $c->{irc_nick},
      Username => $c->{irc_username},
      Ircname  => $c->{irc_name} . $V,
      Server   => $c->{irc_server},
      Port     => $c->{irc_port},
      Debug    => $c->{debug},
    }
  );
}

# What to do when the bot is connected to the IRC server.

sub bot_connected {
  $irc->yield( join => $c->{irc_channel} );
}

# Tell the bot to reconnect after 60 seconds.

sub bot_reconnect {
  $poe_kernel->delay( connect => 60 );    # 60 seconds delay before reconnecting..
}

# Reply to CTCP version.

sub bot_ctcp_version {
  my $who = ( split( /!/, $_[ARG0] ) )[0];
  $irc->yield( ctcpreply => $who => 'VERSION ' . 'Anna v' . $V );
}

# Reply to CTCP ping.

sub bot_ctcp_ping {
  my $who = ( split( /!/, $_[ARG0] ) )[0];
  $irc->yield( ctcpreply => $who => 'PING ' . $_[ARG2] );
}

# Handles channel messages.

sub channel_msg {
  my ( $who, $channel, $msg ) = @_[ ARG0, ARG1, ARG2 ];
  my $username = ( split /!/, $who )[0];
  my $userhost = ( split /!/, $who )[1];
  $channel = $channel->[0];

  if ( $msg =~ m/(https?:\/\/[a-z0-9\.-]+[a-z]{2,6}([\/\w+-_&\?]*))/i ) {
    db_insert_url( $username, $channel, $1 );
  }

  elsif ( ( split / /, $msg )[0] eq "$c->{irc_trigger}" ) {
    handle_triggercmd( $username, $channel, my @cmds = ( split / /, $msg ) );
  }
}

# This handles all the trigger commands.

sub handle_triggercmd {
  my ( $username, $channel, @cmds ) = @_;

  if ( scalar @cmds eq 1 ) {    # grab single url and post to channel
    my $result   = db_get_url();
    my $response = $ua->get( $result->{url} );

    while ( $response->is_error ) {
      db_mark_reported( $result->{id_number} );
      $result   = db_get_url();
      $response = $ua->get( $result->{url} );
    }

    $irc->yield( privmsg => $channel, "$username: $result->{url} ($result->{id_number})" );
  }
  else {
    if ( $cmds[1] =~ m/^total$/i ) {
      $irc->yield( privmsg => $channel, db_get_total() . " active links in database." );
    }
    elsif ( $cmds[1] =~ /^report$/i ) {    #trigger for report
      if ( $cmds[2] =~ /^\d+$/ ) {         #verify third arg is number.
        &db_mark_reported( $cmds[2] );
      }
    }
  }
}

# It's DB all the way down.

sub db_get_url {
  return $db->selectrow_hashref("select * from logger order by random()*(select count(*) from logger) limit 1");
}

sub db_mark_reported {
  my $id  = @_;
  my $pst = $db->prepare("update logger set reported = true where id_number = ?");
  $pst->execute($id) or print STDERR $DBI::errstr;
  $pst->finish();
}

sub db_get_total {
  my $total = $db->selectrow_hashref("select count(*) from logger where reported = false");
  return $total->{count};
}

sub db_insert_url {
  my ( $user, $channel, $url ) = @_;
  my $pst = $db->prepare("insert into logger (nickname,url,channel) values (?,?,?)");
  $pst->execute( $user, $url, $channel ) or print $DBI::errstr;
  $pst->finish();
}

$poe_kernel->run();
exit 0;
