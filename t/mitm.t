#!perl -w
use strict;

# Test runs to completion on dos perl 5.10 - then doesn't exit until all the MitM timeout. No problem on dos with perl 5.14 or perl 5.18 or on linux with perl 5.14. Seems to be a problem with signals in dos perl 5.10 (and earlier?), possibly that signals are ineffective if the receiver is in a system call, such as select. Cpantest isn't reporting any test failures on Windows, but it isn't reporting any successes on Windows earlier than 5.16.2 either.  Possibly tests that don't exit don't get reported, or maybe no-one has run it. Might be an option to replace the signals with the use of timer_callback
#
# There is also another problem that only appears on windows: 
#   panic: attempt to copy freed scalar 1104534 to 1109e7c at C:/STRAWB~1/perl/lib/Test/Builder.pm line 2304.
#
# I suspect it is something to do with fork() and signals(), but not sure what. Unless it is the combination of fork() and a fatal error? Maybe better to add extra sleeps instead of listening before calling fork, and to use in-band messages and exit_when_idle in order to know when to shut down.
#
# subtest() uses threads under the hood - calling fork() from inside subtest doesn't work well on Windows.

use Test::More; # Test::More 0.86 is not enough - doesn't support subtest.  Not sure exactly which version it was added in. Possibly 0.88? 0.98 works fine.  

plan tests => 11;

my $go_hard=0;

sub isWindows(){
  return($^O =~ /MSWin|dos|cygwin|os2/i);
}
my $isWindows=isWindows();

my $iterations;

if(!$go_hard){
  $iterations =  10;
}else{
  # 1000 is about what linux can handle. Windows seems to max out at about 64 (tried perl 5.10 and 5.14).  Haven't tried any other OS. If you do, let me know and I'll update.
  if($isWindows){
    $iterations = 50;
  }else{
    $iterations = 1000;
  }
}

my $short_timeout=3; # used where we can't tell the MitM to quit - where we expect it to timeout
my $long_timeout = $iterations/10 + 30; # used where we know more time is needed, or where we expect to be able to send an 'inband quit'. Depending on number of iterations, script takes about 60 seconds on my little netbook going hard.

use Net::MitM;
use Carp;
use Socket;

print "="x72,"\n";

sub stop_when_idle($$){
  my $name=shift;
  my $mitm=shift;
  $name=$mitm->{name};
  print "$name has been told to stop_when_idle\n";
  $mitm->stop_when_idle();
}


sub expire_callback($$@){
  my $expire_at=shift;
  my $verbose=shift;
  my $server=shift;
  #Note that we have two timeouts here - how often this callback is called, 
  #and how long before calling this becomes fatal
  if(time>$expire_at){
    warn sprintf "Timer expired: %s (pid=%u)\n",$server?$server->{name}:"",$$ if $verbose;
    #Note: if running in parallel, only takes down current process 
    #parent and children, if any, keep running
    exit();
  }
  return 1;
}

sub expire_closure(;$$)
{
  my $expire_timeout=shift || $long_timeout; 
  my $verbose=defined $_[0] ? shift : 1;
  my $t0=time;
  return sub{ return expire_callback($t0 + $expire_timeout, $verbose, @_); }
}

sub file_age($)
{
  my $file=shift or die;
  my $age_in_days = -M $file;
  my $age_in_seconds = $age_in_days / (24*60*60);
  return $age_in_seconds;
}

my $warned=0;
my $last_binding_message=0;
my $next_port=8000;
sub next_port($)
{
  # This is not guaranteed to work because there is a small window in which a 'free' port can be grabbed by another process.
  my $name=shift;
  my $protocol = getprotobyname('tcp') or warn "getprotobyname failed: $!"; # getprotobyname sometimes fails on windows. Unclear why.
  while(1){
    my $candidate=$next_port++;
    my $LISTEN;
    socket($LISTEN, PF_INET, SOCK_STREAM, $protocol) or confess "Fatal: Can't create socket: $!";
    my $ok=bind($LISTEN, sockaddr_in($candidate, INADDR_ANY));
    close $LISTEN;
    if($ok){
      my $binding_message="Binding $name";
      warn("$binding_message to $candidate.\n") if $warned;
      $last_binding_message=$binding_message;
      $warned=0;
      return $candidate;
    }elsif($isWindows ? ($!==9||$!==10048) : $!==98){ # Already in use // I hope the error code doesn't differ on every system. Odds?
      if(! $warned){
        print STDERR "Warning: $name can't bind LISTEN socket to $candidate: (",($!+0),") $!. ";
        $warned=1;
      }
      #$next_port++;
      next;
    }else{
      confess("Fatal (",($!+0),"): Can't bind LISTEN socket to $candidate: $!");
    }
  }
}

my $echo_port=next_port("Echo server");

sub pause($);
sub pause($)
{
  my $seconds=shift;
  my $togo=select(undef,undef,undef,$seconds);
  if($togo<0){
    warn sprintf Net::MitM->hhmmss(). " pause interrupted. Will pause again.\n";
    pause($seconds);
  }
}

# my $running_mitm=undef;
# sub done()
# {
#   warn sprintf("Process %u%s has been signalled [@_] - exiting.\n",$$, ($running_mitm ?  " ($running_mitm->{name})" : ""));
#   exit();
# }
# sub abort()
# {
#   confess sprintf("Process %u has been signalled (@_) - aborting.\n",$$);
#   BAIL_OUT("signalled");
#   exit();
# }

#$SIG{TERM}=\&done;
#$SIG{ALRM}=\&abort;
#$SIG{INT}=\&abort;
$SIG{CLD} = $SIG{CHLD} = "IGNORE";

sub my_kill($@){
  while(my $pid=shift){
    #pause(0.01);
    my $kill=kill('TERM', $pid);
    print sprintf("\nkill of %u = %s\n",$pid,$kill);
    #print "wait=",wait(),"\n"; # or can wait here, but waiting at both doesn't work
    #print "kill (again) =",kill('TERM', $pid),"\n";
    #pause(0.01);
  }
}

sub run_in_background($)
{
  my $server=shift;
  #my $name=shift;
  #my $block=shift;
  if(!$isWindows){
    #listening here means that the parent can't call the child before the child can call listen. But it seems to break windows - probably the combination of listen and fork.  Calling fork inside subtest seems to break windows too, though it works fine on linux.
    $server->listen() 
  }
  my $pid=fork();
  if(!defined $pid){
    #error
    BAIL_OUT("cannot fork: $!");
  }elsif($pid==0){
    #child
    print sprintf "child %u spawned...\n",$$;
    $server->go();
    $server->_destroy(); # FIXME
    exit();
  }else{
    #parent
    if($isWindows){
      # give child time to start
      pause(.5); # 0.5 is enough on my machine. 0.3 is not. YMMV. 
    }else{
      $server->_destroy() # because we listen before forking (to be sure that server is ready before run_in_background returns), we need to make sure that the parent has closed any handles that should be owned by the child, lest the parent 'share' those resources. Windows seems to get unhappy if we try the same thing, so instead we have the child do the listen, and the parent 'waits'. It might be an option to get the parent to communicate to the child via IPC, eg - keep open a back channel, either a TCPIP listen socket, or a pipe, but dos probably can't handle a pipe so maybe parent listening is the cleanest way to go.
    }
    return $pid;
  }
}

# echo server - used in most of our tests
{
my $echo_server;
sub echoback($){
  my $msg=shift;
  if($msg =~ "quit echo server"){
    stop_when_idle($echo_server->{name},$echo_server);
  }
  return $msg;
}

sub new_echo_server() {
  my $echo_server = Net::MitM->new_server($echo_port,\&echoback) || BAIL_OUT("failed to start test server: $!");
  $echo_server->name("echo-server");
  $echo_server->timer_callback($long_timeout,expire_closure($long_timeout));
  $echo_server->log_file("echo.log");
  #$echo_server->verbose(2);
  # side-test of _new_child
  my $new_child=$echo_server->_new_child(); # _new_child will complain (fail) if there are attributes it doesn't expect
  $new_child->name(sprintf "echo-server-child-%u",$$);
  return $echo_server;
}

$echo_server=new_echo_server();
my $echo_server_pid=run_in_background($echo_server);
}

subtest("1. echo server creation" => sub {
  my $echo_server = Net::MitM->new_server($echo_port,\&echoback) || BAIL_OUT("failed to start test server: $!");
  $echo_server->name("echo-server 1");
  is($echo_server->name(),"echo-server 1","round trip of name()");
  is($echo_server->{local_port_num},$echo_port,"initial setting of local port num"); # Note - encapsulation bypassed for testing
  is($echo_server->{server_callback},\&echoback,"initial setting of callback"); # bypasses encapsulation for testing
});

subtest('2. client <-> server (without MitM)' => sub {
  print "2. client <-> server (direct) ---------------\n";
  my $test="direct to server";
  my @clients;
  # works for up to just over 1000 on linux, the limit on windows is rather lower
  for (1..$iterations){
    print "$_/$iterations\n";
    $clients[$_] = my $client = Net::MitM->new_client("localhost",$echo_port);
    $client->name("client 2.$_");
    my $response = $client->send_and_receive("1234.$_");
    is($response, "1234.$_", "$test: send and receive a string ($_ of $iterations)");
  }
  for (1..$iterations){
    $clients[$_]->disconnect_from_server();
  }
});

{
  my $port2=next_port("MitM 3");
  my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
  $mitm->name("MitM 3:$port2");
  my $expire_timeout=$go_hard ? $long_timeout : $short_timeout;
  $mitm->timer_callback($short_timeout,expire_closure($expire_timeout)); # Question: use expire_timeout for both?
  #$mitm->listen() unless $isWindows;
  $mitm->stop_when_idle();#unless $isWindows;
  #my $MitM_pid = run_in_background($mitm->{name},sub{$running_mitm = $mitm; $mitm->go(); exit});
  my $MitM_pid = run_in_background($mitm);
subtest('3. MitM with no callbacks' => sub {
  is($mitm->name(),"MitM 3:$port2","roundtrip name()");
  print "3. MitM with no callbacks ----------------\n";
  my $client = Net::MitM->new_client("localhost",$port2);
  $client->name("client 3:$port2");
  my $response = $client->send_and_receive("232");
  is($response,"232","send and receive a string");
  $client->disconnect_from_server();
  # Not guaranteed to work, but saves time when it does
  #printf "Signalling MitM: %u\n",$MitM_pid;
  #my_kill $MitM_pid;
});
}

# note - log1 and log2 are called in the child process, not in the parent - cannot be used to return a value to parent when running in parallel

sub log1($$)
{
  my $msg=shift;
  my $mitm=shift;
  print "++ log1 called: '$msg' ++\n";
  if($msg =~ "quit"){
    print "quiting\n";
    stop_when_idle("MitM 4",$mitm);
  }
}

sub log2($)
{
  #print "++ log2 called ++\n";
  return undef;
}

subtest('4.0 _sanity_check_options'=>sub {
    my %allow = ('a'=>qr{^a$}i);
    my %good = ('a'=>'A');
    my %bad1 = ('a'=>'A','b'=>'a');
    my %bad2 = ('a'=>'b');
    my $mitm = Net::MitM->new('localhost',$echo_port,$echo_port); # not for use
    $mitm->verbose(-1);
    ok($mitm->_sanity_check_options(\%good,\%allow));
    ok(!$mitm->_sanity_check_options(\%bad1,\%allow));
    ok(!$mitm->_sanity_check_options(\%bad2,\%allow));
});

subtest('4. MitM with readonly callbacks'=>sub {
  print "4. MitM with readonly callbacks ---------------\n";
  my @pids;
  my $previous_client;
  for my $subsubtest (1..$iterations){
    my $port2=next_port("MitM 4");
    print "run_in_background MitM 4.$subsubtest:$port2\n";
    my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
    $mitm->name("MitM 4.$subsubtest:$port2");
    $mitm->verbose(1);
    $mitm->timer_callback($long_timeout,expire_closure($long_timeout)); # shouldn't timeout - is a bug if it does
    $mitm->client_to_server_callback(\&log1,callback_behaviour=>"readonly");
    $mitm->server_to_client_callback(\&log2,callback_behaviour=>"readonly");
    is($mitm->_do_callback('client_to_server','hello world'),'hello world','should be readonly');
    is($mitm->_do_callback('server_to_client','hello world'),'hello world','should be readonly');
    # $mitm->listen() unless $isWindows;
    # my $mitm_pid = run_in_background($mitm->{name},sub{ $running_mitm = $mitm; $mitm->go(); print $mitm->name()," done\n"; exit(); });
    $mitm->stop_when_idle(); # should do some testing without stop when idle
    my $MitM_pid = run_in_background($mitm); # if fork and subtest don't work together on windows, why doesn't this cause grief? Maybe only if something errors?
    #pause(.01) if $isWindows; # should only need a fraction of a second. Would be preferable to listen before forking, but seems to cause grief on windows
    my $client = Net::MitM->new_client("localhost",$port2);
    $client->name("client 4.$subsubtest:$port2");
    my $response = $client->send_and_receive("testing on port:".$port2);
    is($response,"testing on port:".$port2,"send and receive a string");
    $client->send_and_receive("quit");
    #pause(.01); # needs a fraction of a second of delay - waiting until the following loop seems to be enough, at least on linux
    $client->disconnect_from_server();
    #$previous_client->disconnect_from_server() if $previous_client;
    #$previous_client=$client;
    #pause(.2); # should only need a fraction of a second
    #printf "Signalling MitM: %u\n",$mitm_pid;
    #kill 'TERM', $mitm_pid or warn "missed: $!";
    #pause(.1); # should only need a fraction of a second
  }
  #$previous_client->disconnect_from_server();
});

sub manipulate1($$)
{
  my $str = shift;
  my $mitm=shift;
  if($str =~ "quit"){
    print "quiting\n";
    stop_when_idle("MitM 5",$mitm);
  }
  $str =~ s/a/A/;
  #print "manipulate: $str\n";
  return $str." before";
}

sub manipulate2($)
{
  my $str = shift;
  $str =~ s/e/E/;
  return $str;
}

sub test_changing_message_on_the_fly($$){
  my $is_parallel=shift;
  my $name=shift;
  my $test="MitM with readwrite callbacks - parallel=$is_parallel";
  my $port2=next_port("MitM 5.$is_parallel");
  my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");;
  $mitm->name($name);
  # timeout needed when running in parallel - can't use in-band quit to stop parent MitM because child MitM is a different process
  $mitm->timer_callback($short_timeout,expire_closure($short_timeout,!$is_parallel));
  $mitm->client_to_server_callback(\&manipulate1,callback_behaviour=>"modify");
  $mitm->server_to_client_callback(\&manipulate2,callback_behaviour=>"modify");
  $mitm->parallel(1) if $is_parallel;
  #$mitm->listen() unless $isWindows;
  #my $MitM_pid = run_in_background($mitm->{name},sub{$running_mitm = $mitm; $mitm->go();exit});
  my $MitM_pid = run_in_background($mitm);
  my $client = Net::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  my $response = $client->send_and_receive("abc");
  is($response,"Abc bEfore","$test: request manipulation");
  $response = $client->send_and_receive("def");
  is($response,"dEf before","$test: response manipulation");
  $client->send_and_receive("quit");
  $client->_destroy();
  # kill doesn't work reliably on windows, at least on some versions of perl, but saves time when it does
  #printf "Signalling MitM: %u\n",$MitM_pid;
  #my_kill($MitM_pid);
}

subtest("5a. MitM with readwrite callbacks - serial" => sub {
  print "5a. with read write - serial -----------------\n";
  test_changing_message_on_the_fly(0,"MitM 5a");
});

subtest("5b. MitM with readwrite callbacks - parallel" => sub {
  print "5b. with read write - parallel -----------------\n";
  test_changing_message_on_the_fly(1,"MitM 5b");
});

sub suppress_if_odd{
  my $in=shift;
  my $mitm=shift;
  if($in =~ "quit"){
    print "quiting\n";
    stop_when_idle("MitM 6",$mitm);
    return "quit pending";
  }
  return(($in%2)?undef:"<$in>");
}

subtest("6. some messages don't get forwarded" => sub {
  my $port2=next_port("MitM 6 - suppression");
  my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");;
  $mitm->name("MitM 6 - suppression");
  $mitm->timer_callback($short_timeout,expire_closure($short_timeout));
  $mitm->client_to_server_callback(\&suppress_if_odd,callback_behaviour=>"modify");
  #$mitm->verbose(2);
  is($mitm->_do_callback('client_to_server',"1"),undef,'should suppress an odd number');
  is($mitm->_do_callback('client_to_server',"2"),"<2>",'should pass an even number');
  is($mitm->_do_callback('server_to_client',"3"),"3",'no callback, should pass everything unchanged');
  my $MitM_pid = run_in_background($mitm);
  my $client = Net::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  my $spacer=0.1; # should be enough to prevent packets being concatenated in transit
  $client->send_to_server("1");
  pause($spacer);
  $client->send_to_server("2");
  pause($spacer);
  $client->send_to_server("3");
  pause($spacer);
  $client->send_to_server("4");
  pause($spacer);
  my $response=$client->receive_from_server();
  is($response,"<2><4>","should only have passed even numbers");
  $client->send_and_receive("quit");
  $client->_destroy();
  # FIXME This is timing out. It shouldn't.
});

{
  my $done=0;
  subtest('7. MitM with timer_callback'=>sub {
  print "7. timer callback ------------------\n";
    my $port2=next_port("MitM 7");
    sub do_once(){
      return 0;
    }
    my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
    $mitm->timer_callback(0,\&do_once);
    $mitm->name("MitM 7a");
    my ($interval,$callback) = $mitm->timer_callback();
    is($interval,1); # sanity check - mitm disallows an interval of exactly 0
    $mitm->timer_callback(2,\&do_once);
    $mitm->name("mitm-$port2");
    ($interval,$callback) = $mitm->timer_callback();
    is($interval,2);
    is($callback,\&do_once);
    my $t1 = time();
    alarm 5; # if something goes wrong, don't silently hang forever - user may still need to ^C, but at least tell them
    $mitm->go();
    alarm 0;
    my $t2 = time();
    my $t_diff=$t2-$t1;
    # without Time::HiRes, is only accurate to the second, and potentially not even that accurate
    ok($t_diff >= 1, "go() took $t_diff seconds, should take at least 1 second (hopefully, 2)");
    ok($t_diff <= 3, "go() took $t_diff seconds, should take no more than 3 seconds (hopefully, 2)");
    sub do_till_done(){
      return !$done;
    }
    sub set_done(){
      $done=1;
      return shift;
    }
    $mitm->timer_callback(2,\&do_till_done);
    $mitm->server_to_client_callback(\&set_done);
    $mitm->listen() unless $isWindows;
    my $client = Net::MitM->new_client("localhost",$port2);
    $client->name("Client 7-$port2");
    $client->send_to_server("ping");
    $mitm->timer_callback(.1,\&do_till_done);
    is(scalar(@{$mitm->{children}}),0,"no children yet"); # note - breaks encapsulation
    $mitm->go();
    is(scalar(@{$mitm->{children}}),1,"one child now"); # note - breaks encapsulation
    is($done,1,"do till done");
    my $resp = $client->read_from_server("ping");
    is($resp,"ping","round trip");
    $client->_destroy(); # TODO provide a user callable method? Would need to clean up children - if running in serial
    $mitm->go();
    is(scalar(@{$mitm->{children}}),0,"closing client should terminate children"); # note - breaks encapsulation
    $mitm->_destroy(); # here, we wait for MitM to exit - no need to kill it
  });
}

{
subtest('8. stop_when_idle'=>sub {
    print "8. stop_when_idle ------------------\n";
    my $port2=next_port("MitM 8");
    my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
    $mitm->name("MitM 8");
    $mitm->verbose(1);
    $mitm->stop_when_idle(1);
    is($mitm->stop_when_idle(1),1);
    alarm 5; # if something goes wrong, don't silently hang forever - user may still need to ^C, but at least tell them
    #$mitm->listen() unless $isWindows;
    #my $MitM_pid = run_in_background($mitm->{name},sub{$running_mitm = $mitm; $mitm->go(); exit});
    my $MitM_pid = run_in_background($mitm);
    my $client = Net::MitM->new_client("localhost",$port2);
    $client->name("Client 8");
    my $resp = $client->send_and_receive("mitm 8 says ping");
    is($resp,"mitm 8 says ping","round trip");
    $client->disconnect_from_server(); 
    #pause(.1) if $isWindows; # TODO Move this line into disconnect_from_server?
    pause(.1);
    my $client2 = Net::MitM->new_client("localhost",$port2); 
    my $resp2 = $client2->connect_to_server(); # should fail
    ok(!$resp2,"MitM shouldn't be accepting connections - it should have exited");
    alarm 0;
});
}

SKIP: {
  eval { use Time::HiRes qw(time sleep)};
  if($@){
    skip "Time::HiRes, which is not installed, is required for sub-second accuracy of timer_interval. You may still specify fractions of a second, MitM will out by up to a second each time, but it will average out. If this is not precise enough, please install Time::HiRes.\n";
  }
  my $iterations=10; # no need to go hard here
  my $to_go=$iterations;
  my $delay=0.02;
  subtest('9. timer_interval precision'=>sub {
  print "9. timer precision ------------------\n";
    my $port2=next_port("MitM 9");
    my $mitm = Net::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
    $mitm->name("mitm-$port2");
    #$mitm->timer_callback($long_timeout,\&dropout);
    #$mitm->verbose(2);
    sub do_til_done(){
      #print "done=$to_go\n";
      if(--$to_go>0){
	sleep($delay/2);
	return 1;
      }else{
	return 0;
      }
    }
    $mitm->timer_callback($delay,\&do_til_done);
    $mitm->name("mitm-$port2");
    my ($interval,$callback) = $mitm->timer_callback();
    is($interval,$delay);
    is($callback,\&do_til_done);
    my $t1 = time();
    $mitm->go();
    my $t2 = time();
    my $t_diff=$t2-$t1;
    # on my boxes, takes 10 iterations at .2 seconds takes ~2.00125 seconds on windows, ~2.00098 on linx. Allow +/- 0.1. It averages out over a long run.
    my $target=$delay*$iterations;
    ok($t_diff >= ($target-0.1) && $t_diff <= ($target+0.1), "go() took $t_diff seconds, should take close to $target seconds");
  });
}

# As of perl 5.14, on linux, a signal interrupts select(,,,) - causes it returns with an error. On windows, a signal seems to go completely missing if we are inside a select(,,,) call. Therefore, we use a 'back channel' to shutdown the echo server.

print ("Cleaning up\n",("-"x 72),"\n");
my $quit_client = Net::MitM->new_client("localhost",$echo_port);
$quit_client->name("quitter");
$quit_client->connect_to_server();
#my $netstat_before = `netstat | grep localhost:8 | sort`;
my $resp = $quit_client->send_and_receive("quit echo server");
#is($resp,undef,"server should quit");
pause(.1) if $isWindows;
$quit_client->_destroy();
pause(1) if $isWindows;
#my $netstat_after = `netstat | grep localhost:8 | sort`;
#is($netstat_after, $netstat_before, "all ports closed cleanly\n");
#my $lsof_after = `lsof -i |grep $$| sort`;
#is($lsof_after, $lsof_before, "all sockets closed cleanly\n");

#pause(.1); # let children exit - they should already have been signalled
#printf "Signalling echo server: %u\n",$echo_server_pid;
#print kill('TERM',$echo_server_pid) or warn "Failed to kill echo server\n";
#pause(.1); # let echo server die

#open(NEXT_PORT,">next_port.txt") or warn "Cannot open next_port.txt: $!";
#print NEXT_PORT $next_port or warn "Cannot write to next_port.txt: $!";

done_testing(); # not supported by old versions of Test::More

print (sprintf("Done %u\n",$$),("="x 72),"\n");
