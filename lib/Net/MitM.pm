package Net::MitM;

=head1 NAME

Net::MitM - Man in the Middle - connects a client and a server, giving visibility of and control over messages passed.

=head1 VERSION

Version 0.03_02

=cut

our $VERSION = '0.03_02';

=head1 SYNOPSIS

Net::MitM is designed to be inserted between a client and a server. It proxies all traffic through verbatum, and also copies that same data to a log file and/or a callback function, allowing a data session to be monitored, recorded, even altered on the fly.

MitM acts as a 'man in the middle', sitting between the client and server.  To the client, MitM looks like the server.  To the server, MitM looks like the client.

MitM cannot be used to covertly operate on unsuspecting client/server sessions - it requires that you control either the client or the server.  If you control the client, you can tell it to connect via your MitM.  If you control the server, you can move it to a different port, and put a MitM in its place.  

When started, MitM opens a socket and listens for connections. When that socket is connected to, MitM opens another connection to the server.  Messages from either client or server are passed to the other, and a copy of each message is, potentially, logged.  Alternately, callback methods may be used to add business logic, including potentially altering the messages being passed.

MitM can also be used as a proxy, allowing two processes on machines that cannot 'see' each other to communicate via an intermediary machine that is visible to both.

There is an (as yet unreleased) sister module L<Net::Replay> that allows a MitM session to be replayed.

=head3 Usage

Assume the following script is running on the local machine:

    use Net::MitM;
    my $MitM = Net::MitM->new("cpan.org", 80, 10080);
    $MitM->log_file("MitM.log");
    $MitM->go();

A browser connecting to L<http://localhost:10080> will now cause MitM to open a connection to cpan.org, and messages sent by either end will be passed to the other end, and logged to MitM.log.  

For another example, see samples/mitm.pl in the MitM distribution.

=head3 Modifying messages on the fly - a worked example.

However you deploy MitM, it will be virtually identical to having the client and server talk directly.  The difference will be that either the client and/or server will be at an address other than the one its counterpart believes it to be at.  Most programs ignore this, but sometimes it matters.

For example, HTTP browsers pass a number of parameters, one of which is "Host", the host to which the browser believes it is connecting.  Often, this parameter is unused.  But sometimes, a single HTTP server will be serving content for more than one website.  Such a server generally relies on the Host parameter to know what it is to return.  If the MitM is not on the same host as the HTTP server, the host parameter that the browser passes will cause the HTTP server to fail to serve the desired pages.

Further, HTTP servers typically return URLs containing the host address.  If the browser navigates to a returned URL, it will from that point onwards connect directly to the server in the URL instead of communicating via MitM.

Both of these problems can be worked around by modifying the messages being passed.

For example, assume the following script is running on the local machine:

    use Net::MitM;
    sub send_($) {$_[0] =~ s/Host: .*:\d+/Host: cpan.org/;}
    sub receive($) {$_[0] =~ s/cpan.org:\d+/localhost:10080/g;}
    my $MitM = Net::MitM->new("cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&send,callback_behaviour=>"modify");
    $MitM->server_to_client_callback(\&receive,callback_behaviour=>"modify");
    $MitM->log_file("http_MitM.log");
    $MitM->go();

The send callback tells the server that it is to serve cpan.org pages, instead of some other set of pages, while the receive callback tells the browser to access cpan.org URLs via the MitM process, not directly.  The HTTP server will now respond properly, even though the browser sent the wrong hostname, and the browser will now behave as desired and direct future requests via the MitM.

For another example, see samples/http_mitm.pl in the MitM distribution.

A more difficult problem is security aware processes, such as those that use HTTPS based protocols. They are actively hostname aware.  Precisely to defend against a man-in-the-middle attack, they check their counterpart's reported hostname (but not normally the port) against the actual hostname.  Unless client, server and MitM are all on the same host, either the client or the server will notice that the remote hostname is not what it should be, and will abort the connection.  
There is no good workaround for this, unless you can run an instance of MitM on the server, and another on the client - but even if you do, you still have to deal with the communication being encrypted.

=head1 SUBROUTINES/METHODS

=cut

# #######
# Globals
# #######

use 5.002; # has been tested with 5.8.9. an earlier version failed with 5.6.2, but that has probably been fixed.

use warnings FATAL => 'all';
use Socket;
use FileHandle;
use IO::Handle;
use Carp;
use strict;
#BEGIN{eval{require Time::HiRes; import Time::HiRes qw(time)}}; # only needed for high precision time_interval - will still work fine even if missing
eval {use Time::HiRes qw(time)}; # only needed for high precision time_interval - will still work fine even if missing

=head2 new( remote_ip_address, remote_port_num, local_port_num )

Creates a new MitM

=head4 Parameters

=over

=item * remote_ip_address - the remote hostname/IP address of the server 

=item * remote_port_num - the remote port number of the server

=item * local_port_num - the port number to listen on

=item * Returns - a new MitM object

=back

=head4 Usage

To keep a record of all messages sent:

    use Net::MitM;
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->log_file("MitM.log");
    $MitM->go();

=cut 

sub hhmmss();

my $mitm_count=0;

sub _new(){
  my %this;
  $this{verbose} = 1;
  $this{parallel} = 0;
  $this{mydate} = \&hhmmss;
  $this{name} = "MitM".++$mitm_count;
  return \%this;
}

sub new($$$;$) {
  my $class=shift;
  my $this=_new();
  $this->{remote_ip_address} = shift or croak "remote hostname/ip address missing";
  $this->{remote_port_num} = shift or croak "remote port number missing";
  $this->{local_port_num} = shift || $this->{remote_port_num};
  return bless($this, $class);
}

=head2 go( )

Listen on local_port, accept incoming connections, and forwards messages back and forth.

=head4 Parameters

=over

=item * --none--

=item * Returns --none--

=back

=head4 Usage

When a connection on local_port is received a connect to remote_ip_address:remote_port_num is created and messages from the client are passed to the server and vice-versa. 

If parallel() was set, which is not the default, there will be a new process created for each such session.

If any callback functions have been set, they will be called before each message is passed.

If logging is on, messages will be logged.

By default, go() does not return.  The function L<stop_when_idle()> can be called to force go() to return.   You may want to L<fork> before calling it.  

If new_server() was used instead of new(), messages from client are instead passed to the server callback function.

=cut

# Convenience function - intentionally not exposed. If you really want to call it, you can of course. But if you are going to violate encapsulation, why not go directly to the variables?

sub _set($;$) {
  my $this=shift;
  my $key=shift or confess "missing mandatory parameter";
  my $value=shift;
  if(defined $value){
    $this->{$key} = $value;
  }
  return $this->{$key};
}

=head2 name( [name] )

Names the object - will be reported back in logging/debug

=head4 Parameters

=over

=item * name - the new name (default is MitM1, MitM2, ...)

=item * Returns - the current or new setting

=back

=head4 Usage

For a minimal MitM:

    use Net::MitM;
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->go();

=cut 

sub name(;$) {
  my $this=shift;
  my $value=shift;
  return $this->_set("name", $value);
}

=head2 verbose( [level] )

Turns on/off reporting to stdout. 

=head4 Parameters

=over

=item * level - how verbose to be. 0=nothing, 1=normal, 2=debug. The default is 1.

=item * Returns - the current or new setting

=back

=head4 Usage

Setting verbose changes the amount of information printed to stdout.

=cut 

sub verbose(;$) {
  my $this=shift;
  my $verbose=shift;
  #warn "verbose->(",$verbose||"--undef--",")\n";
  return $this->_set("verbose", $verbose);
}

=head2 client_to_server_callback( callback [callback_behaviour => behaviour] )

Set a callback function to monitor/modify each message sent to server

=head4 Parameters

=over

=item * callback - a reference to a function to be called for each message sent to server

=item * callback_behaviour - explicitly sets the callback as readonly, modifying or conditional.

=item * Returns - the current or new setting

=back

=head4 Usage

If a client_to_server_callback callback is set, it will be called with a copy of each message received from the client before it is sent to the server.  

What the callback returns determines what will be sent, depending on the value of callback_behaviour:

=over

=item * If callback_behaviour = "readonly", the return value from the callback is ignored, and the original message is sent.

=item * If callback_behaviour = "modify", the return value from the callback is sent instead of the original message, unless the return value is undef, in which case nothing is sent

=item * If callback_behaviour = "conditional", which is the default, that the return value from the callback is sent instead of the original message, or if the return value is undef, then the original message is sent.  

=back

For example, to modify messages:

    use Net::MitM;
    sub send_($) {$_[0] =~ s/Host: .*:\d+/Host: cpan.org/;}
    sub receive($) {$_[0] =~ s/www.cpan.org(:\d+)?/localhost:10080/g;}
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&send, callback_behaviour=>"modify");
    $MitM->server_to_client_callback(\&receive, callback_behaviour=>"modify");
    $MitM->go();

If the callback is readonly, it should either return a copy of the original message, or undef. Be careful not to accidentally return something else - remember that perl methods implicitly returns the value of the last command executed.

For example, to write messages to a log:

    sub peek($) {my $msg = shift; print LOG; return $msg;}
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&peek, callback_behaviour=>"readonly");
    $MitM->server_to_client_callback(\&peek, callback_behaviour=>"readonly");
    $MitM->go();

For historical reasons, "conditional" is the default.  It is not recommended, and may be deprecated in a future release.

"conditional" may be used for readonly or modify type behaviour.  For readonly behaviour, either return the original message, or return null. For example:

    sub peek($) {my $msg = shift; print LOG; return $msg;}
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&peek,callback_behaviour=>"readonly");
    ...

    sub peek($) {my $msg = shift; print LOG; return undef;}
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&peek,callback_behaviour=>"readonly");
    ...

But be careful. This is unlikely to do what you would want:
    sub peek($) {my $msg = shift; print LOG}
    my $MitM = Net::MitM->new("www.cpan.org", 80, 10080);
    $MitM->client_to_server_callback(\&peek,callback_behaviour=>"readonly");
    ...

Assuming print LOG succeeds, print will return a true value (probably 1), and MitM will send that value, not $msg.

=cut 

sub _sanity_check_options($$)
{
  my $self=shift;
  my $options=shift;
  my $allowed=shift;
  foreach my $key (keys %$options){
    if(!$allowed->{$key}){
      carp "Warning: $key not a supported option. Expected: ",join(" ",map {"'$_'"} keys %$options) unless defined $self->{verbose} && $self->{verbose}<=0;
      return undef;
    }
    if( $options->{$key} !~ $allowed->{$key}){
      carp "Warning: $key=$options->{$key} not a supported option.\n" unless $self->{verbose}<=0;
      return undef;
    }
  }
  return 1;
}

sub client_to_server_callback(;$%) {
  my $this=shift;
  my $callback=shift;
  my %options=@_;
  $this->_sanity_check_options(\%options,{callback_behaviour=>qr{^(readonly|modify|conditional)$}});
  $this->_set("client_to_server_callback_behaviour", $options{callback_behaviour}) if $options{callback_behaviour};
  return $this->_set("client_to_server_callback", $callback);
}

=head2 server_to_client_callback( [callback] [,callback_behaviour=>behaviour] )

Set a callback function to monitor/modify each message received from server.

=head4 Parameters

=over

=item * callback - a reference to a function to be called for each inward message

=item * callback_behaviour - explicitly sets the callback to readonly, modify or conditional.

=item * Returns - the current or new setting of callback

=back

=head4 Usage

If a server_to_client_callback callback is set, it will be called with a copy of each message received from the server before it is sent to the client.  

What the callback returns determines what will be sent, depending on the value of callback_behaviour:

=over

=item * If callback_behaviour = "readonly", the return value from the callback is ignored, and the original message is sent.

=item * If callback_behaviour = "modify", the return value from the callback is sent instead of the original message, unless the return value is undef, in which case nothing is sent

=item * If callback_behaviour = "conditional", which is the default, that the return value from the callback is sent instead of the original message, or if the return value is undef, then the original message is sent.  

=back

=cut 

sub server_to_client_callback(;$%) {
  my $this=shift;
  my $callback=shift;
  my %options=@_;
  $this->_set("server_to_client_callback_behaviour", $options{callback_behaviour}) if $options{callback_behaviour};
  return $this->_set("server_to_client_callback", $callback);
}

=head2 timer_callback( [interval, callback] )

Set a callback function to be called at regular intervals

=head4 Parameters

=over

=item * interval - how often the callback function is to be called - must be > 0 seconds, may be fractional

=item * callback - a reference to a function to be called every interval seconds

=item * Returns - the current or new setting, as an array

=back

=head4 Usage

If the callback is set, it will be called every interval seconds.   

Interval must be > 0 seconds.  It may be fractional.  If interval is passed as 0 it will be reset to 1 second. This is to prevent accidental spin-wait. If you really want to spin-wait, pass an extremely small but non-zero interval.

The time spent in callbacks is not additional to the specified interval - the timer callback will be called every interval seconds, or as close as possible to every interval seconds.  

Please remember that if you have called fork before calling go() that the timer_callback method will be executed in a different process to the parent - the two processes will need to use some form of IPC if they are to communicate.

Historical note: Prior to version 0.03_01, if the callback returned false, mainloop would exit and return control to the caller. (FIXME It still does.)  stop_when_idle() can be used to persuade go() to exit. (FIXME check what happens if go() is called after stopping.  TODO Add an unconditional stop() method)

=cut 

#FIXME ignore return code from timer_callback. (Or deprecate this function and create a new one?)
#FIXME check what happens if go() is called after stopping.  
#TODO Add an unconditional stop() method
#TODO - make callback optional - if the interval is set and the callback is not set, mainloop to return interval seconds after being called.   
#TODO - Add an idle_timer callback

sub timer_callback(;$) {
  my $this=shift;
  my $interval=shift;
  my $callback=shift;
  if(defined $interval && $interval==0){
    $interval=1;
  }
  $interval=$this->_set("timer_interval", $interval);
  $callback=$this->_set("timer_callback", $callback);
  return ($interval, $callback);
}

=head2 parallel( [level] )

Turns on/off running in parallel.

=head4 Parameters

=over

=item * level - 0=serial, 1=parallel. Default is 0 (run in serial).

=item * Returns - the current or new setting

=back

=head4 Usage

If running in parallel, MitM starts a new process for each new connection using L<fork>.

Running in serial still allows multiple clients to run concurrently, as so long as none of them have long-running callbacks.  If they do, they will block other clients from sending/recieving.

=cut 

sub parallel(;$) {
  my $this=shift;
  my $parallel=shift;
  if($parallel){
    $SIG{CLD} = "IGNORE"; 
  }
  return $this->_set("parallel", $parallel);
}

=head2 serial( [level] )

Turns on/off running in serial

=head4 Parameters

=over

=item * level - 0=parallel, 1=serial. Default is 1, i.e. run in serial.  

=item * Returns - the current or new setting

=back

=head4 Usage

Calling this function with level=$l is exactly equivalent to calling parallel with level=!$l.

If running in parallel, MitM starts a new process for each new connection using L<fork>.

Running in serial, which is the default, still allows multiple clients to run concurrently, as so long as none of them have long-running callbacks.  If they do, they will block other clients from sending/recieving.

=cut 

sub serial(;$) {
  my $this=shift;
  my $level=shift;
  my $parallel = $this->parallel(defined $level ? ! $level : undef);
  return $parallel ? 0 : 1;
}

=head2 log_file( [log_file_name] ] )

log_file() sets, or clears, a log file.  

=head4 Parameters

=over

=item * log_file_name - the name of the log file to be appended to. Passing "" disables logging. Passing nothing, or undef, returns the current log filename without change.

=item * Returns - log file name

=back

=head4 Usage 

The log file contains a record of connects and disconnects and messages as sent back and forwards.  Log entries are timestamped.  If the log file already exists, it is appended to.  

The default timestamp is "hh:mm:ss", eg 19:49:43 - see mydate() and hhmmss().

=cut 

sub log_file(;$) {
  my $this=shift;
  my $new_log_file=shift;
  if(defined $new_log_file){
    if(!$new_log_file){
      if($this->{LOGFILE}){
        close($this->{LOGFILE});
        $this->{log_file}=$this->{LOGFILE}=undef;
        print "Logging turned off\n" if $this->{verbose};
      }
    }else{
      my $LOGFILE;
      if( open($LOGFILE, ">>$new_log_file") ) {
        binmode($LOGFILE);
        $LOGFILE->autoflush(1); # TODO make this configurable?
        $this->{log_file}=$new_log_file;
        $this->{LOGFILE}=$LOGFILE;
      }
      else {
        print "Failed to open $new_log_file for logging: $!" if $this->{verbose}; 
      }
      print "Logging to $this->{log_file}\n" if $this->{verbose} && $this->{log_file};
    }
  }
  return $this->{log_file};
}

=head2 stop_when_idle( boolean )

Wait for remaining children to exit, then exit

=head4 Parameters

=over

=item * flag - whether to exit when idle, or not. The default is true (exit when idle).

=item * Returns the current status (true=exit when idle, false=keep running)

=back

=head4 Usage 

Causes MitM or Server to return from go() once its last child exits. 

If L<go()> is called after stop_when_idle() then L<stop_when_idle()> only takes effect after at least one child has been created.

MitM or Server will exit immediately if there are currently no children or if MitM or Server is running in parrallel.
Otherwise it will stop accepting new children and exit when the last child exits.

=cut

sub stop_when_idle
{
  my $this=shift;
  if($this->{parent}){
    return $this->{parent}->stop_when_idle(@_);
  }else{
    my $stop_when_idle=shift||1;
    my $retval= $this->_set("stop_when_idle", $stop_when_idle);
    $this->log("stop_when_idle set to: ",$this->{stop_when_idle}||'--undefined--');
    return $retval;
  }
}

=head2 defrag_delay( [delay] )

Use a small delay to defragment messages

=head4 Parameters

=over

=item * Delay - seconds to wait - fractions of a second are OK

=item * Returns - the current setting.

=back

=head4 Usage

Under TCPIP, there is always a risk that large messages will be fragmented in transit, and that messages sent close together may be concatenated.

Client/Server programs have to know how to turn a stream of bytes into the messages they care about, either by repeatedly reading until they see an end-of-message (defragmenting), or by splitting the bytes read into multiple messages (deconcatenating).

For our purposes, fragmentation and concatenation can make our logs harder to read.

Without knowning the protocol, it's not possible to tell for sure if a message has been fragmented or concatenated.

A small delay can be used as a way of defragmenting messages, although it increases the risk that separate messages may be concatenated.

Eg:
    $MitM->defrag_delay( 0.1 );

=cut 

sub defrag_delay(;$) {
  my $this=shift;
  my $defrag_delay=shift;
  return $this->_set("defrag_delay",$defrag_delay);
}

=head2 protocol( [protocol] )

Set protocol to tcp (default) or udp

=head4 Parameters

=over

=item * protocol - either 'tcp' or 'udp'

=item * Returns - the current setting.

=back

=head4 Usage

Eg:
    $MitM->protocol( 'udp' );

=cut 

sub protocol(;$) {
  my $this=shift;
  my $protocol=shift;
  return $this->_set("protocol",$protocol);
}

=head1 SUPPORTING SUBROUTINES/METHODS

The remaining functions are supplimentary.  new_server() and new_client() provide a simple client and a simple server that may be useful in some circumstances.  The other methods are only likely to be useful if you choose to bypass go() in order to, for example, have more control over messages being received and sent.

=head2 new_server( local_port_num, callback_function )

Returns a very simple server, adequate for simple tasks.

=head4 Parameters

=over

=item * local_port_num - the Port number to listen on

=item * callback_function - a reference to a function to be called when a message arrives - must return a response which will be returned to the client

=item * Returns - a new server

=back

=head4 Usage

  sub do_something($){
    my $in = shift;
    my $out = ...
    return $out;
  }

  my $server = Net::MitM->new_server(8080,\&do_something) || die;
  $server->go();
 
The server returned by new_server has a method, go(), which tells it to start receiving messages (arbitrary strings).  Each string is passed to the callback_function, which is expected to return a single string, being the response to be returned to caller.  If the callback returns undef, the original message will be echoed back to the client.   

go() does not return. You may want to L<fork> before calling it.

See, for another example, samples/echo_server.pl in the MitM distribution.

=cut 

sub new_server($%) {
  my $class=shift;
  my $this=_new();
  $this->{local_port_num} = shift or croak "no port number passed";
  $this->{server_callback} = shift or croak "no callback passed";
  return bless $this, $class;
}

=head2 new_client( remote_host, remote_port_num )

new_client() returns a very simple client, adequate for simple tasks

The client returned has a method, send_and_receive(), which sends a message and receives a response. 

Alternately, send_to_server() may be used to send a message, and receive_from_server() may be used to receive a message.

Explicitly calling connect_to_server() is optional, but may be useful if you want to be sure the server is reachable.  If you don't call it explicitly, it will be called the first time a message is sent.

=head4 Parameters

=over

=item * remote_ip_address - the hostname/IP address of the server

=item * remote_port_num - the Port number of the server

=item * Returns - a new client object

=back

=head4 Usage

  my $client = Net::MitM->new_client("localhost", 8080) || die("failed to start test client: $!");
  $client->connect_to_server();
  my $resp = $client->send_and_receive("hello");
  ...

See, for example, samples/client.pl or samples/clients.pl in the MitM distribution.

=cut 

sub new_client($%) {
  my $class=shift;
  my $this=_new();
  $this->{remote_ip_address} = shift or croak "remote hostname/ip address missing";
  $this->{remote_port_num} = shift or croak "remote port number missing";
  return bless $this, $class;
}

#FIXME repetition in doco - clean it up

=head2 log( string )

log is a convenience function that prefixes output with a timestamp and PID information then writes to log_file.

=head4 Parameters

=over

=item * string(s) - one or more strings to be logged

=item * Returns --none--

=back

=head4 Usage

log is a convenience function that prefixes output with a timestamp and PID information then writes to log_file.

log() does nothing unless log_file is set, which by default, it is not.

=cut 

sub log($@)
{
  my $this=shift;
  printf {$this->{LOGFILE}} "%u/%s %s\n", $$, $this->{mydate}(), "@_" if $this->{LOGFILE};
  return undef;
}

=head2 echo( string(s) )

Prints to stdout and/or the logfile

=head4 Parameters

=over

=item * string(s) - one or more strings to be echoed (printed)

=item * Returns --none--

=back

=head4 Usage

echo() is a convenience function that prefixes output with a timestamp and PID information and prints it to standard out if verbose is set and, if log_file() has been set, logs it to the log file.

=cut 

sub echo($@) 
{
  my $this=shift;
  $this->log("@_");
  return if !$this->{verbose};
  confess "Did not expect not to have a name" if !$this->{name};
  if($_[0] =~ m/^[<>]{3}$/){
    my $prefix=shift;
    my $msg=join "", @_;
    chomp $msg;
    printf("%s: %u/%s %s %s\n", $this->{name}, $$, $this->{mydate}(), $prefix, $msg);
  }else{
    printf("%s: %u/%s\n", $this->{name}, $$, join(" ", $this->{mydate}(), @_));
  }
  return undef;
}

=head2 send_to_server( string(s) )

send_to_server() sends a message to the server

=head4 Parameters

=over

=item * string(s) - one or more strings to be sent

=item * Return: true if successful

=back

=head4 Usage

If a callback is set, it will be called before the message is sent.

send_to_server() may 'die' if it detects a failure to send.

=cut 

sub _do_callback($$)
{
  my $this=shift;
  my $direction = shift;
  my $msg = shift;
  my $callback = $this->{$direction."_callback"};
  if($callback){
    $this->echo("calling $direction callback ($msg)\n") if $this->{verbose}>1;
    my $new_msg = $callback->($msg,$this);
#warn "~~~ ",$new_msg||"--undef--","\n";
    my $callback_behaviour = $this->{$direction."_callback_behaviour"} || 'conditional';
    #warn ("callback behaviour is ($callback_behaviour)\n") if $this->{verbose}>1;
    if($callback_behaviour eq 'modify' || ($callback_behaviour ne 'readonly' && defined $new_msg)){
      $msg = $new_msg;
    }
  }
#warn "+++ ",$msg||"--undef--","\n";
  return $msg;
}

sub _logmsg
{
  my $this = shift;
  my $direction = shift;
  my $msg = shift;
  if($this->{verbose}>1){
    $this->echo($direction,"(".length($msg)." bytes) {$msg}\n");
  }else{
    # don't print the whole message by default, in case it is either binary &/or long
    $this->echo($direction,"(".length($msg)." bytes)\n");
    $this->log($direction," {{{$msg}}}\n");
  }
}

sub send_to_server($@)
{
    my $this = shift;
    my $msg = shift;
    $this->connect_to_server();
    $msg = $this->_do_callback( 'client_to_server', $msg );
    if(!defined $msg){
      warn "client to server callback says no\n" if $this->{verbose}>1;
      return undef;
    }
    $this->_logmsg(">>>",$msg);
    confess "SERVER being null was unexpected" if !$this->{SERVER};
    print({$this->{SERVER}} $msg) || die "Can't send to server: $?";
    return undef;
}

=head2 send_to_client( string(s) )

Sends a message to the client

=head4 Parameters

=over

=item * string(s) - one or more strings to be sent

=item * Return: true if successful

=back

=head4 Usage

If a callback is set, it will be called before the message is sent.

=cut 

sub _send_to_client($@)
{
    my $this = shift;
    my $msg = shift;
    $this->_logmsg("<<<",$msg);
    return print({$this->{CLIENT}} $msg);
}

sub send_to_client($@)
{
    my $this = shift;
    my $msg = shift;
    $msg = $this->_do_callback( 'server_to_client', $msg );
    if(!defined $msg){
      warn "server to client callback says no\n" if $this->{verbose}>1;
      return undef
    }
    return $this->_send_to_client($msg);
}

=head2 receive_from_server( )

Receives a message from the server

=head4 Parameters

=over

=item * --none--

=item * Returns - the message read, or undef if the server disconnected.  

=back

=head4 Usage

Blocks until a message is received.

This method used to be called read_from_server(), and may still be called via that name.

=cut 

sub receive_from_server()
{
  my $this=shift;
  my $msg;
  sysread($this->{SERVER},$msg,100000) or confess "Fatal: sysread failed: $!";
  if(length($msg) == 0)
  {
    $this->echo("Server disconnected\n");
    return undef;
  }
  return $msg;
}

=head2 read_from_server( ) [Deprecated]

use instead: receive_from_server( )

=cut 

sub read_from_server() { my $this=shift;return $this->receive_from_server(); }

=head2 send_and_receive( )

Sends a message to the server and receives a response

=head4 Parameters

=over

=item * the message(s) to be sent

=item * Returns - message read, or undef if the server disconnected. 

=back

=head4 Usage

Blocks until a message is received.  If the server does not always return exactly one message for each message it receives, send_and_receive() will either concatenate messages or block forever.

=cut 

sub send_and_receive($)
{
  my $this=shift;
  $this->send_to_server(@_);
  return $this->receive_from_server();
}

=head2 connect_to_server( )

Connects to the server

=head4 Parameters

=over

=item * --none--

=item * Returns true if successful 

=back

=head4 Usage

This method is automatically called when needed. It only needs to be called directly if you want to be sure that the connection to server succeeds before proceeding.

Changed in v0.03_01: return true/false if connect successful/unsuccessful. Previously died if connect fails.  Failure to resolve remote internet address/port address is still fatal.

=cut

# TODO would be nice to have a way to specify backup server(s) if 1st connection fails.  Also nice to have a way to specify round-robin servers for load balancing.

sub _socket($)
{
  my $this=shift;
  my $socket=shift;
  my $protocol = $this->{protocol}||'tcp';
  my $proto = getprotobyname($protocol) or die "Can't getprotobyname\n";
  my $sock = $protocol eq 'udp' ? SOCK_DGRAM : SOCK_STREAM ;
  
  socket($this->{$socket}, PF_INET, $sock, $proto) or confess "Fatal: Can't create $protocol socket: $!";
}

sub connect_to_server()
{
  my $this=shift;
  return if $this->{SERVER};
  $this->_socket("SERVER");
  confess "remote_ip_address unexpectedly not known" if !$this->{remote_ip_address};
  my $remote_ip_aton = inet_aton( $this->{remote_ip_address} ) or croak "Fatal: Cannot resolve internet address: '$this->{remote_ip_address}'\n";
  my $remote_port_address = sockaddr_in($this->{remote_port_num}, $remote_ip_aton ) or die "Fatal: Can't get port address: $!"; # TODO Is die the way to go here? Not sure it isn't. Not sure it is.
  $this->echo("Connecting to $this->{remote_ip_address}\:$this->{remote_port_num} [verbose=$this->{verbose}]\n");
  my $connect = connect($this->{SERVER}, $remote_port_address) or return undef;
  $this->{SERVER}->autoflush(1);
  binmode($this->{SERVER});
  return $connect;
}

=head2 disconnect_from_server( )

Disconnects from the server

=head4 Parameters

=over

=item * --none--

=item * Returns --none--

=back

=head4 Usage

disconnect_from_server closes any connections.

It is only intended to be called on clients.  

For MitM, like for any server, disconnection is best triggered by the other party disconnecting, not by the server. If a server disconnects while it has an active client connection open and exits or otherwise stops listening, it will not be able to reopen the same port for listening until the old connection has timed out which can take up to a few minutes.

=cut

sub disconnect_from_server()
{
  my $this=shift;
  $this->log("initiating disconnect");
  $this->_destroy();
  return undef;
}

sub _pause($){
  # warning - select may return early if, for eg, process catches a signal (if it survives the signal)
  select undef,undef,undef,shift;
  return undef;
}

sub _message_from_client_to_server(){ # TODO Too many too similar sub names, some of which maybe should be public
  my $this=shift;
  # optional sleep to reduce risk of split messages
  _pause($this->{defrag_delay}) if $this->{defrag_delay};
  # It would be possible to be more agressive by repeatedly waiting until there is a break, but that would probably err too much towards concatenating seperate messages - especially under load.
  my $msg;
  sysread($this->{CLIENT},$msg,10000);
  # (0 length message means connection closed)
  if(length($msg) == 0) { 
    $this->echo("Client disconnected\n");
    $this->_destroy();
    return undef;
  }
  # Send message to server, if any. Else 'send' to callback function and return result to client.
  if($this->{SERVER}){
    $this->send_to_server($msg);
  }elsif($this->{server_callback}){
    $this->send_to_client( $this->{server_callback}($msg) );
  }else{
    confess "$this->{name}: Did not expect to have neither a connection to a SERVER nor a server_callback";
  }
  return undef;
}

=head2 graceful_shut_down( )

Shut down the server gracefully

=head4 Parameters

=over

=item * --none--

=item * Returns --none--

=back

=head4 Usage

graceful_shut_down closes the LISTEN socket so that no more clients will be accepted.  When the last client has exited, mainloop will exit.

If running in parallel mode, graceful_shut_down will take effect immediately, the children will keep running.  This might change in a future release.

=cut

sub graceful_shut_down()
{
  my $this=shift;
  $this->log("initiating disconnect");
  $this->_destroy_fh("LISTEN");
  return undef;
}

sub _message_from_server_to_client(){ # TODO Too many too similar sub names
  my $this=shift;
  # sleep to avoid splitting messages
  _pause($this->{defrag_delay}) if $this->{defrag_delay};
  # Read from SERVER and copy to CLIENT
  my $msg = $this->receive_from_server();
  if(!defined $msg){
    $this->_destroy();
    return undef;
  }
  $this->send_to_client($msg);
  return undef;
}

sub _cull_child()
{
  my $this=shift or die;
  my $child=shift or die;
  for my $i (0 .. @{$this->{children}}){
    if($child==$this->{children}[$i]){
      $this->echo("Child $child->{name} is done, cleaning it up") if $this->{verbose}>1;
      splice @{$this->{children}}, $i,1;
      return;
    }
  }
  confess "Child $child->{name} is finished, but I can't find it to clean it up";
}

# _main_loop is called both by listeners and by forked children. When called by listeners, it also includes any children running in serial

my $warned_about_deprecation=0;
sub _main_loop()
{
  my $this=shift;
  my $last_time;
  my $target_time;
  if($this->{timer_interval}&&$this->{timer_callback}){
    $last_time=time();
    $target_time=$last_time+$this->{timer_interval};
  }
  # Main Loop
  MAINLOOP: while(1)
  {
    # Build file descriptor list for select call 
    my $rin = "";
    if($this->{LISTEN}){
      confess "LISTEN is unexpectedly not a filehandle" if !fileno($this->{LISTEN});
      vec($rin, fileno($this->{LISTEN}), 1) = 1;
    }
    foreach my $each ($this, @{$this->{children}}) {
      vec($rin, fileno($each->{CLIENT}), 1) = 1 if $each->{CLIENT}; # TODO if no client, child should probably be dead
      vec($rin, fileno($each->{SERVER}), 1) = 1 if $each->{SERVER};
    }
    # and listen...
    my $rout = $rin;
    my $delay;
    if($this->{timer_interval}){
      if(time() > $target_time){
	my $resp = $this->{timer_callback}($this);
	if($resp){
	  # TODO Add a deprecated warning?
	}else{
	  last MAINLOOP;
	} 
	$last_time=$target_time;
	$target_time+=$this->{timer_interval};
      }
      $delay=$target_time-time();
      $delay=0 if($delay<0);
      $this->echo("delay=$delay") if $this->{verbose} > 1;
    }else{
      $delay=undef;
    }
    my $status=select( $rout, "", "", $delay ); 
    if($status==-1){
      warn "something happened - were we signalled? if so, why do we live?\n";
    }
    if( $this->{LISTEN} && vec($rout,fileno($this->{LISTEN}),1) ) {
      my $child = $this->_spawn_child();
      push @{$this->{children}}, $child if $child;
      next;
    }
    CHILDREN: foreach my $each($this, @{$this->{children}}) {
      confess "We have a child with no CLIENT\n" if !$each->{CLIENT} && $each!=$this;
      if($each->{CLIENT} && vec($rout,fileno($each->{CLIENT}),1) ) {
        $each->_message_from_client_to_server(); # TODO Too many too similar sub names
        if(!$each->{CLIENT}){
          $each->log("No Client\n");
          # client has disconnected
          if($each==$this){
            # we are the child - OK to exit
            $each->log("We are the child");
            return;
          }else{
            # we are the parent - clean up child 
            $each->log("We are the parent");
            $each->log("stop_when_idle is: ",$this->{stop_when_idle}||'--undefined--');
            $each->log("number of children (before cull): ",scalar(@{$this->{children}}));
            $this->_cull_child($each);
            $each->log("number of children (after cull): ",scalar(@{$this->{children}}));
            # keep going?
            if($this->{stop_when_idle} && (!@{$this->{children}})){
              $this->log("idle exiting mainloop");
              return undef;
            }
            $each->log("continuing: ",$this->{stop_when_idle}?'y':'n',!@{$this->{children}});
            last CHILDREN; # _cull_child impacts the children array - not safe to continue without regenerating rout
          }
        }else{
          $each->echo("We still have a client") if $this->{verbose}>1;
        }
      }
      if($each->{SERVER} && vec($rout,fileno($each->{SERVER}),1) ) {
        $each->_message_from_server_to_client(); # TODO Too many too similar sub names
        if(!$each->{SERVER}){
          # server has disconnected
          if($each==$this){
            # we are the child - OK to exit
            return; #might be better to die or exit at this point instead?
          }else{
            $this->_cull_child($each);
            if($this->{stop_when_idle} && !@{$this->{children}}){
              $this->log("idle exiting mainloop - server disconnected");
              return undef;
            }
            last CHILDREN; # _cull_child impacts the children array - not safe to continue without regenerating rout
          }
        }
      }
    } # foreach CHILDREN
  }
  return undef;
}

=head2 hhmmss( )

The default timestamp function - returns localtime in hh:mm:ss format

=head4 Parameters

=over

=item * --none--

=item * Returns - current time in hh:mm:ss format

=back

=head4 Usage

This function is, by default, called when a message is written to the log file.

It may be overridden by calling mydate().

=cut

sub hhmmss()
{
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
  return sprintf "%02d:%02d:%02d",$hour,$min,$sec;
}

=head2 mydate( )

Override the standard hh:mm:ss datestamp

=head4 Parameters

=over

=item * datestamp_callback - a reference to a function that returns a datestamp

=item * Returns - a reference to the current or updated callback function

=back

=head4 Usage

For example:

  sub yymmddhhmmss {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    return sprintf "%02d/%02d/%02d %02d:%02d:%02d", 
      $year+1900,$mon+1,$mday,$hour,$min,$sec;
  }
  mydate(\&yymmddhhmmss);

=cut

sub mydate(;$)
{
  my $this=shift;
  my $mydate=shift||undef;
  if(defined $mydate){
    $this->{mydate} = $mydate;
  }
  return $this->{mydate};
}

=head2 listen( )

Listen on local_port and prepare to accept incoming connections

=head4 Parameters

=over

=item * --none--

=item * Return --none--

=back

=head4 Usage

This method is called by go(). It only needs to be called directly if go() is being bypassed for some reason.

=cut

sub listen()
{
  my $this=shift;
  return if $this->{LISTEN};
  $this->echo(sprintf "Server %u listening on port %d (%s)\n",$$,$this->{local_port_num},$this->{parallel}?"parallel":"serial");
  $this->_socket("LISTEN");
  bind($this->{LISTEN}, sockaddr_in($this->{local_port_num}, INADDR_ANY)) or confess "Fatal: $this->{name} can't bind LISTEN socket [$this->{LISTEN}] to $this->{local_port_num}: (",$!+0,") $!";
  listen($this->{LISTEN},1) or confess "Fatal: Can't listen to socket: $!";
  $this->echo("Waiting on port $this->{local_port_num}\n");
  return undef;
}

sub _accept($)
{
  # Accept a new connection 
  my $this=shift;
  my $LISTEN=shift;
  my $client_paddr = accept($this->{CLIENT}, $LISTEN) or confess "accept failed: $!"; 
  $this->{CLIENT}->autoflush(1);
  binmode($this->{CLIENT});
  my ($client_port, $client_iaddr) = sockaddr_in( $client_paddr );
  $this->log("Connection accepted from", inet_ntoa($client_iaddr).":$client_port\n"); 
  if($this->{remote_ip_address}){
    $this->connect_to_server() or confess "Fatal: Can't connect to $this->{remote_ip_address}:$this->{remote_port_num}: $!";
}
  $this->{client_port} = $client_port;
  $this->{client_iaddr} = inet_ntoa($client_iaddr);
  return undef;
}

sub _new_child(){
  my $parent=shift;
  my $child=_new();
  my $all_good=1;
  foreach my $key (keys %{$parent}){
    if($key=~m/^(LISTEN|children|connections|timer_interval|timer_callback|is_running|stop_when_idle)$/){
      # do nothing - these parameters are not inherited
    }elsif($key =~ m/^(parallel|log_file|verbose|mydate|(client_to_server|server_to_client|server)_callback(_behaviour)?|(local|remote)_(port_num|ip_address)|protocol)$/){
      $child->{$key}=$parent->{$key};
    }elsif($key =~ m/^(name)$/){
      $child->{$key}=$parent->{$key}.".jr";
    }elsif($key eq "LOGFILE"){
      # TODO might want to have a different logfile for each child, or at least, an option to do so.
      $child->{$key}=$parent->{$key};
    }else{
      warn "internal error - unexpected attribute: $key = {$parent->$key}\n";
      $all_good=0;
    }
  }
  die "Internal error in _new_child()" unless $all_good;
  $child->{parent}=$parent;
  return bless $child;
}

sub _spawn_child(){
  my $this=shift;
  my $child = $this->_new_child();
  $child->_accept($this->{LISTEN});
  confess "We have a child with no CLIENT\n" if !$child->{CLIENT};
  # hand-off the connection
  $this->echo("starting connection:",++$this->{connections});
  if(!$this->{parallel}){
    return $child;
  }
  my $pid = fork();
  if(!defined $pid){
    # Error
    $this->echo("Cannot fork!: $!\nNew connection will run in the current thread\n");
    return $child;
  }elsif(!$pid){
    # This is the child process
    $child->echo(sprintf"Running %u",$$) if $child->{verbose}>1;
    confess "We have a child with no CLIENT\n" if !$child->{CLIENT};
    # The active instance of the parent is potentially in a different process
    # Ideally, we would have the parent go out of scope, but we can clean up the bits that matter
    close $this->{LISTEN};
    $this->{LISTEN} = undef;
    $child->_main_loop();
    $child->log(sprintf"Exiting %u",$$);
    exit;
  }else{
    # This is the parent process.  The active child instance is in its own process, we clean up what we can
    $child->_destroy();
    return undef;
  }
}

sub go()
{
  my $this=shift;
  $this->log("go");
  $this->listen();
  $this->_main_loop();
  $this->log("stopped");
  return undef;
}

#sub _destroy_fh() { my $this=shift; my $file_handle=shift; if($this->{$file_handle}){ $this->log( "$this->{name}: closing $file_handle socket ". ($this->{local_port_num}||"")."\n") if $this->{verbose}; close $this->{$file_handle} or die; $this->{$file_handle}=undef; } return undef; }

sub _destroy()
{
  my $this=shift;
  # TODO? Tell children that they are being shutdown? 
  close $this->{LISTEN} if($this->{LISTEN});
  close $this->{CLIENT} if($this->{CLIENT});
  close $this->{SERVER} if($this->{SERVER});
  $this->{LISTEN}=$this->{SERVER}=$this->{CLIENT}=undef;
  return undef;
}

=head1 Exports

MitM does not export any functions or variables.  
If parallel() is turned on, which by default it is not, MitM sets SIGCHD to IGNORE, and as advertised, it calls fork() once for each new connection.

=head1 AUTHOR

Ben AVELING, C<< <ben dot aveling at optusnet dot com dot au> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-Net-MitM at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-MitM>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::MitM

You can also look for information at:

=over

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-MitM>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-MitM>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-MitM>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-MitM/>

=back

=head1 ACKNOWLEDGEMENTS

I'd like to acknowledge W. Richard Steven's and his fantastic introduction to TCPIP: "TCP/IP Illustrated, Volume 1: The Protocols", Addison-Wesley, 1994. (L<http://www.kohala.com/start/tcpipiv1.html>). 
It got me started. Recommend. RIP.
The Blue Camel Book is also pretty useful, and Langworth & chromatic's "Perl Testing, A Developer's Notebook" is also worth a hat tip.

=head1 ALTERNATIVES

If what you want is a pure proxy, especially if you want an ssh proxy or support for firewalls, you might want to evaluate Philippe "BooK" Bruhat's L<Net::Proxy>.

And if you want a full "portable multitasking and networking framework for any event loop", you may be looking for L<POE>.

=head1 LICENSE AND COPYRIGHT

Copyleft 2013 Ben AVELING.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, have, hold and cherish,
use, offer to use, sell, offer to sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. SO THERE.

=cut

1; # End of Net::MitM
