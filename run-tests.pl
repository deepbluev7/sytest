#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use lib 'lib';

use Carp;

use Future;
use IO::Async::Loop;

use Data::Dump qw( pp );
use File::Basename qw( basename );
use File::Find;
use Getopt::Long;
use IO::Socket::SSL;
use List::Util qw( all );
use POSIX qw( strftime );

use SyTest::Synapse;
use SyTest::MatrixClient;

GetOptions(
   'N|number=i'    => \(my $NUMBER = 2),
   'C|client-log+' => \my $CLIENT_LOG,
   'S|server-log+' => \my $SERVER_LOG,
) or exit 1;

if( $CLIENT_LOG ) {
   require Net::Async::HTTP;
   require Class::Method::Modifiers;

   Class::Method::Modifiers::install_modifier( "Net::Async::HTTP",
      around => _do_request => sub {
         my ( $orig, $self, %args ) = @_;
         my $request = $args{request};

         my $request_uri = $request->uri;
         return $orig->( $self, %args ) if $request_uri->path =~ m{/events$};

         print STDERR "\e[1;32mRequesting\e[m:\n";
         print STDERR "  $_\n" for split m/\n/, $request->as_string;
         print STDERR "-- \n";

         return $orig->( $self, %args )
            ->on_done( sub {
               my ( $response ) = @_;

               print STDERR "\e[1;33mResponse\e[m from $request_uri:\n";
               print STDERR "  $_\n" for split m/\n/, $response->as_string;
               print STDERR "-- \n";
            }
         );
      }
   );

   Class::Method::Modifiers::install_modifier( "Net::Async::Matrix",
      before => _incoming_event => sub {
         my ( $self, $event ) = @_;

         print STDERR "\e[1;33mReceived event\e[m from $self->{server}:\n";
         print STDERR "  $_\n" for split m/\n/, pp( $event );
         print STDERR "-- \n";
      }
   );
}

my $loop = IO::Async::Loop->new;

# Start up 3 homeservers

my %synapses_by_port;
END {
   print STDERR "Killing synapse servers...\n" if %synapses_by_port;
   print STDERR "[${\$_->pid}] " and kill INT => $_->pid for values %synapses_by_port;
   print STDERR "\n";
}
$SIG{INT} = sub { exit 1 };

my @PORTS = 8001 .. 8000+$NUMBER;
my @f;
foreach my $port ( @PORTS ) {
   my $synapse = $synapses_by_port{$port} = SyTest::Synapse->new(
      synapse_dir  => "../synapse",
      port         => $port,
      print_output => $SERVER_LOG,
   );
   $loop->add( $synapse );

   push @f, Future->wait_any(
      $synapse->started_future,

      $loop->delay_future( after => 10 )
         ->then_fail( "Synapse server on port $port failed to start" ),
   );
}

Future->needs_all( @f )->get;

my @clients = Future->needs_all(
   map {
      my $port = $_;

      my $matrix = SyTest::MatrixClient->new(
         server => "localhost",
         port   => $port,
         SSL    => 1,
         SSL_verify_mode => SSL_VERIFY_NONE,

         on_error => sub {
            my ( $self, $failure, $name, @args ) = @_;

            die $failure unless $name and $name eq "http";
            my ( $response, $request ) = @args;

            print STDERR "Received from " . $request->uri . "\n";
            if( defined $response ) {
               print STDERR "  $_\n" for split m/\n/, $response->as_string;
            }
            else {
               print STDERR "No response\n";
            }

            die $failure;
         },
      );

      $loop->add( $matrix );

      Future->done( $matrix );
   } @PORTS
)->get;

# Some tests create objects as a side-effect that later tests will depend on,
# such as clients, users, rooms, etc... These are called the Environment
my %test_environment;
$test_environment{clients} = \@clients;

sub provide
{
   my ( $name, $value ) = @_;
   exists $test_environment{$name} and
      carp "Overwriting existing test environment key '$name'";

   $test_environment{$name} = $value;
}

sub _test
{
   my ( $filename, $name, %params ) = @_;

   my @reqs;
   foreach my $req ( @{ $params{requires} || [] } ) {
      push @reqs, $test_environment{$req} and next if $test_environment{$req};

      print "\e[1;33mSKIP\e[m $name ($filename) due to lack of $req\n";
      return;
   }

   print "\e[36mTesting if: $name ($filename)\e[m... ";

   my $check = $params{check};

   my $success = eval {
      if( my $do = $params{do} ) {
         if( $check ) {
            eval { $check->( @reqs )->get } and
               warn "Warning: $name was already passing before we did anything\n";
         }

         $do->( @reqs )->get;
      }

      if( $check ) {
         my $attempts = $params{wait_time} // 0;
         do {
            eval {
               $check->( @reqs )->get or
                  die "Test check function failed to return a true value"
            } and return 1; # returns from the containing outer eval

            die "$@" unless $attempts;

            $loop->delay_future( after => 1 )->get;
            $attempts--;
         } while(1);
      }

      1;
   };

   if( $success ) {
      print "\e[32mPASS\e[m\n";
   }
   else {
      my $e = $@; chomp $e;
      print "\e[1;31mFAIL\e[m:\n";
      print " | $_\n" for split m/\n/, $e;
      print " +----------------------\n";
   }

   foreach my $req ( @{ $params{provides} || [] } ) {
      exists $test_environment{$req} and next;

      print "\e[1;31mWARN\e[m: Test failed to provide the '$req' environment as promised\n";
   }

   return $success;
}

my $failed;

find({
   no_chdir => 1,
   preprocess => sub { sort @_ },
   wanted => sub {
      my $filename = $_;

      return unless basename( $filename ) =~ m/^\d+.*\.pl$/;

      no warnings 'once';
      local *test = sub {
         _test( $filename, @_ ) or $failed++;
         1; # return true so the final 'test' in the file makes 'do' see a true value
      };

      # This is hideous
      do $File::Find::name or
         die $@ || "Cannot 'do $_' - $!";
   }},
   "tests"
);

if( $failed ) {
   print STDERR "\n\e[1;31m$failed tests FAILED\e[m\n";
   exit 1;
}
else {
   print STDERR "\n\e[1;32mAll tests PASSED\e[m\n";
   exit 0;
}
